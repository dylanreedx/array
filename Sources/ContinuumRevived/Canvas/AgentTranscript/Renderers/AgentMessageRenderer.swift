import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// Who an Array agent that sent a message is right now — its identity colour,
/// and whether it has a tile to open. Resolved when the card is drawn, outside
/// the document, for the same reason `AgentReferenceStatusSource` is: a colour
/// change must never rewrite transcript history.
struct AgentMessageSenderSource: @unchecked Sendable {
    struct Sender: Equatable {
        /// A palette name (`ZoneColorConfig.palette`), nil when it has none.
        var identityColorName: String?
        var hasTile: Bool
    }

    let current: (UUID) -> Sender?

    static let unavailable = AgentMessageSenderSource(current: { _ in nil })
}

/// A turn another agent wrote, drawn as FROM that agent: its name in the
/// header, its identity colour down the leading edge, and its words as the
/// card's body. Never a user bubble — the user did not type it.
///
/// The same grammar as the task card beside it (an artifact-surface card with a
/// hairline), with the sender's colour as the one accent. An Array sender with a
/// tile makes the header a button that reveals that tile.
@MainActor
final class AgentMessageRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .agentMessage

    func makeView() -> NSView { AgentMessageCardView(frame: .zero) }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentMessageCardView,
              case let .agentMessage(payload) = block.payload else { return }
        view.apply(blockID: block.id, payload: payload, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        guard case let .agentMessage(payload) = block.payload else { return 0 }
        return AgentMessageCardView.rowHeight(text: payload.text, width: width, zoom: context.pageZoom)
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentMessageCardView,
              case let .agentMessage(payload) = block.payload else { return }
        view.applyAccessibility(payload)
    }
}

