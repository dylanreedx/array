import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// What the composer gives dictation so it can edit the draft without the
/// draft store seeing every hypothesis.
@MainActor
protocol ComposerDictationHost: AnyObject {
    var dictationTextView: ComposerTextView { get }
    /// Runs `edit` with draft publishing suppressed and the edit marked as
    /// dictation's own, so the composer does not mistake it for typing.
    func performDictationEdit(_ edit: () -> Void)
    func dictationStateDidChange(_ state: DictationState)
    func dictationLevelDidChange(_ level: Float)
    func dictationPreparationDidChange(downloadingModel: Bool)
    /// Once per session, after the text is final: the one place the draft is
    /// persisted (DI-01).
    func dictationSessionDidEnd(_ outcome: DictationOutcome)
}

/// Binds one `DictationSession` to one composer editor.
///
/// The session reports what the text should be; this applies it to the
/// editor. Three ranges matter, all UTF-16 offsets into the text storage:
///
/// - `ownedStart..<anchor` — settled text this session inserted since the user
///   last touched the editor. Esc takes back exactly this.
/// - `anchor..<anchor + provisionalLength` — the live hypothesis, drawn in the
///   secondary text colour through a temporary attribute (never stored, never
///   copied, never persisted).
/// - Everything else belongs to the user and is never edited here.
///
/// When the user types, pastes or moves the caret mid-session, what is on
/// screen becomes theirs (`userDidTouchText`) and dictation carries on from the
/// new caret, so a later hypothesis can never reach back across their edit.
@MainActor
final class ComposerDictationController {
    /// Checks swap in a `FakeDictationEngine`. Production builds the on-device
    /// engine on macOS 26 and later; below that there is no engine and the
    /// composer offers no dictation at all.
    static var qaEngineFactory: (@MainActor () -> any DictationEngine)?
    /// Where the Settings toggle is read. Checks point this at a suite: they
    /// must never touch the real defaults domain.
    static var defaults: UserDefaults = .standard

    /// Offered on this Mac and turned on in Settings.
    static var isOffered: Bool { isAvailable && DictationConfig.isEnabled(defaults: defaults) }

    static var isAvailable: Bool {
        if qaEngineFactory != nil { return true }
        if #available(macOS 26, *) { return true }
        return false
    }

    private static func makeEngine() -> (any DictationEngine)? {
        if let qaEngineFactory { return qaEngineFactory() }
        if #available(macOS 26, *) { return SpeechAnalyzerDictationEngine() }
        return nil
    }

    private weak var host: ComposerDictationHost?
    private var session: DictationSession?
    private var engine: (any DictationEngine)?
    private(set) var state: DictationState = .idle
    private var ownedStart = 0
    private var anchor = 0
    private var provisionalLength = 0
    /// Set while the session promotes an on-screen hypothesis the user has
    /// already adopted: the text is physically there, so nothing is edited.
    private var absorbing = false
    /// The user edited during finalizing. The session will still deliver its
    /// last segments, but the place they were meant for is gone.
    private var ignoresRemainingText = false
    private var preparationPoll: Timer?

    init(host: ComposerDictationHost) {
        self.host = host
    }

    var isActive: Bool { state.isActive }
    var hasProvisionalText: Bool { provisionalLength > 0 }
    var qaProvisionalRange: NSRange? {
        provisionalLength > 0 ? NSRange(location: anchor, length: provisionalLength) : nil
    }

    // MARK: - Commands

    /// ⇧⌘D and the mic button: start, finish, or abandon a session that has
    /// not started listening yet.
    func toggle() {
        switch state {
        case .idle, .error: start()
        case .listening: finish()
        case .preparing: cancel()
        case .finalizing: break
        }
    }

    @discardableResult
    func start() -> Bool {
        guard !state.isActive, let host, let engine = Self.makeEngine() else { return false }
        let textView = host.dictationTextView
        // Dictation never replaces a selection: it collapses to the selection's
        // end and inserts there, so nothing the user wrote is lost to a stray
        // highlight.
        let selection = textView.selectedRange()
        anchor = NSMaxRange(selection)
        ownedStart = anchor
        provisionalLength = 0
        ignoresRemainingText = false
        if selection.length > 0 {
            host.performDictationEdit { textView.setSelectedRange(NSRange(location: anchor, length: 0)) }
        }

        let session = DictationSession(engine: engine)
        session.onStateChange = { [weak self] state in self?.sessionStateDidChange(state) }
        session.onProvisionalChange = { [weak self] text in self?.showProvisional(text) }
        session.onCommit = { [weak self] text in self?.insertSettled(text) }
        session.onLevel = { [weak self] level in self?.host?.dictationLevelDidChange(level) }
        session.onSessionEnd = { [weak self] outcome in self?.sessionDidEnd(outcome) }
        self.session = session
        self.engine = engine
        DictationCoordinator.shared.adopt(session)
        return session.start()
    }

