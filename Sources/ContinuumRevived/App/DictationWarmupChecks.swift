import AppKit
import Foundation

// 0.7.56 regression: the mic pre-warm task called `prepare()`, which waits for
// the in-flight warm-up, which was that same task. Nothing ever finished, so a
// press after a pre-warm sat on "Getting ready…" forever. This drives the real
// prewarm -> press handoff with a fake cold prepare (`qaColdDelay`) and requires
// the press to return promptly, with the warm analyzer adopted.
extension AppDelegate {
    @MainActor
    static func runDictationWarmupSelfCheck() throws -> String {
        struct Failure: Error, CustomStringConvertible { let description: String }
        guard #available(macOS 26, *) else { return "skipped: needs macOS 26" }
        SpeechAnalyzerDictationEngine.qaColdDelay = .milliseconds(300)
        defer { SpeechAnalyzerDictationEngine.qaColdDelay = nil }

        SpeechAnalyzerDictationEngine.prewarm()
        let engine = SpeechAnalyzerDictationEngine()
        var finished: Result<Void, Error>?
        let started = Date()
        Task { @MainActor in
            do { try await engine.prepare(); finished = .success(()) } catch { finished = .failure(error) }
        }
        while finished == nil, Date().timeIntervalSince(started) < 2 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let elapsed = Date().timeIntervalSince(started)
        guard let outcome = finished else {
            throw Failure(description: "dictation warm-up: press still preparing after 2s with a warm-up in flight (deadlock)")
        }
        if case .failure(let error) = outcome { throw Failure(description: "dictation warm-up: press failed: \(error)") }
        return "press after pre-warm returned in \(Int(elapsed * 1000))ms"
    }
}