@MainActor
final class AgentMessageCardView: NSView {
    // Metrics at 100%, each scaled by the tile's page zoom.
    private static func padding(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.m)) }
    private static func accentWidth(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(3)) }
    private static func headerHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(18)) }
    private static func headerGap(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.xs)) }
    private static func glyphSide(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(12)) }
    /// The row's breathing room around the card, as the task card has.
    private static func rowInset(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(7)) }
    private static func maximumCardWidth(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(640)) }

    static func cardWidth(rowWidth: CGFloat, zoom: AgentPageZoom) -> CGFloat {
        max(0, min(rowWidth, maximumCardWidth(zoom: zoom)))
    }

    private static func bodyWidth(cardWidth: CGFloat, zoom: AgentPageZoom) -> CGFloat {
        max(1, cardWidth - accentWidth(zoom: zoom) - padding(zoom: zoom) * 2)
    }

    /// Measured by a wrapping label cell, the same cell kind that draws it, so
    /// the measured height and the drawn height cannot disagree.
    static func bodyHeight(text: String, width: CGFloat, zoom: AgentPageZoom) -> CGFloat {
        measuringCell.font = .token(.body, zoom: zoom)
        measuringCell.stringValue = text
        let size = measuringCell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        return ceil(size.height)
    }

    static func rowHeight(text: String, width: CGFloat, zoom: AgentPageZoom) -> CGFloat {
        let body = bodyHeight(text: text, width: bodyWidth(cardWidth: cardWidth(rowWidth: width, zoom: zoom), zoom: zoom), zoom: zoom)
        return cardHeight(bodyHeight: body, zoom: zoom) + rowInset(zoom: zoom) * 2
    }

    private static func cardHeight(bodyHeight: CGFloat, zoom: AgentPageZoom) -> CGFloat {
        padding(zoom: zoom) * 2 + headerHeight(zoom: zoom) + headerGap(zoom: zoom) + bodyHeight
    }

    private static let measuringCell: NSTextFieldCell = {
        let cell = NSTextFieldCell(textCell: "")
        cell.isBordered = false
        cell.isBezeled = false
        cell.drawsBackground = false
        cell.wraps = true
        cell.lineBreakMode = .byWordWrapping
        return cell
    }()

    private let card = NSView(frame: .zero)
    private let accent = CALayer()
    let senderButton = AgentMessageSenderButton(frame: .zero)
    let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private var zoom: AgentPageZoom = .default
    private(set) var payload: AgentMessagePayload?
    /// The sender's identity tint as last applied; nil for none.
    private(set) var accentColor: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        card.wantsLayer = true
        card.layer?.borderWidth = CGFloat(LineWidth.hairline)
        card.layer?.masksToBounds = true
        card.layer?.addSublayer(accent)
        addSubview(card)
        card.addSubview(senderButton)
        bodyLabel.isSelectable = true
        bodyLabel.drawsBackground = false
        bodyLabel.isBordered = false
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.setAccessibilityElement(false)
        card.addSubview(bodyLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(blockID: AgentNodeID, payload: AgentMessagePayload, context: AgentRenderContext) {
        zoom = context.pageZoom
        self.payload = payload
        identifier = NSUserInterfaceItemIdentifier("agent.message.\(blockID.rawValue)")
        let tokens = context.tokens
        let appearance = context.appearance
        let sender = payload.senderAgentID.flatMap(context.agentMessageSenders.current)
        accentColor = sender?.identityColorName.map { ZoneChromeNSView.color(named: $0) }

        card.layer?.cornerRadius = CGFloat(zoom.scaled(AgentTileRadius.artifact))
        card.layer?.backgroundColor = tokens.artifactSurface.color.cgColor(for: appearance)
        card.layer?.borderColor = tokens.decorativeLine.color.cgColor(for: appearance)
        // A sender with no colour keeps the card's own quiet edge, never a
        // stand-in hue that would read as somebody's identity.
        accent.backgroundColor = (accentColor ?? tokens.decorativeLine.color.nsColor(for: appearance)).cgColor

        let revealable = payload.origin == .array && sender?.hasTile == true
        senderButton.apply(
            name: payload.senderName,
            caption: Self.caption(payload.origin),
            tint: accentColor,
            revealable: revealable,
            zoom: zoom,
            primary: tokens.primaryText.color.nsColor(for: appearance),
            secondary: tokens.secondaryText.color.nsColor(for: appearance))
        let actions = context.actions
        senderButton.onActivate = revealable ? { [senderID = payload.senderAgentID] in
            guard let senderID else { return }
            actions.perform(.revealMessageSender(blockID: blockID, agentID: senderID))
        } : nil

        bodyLabel.font = .token(.body, zoom: zoom)
        bodyLabel.textColor = tokens.primaryText.color.nsColor(for: appearance)
        bodyLabel.stringValue = payload.text
        applyAccessibility(payload)
        needsLayout = true
    }

    /// What kind of sender this is, after its name.
    static func caption(_ origin: AgentMessagePayload.Origin) -> String {
        switch origin {
        case .array: return "Message"
        case .crossSession, .peer: return "Claude session"
        case .background: return "Background"
        }
    }

    func applyAccessibility(_ payload: AgentMessagePayload) {
        setAccessibilityLabel("Message from \(payload.senderName)")
        setAccessibilityValue(payload.text)
    }

    override func layout() {
        super.layout()
        // Arithmetic only, plus the body cell's own wrap: the row's height was
        // measured by the renderer with the same cell and width. Frames are
        // assigned only when they move (performance.md, trap 3).
        let inset = Self.rowInset(zoom: zoom)
        let width = Self.cardWidth(rowWidth: bounds.width, zoom: zoom)
        let cardFrame = NSRect(x: 0, y: inset, width: width, height: max(0, bounds.height - inset * 2))
        if card.frame != cardFrame { card.frame = cardFrame }
        let accentWidth = Self.accentWidth(zoom: zoom)
        let accentFrame = CGRect(x: 0, y: 0, width: accentWidth, height: cardFrame.height)
        if accent.frame != accentFrame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            accent.frame = accentFrame
            CATransaction.commit()
        }
        let padding = Self.padding(zoom: zoom)
        let x = accentWidth + padding
        let contentWidth = Self.bodyWidth(cardWidth: width, zoom: zoom)
        let headerHeight = Self.headerHeight(zoom: zoom)
        // `card` is not flipped: y grows upward inside it.
        let headerY = cardFrame.height - padding - headerHeight
        let headerFrame = NSRect(
            x: x, y: headerY,
            width: min(contentWidth, senderButton.intrinsicContentSize.width), height: headerHeight)
        if senderButton.frame != headerFrame { senderButton.frame = headerFrame }
        let bodyFrame = NSRect(x: x, y: padding, width: contentWidth,
                               height: max(0, headerY - Self.headerGap(zoom: zoom) - padding))
        if bodyLabel.frame != bodyFrame { bodyLabel.frame = bodyFrame }
    }
}

