import Foundation

/// DI-01 prototype vocabulary. This file is deliberately free of `Speech`,
/// `AVFAudio` and AppKit: it is the seam that lets the state machine be driven
/// deterministically by a fake, offline, on any macOS, while the real engine
/// (`SpeechAnalyzerDictationEngine`, app target, macOS 26+) stays swappable.
///
/// The engine owns audio capture AND recognition together, deliberately. Levels
/// for the waveform come from the same tap that feeds the recognizer, so there
/// is exactly one capture owner and the orange system microphone indicator can
/// never outlive a session (see `DictationCoordinator`).

/// Why a dictation session ended badly. Deliberately a closed, opaque
/// vocabulary: provider/engine error text can carry local context (device
/// names, file paths, locale identifiers), and the composer's existing
/// attachment-failure path already establishes that a UI-facing failure names a
/// CATEGORY and never the underlying error description.
public enum DictationFailure: String, Equatable, Sendable {
    case microphonePermissionDenied
    case speechPermissionDenied
    /// The host cannot run the transcriber at all — OS below the floor, or
    /// hardware the model does not support.
    case unsupportedOnThisDevice
    /// The locale's model is not installed and could not be installed.
    case assetsUnavailable
    case audioEngineFailed
    case recognizerFailed
}

/// One observation from a running engine.
public enum DictationEngineEvent: Equatable, Sendable {
    /// Capture and recognition are both live. The session may leave `preparing`.
    case ready
    /// Normalized 0...1 input level for the waveform, sampled from the tap.
    case level(Float)
    /// A volatile hypothesis. Replaces the whole provisional span; never
    /// persisted, never sendable.
    case volatile(String)
    /// A settled segment. Appended to committed text exactly once.
    case final(String)
    /// The engine has flushed everything it will ever emit.
    case finished
    case failed(DictationFailure)
}

@MainActor
public protocol DictationEngine: AnyObject {
    /// Acquire permissions and assets. May be slow (first-run model download).
    /// Throws `DictationFailure` only.
    func prepare() async throws
    /// Begin capture. Events arrive on the main actor.
    func start(emitting sink: @escaping @MainActor (DictationEngineEvent) -> Void) throws
    /// Graceful stop: flush pending finals, then emit `.finished`.
    func stop()
    /// Immediate stop: drop everything, emit nothing further.
    func cancel()
}

/// A fully deterministic engine for checks. Emits exactly what a test tells it
/// to, synchronously, with no audio hardware, no timers and no `Speech` import.
@MainActor
public final class FakeDictationEngine: DictationEngine {
    public enum PrepareOutcome: Equatable, Sendable {
        case succeeds
        case fails(DictationFailure)
        /// Never completes, so a check can observe `preparing` and cancel out of it.
        case hangs
    }

    public var prepareOutcome: PrepareOutcome = .succeeds
    /// Emitted automatically on `start`. Default mirrors a real engine.
    public var emitsReadyOnStart = true
    /// Emitted on `stop` after any queued finals. A check can suppress this to
    /// observe a stuck `finalizing`.
    public var emitsFinishedOnStop = true

    public private(set) var prepareCallCount = 0
    public private(set) var startCallCount = 0
    public private(set) var stopCallCount = 0
    public private(set) var cancelCallCount = 0
    /// True between `start` and whichever of `stop`/`cancel` arrives first. The
    /// hot-microphone assertion reads this.
    public private(set) var isCapturing = false

    private var sink: (@MainActor (DictationEngineEvent) -> Void)?

    public init() {}

    public func prepare() async throws {
        prepareCallCount += 1
        switch prepareOutcome {
        case .succeeds:
            return
        case .fails(let failure):
            throw failure
        case .hangs:
            // Suspends until the enclosing Task is cancelled, which is what
            // `DictationSession.cancel()` does to its prepare task.
            try await withTaskCancellationHandler {
                try await Task.sleep(nanoseconds: .max)
            } onCancel: {}
        }
    }

    public func start(emitting sink: @escaping @MainActor (DictationEngineEvent) -> Void) throws {
        startCallCount += 1
        self.sink = sink
        isCapturing = true
        if emitsReadyOnStart { sink(.ready) }
    }

    public func stop() {
        stopCallCount += 1
        isCapturing = false
        if emitsFinishedOnStop { sink?(.finished) }
    }

    public func cancel() {
        cancelCallCount += 1
        isCapturing = false
        sink = nil
    }

    // MARK: - Test drivers

    /// Push one event as if the real engine produced it.
    public func emit(_ event: DictationEngineEvent) { sink?(event) }

    public func emitVolatile(_ text: String) { emit(.volatile(text)) }
    public func emitFinal(_ text: String) { emit(.final(text)) }
    public func emitLevel(_ level: Float) { emit(.level(level)) }
    public func emitFailure(_ failure: DictationFailure) { emit(.failed(failure)) }
}

extension DictationFailure: Error {}
