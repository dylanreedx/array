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
        return CommandOutputView.measuredHeight(text: payload.text, width: width, expanded: expanded)
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

    private(set) var disclosureButton = AgentDisclosureButton(frame: .zero)
    private(set) var iconView = NSImageView(frame: .zero)
    private(set) var titleLabel = NSTextField(labelWithString: "Command output")
    private(set) var statusLabel = NSTextField(labelWithString: "")
    private(set) var scrollView = NSScrollView(frame: .zero)
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
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
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

        isExpanded = context.actions.isExpanded(
            blockID: blockID,
            default: payload.status.agentToolDefaultExpanded
        )
        statusLabel.stringValue = Self.statusText(status: payload.status, exitCode: payload.exitCode)
        outputTextView.apply(text: payload.text, context: context)
        disclosureButton.apply(expanded: isExpanded, title: "command output")
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
        let inset = Self.horizontalInset
        let buttonSide = CGFloat(Space.xxl)
        disclosureButton.frame = NSRect(
            x: inset, y: (Self.rowHeight - buttonSide) / 2,
            width: buttonSide, height: buttonSide
        )
        iconView.frame = NSRect(
            x: disclosureButton.frame.maxX + CGFloat(Space.s),
            y: (Self.rowHeight - buttonSide) / 2,
            width: buttonSide, height: buttonSide
        )
        let statusWidth = min(ceil(statusLabel.intrinsicContentSize.width) + CGFloat(Space.s), max(0, bounds.width * 0.46))
        statusLabel.frame = NSRect(
            x: max(iconView.frame.maxX, bounds.maxX - inset - statusWidth),
            y: (Self.rowHeight - statusLabel.intrinsicContentSize.height) / 2,
            width: statusWidth, height: statusLabel.intrinsicContentSize.height
        )
        let titleX = iconView.frame.maxX + CGFloat(Space.m)
        titleLabel.frame = NSRect(
            x: titleX,
            y: (Self.rowHeight - titleLabel.intrinsicContentSize.height) / 2,
            width: max(1, statusLabel.frame.minX - titleX - CGFloat(Space.m)),
            height: titleLabel.intrinsicContentSize.height
        )

        guard isExpanded else {
            scrollView.frame = .zero
            copyButton.frame = .zero
            return
        }
        let detailY = Self.rowHeight
        let copyWidth = copyButton.intrinsicContentSize.width
        copyButton.frame = NSRect(
            x: max(inset, bounds.maxX - inset - copyWidth), y: detailY,
            width: copyWidth, height: CGFloat(Space.xxl)
        )
        let outputY = copyButton.frame.maxY + CGFloat(Space.xs)
        scrollView.frame = NSRect(
            x: 0, y: outputY, width: bounds.width,
            height: max(0, bounds.height - outputY - Self.outputBottomInset)
        )
        scrollView.layoutSubtreeIfNeeded()
        outputTextView.sizeDocument(toFit: scrollView.contentSize)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = context.tokens.artifactSurface.color.cgColor(for: theme)
        titleLabel.textColor = context.tokens.primaryText.color.nsColor(for: theme)
        statusLabel.textColor = status == .failed
            ? AgentLineRole.attention.color.nsColor(for: theme)
            : context.tokens.secondaryText.color.nsColor(for: theme)
        disclosureButton.contentTintColor = context.tokens.secondaryText.color.nsColor(for: theme)
        iconView.contentTintColor = context.tokens.secondaryText.color.nsColor(for: theme)
        copyButton.contentTintColor = context.tokens.secondaryText.color.nsColor(for: theme)
        outputTextView.applyTheme(theme)
    }

    static func measuredHeight(text: String, width: CGFloat, expanded: Bool) -> CGFloat {
        guard expanded else { return rowHeight }
        let outputHeight = min(
            maximumOutputHeight,
            max(minimumOutputHeight, CommandOutputTextView.measuredSize(text).height)
        )
        return rowHeight + CGFloat(Space.xxl + Space.xs) + outputHeight + outputBottomInset
    }

    func copyEntireOutput(to pasteboard: NSPasteboard) {
        outputTextView.writeEntireOutput(to: pasteboard)
    }

    @objc private func toggleDisclosure(_ sender: Any?) {
        guard let blockID else { return }
        isExpanded.toggle()
        context.actions.setExpanded(isExpanded, blockID: blockID)
        disclosureButton.apply(expanded: isExpanded, title: "command output")
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
        textContainerInset = NSSize(width: CGFloat(Space.l), height: CGFloat(Space.m))
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
        string = text
        font = NSFont.token(.bodyMono)
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
        let measured = Self.measuredSize(string)
        frame.size = NSSize(width: max(viewport.width, measured.width), height: max(viewport.height, measured.height))
    }

    static func measuredSize(_ text: String) -> NSSize {
        let font = NSFont.token(.bodyMono)
        let sample = text.isEmpty ? " " : text
        let unbounded = CGFloat.greatestFiniteMagnitude
        let rect = (sample as NSString).boundingRect(
            with: NSSize(width: unbounded, height: unbounded),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let newlineCount = text.reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
        let measuredWidth = ceil(rect.width) + CGFloat(Space.l) * 2
        let linesHeight = CGFloat(newlineCount + 1) * lineHeight
        let measuredHeight = max(ceil(rect.height), linesHeight) + CGFloat(Space.m) * 2
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

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
