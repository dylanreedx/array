import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOWebSocket
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationService

/// `GET /collaboration/v1/areas/<area>/tiles/<object>/stream`, upgraded to a
/// WebSocket: a shared terminal's frames (`.plans/114-terminal-sharing`). The
/// owner's host sends `StreamMessage` frames; every other member receives
/// them as they arrive. Admission (bearer, membership, a live tile the area
/// holds) happens before the upgrade; the store re-checks on open and closes
/// the lane when any of them goes.
final class CollaborationTileStreamSocket: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    /// A frame's bytes in base64 and its envelope.
    static let maximumFrameBytes = 256 * 1024

    struct Request { let area: UUID; let object: UUID; let token: String }
    static func request(_ head: HTTPRequestHead) -> Request? {
        guard head.method == .GET else { return nil }
        let parts = head.uri.split(separator: "/")
        guard parts.count == 7, parts[0] == "collaboration", parts[1] == "v1", parts[2] == "areas", parts[4] == "tiles", parts[6] == "stream",
              let area = UUID(uuidString: String(parts[3])), let object = UUID(uuidString: String(parts[5])),
              let header = head.headers.first(name: "authorization"), header.hasPrefix("Bearer ") else { return nil }
        return .init(area: area, object: object, token: String(header.dropFirst(7)))
    }

    private let store: CollaborationStore
    private let request: Request
    private var inbound: AsyncStream<Collaboration.LiveTile.TerminalFrame>.Continuation?
    private var task: Task<Void, Never>?
    private var closing = false
    private let decoder = JSONDecoder()

    init(store: CollaborationStore, request: Request) {
        self.store = store; self.request = request
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let (inputs, continuation) = AsyncStream<Collaboration.LiveTile.TerminalFrame>.makeStream(bufferingPolicy: .bufferingNewest(256))
        inbound = continuation
        let box = TileStreamSocketContext(context), loop = context.eventLoop
        let store = store, request = request
        let handler = TileStreamSocketHandlerRef(self)
        task = Task {
            let lane: (id: UUID, sends: Bool, messages: AsyncStream<Collaboration.LiveTile.StreamMessage>)
            do { lane = try await store.openTileStream(token: request.token, area: request.area, object: request.object) }
            catch {
                loop.execute { handler.value?.close(box.context, code: .policyViolation) }
                return
            }
            await withTaskGroup(of: Void.self) { group in
                // One consumer keeps the host's frames in order.
                group.addTask {
                    for await frame in inputs {
                        do { try await store.streamTileFrame(lane.id, frame: frame) }
                        catch { loop.execute { handler.value?.close(box.context, code: .policyViolation) }; return }
                    }
                }
                group.addTask {
                    let encoder = JSONEncoder()
                    for await message in lane.messages {
                        guard let data = try? encoder.encode(message) else { continue }
                        loop.execute { handler.value?.write(data, box.context) }
                    }
                    loop.execute { handler.value?.close(box.context, code: .policyViolation) }
                }
                await group.next()
                group.cancelAll()
            }
            await store.closeTileStream(lane.id)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var bytes = frame.unmaskedData
            guard frame.fin, bytes.readableBytes <= Self.maximumFrameBytes else { close(context, code: .messageTooLarge); return }
            guard let data = bytes.readData(length: bytes.readableBytes),
                  let message = try? decoder.decode(Collaboration.LiveTile.StreamMessage.self, from: data), let value = message.frame else {
                close(context, code: .unacceptableData); return
            }
            inbound?.yield(value)
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
        // A watcher that cannot keep up skips frames; it sees the gap and
        // takes the newest screen from the state lane.
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
        let box = TileStreamSocketContext(context)
        context.writeAndFlush(wrapOutboundOut(.init(fin: true, opcode: .connectionClose, data: buffer))).whenComplete { _ in
            box.context.close(promise: nil)
        }
    }
}

private final class TileStreamSocketContext: @unchecked Sendable {
    let context: ChannelHandlerContext
    init(_ context: ChannelHandlerContext) { self.context = context }
}

private final class TileStreamSocketHandlerRef: @unchecked Sendable {
    weak var value: CollaborationTileStreamSocket?
    init(_ value: CollaborationTileStreamSocket) { self.value = value }
}
