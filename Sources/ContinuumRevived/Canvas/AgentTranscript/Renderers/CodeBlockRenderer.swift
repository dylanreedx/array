import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// Fenced code remains an inert semantic artifact: selection and copy are native,
/// while parsing, execution, and future syntax classification stay elsewhere.
@MainActor
final class CodeBlockRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .fencedCode
    private let highlighter: any CodeHighlighting

    init(highlighter: any CodeHighlighting = PlainCodeHighlighter()) {
        self.highlighter = highlighter
    }

    func makeView() -> NSView {
        CodeBlockView(highlighter: highlighter)
    }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? CodeBlockView,
              case let .fencedCode(payload) = block.payload else { return }
        view.apply(blockID: block.id, payload: payload, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        guard case let .fencedCode(payload) = block.payload else { return 0 }
        return CodeBlockView.measuredHeight(for: payload.code)
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? CodeBlockView,
              case let .fencedCode(payload) = block.payload else { return }
        view.applyAccessibility(language: payload.language, isComplete: payload.isComplete)
    }
}

@MainActor
final class CodeBlockView: NSView {
    static let headerHeight = CGFloat(Space.xxl + Space.s)
    static let maximumExpandedHeight: CGFloat = 320
    static let minimumCodeHeight = CGFloat(Metrics.lineHeight(for: .bodyMono)) + CGFloat(Space.m) * 2

    private(set) var codeTextView: CodeTextView
    private(set) var scrollView = NSScrollView(frame: .zero)
    private(set) var languageLabel = NSTextField(labelWithString: "Code")
    private(set) var streamingLabel = NSTextField(labelWithString: "Streaming")
    private(set) var copyButton = CodeCopyButton(frame: .zero)

    private var blockID: AgentNodeID?
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)

    init(highlighter: any CodeHighlighting = PlainCodeHighlighter()) {
        codeTextView = CodeTextView(highlighter: highlighter)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        layer?.masksToBounds = true

        languageLabel.font = NSFont.token(.label)
        languageLabel.lineBreakMode = .byTruncatingTail
        streamingLabel.font = NSFont.token(.caption)
        streamingLabel.isHidden = true

        copyButton.target = self
        copyButton.action = #selector(copyEntireBlock(_:))

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = codeTextView

        addSubview(languageLabel)
        addSubview(streamingLabel)
        addSubview(copyButton)
        addSubview(scrollView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(blockID: AgentNodeID, payload: AgentCodePayload, context: AgentRenderContext) {
        self.blockID = blockID
        self.context = context
        let language = Self.displayLanguage(payload.language)
        languageLabel.stringValue = language ?? "Code"
        streamingLabel.isHidden = payload.isComplete
        codeTextView.apply(code: payload.code, language: language, context: context)
        identifier = NSUserInterfaceItemIdentifier("agent.codeBlock.\(blockID.rawValue)")
        applyAccessibility(language: language, isComplete: payload.isComplete)
        applyTokens()
        needsLayout = true
    }

    func applyAccessibility(language: String?, isComplete: Bool) {
        let name = Self.displayLanguage(language).map { "\($0) code block" } ?? "Code block"
        setAccessibilityLabel(isComplete ? name : "\(name), streaming")
        var children: [NSView] = [languageLabel]
        if !isComplete { children.append(streamingLabel) }
        children.append(contentsOf: [copyButton, codeTextView])
        setAccessibilityChildren(children)
    }

    override func layout() {
        super.layout()
        let side = CGFloat(Space.l)
        let copyWidth = copyButton.intrinsicContentSize.width
        copyButton.frame = NSRect(
            x: max(side, bounds.maxX - side - copyWidth), y: CGFloat(Space.s),
            width: copyWidth, height: Self.headerHeight - CGFloat(Space.m)
        )
        let streamingWidth = streamingLabel.isHidden ? 0 : streamingLabel.intrinsicContentSize.width
        streamingLabel.frame = NSRect(
            x: max(side, copyButton.frame.minX - CGFloat(Space.m) - streamingWidth),
            y: CGFloat(Space.m), width: streamingWidth,
            height: streamingLabel.intrinsicContentSize.height
        )
        languageLabel.frame = NSRect(
            x: side, y: CGFloat(Space.m),
            width: max(1, streamingLabel.frame.minX - side - CGFloat(Space.m)),
            height: languageLabel.intrinsicContentSize.height
        )
        scrollView.frame = NSRect(
            x: 0, y: Self.headerHeight, width: bounds.width,
            height: max(0, bounds.height - Self.headerHeight)
        )
        scrollView.layoutSubtreeIfNeeded()
        codeTextView.sizeDocument(toFit: scrollView.contentSize)
    }

    static func measuredHeight(for code: String) -> CGFloat {
        min(maximumExpandedHeight, headerHeight + max(minimumCodeHeight, CodeTextView.measuredCodeSize(code).height))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = context.tokens.codeSurface.color.cgColor(for: theme)
        languageLabel.textColor = context.tokens.secondaryText.color.nsColor(for: theme)
        streamingLabel.textColor = context.tokens.secondaryText.color.nsColor(for: theme)
        copyButton.contentTintColor = context.tokens.secondaryText.color.nsColor(for: theme)
        codeTextView.applyTheme(theme)
    }

    @objc private func copyEntireBlock(_ sender: Any?) {
        codeTextView.writeEntireCode(to: .general)
        if let blockID { context.actions.perform(.copy(blockID: blockID)) }
    }

    func copyEntireBlock(to pasteboard: NSPasteboard) {
        codeTextView.writeEntireCode(to: pasteboard)
    }

    private static func displayLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Borderless native hit testing and keyboard behavior with no Aqua bezel.
@MainActor
final class CodeCopyButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "Copy"
        font = NSFont.token(.label)
        isBordered = false
        bezelStyle = .inline
        focusRingType = .exterior
        setButtonType(.momentaryChange)
        identifier = NSUserInterfaceItemIdentifier("agent.codeBlock.copy")
        setAccessibilityRole(.button)
        setAccessibilityLabel("Copy code")
        toolTip = "Copy code"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityChildren() -> [Any]? { [] }
}
