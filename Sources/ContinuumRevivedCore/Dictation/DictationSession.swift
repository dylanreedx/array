import Foundation

/// The six presentation states DI-01 specifies. `cancel` is deliberately NOT a
/// state — it is a command that lands in `.idle` from anywhere. Modelling it as
/// a state would make "cancelled" observable after the fact, and the whole point
/// of cancel is that it leaves no trace.
public enum DictationState: Equatable, Sendable {
    case idle
    /// Permissions and assets are being acquired. May last minutes on a first
    /// run that has to download a model, so this state is explicitly visible.
    case preparing
    case listening
    /// `stop` has been requested; the engine is flushing its last finals.
    case finalizing
    case error(DictationFailure)

    /// True while the session owns the microphone or is about to.
    public var isActive: Bool {
        switch self {
        case .idle, .error: return false
        case .preparing, .listening, .finalizing: return true
        }
    }
}

/// How a session stopped being active. A host persists on `.completed` and
/// removes the session's whole inserted range on `.cancelled`.
public enum DictationOutcome: Equatable, Sendable {
    /// `stop()` ran to completion. `text` is everything the session settled.
    case completed(text: String)
    /// `cancel()`. The session leaves no trace; the host withdraws the entire
    /// range it inserted, which is also exactly one undo step.
    case cancelled
    case failed(DictationFailure)
}

/// The pure dictation state machine.
///
/// Owns no text storage, no view and no draft store. It reports what the text
/// SHOULD be — `committedText` (settled within this session) and
/// `provisionalText` (a hypothesis that may still change) — and the host applies
/// that to whatever editor it owns. That split is the whole design:
///
/// - `onProvisionalChange` fires many times per second and must NEVER reach
///   persistence. Routing volatile results through the composer's
///   `publishDraftChange()` would issue one disk write per partial.
/// - `onCommit` means "settled — put this in the editor". It deliberately does
///   NOT mean "persist now": `cancel()` withdraws committed text too, so a host
///   that persisted per-commit would disagree with the session about what
///   survived. Persist on `onSessionEnd(.completed)` and only there.
/// - Nothing here can send. Submission stays exactly where it is today: the
///   composer's Return policy and the tile's action button.
@MainActor
public final class DictationSession {
    public private(set) var state: DictationState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// Settled text produced by this session, in order.
    public private(set) var committedText: String = ""
    /// The current hypothesis. Replaced wholesale by each volatile result.
    public private(set) var provisionalText: String = ""

    public var onStateChange: ((DictationState) -> Void)?
    /// Fires on every volatile result. Never persist this.
    public var onProvisionalChange: ((String) -> Void)?
    /// Fires once per settled segment. Apply it to the editor; do NOT persist
    /// on it — see `onSessionEnd`.
    public var onCommit: ((String) -> Void)?
    /// The one place a host learns a session is over and how. Persist on
    /// `.completed`; withdraw the whole inserted range on `.cancelled`.
    public var onSessionEnd: ((DictationOutcome) -> Void)?
    /// Normalized 0...1 input level for the waveform.
    public var onLevel: ((Float) -> Void)?

    /// True while a hypothesis is on screen. The composer's send policy reads
    /// this the same way it already reads `hasMarkedText()`: text an input
    /// source still owns must not be submittable.
    public var hasProvisionalText: Bool { !provisionalText.isEmpty }

    private let engine: any DictationEngine
    private var prepareTask: Task<Void, Never>?
    /// Bumped by every start/cancel/stop. An event carrying a stale generation
    /// belongs to an engine we have already abandoned and is dropped.
    private var generation: UInt64 = 0

    public init(engine: any DictationEngine) {
        self.engine = engine
    }

    // MARK: - Commands

