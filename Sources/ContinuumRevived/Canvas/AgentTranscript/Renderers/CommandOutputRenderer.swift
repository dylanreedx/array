import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// Bounded command output with exact native selection/copy. The semantic payload
/// contains output and exit state only, so this renderer cannot leak a command's
/// arguments, working directory, or provider record.
@MainActor
final class CommandOutputRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .commandOutput

    func makeView() -> NSView {
        CommandOutputView()
    }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? CommandOutputView,
              case let .commandOutput(payload) = block.payload else { return }
        view.apply(blockID: block.id, payload: payload, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        guard case let .commandOutput(payload) = block.payload else { return 0 }
        let expanded = context.actions.isExpanded(
            blockID: block.id,
            default: payload.status.agentToolDefaultExpanded
        )
        return CommandOutputView.measuredHeight(
            text: payload.text, width: width, expanded: expanded, zoom: context.pageZoom)
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? CommandOutputView,
              case let .commandOutput(payload) = block.payload else { return }
        view.applyAccessibility(status: payload.status, exitCode: payload.exitCode)
    }
}

@MainActor
final class CommandOutputView: NSView {
    static let rowHeight = ToolCallView.rowHeight
    static let maximumOutputHeight: CGFloat = 240
    static let minimumOutputHeight = CGFloat(Metrics.lineHeight(for: .bodyMono)) + CGFloat(Space.m) * 2
    static let horizontalInset = CGFloat(Space.l)
    static let outputBottomInset = CGFloat(Space.m)
    // WS5: the same metrics at a tile's page zoom. The zero-argument statics
    // above are the 100% values and stay put — out-of-module witnesses read
    // them — so these are companions.
    static func rowHeight(zoom: AgentPageZoom) -> CGFloat { ToolCallView.rowHeight(zoom: zoom) }
    static func maximumOutputHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(240)) }
    static func minimumOutputHeight(zoom: AgentPageZoom) -> CGFloat {
        CGFloat(zoom.lineHeight(for: .bodyMono)) + CGFloat(zoom.scaled(Space.m)) * 2
    }
    static func horizontalInset(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.l)) }
    static func outputBottomInset(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.m)) }
    private var zoom: AgentPageZoom { context.pageZoom }

    private(set) var disclosureButton = AgentDisclosureButton(frame: .zero)
    private(set) var iconView = NSImageView(frame: .zero)
    private(set) var titleLabel = NSTextField(labelWithString: "Command output")
    private(set) var statusLabel = NSTextField(labelWithString: "")
    private(set) var scrollView = CodeBlockScrollView(frame: .zero)
    private(set) var outputTextView = CommandOutputTextView(frame: .zero)
    private(set) var copyButton = CommandOutputCopyButton(frame: .zero)
    private(set) var isExpanded = false

    private var blockID: AgentNodeID?
    private var status: AgentItemStatus = .pending
    private var exitCode: Int?
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        layer?.masksToBounds = true

        disclosureButton.target = self
        disclosureButton.action = #selector(toggleDisclosure(_:))
        iconView.image = CanvasSymbolImage.image(named: "terminal")
        iconView.imageScaling = .scaleProportionallyDown
        titleLabel.font = NSFont.token(.label)
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = NSFont.token(.caption)
        statusLabel.lineBreakMode = .byTruncatingTail

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        // See the note in `ToolCallRenderer`: this pane has the same zero-slack
        // geometry and inherited the same clipping.
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = outputTextView

        copyButton.target = self
        copyButton.action = #selector(copyEntireOutput(_:))

        addSubview(disclosureButton)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(statusLabel)
        addSubview(scrollView)
        addSubview(copyButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(blockID: AgentNodeID, payload: AgentCommandOutputPayload, context: AgentRenderContext) {
        self.blockID = blockID
        self.status = payload.status
        self.exitCode = payload.exitCode
        self.context = context

        // WS5: re-derived per apply, never left at the construction-time zoom —
        // this view is recycled across rows and across tiles.
        let zoom = context.pageZoom
        layer?.cornerRadius = CGFloat(zoom.scaled(AgentTileRadius.artifact))
        titleLabel.font = NSFont.token(.label, zoom: zoom)
        statusLabel.font = NSFont.token(.caption, zoom: zoom)
        copyButton.applyZoom(zoom)

        isExpanded = context.actions.isExpanded(
            blockID: blockID,
            default: payload.status.agentToolDefaultExpanded
        )
        statusLabel.stringValue = Self.statusText(status: payload.status, exitCode: payload.exitCode)
        outputTextView.apply(text: payload.text, context: context)
        disclosureButton.apply(expanded: isExpanded, title: "command output", zoom: zoom)
        setDetailHidden(!isExpanded)
        identifier = NSUserInterfaceItemIdentifier("agent.commandOutput.\(blockID.rawValue)")
        applyAccessibility(status: payload.status, exitCode: payload.exitCode)
        applyTokens()
        needsLayout = true
    }

    func applyAccessibility(status: AgentItemStatus, exitCode: Int?) {
        setAccessibilityLabel("Command output, \(Self.statusText(status: status, exitCode: exitCode))")
        setAccessibilityChildren(isExpanded
            ? [disclosureButton, titleLabel, statusLabel, copyButton, outputTextView]
            : [disclosureButton, titleLabel, statusLabel])
    }

    override func layout() {
        super.layout()
        let zoom = self.zoom
        let rowHeight = Self.rowHeight(zoom: zoom)
        let inset = Self.horizontalInset(zoom: zoom)
        let buttonSide = CGFloat(zoom.scaled(Space.xxl))
        disclosureButton.frame = NSRect(
            x: inset, y: (rowHeight - buttonSide) / 2,
            width: buttonSide, height: buttonSide
        )
        iconView.frame = NSRect(
            x: disclosureButton.frame.maxX + CGFloat(zoom.scaled(Space.s)),
            y: (rowHeight - buttonSide) / 2,
            width: buttonSide, height: buttonSide
        )
        let statusWidth = min(
            ceil(statusLabel.intrinsicContentSize.width) + CGFloat(zoom.scaled(Space.s)),
            max(0, bounds.width * 0.46))
        statusLabel.frame = NSRect(
            x: max(iconView.frame.maxX, bounds.maxX - inset - statusWidth),
            y: (rowHeight - statusLabel.intrinsicContentSize.height) / 2,
            width: statusWidth, height: statusLabel.intrinsicContentSize.height
        )
        let titleX = iconView.frame.maxX + CGFloat(zoom.scaled(Space.m))
        titleLabel.frame = NSRect(
            x: titleX,
            y: (rowHeight - titleLabel.intrinsicContentSize.height) / 2,
            width: max(1, statusLabel.frame.minX - titleX - CGFloat(zoom.scaled(Space.m))),
            height: titleLabel.intrinsicContentSize.height
        )

        guard isExpanded else {
            scrollView.frame = .zero
            copyButton.frame = .zero
            return
        }
        let detailY = rowHeight
        let copyWidth = copyButton.intrinsicContentSize.width
        copyButton.frame = NSRect(
            x: max(inset, bounds.maxX - inset - copyWidth), y: detailY,
            width: copyWidth, height: CGFloat(zoom.scaled(Space.xxl))
        )
        let outputY = copyButton.frame.maxY + CGFloat(zoom.scaled(Space.xs))
        scrollView.frame = NSRect(
            x: 0, y: outputY, width: bounds.width,
            height: max(0, bounds.height - outputY - Self.outputBottomInset(zoom: zoom))
        )
        scrollView.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        let measuredOutput = CommandOutputTextView.measuredSize(outputTextView.string, zoom: zoom)
        let needsVerticalScroll = measuredOutput.height > scrollView.contentSize.height + 0.5
        if scrollView.hasVerticalScroller != needsVerticalScroll {
            scrollView.hasVerticalScroller = needsVerticalScroll
            scrollView.layoutSubtreeIfNeeded()
        }
        outputTextView.sizeDocument(toFit: scrollView.contentSize)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        // `.plans/45` T6. Command output is code, not an artifact card: it takes
        // the code surface, the same one CodeBlockView uses. Keeping a fill here
        // is deliberate — §11 keeps fills for code, diff, plan and approval.
        layer?.backgroundColor = context.tokens.codeSurface.color.cgColor(for: theme)
        titleLabel.textColor = context.tokens.primaryText.color.nsColor(for: theme)
        statusLabel.textColor = status == .failed
            ? AgentLineRole.attention.color.nsColor(for: theme)
            : context.tokens.secondaryText.color.nsColor(for: theme)
        disclosureButton.contentTintColor = context.tokens.secondaryText.color.nsColor(for: theme)
        iconView.contentTintColor = context.tokens.secondaryText.color.nsColor(for: theme)
        copyButton.contentTintColor = context.tokens.secondaryText.color.nsColor(for: theme)
        outputTextView.applyTheme(theme)
    }

    static func measuredHeight(
        text: String, width: CGFloat, expanded: Bool, zoom: AgentPageZoom = .default
    ) -> CGFloat {
        guard expanded else { return rowHeight(zoom: zoom) }
        let outputHeight = min(
            maximumOutputHeight(zoom: zoom),
            max(minimumOutputHeight(zoom: zoom), CommandOutputTextView.measuredSize(text, zoom: zoom).height)
        )
        return rowHeight(zoom: zoom) + CGFloat(zoom.scaled(Space.xxl + Space.xs))
            + outputHeight + outputBottomInset(zoom: zoom)
    }

    func copyEntireOutput(to pasteboard: NSPasteboard) {
        outputTextView.writeEntireOutput(to: pasteboard)
    }

    @objc private func toggleDisclosure(_ sender: Any?) {
        guard let blockID else { return }
        isExpanded.toggle()
        context.actions.setExpanded(isExpanded, blockID: blockID)
        disclosureButton.apply(expanded: isExpanded, title: "command output", zoom: zoom)
        setDetailHidden(!isExpanded)
        applyAccessibility(status: status, exitCode: exitCode)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    @objc private func copyEntireOutput(_ sender: Any?) {
        outputTextView.writeEntireOutput(to: .general)
        if let blockID { context.actions.perform(.copy(blockID: blockID)) }
    }

    private func setDetailHidden(_ hidden: Bool) {
        scrollView.isHidden = hidden
        copyButton.isHidden = hidden
    }

    private static func statusText(status: AgentItemStatus, exitCode: Int?) -> String {
        let presentation = status.agentToolStatusPresentation
        if let exitCode {
            return "\(presentation.glyph) \(presentation.label), exit \(exitCode)"
        }
        return "\(presentation.glyph) \(presentation.label)"
    }
}

@MainActor
final class CommandOutputTextView: NSTextView {
    private var theme: TokenTheme = .dark
    private var tokens: AgentRenderTokens = .transcript
    /// WS5: the zoom of the last `apply(text:context:)`. The container inset and
    /// the mono font are re-derived from it rather than frozen at construction.
    private var pageZoom: AgentPageZoom = .default

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: frameRect, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = false
        drawsBackground = false
        isHorizontallyResizable = true
        isVerticallyResizable = true
        textContainerInset = Self.containerInset(zoom: .default)
        textContainer?.lineFragmentPadding = 0
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Command output")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(text: String, context: AgentRenderContext) {
        let selection = selectedRange()
        theme = context.appearance
        tokens = context.tokens
        pageZoom = context.pageZoom
        textContainerInset = Self.containerInset(zoom: pageZoom)
        string = text
        font = NSFont.token(.bodyMono, zoom: pageZoom)
        textColor = tokens.primaryText.color.nsColor(for: theme)
        let length = (text as NSString).length
        let location = min(selection.location, length)
        setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
    }

    func applyTheme(_ theme: TokenTheme) {
        self.theme = theme
        textColor = tokens.primaryText.color.nsColor(for: theme)
    }

    func sizeDocument(toFit viewport: NSSize) {
        let measured = Self.measuredSize(string, zoom: pageZoom)
        frame.size = NSSize(width: max(viewport.width, measured.width), height: max(viewport.height, measured.height))
    }

    /// The text-container inset an output surface uses at `zoom`. Shared by the
    /// live view and `measuredSize` so the measured box matches the painted one.
    static func containerInset(zoom: AgentPageZoom) -> NSSize {
        NSSize(width: CGFloat(zoom.scaled(Space.l)), height: CGFloat(zoom.scaled(Space.m)))
    }

    static func measuredSize(_ text: String, zoom: AgentPageZoom = .default) -> NSSize {
        let font = NSFont.token(.bodyMono, zoom: zoom)
        let sample = text.isEmpty ? " " : text
        let unbounded = CGFloat.greatestFiniteMagnitude
        let rect = (sample as NSString).boundingRect(
            with: NSSize(width: unbounded, height: unbounded),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let newlineCount = text.reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
        let inset = containerInset(zoom: zoom)
        let measuredWidth = ceil(rect.width) + inset.width * 2
        let linesHeight = CGFloat(newlineCount + 1) * lineHeight
        let measuredHeight = max(ceil(rect.height), linesHeight) + inset.height * 2
        return NSSize(width: measuredWidth, height: measuredHeight)
    }

    func writeEntireOutput(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

@MainActor
final class CommandOutputCopyButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "Copy"
        font = NSFont.token(.label)
        isBordered = false
        bezelStyle = .inline
        focusRingType = .exterior
        setButtonType(.momentaryChange)
        identifier = NSUserInterfaceItemIdentifier("agent.commandOutput.copy")
        setAccessibilityRole(.button)
        setAccessibilityLabel("Copy command output")
        toolTip = "Copy command output"
    }

    /// WS5: re-derived per apply — this button is recycled with its row.
    func applyZoom(_ zoom: AgentPageZoom) {
        font = NSFont.token(.label, zoom: zoom)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
