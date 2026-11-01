import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ContinuumRevivedCollaborationProtocol

/// The device's end of an area's cursor lane (a WebSocket on the relay). Send
/// this device's positions; read teammates' as they arrive. `messages`
/// finishes when the connection ends, for any reason.
public final class CollaborationCursorLaneClient: @unchecked Sendable {
    public let messages: AsyncStream<Collaboration.CursorLaneMessage>
    #if !canImport(FoundationNetworking)
    private let task: URLSessionWebSocketTask
    private let encoder = JSONEncoder()

    init(task: URLSessionWebSocketTask) {
        self.task = task
        let (messages, continuation) = AsyncStream<Collaboration.CursorLaneMessage>.makeStream(bufferingPolicy: .bufferingNewest(64))
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
                if let value = try? decoder.decode(Collaboration.CursorLaneMessage.self, from: data) { continuation.yield(value) }
            }
            continuation.finish()
        }
    }
    public func send(_ input: Collaboration.PresenceInput) async throws {
        let data = try encoder.encode(input)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
    public func close() { task.cancel(with: .goingAway, reason: nil) }
    #else
    init() { messages = AsyncStream { $0.finish() } }
    public func send(_ input: Collaboration.PresenceInput) async throws { throw CollaborationClientError.server(status: 501, code: "cursorLaneUnavailable") }
    public func close() {}
    #endif
}

extension CollaborationAPI {
    /// Opens the area's cursor lane. Throws `.server(status:code:)` with the
    /// relay's HTTP status when it refuses the upgrade — 404 from a relay that
    /// predates the lane or for a non-member — so a caller can stop retrying
    /// and keep using update pages.
    public func openCursorLane(area: UUID) async throws -> CollaborationCursorLaneClient {
        #if canImport(FoundationNetworking)
        throw CollaborationClientError.server(status: 501, code: "cursorLaneUnavailable")
        #else
        guard var components = URLComponents(url: baseURL.appendingPathComponent("areas/\(area)/cursor-stream"), resolvingAgainstBaseURL: false)
        else { throw CollaborationClientError.invalidEndpoint }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { throw CollaborationClientError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let credential { request.setValue("Bearer \(credential)", forHTTPHeaderField: "authorization") }
        let task = session.webSocketTask(with: request)
        task.resume()
        // A ping round trip proves the upgrade happened and the lane is open.
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                task.sendPing { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            task.cancel()
            if let status, status != 101 { throw CollaborationClientError.server(status: status, code: "cursorLaneRefused") }
            throw error
        }
        return CollaborationCursorLaneClient(task: task)
        #endif
    }
}
