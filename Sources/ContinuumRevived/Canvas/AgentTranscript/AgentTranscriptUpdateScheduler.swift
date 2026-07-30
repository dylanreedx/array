import AppKit
import ContinuumRevivedAgentContent

/// Main-thread visual update gate. Streaming producers may submit many semantic
/// snapshots, but the list is presented at most once per display interval.
@MainActor
final class AgentTranscriptUpdateScheduler {
    static let maximumVisualUpdatesPerSecond = 30
    private let interval: TimeInterval = 1.0 / 30.0
    private var timer: Timer?
    private var pending: (() -> Void)?
    private(set) var visualApplyCount = 0

    func schedule(_ update: @escaping () -> Void, final: Bool = false) {
        pending = update // latest snapshot wins; semantic source remains authoritative
        if ProcessInfo.processInfo.environment["CONTINUUM_P3_11_NEGATIVE_WITNESS"] == "1" {
            // Deterministic fault injection: recreates one visual apply per token
            // so the 5,000-delta geometry bound must fail red.
            flush()
        } else if final {
            flush()
        } else {
            armTimer()
        }
    }

    func flush() {
        timer?.invalidate()
        timer = nil
        guard let update = pending else { return }
        pending = nil
        visualApplyCount += 1
        update()
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        pending = nil
    }

    private func armTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timer = nil
                self?.flush()
            }
        }
    }
}