/// The card's header: a glyph in the sender's colour, its name, and what kind of
/// sender it is. A button only when the sender is an Array agent with a tile.
@MainActor
final class AgentMessageSenderButton: NSButton {
    private let glyphView = NSImageView(frame: .zero)
    let nameLabel = NSTextField(labelWithString: "")
    private var zoom: AgentPageZoom = .default
    private var revealable = false
    private var titleSize = NSSize.zero
    var onActivate: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        attributedTitle = NSAttributedString(string: "")
        image = nil
        imagePosition = .noImage
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        target = self
        action = #selector(activate(_:))
        glyphView.imageScaling = .scaleProportionallyDown
        glyphView.setAccessibilityElement(false)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setAccessibilityElement(false)
        addSubview(glyphView)
        addSubview(nameLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The cell paints nothing; the subviews own the content.
    override func draw(_ dirtyRect: NSRect) {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        revealable && frame.contains(point) ? self : nil
    }

    var isRevealable: Bool { revealable }

    func apply(
        name: String, caption: String, tint: NSColor?, revealable: Bool, zoom: AgentPageZoom,
        primary: NSColor, secondary: NSColor
    ) {
        self.zoom = zoom
        self.revealable = revealable
        isEnabled = revealable
        let pointSize = CGFloat(zoom.scaled(11))
        glyphView.image = CanvasSymbolImage.image(named: "bubble.left.fill", pointSize: pointSize, weight: .semibold)
            ?? CanvasSymbolImage.image(named: "bubble.left", pointSize: pointSize, weight: .semibold)
        glyphView.contentTintColor = tint ?? secondary
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.token(.label, zoom: zoom)
        let composed = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
            .foregroundColor: primary, .paragraphStyle: paragraph])
        composed.append(NSAttributedString(string: "  ·  \(caption)", attributes: [
            .font: font, .foregroundColor: secondary, .paragraphStyle: paragraph]))
        nameLabel.attributedStringValue = composed
        let cell = NSTextFieldCell(textCell: "")
        cell.attributedStringValue = composed
        titleSize = NSSize(width: ceil(cell.cellSize.width), height: ceil(cell.cellSize.height))
        toolTip = revealable ? "Show \(name)" : nil
        setAccessibilityRole(revealable ? .button : .staticText)
        setAccessibilityLabel(revealable ? "Show \(name)" : name)
        invalidateIntrinsicContentSize()
        window?.invalidateCursorRects(for: self)
        needsLayout = true
    }

    private var glyphSide: CGFloat { CGFloat(zoom.scaled(12)) }
    private var gap: CGFloat { CGFloat(zoom.scaled(Space.xs)) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: glyphSide + gap + titleSize.width, height: titleSize.height)
    }

    override func layout() {
        super.layout()
        let glyphFrame = NSRect(x: 0, y: floor((bounds.height - glyphSide) / 2), width: glyphSide, height: glyphSide)
        if glyphView.frame != glyphFrame { glyphView.frame = glyphFrame }
        let nameFrame = NSRect(
            x: glyphSide + gap, y: floor((bounds.height - titleSize.height) / 2),
            width: max(0, bounds.width - glyphSide - gap), height: titleSize.height)
        if nameLabel.frame != nameFrame { nameLabel.frame = nameFrame }
    }

    override func resetCursorRects() {
        if revealable { addCursorRect(bounds, cursor: .pointingHand) }
    }

    @objc private func activate(_ sender: Any?) {
        guard revealable else { return }
        onActivate?()
    }
}
