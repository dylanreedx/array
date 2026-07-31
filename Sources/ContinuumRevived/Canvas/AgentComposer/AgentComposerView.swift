import AppKit
import ContinuumRevivedAgentUI

/// A view-owned snapshot of composer editing state. Tiles bind to this value;
/// they do not reach through the composer to mutate its NSTextView.
struct AgentComposerDraft: Equatable {
    var text: String
    var selection: NSRange
    var revision: UInt64

    static let empty = AgentComposerDraft(text: "", selection: NSRange(location: 0, length: 0), revision: 0)
}

/// Isolated custom composer shell. The surface and focus treatment are owned here
/// while `ComposerTextView` remains the native editing engine.
@MainActor
final class AgentComposerView: NSView, TokenThemed, ComposerTextViewObserver {
    let textView: ComposerTextView
    private(set) var scrollView: NSScrollView
    private let placeholderLabel = NSTextField(labelWithString: "Send a prompt to the agent…")

    var onDraftChange: ((AgentComposerDraft) -> Void)?
    var onSubmitPrompt: ((String) -> Void)?
    var onDismissSuggestions: (() -> Void)?
    private(set) var draft: AgentComposerDraft = .empty
    private(set) var isEditorFocused = false
    private var isApplyingDraft = false
    private let heightController = ComposerHeightController(
        maximumVisibleLines: AgentComposerView.maximumVisibleLines
    )

    static let cornerRadius = CGFloat(AgentTileRadius.composer)
    static let internalPadding = CGFloat(Space.l)
    static let idleBorderWidth: CGFloat = 1
    static let focusedBorderWidth: CGFloat = 2
    static let maximumVisibleLines = 8

    override init(frame frameRect: NSRect) {
        textView = ComposerTextView(frame: .zero)
        scrollView = NSScrollView(frame: .zero)
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = false

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        placeholderLabel.font = .token(.body)
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.setAccessibilityElement(false)
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.internalPadding),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.internalPadding),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.internalPadding),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.internalPadding),
            placeholderLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: scrollView.topAnchor),
        ])

        textView.composerObserver = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(readabilityOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        textView.applyTokens()
        updatePlaceholder()
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        let width = max(1, scrollView.contentSize.width > 0
            ? scrollView.contentSize.width
            : bounds.width - Self.internalPadding * 2)
        let measurement = heightController.measure(textView: textView, width: width)
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: measurement.visibleEditorHeight + (Self.internalPadding * 2)
        )
    }

    override func layout() {
        super.layout()
        updateEditorGeometry()
    }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(textView) ?? false
    }

    func apply(_ newDraft: AgentComposerDraft) {
        let utf16Count = (newDraft.text as NSString).length
        let location = min(max(newDraft.selection.location, 0), utf16Count)
        let length = min(max(newDraft.selection.length, 0), utf16Count - location)
        let safeSelection = NSRange(location: location, length: length)

        isApplyingDraft = true
        if textView.string != newDraft.text { textView.string = newDraft.text }
        textView.setSelectedRange(safeSelection)
        draft = AgentComposerDraft(text: newDraft.text, selection: safeSelection, revision: newDraft.revision)
        isApplyingDraft = false
        updatePlaceholder()
        editorContentsChanged()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = AgentSurfaceRole.composer.color.cgColor(for: theme)
        layer?.borderColor = (isEditorFocused ? AgentLineRole.focusRing : .decorativeHairline).color.cgColor(for: theme)
        layer?.borderWidth = isEditorFocused ? Self.focusedBorderWidth : Self.idleBorderWidth
        placeholderLabel.font = .token(.body)
        placeholderLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        // Update existing draft attributes as well as typing attributes so
        // TextKit line metrics follow token/readability changes immediately.
        let editorFont = NSFont.token(.body)
        textView.font = editorFont
        if let textStorage = textView.textStorage, textStorage.length > 0 {
            textStorage.addAttribute(
                .font, value: editorFont,
                range: NSRange(location: 0, length: textStorage.length)
            )
        }
        textView.applyTokens()
        textView.layoutManager?.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: textView.textStorage?.length ?? 0),
            actualCharacterRange: nil
        )
        editorContentsChanged()
    }

    @objc private func readabilityOptionsDidChange(_ notification: Notification) {
        applyTokens()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func composerTextDidChange(_ textView: ComposerTextView) {
        publishDraftChange()
        updatePlaceholder()
        editorContentsChanged()
    }

    func composerSelectionDidChange(_ textView: ComposerTextView) {
        publishDraftChange()
    }

    func composerFocusDidChange(_ textView: ComposerTextView, focused: Bool) {
        isEditorFocused = focused
        applyTokens()
    }

    func composerRequestedSend(_ textView: ComposerTextView) {
        let prompt = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        onSubmitPrompt?(prompt)
    }

    func composerRequestedDismissSuggestions(_ textView: ComposerTextView) {
        onDismissSuggestions?()
    }

    private func publishDraftChange() {
        guard !isApplyingDraft else { return }
        let textChanged = textView.string != draft.text
        draft = AgentComposerDraft(
            text: textView.string,
            selection: textView.selectedRange(),
            revision: textChanged ? draft.revision &+ 1 : draft.revision
        )
        onDraftChange?(draft)
    }

    private func updatePlaceholder() {
        placeholderLabel.isHidden = !textView.string.isEmpty
    }

    private func editorContentsChanged() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func updateEditorGeometry() {
        let viewport = scrollView.contentSize
        guard viewport.width > 0, viewport.height > 0 else { return }
        let previousHeight = heightController.measurement?.visibleEditorHeight
        let measurement = heightController.update(
            textView: textView, scrollView: scrollView, width: viewport.width
        )
        if let previousHeight, abs(previousHeight - measurement.visibleEditorHeight) > 0.5 {
            invalidateIntrinsicContentSize()
        }
    }

    // Deterministic AppKit probes; not a tile integration seam.
    var qaPlaceholderVisible: Bool { !placeholderLabel.isHidden }
    var qaPlaceholderColor: NSColor? { placeholderLabel.textColor }
    var qaHeightMeasurement: ComposerHeightController.Measurement? { heightController.measurement }
}
