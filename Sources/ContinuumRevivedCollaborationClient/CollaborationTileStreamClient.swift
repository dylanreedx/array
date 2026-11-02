import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ContinuumRevivedCollaborationProtocol

/// The device's end of a shared terminal's stream lane (a WebSocket on the
/// relay, `.plans/114-terminal-sharing`). The owner's host sends frames; a
/// watcher reads them. `messages` finishes when the connection ends.
public final class CollaborationTileStreamClient: @unchecked Sendable {
    public let messages: AsyncStream<Collaboration.LiveTile.StreamMessage>
    #if !canImport(FoundationNetworking)
    private let task: URLSessionWebSocketTask
    private let encoder = JSONEncoder()

    init(task: URLSessionWebSocketTask) {
        self.task = task
        let (messages, continuation) = AsyncStream<Collaboration.LiveTile.StreamMessage>.makeStream(bufferingPolicy: .bufferingNewest(512))
        self.messages = messages
        Task {
            let decoder = JSONDecoder()
            while true {
                let message: URLSessionWebSocketTask.Message
                do { message = try await task.receive() } catch { break }
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let value): data = value
                @unknown default: continue
                }
                if let value = try? decoder.decode(Collaboration.LiveTile.StreamMessage.self, from: data) { continuation.yield(value) }
            }
            continuation.finish()
        }
    }
    public func send(_ frame: Collaboration.LiveTile.TerminalFrame) async throws {
        let data = try encoder.encode(Collaboration.LiveTile.StreamMessage(frame: frame))
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
    public func close() { task.cancel(with: .goingAway, reason: nil) }
    #else
    init() { messages = AsyncStream { $0.finish() } }
    public func send(_ frame: Collaboration.LiveTile.TerminalFrame) async throws { throw CollaborationClientError.server(status: 501, code: "tileStreamUnavailable") }
    public func close() {}
    #endif
}

extension CollaborationAPI {
    /// Opens a shared tile's stream lane. Throws `.server(status:code:)` with
    /// the relay's HTTP status when it refuses the upgrade: 404 from a relay
    /// that predates the lane, or for a non-member. A caller then stays on
    /// the state lane.
    public func openTileStream(area: UUID, object: UUID) async throws -> CollaborationTileStreamClient {
        #if canImport(FoundationNetworking)
        throw CollaborationClientError.server(status: 501, code: "tileStreamUnavailable")
        #else
        guard var components = URLComponents(url: baseURL.appendingPathComponent("areas/\(area)/tiles/\(object)/stream"), resolvingAgainstBaseURL: false)
        else { throw CollaborationClientError.invalidEndpoint }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { throw CollaborationClientError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let credential { request.setValue("Bearer \(credential)", forHTTPHeaderField: "authorization") }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20
        task.resume()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                task.sendPing { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            task.cancel()
            if let status, status != 101 { throw CollaborationClientError.server(status: status, code: "tileStreamRefused") }
            throw error
        }
        return CollaborationTileStreamClient(task: task)
        #endif
    }
}
