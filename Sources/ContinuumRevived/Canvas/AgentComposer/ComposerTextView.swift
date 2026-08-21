import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// The native editing engine for the agent composer. Visual containment belongs to
/// `AgentComposerView`; this view retains TextKit selection, pasteboard, IME,
/// spelling, accessibility, and undo behavior.
@MainActor
protocol ComposerTextViewObserver: AnyObject {
    func composerTextDidChange(_ textView: ComposerTextView)
    func composerSelectionDidChange(_ textView: ComposerTextView)
    func composerFocusDidChange(_ textView: ComposerTextView, focused: Bool)
    func composerRequestedSend(_ textView: ComposerTextView)
    func composerHasSendableAttachments(_ textView: ComposerTextView) -> Bool
    func composerRequestedCompletionCommand(
        _ textView: ComposerTextView,
        command: ChoiceListCommand
    ) -> Bool
    func composerRequestedDismissSuggestions(_ textView: ComposerTextView)
    func composerRequestedAttachmentImport(
        _ textView: ComposerTextView,
        intake: ComposerPasteboardIntake
    )
}

@MainActor
final class ComposerTextView: NSTextView, NSTextViewDelegate {
    weak var composerObserver: ComposerTextViewObserver?
    /// Set by the completion controller while its custom surface is presented.
    /// Escape remains native when there is no completion surface to dismiss.
    var suggestionsAreVisible = false

    private var promptHistory: AgentPromptHistory?
    private var promptHistoryAgentID: AgentID?
    private var isApplyingHistoryReplacement = false

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
        // ComposerHeightController owns the container width explicitly. Width
        // tracking against a momentarily zero-width live clip view loops the
        // display cycle until AppKit kills the app (P5.5 boot finding).
        container.widthTracksTextView = false
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
        registerForDraggedTypes([.fileURL, .png, .tiff, ComposerImagePasteboardDecoder.jpegPasteboardType])
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

    /// Binds history to agent identity rather than tile identity. The owner must
    /// call `recordAcceptedPrompt` only after its send intent is accepted.
    func bindPromptHistory(_ history: AgentPromptHistory, agentID: AgentID) {
        if let previousAgentID = promptHistoryAgentID,
           let previousHistory = promptHistory,
           previousAgentID != agentID || previousHistory !== history {
            previousHistory.cancelNavigation(for: previousAgentID)
        }
        promptHistory = history
        promptHistoryAgentID = agentID
    }

    func recordAcceptedPrompt(_ prompt: String) {
        guard let promptHistory, let promptHistoryAgentID else { return }
        promptHistory.recordAccepted(prompt, for: promptHistoryAgentID)
    }

    /// Where `paste:` and its validation read from. Production is the general
    /// pasteboard; checks substitute a private one so they can drive the real
    /// override without mutating process-global state. Both the action and its
    /// validation MUST read the same source, or the menu can enable a paste the
    /// handler then refuses (or the reverse, which is the bug below).
    var attachmentPasteboardProvider: () -> NSPasteboard = { .general }

    override func paste(_ sender: Any?) {
        if !handleAttachmentIntake(from: attachmentPasteboardProvider()) {
            super.paste(sender)
        }
    }