    /// Return, ⇧⌘D, the mic button, focus leaving the editor: keep the words.
    func finish() {
        switch state {
        case .listening: session?.stop()
        case .preparing: cancel()
        case .idle, .finalizing, .error: break
        }
    }

    /// Esc, tile close, rebind: leave the draft as it was before this session
    /// (or before the user's last edit, which made earlier words theirs).
    func cancel() {
        guard let session, state.isActive else { return }
        session.cancel()
    }

    /// The user typed, pasted, deleted or moved the caret while a session was
    /// live. What is on screen is now theirs.
    func userDidTouchText() {
        guard let session, let host, state.isActive else { return }
        clearProvisionalStyle()
        if state == .listening {
            absorbing = true
            session.userDidEdit()
            absorbing = false
        } else if state == .finalizing {
            ignoresRemainingText = true
        }
        provisionalLength = 0
        anchor = NSMaxRange(host.dictationTextView.selectedRange())
        ownedStart = anchor
    }

    /// An undo is about to run. The hypothesis is not in the undo history, so
    /// it has to leave the text first or every recorded range is off by its
    /// length.
    func undoWillRun() {
        guard provisionalLength > 0 else { return }
        removeProvisional()
    }

    // MARK: - Session events

    private func sessionStateDidChange(_ newState: DictationState) {
        state = newState
        if newState == .preparing {
            startPreparationPoll()
        } else {
            stopPreparationPoll()
        }
        host?.dictationStateDidChange(newState)
    }

    private func showProvisional(_ text: String) {
        if absorbing || ignoresRemainingText {
            provisionalLength = 0
            return
        }
        guard let host else { return }
        let textView = host.dictationTextView
        guard let storage = textView.textStorage else { return }
        let range = NSRange(location: anchor, length: provisionalLength)
        guard NSMaxRange(range) <= storage.length else { return reanchorAtCaret() }
        let display = text.isEmpty ? "" : spaced(text, at: anchor, in: storage)
        host.performDictationEdit {
            // The hypothesis is not an edit the user can undo: it is replaced
            // several times a second and withdrawn before every settled insert.
            textView.undoManager?.disableUndoRegistration()
            defer { textView.undoManager?.enableUndoRegistration() }
            guard textView.shouldChangeText(in: range, replacementString: display) else { return }
            storage.replaceCharacters(in: range, with: NSAttributedString(string: display, attributes: textView.typingAttributes))
            textView.didChangeText()
            provisionalLength = (display as NSString).length
            textView.setSelectedRange(NSRange(location: anchor + provisionalLength, length: 0))
        }
        applyProvisionalStyle()
    }

    private func insertSettled(_ text: String) {
        guard !absorbing, !ignoresRemainingText, let host else { return }
        let textView = host.dictationTextView
        guard let storage = textView.textStorage else { return }
        if provisionalLength > 0 { removeProvisional() }
        guard anchor <= storage.length else { return reanchorAtCaret() }
        let display = spaced(text, at: anchor, in: storage)
        let range = NSRange(location: anchor, length: 0)
        host.performDictationEdit {
            // One undo step per settled phrase, like a burst of typing.
            textView.breakUndoCoalescing()
            guard textView.shouldChangeText(in: range, replacementString: display) else { return }
            storage.replaceCharacters(in: range, with: NSAttributedString(string: display, attributes: textView.typingAttributes))
            textView.didChangeText()
            textView.undoManager?.setActionName("Dictation")
            textView.breakUndoCoalescing()
            anchor += (display as NSString).length
            textView.setSelectedRange(NSRange(location: anchor, length: 0))
        }
    }

    private func sessionDidEnd(_ outcome: DictationOutcome) {
        stopPreparationPoll()
        if provisionalLength > 0 { removeProvisional() }
        if case .cancelled = outcome { withdrawOwnedText() }
        clearProvisionalStyle()
        session = nil
        engine = nil
        ignoresRemainingText = false
        host?.dictationSessionDidEnd(outcome)
    }

    // MARK: - Text helpers

