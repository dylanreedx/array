import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOWebSocket
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationService

/// `GET /collaboration/v1/areas/<area>/cursor-stream`, upgraded to a WebSocket:
/// the device sends `PresenceInput` text frames, and receives its teammates'
/// `CursorLaneMessage`s as they arrive. Admission (bearer and active
/// membership) happens before the upgrade; the store re-checks on open and
/// closes the lane on revocation.
final class CollaborationCursorSocket: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    /// A frame is one cursor and viewport: a few hundred bytes.
    static let maximumFrameBytes = 2048

    struct Request { let area: UUID; let token: String }
    static func request(_ head: HTTPRequestHead) -> Request? {
        guard head.method == .GET else { return nil }
        let parts = head.uri.split(separator: "/")
        guard parts.count == 5, parts[0] == "collaboration", parts[1] == "v1", parts[2] == "areas", parts[4] == "cursor-stream",
              let area = UUID(uuidString: String(parts[3])),
              let header = head.headers.first(name: "authorization"), header.hasPrefix("Bearer ") else { return nil }
        return .init(area: area, token: String(header.dropFirst(7)))
    }

    private let store: CollaborationStore
    private let area: UUID
    private let token: String
    private var inbound: AsyncStream<Collaboration.PresenceInput>.Continuation?
    private var task: Task<Void, Never>?
    private var closing = false
    private let decoder = JSONDecoder()

    init(store: CollaborationStore, area: UUID, token: String) {
        self.store = store; self.area = area; self.token = token
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let (inputs, continuation) = AsyncStream<Collaboration.PresenceInput>.makeStream(bufferingPolicy: .bufferingNewest(64))
        inbound = continuation
        let box = CursorSocketContext(context), loop = context.eventLoop
        let store = store, area = area, token = token
        // A constant box, not a captured `weak self` var: child tasks may not
        // share a mutable capture (Swift 6.1 region isolation on Linux).
        let handler = CursorSocketHandlerRef(self)
        task = Task {
            let lane: (id: UUID, messages: AsyncStream<Collaboration.CursorLaneMessage>)
            do { lane = try await store.openCursorLane(token: token, area: area) }
            catch {
                loop.execute { handler.value?.close(box.context, code: .policyViolation) }
                return
            }
            await withTaskGroup(of: Void.self) { group in
                // One consumer keeps this device's frames in order.
                group.addTask { for await input in inputs { try? await store.streamCursor(lane.id, input: input) } }
                group.addTask {
                    let encoder = JSONEncoder()
                    for await message in lane.messages {
                        guard let data = try? encoder.encode(message) else { continue }
                        loop.execute { handler.value?.write(data, box.context) }
                    }
                    // The relay ended the lane (device or membership revoked).
                    loop.execute { handler.value?.close(box.context, code: .policyViolation) }
                }
                await group.next()
                group.cancelAll()
            }
            await store.closeCursorLane(lane.id)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var bytes = frame.unmaskedData
            guard frame.fin, bytes.readableBytes <= Self.maximumFrameBytes else { close(context, code: .messageTooLarge); return }
            guard let data = bytes.readData(length: bytes.readableBytes),
                  let input = try? decoder.decode(Collaboration.PresenceInput.self, from: data) else {
                close(context, code: .unacceptableData); return
            }
            inbound?.yield(input)
        case .ping:
            guard context.channel.isActive else { return }
            context.writeAndFlush(wrapOutboundOut(.init(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        case .connectionClose:
            close(context, code: .normalClosure)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        inbound?.finish(); inbound = nil
        task?.cancel(); task = nil
        context.fireChannelInactive()
    }

    private func write(_ data: Data, _ context: ChannelHandlerContext) {
        // A reader that cannot keep up skips frames; the next one supersedes them.
        guard context.channel.isActive, context.channel.isWritable, !closing else { return }
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.writeAndFlush(wrapOutboundOut(.init(fin: true, opcode: .text, data: buffer)), promise: nil)
    }

    private func close(_ context: ChannelHandlerContext, code: WebSocketErrorCode) {
        guard !closing else { return }
        closing = true
        inbound?.finish(); inbound = nil
        guard context.channel.isActive else { return }
        var buffer = context.channel.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: code)
        let box = CursorSocketContext(context)
        context.writeAndFlush(wrapOutboundOut(.init(fin: true, opcode: .connectionClose, data: buffer))).whenComplete { _ in
            box.context.close(promise: nil)
        }
    }
}

private final class CursorSocketContext: @unchecked Sendable {
    let context: ChannelHandlerContext
    init(_ context: ChannelHandlerContext) { self.context = context }
}

private final class CursorSocketHandlerRef: @unchecked Sendable {
    weak var value: CollaborationCursorSocket?
    init(_ value: CollaborationCursorSocket) { self.value = value }
}