    /// A plain-text NSTextView (`isRichText = false`, `importsGraphics = false`)
    /// reports it cannot read an image-only pasteboard, so AppKit DISABLES
    /// `paste:` and ⌘V just beeps — `paste(_:)` above is never called and the
    /// image intake never gets a chance. A macOS screenshot is exactly that case:
    /// its pasteboard item carries `public.png` and nothing else. A browser's
    /// "copy image" also puts HTML/text flavours on the board, so validation
    /// passed and pasting worked there — same code, different pasteboard, which
    /// is why this looked like a screenshot-only bug.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)),
           !ComposerPasteboardIntake(from: attachmentPasteboardProvider()).isEmpty {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func performDragOperation(_ draggingInfo: NSDraggingInfo) -> Bool {
        handleAttachmentIntake(from: draggingInfo.draggingPasteboard)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ComposerPasteboardIntake(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    @discardableResult
    private func handleAttachmentIntake(from pasteboard: NSPasteboard) -> Bool {
        let intake = ComposerPasteboardIntake(from: pasteboard)
        guard !intake.isEmpty else { return false }
        composerObserver?.composerRequestedAttachmentImport(self, intake: intake)
        return true
    }

    // Drives the exact handler shared by paste and drop without mutating the
    // process-global general pasteboard in deterministic component checks.
    func qaHandleAttachmentIntake(from pasteboard: NSPasteboard) -> Bool {
        handleAttachmentIntake(from: pasteboard)
    }

    override func keyDown(with event: NSEvent) {
        if handleCompletionKey(event) { return }
        if handlePromptHistoryKey(event) { return }

        let action = ComposerKeyPolicy.action(
            for: event,
            hasMarkedText: hasMarkedText(),
            hasTrimmedContent: !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            suggestionsVisible: suggestionsAreVisible,
            hasAttachments: composerObserver?.composerHasSendableAttachments(self) ?? false
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

    private func handleCompletionKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // A directory transition dismisses the old rows while the replacement
        // query is in flight. Keep Backspace/Return in the composer-owned path
        // during that short window so an immediate ascent cannot delete `@` or
        // submit the draft before the new picker rows arrive.
        let isNavigationFallbackKey = event.keyCode == 51 || [36, 76].contains(event.keyCode)
        guard (suggestionsAreVisible || isNavigationFallbackKey),
              !hasMarkedText(),
              modifiers.intersection([.shift, .control, .option, .command]).isEmpty
        else { return false }

        let command: ChoiceListCommand
        switch event.keyCode {
        case 126: command = .previous
        case 125: command = .next
        case 115: command = .first
        case 119: command = .last
        case 36, 76: command = .accept
        case 124, 48: command = .open // Right or Tab descends into a focused directory.
        case 123, 51: command = .ascend // Left or empty-query Backspace ascends.
        default: return false
        }
        return composerObserver?.composerRequestedCompletionCommand(self, command: command) == true
    }

    private func handlePromptHistoryKey(_ event: NSEvent) -> Bool {
        let disallowedModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        guard event.modifierFlags.intersection(disallowedModifiers).isEmpty,
              !hasMarkedText(),
              selectedRange().length == 0,
              let promptHistory,
              let agentID = promptHistoryAgentID,
              let linePosition = visualLinePosition()
        else { return false }

        let replacement: String?
        switch event.keyCode {
        case 126 where linePosition.isFirst: // Up
            replacement = promptHistory.previous(for: agentID, preserving: string)
        case 125 where linePosition.isLast && promptHistory.isNavigating(for: agentID): // Down
            replacement = promptHistory.next(for: agentID)
        default:
            return false
        }
        guard let replacement else { return false }
        replaceTextFromHistory(replacement)
        return true
    }

    /// Uses TextKit line fragments, so soft wrapping participates in the boundary
    /// decision while embedded newline count does not stand in for visual lines.
    private func visualLinePosition() -> (isFirst: Bool, isLast: Bool)? {
        guard let layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let selectionLocation = selectedRange().location
        let characterCount = (string as NSString).length
        guard selectionLocation <= characterCount else { return nil }
        if characterCount == 0 { return (true, true) }

        var lineGlyphRanges: [NSRange] = []
        layoutManager.enumerateLineFragments(
            forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)
        ) { _, _, _, glyphRange, _ in
            lineGlyphRanges.append(glyphRange)
        }

        let hasTrailingEmptyLine = selectionLocation == characterCount
            && string.hasSuffix("\n")
            && layoutManager.extraLineFragmentTextContainer != nil
        if hasTrailingEmptyLine {
            return (lineGlyphRanges.isEmpty, true)
        }
        guard !lineGlyphRanges.isEmpty else { return (true, true) }

        let characterIndex = min(selectionLocation, characterCount - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        guard let lineIndex = lineGlyphRanges.firstIndex(where: { NSLocationInRange(glyphIndex, $0) }) else {
            return nil
        }
        return (lineIndex == 0, lineIndex == lineGlyphRanges.count - 1)
    }

    private func replaceTextFromHistory(_ replacement: String) {
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: fullRange, replacementString: replacement) else { return }
        isApplyingHistoryReplacement = true
        defer { isApplyingHistoryReplacement = false }
        textStorage?.replaceCharacters(in: fullRange, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: (replacement as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
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
        if !isApplyingHistoryReplacement,
           let promptHistory,
           let promptHistoryAgentID {
            promptHistory.cancelNavigation(for: promptHistoryAgentID)
        }
        composerObserver?.composerTextDidChange(self)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        composerObserver?.composerSelectionDidChange(self)
    }
}