    /// Legal from `.idle` and `.error` only. Returns false when refused, so a
    /// check can assert that a second start cannot open a second capture.
    @discardableResult
    public func start() -> Bool {
        switch state {
        case .idle, .error:
            break
        case .preparing, .listening, .finalizing:
            return false
        }

        generation &+= 1
        let generation = self.generation
        committedText = ""
        provisionalText = ""
        state = .preparing

        prepareTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.engine.prepare()
                guard !Task.isCancelled, self.generation == generation else { return }
                try self.engine.start { [weak self] event in
                    self?.handle(event, generation: generation)
                }
            } catch is CancellationError {
                return
            } catch let failure as DictationFailure {
                guard self.generation == generation else { return }
                self.fail(failure)
            } catch {
                guard self.generation == generation else { return }
                self.fail(.recognizerFailed)
            }
        }
        return true
    }

    /// Graceful finish. Legal from `.listening` only.
    @discardableResult
    public func stop() -> Bool {
        guard state == .listening else { return false }
        state = .finalizing
        engine.stop()
        return true
    }

    /// Abandon everything. Legal from any state; a no-op in `.idle`.
    ///
    /// Guarantees on return: the engine is no longer capturing, the provisional
    /// span has been withdrawn, and NOTHING has been committed — so a host that
    /// wired `onCommit` to its draft store has written nothing.
    @discardableResult
    public func cancel() -> Bool {
        guard state != .idle else { return false }
        generation &+= 1
        prepareTask?.cancel()
        prepareTask = nil
        engine.cancel()
        withdrawProvisional()
        committedText = ""
        state = .idle
        onSessionEnd?(.cancelled)
        return true
    }

    /// The user typed while dictation was live.
    ///
    /// The hypothesis is promoted to committed text and the span re-anchors, so
    /// a later volatile result can never reach back across what the user just
    /// wrote. Silently continuing to replace the provisional span is the defect
    /// this exists to prevent.
    public func userDidEdit() {
        guard state == .listening, !provisionalText.isEmpty else { return }
        let settled = provisionalText
        provisionalText = ""
        onProvisionalChange?("")
        commit(settled)
    }

    // MARK: - Engine events

    private func handle(_ event: DictationEngineEvent, generation: UInt64) {
        // Stale engine, or a session already torn down. Dropping here is what
        // makes rebind/close safe: a late buffer cannot resurrect a dead session.
        guard generation == self.generation, state.isActive else { return }

        switch event {
        case .ready:
            guard state == .preparing else { return }
            state = .listening

        case .level(let level):
            guard state == .listening else { return }
            onLevel?(min(max(level, 0), 1))

        case .volatile(let text):
            guard state == .listening else { return }
            provisionalText = text
            onProvisionalChange?(text)

        case .final(let text):
            guard state == .listening || state == .finalizing else { return }
            if !provisionalText.isEmpty {
                provisionalText = ""
                onProvisionalChange?("")
            }
            commit(text)

        case .finished:
            guard state == .finalizing else { return }
            withdrawProvisional()
            state = .idle
            onSessionEnd?(.completed(text: committedText))

        case .failed(let failure):
            fail(failure)
        }
    }

    // MARK: - Helpers

    private func commit(_ text: String) {
        guard !text.isEmpty else { return }
        committedText += text
        onCommit?(text)
    }

    private func withdrawProvisional() {
        guard !provisionalText.isEmpty else { return }
        provisionalText = ""
        onProvisionalChange?("")
    }

    /// A failure withdraws the hypothesis but KEEPS text already committed: the
    /// user said those words and they were settled. Only `cancel` discards.
    private func fail(_ failure: DictationFailure) {
        prepareTask?.cancel()
        prepareTask = nil
        engine.cancel()
        withdrawProvisional()
        state = .error(failure)
        onSessionEnd?(.failed(failure))
    }
}

/// Process-wide guarantee that at most one session is non-`.idle`.
///
/// Array is a canvas with N agent tiles, each owning a composer. Without this,
/// starting dictation in a second tile opens a second microphone tap while the
/// first is still live. Keyed adoption reuses the composer's existing
/// binding-generation identity rather than inventing a second one.
@MainActor
public final class DictationCoordinator {
    public static let shared = DictationCoordinator()

    private weak var activeSession: DictationSession?

    public init() {}

    /// Cancels whatever was running and makes `session` the sole owner.
    public func adopt(_ session: DictationSession) {
        if let activeSession, activeSession !== session {
            activeSession.cancel()
        }
        activeSession = session
    }

    /// Called by a host on focus loss, rebind, or tile close.
    public func relinquish(_ session: DictationSession) {
        guard activeSession === session else { return }
        session.cancel()
        activeSession = nil
    }

    public var activeSessionForQA: DictationSession? { activeSession }
}
