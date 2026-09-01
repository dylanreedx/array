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
        return CodeBlockView.measuredHeight(for: payload.code, zoom: context.pageZoom)
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

    // WS5: the same three metrics at a tile's page zoom. The zero-argument
    // properties above are the 100% values other call sites (and the UI probes)
    // still read, so they stay exactly as they are.
    static func headerHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.xxl + Space.s)) }
    static func maximumExpandedHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(320)) }
    static func minimumCodeHeight(zoom: AgentPageZoom) -> CGFloat {
        CGFloat(zoom.lineHeight(for: .bodyMono)) + CGFloat(zoom.scaled(Space.m)) * 2
    }

    private(set) var codeTextView: CodeTextView
    private(set) var scrollView = CodeBlockScrollView(frame: .zero)
    private(set) var languageLabel = NSTextField(labelWithString: "Code")
    private(set) var streamingLabel = NSTextField(labelWithString: "Streaming")
    private(set) var copyButton = CodeCopyButton(frame: .zero)

    private var blockID: AgentNodeID?
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)

    /// The page zoom of the last `apply`. Every metric below reads it, so a
    /// recycled block re-derives rather than keeping the zoom it was built at.
    private var zoom: AgentPageZoom { context.pageZoom }

    init(highlighter: any CodeHighlighting = PlainCodeHighlighter()) {
        codeTextView = CodeTextView(highlighter: highlighter)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true

        languageLabel.lineBreakMode = .byTruncatingTail
        streamingLabel.isHidden = true

        copyButton.target = self
        copyButton.action = #selector(copyEntireBlock(_:))

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        // Overlay scrollers do not shrink the viewport when a long line reveals
        // the horizontal bar. Without this, that lost height can falsely make a
        // one-line block appear to overflow vertically.
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = codeTextView

        addSubview(languageLabel)
        addSubview(streamingLabel)
        addSubview(copyButton)
        addSubview(scrollView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyZoomMetrics()
        applyTokens()
    }

    /// Every construction-time metric, re-derived from the CURRENT context's
    /// zoom. A recycled block runs this again from `apply`.
    private func applyZoomMetrics() {
        let zoom = self.zoom
        layer?.cornerRadius = CGFloat(zoom.scaled(AgentTileRadius.artifact))
        languageLabel.font = NSFont.token(.label, zoom: zoom)
        streamingLabel.font = NSFont.token(.caption, zoom: zoom)
        copyButton.applyZoom(zoom)
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
        applyZoomMetrics()
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
        let zoom = self.zoom
        let headerHeight = Self.headerHeight(zoom: zoom)
        let side = CGFloat(zoom.scaled(Space.l))
        let copyWidth = copyButton.intrinsicContentSize.width
        copyButton.frame = NSRect(
            x: max(side, bounds.maxX - side - copyWidth), y: CGFloat(zoom.scaled(Space.s)),
            width: copyWidth, height: headerHeight - CGFloat(zoom.scaled(Space.m))
        )
        let streamingWidth = streamingLabel.isHidden ? 0 : streamingLabel.intrinsicContentSize.width
        streamingLabel.frame = NSRect(
            x: max(side, copyButton.frame.minX - CGFloat(zoom.scaled(Space.m)) - streamingWidth),
            y: CGFloat(zoom.scaled(Space.m)), width: streamingWidth,
            height: streamingLabel.intrinsicContentSize.height
        )
        languageLabel.frame = NSRect(
            x: side, y: CGFloat(zoom.scaled(Space.m)),
            width: max(1, streamingLabel.frame.minX - side - CGFloat(zoom.scaled(Space.m))),
            height: languageLabel.intrinsicContentSize.height
        )
        scrollView.frame = NSRect(
            x: 0, y: headerHeight, width: bounds.width,
            height: max(0, bounds.height - headerHeight)
        )
        scrollView.layoutSubtreeIfNeeded()
        let measuredCodeSize = CodeTextView.measuredCodeSize(codeTextView.string, zoom: zoom)
        let needsVerticalScroll = measuredCodeSize.height > scrollView.contentSize.height + 0.5
        if scrollView.hasVerticalScroller != needsVerticalScroll {
            scrollView.hasVerticalScroller = needsVerticalScroll
            scrollView.layoutSubtreeIfNeeded()
        }
        codeTextView.sizeDocument(toFit: scrollView.contentSize)
    }

    static func measuredHeight(for code: String, zoom: AgentPageZoom = .default) -> CGFloat {
        min(
            maximumExpandedHeight(zoom: zoom),
            headerHeight(zoom: zoom)
                + max(minimumCodeHeight(zoom: zoom), CodeTextView.measuredCodeSize(code, zoom: zoom).height)
        )
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

/// A fenced-code block is nested inside the transcript or Markdown document
/// scroller. When the code fits vertically, a vertical trackpad gesture belongs
/// to that outer owner; retaining it here makes even a one-line snippet feel like
/// a dead patch in the document. Horizontal gestures remain local for long lines,
/// and capped multiline blocks keep their own vertical scrolling.
@MainActor
final class CodeBlockScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let vertical = abs(event.scrollingDeltaY)
        let horizontal = abs(event.scrollingDeltaX)
        if !hasVerticalScroller, vertical > 0, vertical >= horizontal,
           let nextResponder {
            nextResponder.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
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

    /// WS5: re-derived on every `apply`, because the button outlives the zoom it
    /// was constructed at.
    func applyZoom(_ zoom: AgentPageZoom) {
        font = NSFont.token(.label, zoom: zoom)
        invalidateIntrinsicContentSize()
    }

    override func accessibilityChildren() -> [Any]? { [] }
}
