import Foundation

/// Correlates native completion, never application success. Kept internal until
/// the workspace ownership/grant/observation layer can safely expose actions.
@MainActor
final class IOSPreviewActionChannel {
    enum Failure: Error, Equatable {
        case rejected
        /// Dispatch may have happened. The caller must observe; never replay.
        case outcomeUnknown
    }
    private struct Reply: Decodable {
        let requestID: Int
        let outcome: String
    }
    private struct Pending {
        let id: Int
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: Pending?
    private var nextID = 0
    private var closed = false
    var onUncertain: (() -> Void)?

    func perform(timeout: TimeInterval = 5, transmit: (Int) -> Bool) async throws {
        guard !closed, pending == nil, timeout.isFinite, timeout > 0, timeout <= 5,
              nextID < 9_007_199_254_740_991 else { throw Failure.rejected }
        try Task.checkCancellation()
        nextID += 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.uncertain(id: id)
                }
                pending = Pending(id: id, continuation: continuation, timeout: timer)
                if !transmit(id) { finish(.failure(Failure.rejected)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.uncertain(id: id) }
        }
    }

    /// Returns true only for the internal correlated protocol. Legacy human
    /// input errors continue through the existing preview failure path.
    func receive(tag: UInt8, body: Data) -> Bool {
        guard tag == 0x84 || tag == 0x91 else { return false }
        guard !closed else { return true }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: body) else {
            if tag == 0x84 { invalidate(); onUncertain?(); return true }
            return false
        }
        guard reply.requestID == pending?.id else { return true } // late reply
        if tag == 0x84, reply.outcome == "native_sequence_completed" {
            finish(.success(()))
        } else if tag == 0x91, reply.outcome == "rejected" {
            finish(.failure(Failure.rejected))
        } else {
            uncertain(id: reply.requestID)
        }
        return true
    }

    /// Stopping/disconnecting after admission cannot prove that input did not
    /// reach the simulator. All waiters settle once, even if a late ack arrives.
    func invalidate() {
        closed = true
        finish(.failure(Failure.outcomeUnknown))
    }
    private func uncertain(id: Int) {
        guard pending?.id == id else { return }
        invalidate()
        onUncertain?()
    }
    private func finish(_ result: Result<Void, Error>) {
        let previous = pending; pending = nil
        previous?.timeout.cancel()
        previous?.continuation.resume(with: result)
    }
}