    private func removeProvisional() {
        guard let host, let storage = host.dictationTextView.textStorage else { return }
        let textView = host.dictationTextView
        let range = NSRange(location: anchor, length: provisionalLength)
        provisionalLength = 0
        clearProvisionalStyle()
        guard NSMaxRange(range) <= storage.length else { return }
        host.performDictationEdit {
            textView.undoManager?.disableUndoRegistration()
            defer { textView.undoManager?.enableUndoRegistration() }
            guard textView.shouldChangeText(in: range, replacementString: "") else { return }
            storage.replaceCharacters(in: range, with: "")
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: anchor, length: 0))
        }
    }

    private func withdrawOwnedText() {
        guard let host, let storage = host.dictationTextView.textStorage else { return }
        let textView = host.dictationTextView
        let range = NSRange(location: ownedStart, length: max(0, anchor - ownedStart))
        anchor = ownedStart
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        host.performDictationEdit {
            // Undoable, so a mistaken Esc can be taken back with ⌘Z.
            textView.breakUndoCoalescing()
            guard textView.shouldChangeText(in: range, replacementString: "") else { return }
            storage.replaceCharacters(in: range, with: "")
            textView.didChangeText()
            textView.undoManager?.setActionName("Discard Dictation")
            textView.breakUndoCoalescing()
            textView.setSelectedRange(NSRange(location: ownedStart, length: 0))
        }
    }

    /// A space before dictated words that would otherwise run into the
    /// preceding text. The engine already spaces its own segments apart.
    private func spaced(_ text: String, at location: Int, in storage: NSTextStorage) -> String {
        guard location > 0, let first = text.unicodeScalars.first,
              !CharacterSet.whitespacesAndNewlines.contains(first),
              !CharacterSet(charactersIn: ".,;:!?)]}").contains(first) else { return text }
        let previous = (storage.string as NSString).character(at: location - 1)
        guard let scalar = Unicode.Scalar(previous),
              !CharacterSet.whitespacesAndNewlines.contains(scalar),
              !CharacterSet(charactersIn: "([{/").contains(scalar) else { return text }
        return " " + text
    }

    private func reanchorAtCaret() {
        guard let host else { return }
        provisionalLength = 0
        anchor = NSMaxRange(host.dictationTextView.selectedRange())
        ownedStart = anchor
    }

    private func applyProvisionalStyle() {
        guard let host, provisionalLength > 0 else { return }
        let textView = host.dictationTextView
        guard let layoutManager = textView.layoutManager else { return }
        let color = TextToken.textSecondary.color.nsColor(for: textView.effectiveTokenTheme)
        layoutManager.addTemporaryAttribute(
            .foregroundColor, value: color,
            forCharacterRange: NSRange(location: anchor, length: provisionalLength))
    }

    private func clearProvisionalStyle() {
        guard let textView = host?.dictationTextView, let layoutManager = textView.layoutManager,
              let length = textView.textStorage?.length, length > 0 else { return }
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
    }

    /// Refreshes the hypothesis colour after an appearance change.
    func restyle() {
        clearProvisionalStyle()
        applyProvisionalStyle()
    }

    // MARK: - First-run model download

    private func startPreparationPoll() {
        stopPreparationPoll()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPreparation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        preparationPoll = timer
    }

    private func stopPreparationPoll() {
        preparationPoll?.invalidate()
        preparationPoll = nil
    }

    private func pollPreparation() {
        var downloading = false
        if #available(macOS 26, *), let engine = engine as? SpeechAnalyzerDictationEngine {
            downloading = engine.installProgress != nil
        }
        host?.dictationPreparationDidChange(downloadingModel: downloading)
    }

    isolated deinit {
        preparationPoll?.invalidate()
    }
}

extension DictationFailure {
    /// What the composer says when a session cannot run. Names the fix, never
    /// the engine's own error text (DI-01).
    var composerMessage: String {
        switch self {
        case .microphonePermissionDenied:
            return "Turn on the microphone for Array in System Settings › Privacy & Security"
        case .speechPermissionDenied:
            return "Turn on speech recognition for Array in System Settings › Privacy & Security"
        case .unsupportedOnThisDevice:
            return "Dictation isn’t available on this Mac"
        case .assetsUnavailable:
            return "Couldn’t download the speech model — check your connection and try again"
        case .audioEngineFailed:
            return "The microphone stopped — try again"
        case .recognizerFailed:
            return "Dictation stopped unexpectedly — try again"
        }
    }
}
