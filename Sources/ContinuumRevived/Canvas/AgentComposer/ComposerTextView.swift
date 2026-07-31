import AppKit
import ContinuumRevivedAgentUI

/// The native editing engine for the agent composer. Visual containment belongs to
/// `AgentComposerView`; this view retains TextKit selection, pasteboard, IME,
/// spelling, accessibility, and undo behavior.
@MainActor
protocol ComposerTextViewObserver: AnyObject {
    func composerTextDidChange(_ textView: ComposerTextView)
    func composerSelectionDidChange(_ textView: ComposerTextView)
    func composerFocusDidChange(_ textView: ComposerTextView, focused: Bool)
    func composerRequestedSend(_ textView: ComposerTextView)
    func composerRequestedDismissSuggestions(_ textView: ComposerTextView)
}

@MainActor
final class ComposerTextView: NSTextView, NSTextViewDelegate {
    weak var composerObserver: ComposerTextViewObserver?
    /// Set by the completion controller while its custom surface is presented.
    /// Escape remains native when there is no completion surface to dismiss.
    var suggestionsAreVisible = false

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configureEditor()
    }

    override convenience init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: max(frameRect.width, 1), height: .greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        self.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureEditor() {
        delegate = self
        isEditable = true
        isSelectable = true
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = true
        drawsBackground = false
        isHorizontallyResizable = false
        isVerticallyResizable = true
        autoresizingMask = [.width]
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        font = .token(.body)
        let lineHeight = layoutManager?.defaultLineHeight(for: font ?? .token(.body)) ?? 17
        minSize = NSSize(width: 0, height: lineHeight)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Agent prompt")
        setAccessibilityHelp("Enter a prompt for the agent")
    }

    /// TextKit's laid-out document height at the current tracked width. The shell
    /// uses this to grow through eight lines and then lets its clip view scroll.
    func measuredDocumentHeight() -> CGFloat {
        guard let layoutManager, let textContainer else { return minSize.height }
        layoutManager.ensureLayout(for: textContainer)
        return max(minSize.height, ceil(layoutManager.usedRect(for: textContainer).height))
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        textColor = TextToken.textPrimary.color.nsColor(for: theme)
        insertionPointColor = TextToken.textPrimary.color.nsColor(for: theme)
        selectedTextAttributes = [
            .backgroundColor: AgentSurfaceRole.rowSelected.color.nsColor(for: theme),
            .foregroundColor: TextToken.textPrimary.color.nsColor(for: theme),
        ]
        typingAttributes[.font] = NSFont.token(.body)
        typingAttributes[.foregroundColor] = TextToken.textPrimary.color.nsColor(for: theme)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { composerObserver?.composerFocusDidChange(self, focused: true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { composerObserver?.composerFocusDidChange(self, focused: false) }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let action = ComposerKeyPolicy.action(
            for: event,
            hasMarkedText: hasMarkedText(),
            hasTrimmedContent: !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            suggestionsVisible: suggestionsAreVisible
        )
        switch action {
        case .send:
            composerObserver?.composerRequestedSend(self)
        case .dismissSuggestions:
            suggestionsAreVisible = false
            composerObserver?.composerRequestedDismissSuggestions(self)
        case .nativeTextSystem:
            super.keyDown(with: event)
        }
    }

    /// Replaces a completion query as one native undo unit. `insertText` is kept as
    /// the mutation primitive so TextKit records both the replaced text and the
    /// pre-insertion selection; the explicit group prevents a multi-part completion
    /// from coalescing with the user's preceding typing.
    func insertCompletion(_ completion: String, replacementRange: NSRange) {
        let selectionBeforeInsertion = selectedRange()
        let selectionAfterInsertion = NSRange(
            location: replacementRange.location + (completion as NSString).length,
            length: 0
        )
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        // Register before TextKit's replacement action. Undo groups run in reverse,
        // so the text is restored first and this action then restores the exact
        // pre-completion selection instead of TextKit's whole replacement range.
        undoManager?.registerUndo(withTarget: self) { textView in
            textView.setSelectedRange(selectionBeforeInsertion)
            textView.undoManager?.registerUndo(withTarget: textView) { redoTextView in
                redoTextView.setSelectedRange(selectionAfterInsertion)
            }
        }
        insertText(completion, replacementRange: replacementRange)
        undoManager?.endUndoGrouping()
        breakUndoCoalescing()
    }

    func textDidChange(_ notification: Notification) {
        composerObserver?.composerTextDidChange(self)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        composerObserver?.composerSelectionDidChange(self)
    }
}
