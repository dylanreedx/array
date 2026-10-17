import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// The board task a user sent with their turn: the composer's "▣ Title · Task
/// context" chip, kept after the send. Same grammar as the file-reference rail
/// beside it — an artifact-surface capsule with a glyph — with the task's first
/// line of description muted underneath. The agent received the whole task; the
/// document holds only this title and summary, never the board/card ids.
@MainActor
final class AgentTaskReferenceRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .taskReference

    func makeView() -> NSView { AgentTaskReferenceRowView(frame: .zero) }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentTaskReferenceRowView,
              case let .taskReference(payload) = block.payload else { return }
        view.apply(blockID: block.id, payload: payload, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        guard case let .taskReference(payload) = block.payload else { return 0 }
        return AgentTaskReferenceRowView.rowHeight(hasSummary: payload.hasSummary, zoom: context.pageZoom)
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentTaskReferenceRowView,
              case let .taskReference(payload) = block.payload else { return }
        view.applyAccessibility(payload)
    }
}

private extension AgentTaskReferencePayload {
    var hasSummary: Bool { !(summary ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
}

@MainActor
final class AgentTaskReferenceRowView: NSView {
    /// Card heights match the file chip (one line) and fit a caption under the
    /// title (two lines); the row adds the file rail's breathing room.
    static func cardHeight(hasSummary: Bool, zoom: AgentPageZoom) -> CGFloat {
        CGFloat(zoom.scaled(hasSummary ? 44 : 26))
    }
    static func rowHeight(hasSummary: Bool, zoom: AgentPageZoom) -> CGFloat {
        cardHeight(hasSummary: hasSummary, zoom: zoom) + CGFloat(zoom.scaled(14))
    }
    private static func maximumCardWidth(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(440)) }

    private let card = NSView(frame: .zero)
    private let glyphLabel = NSTextField(labelWithString: "▣")
    let titleLabel = NSTextField(labelWithString: "")
    let summaryLabel = NSTextField(labelWithString: "")
    private var zoom: AgentPageZoom = .default
    private var hasSummary = false
    /// Natural card width, derived in `apply` so `layout()` measures nothing.
    private var naturalCardWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        card.wantsLayer = true
        // A hairline is a device property, not a metric: it does not scale.
        card.layer?.borderWidth = CGFloat(LineWidth.hairline)
        addSubview(card)
        for label in [glyphLabel, titleLabel, summaryLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setAccessibilityElement(false)
            card.addSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(blockID: AgentNodeID, payload: AgentTaskReferencePayload, context: AgentRenderContext) {
        zoom = context.pageZoom
        hasSummary = payload.hasSummary
        identifier = NSUserInterfaceItemIdentifier("agent.taskReference.\(blockID.rawValue)")
        let tokens = context.tokens
        let appearance = context.appearance
        // Corner style (Settings › Appearance › Corner style): an artifact card.
        card.layer?.cornerRadius = CornerRole.artifact.cgRadius(zoom: zoom)
        card.layer?.backgroundColor = tokens.artifactSurface.color.cgColor(for: appearance)
        card.layer?.borderColor = tokens.decorativeLine.color.cgColor(for: appearance)

        glyphLabel.font = .systemFont(ofSize: CGFloat(zoom.scaled(13)), weight: .semibold)
        glyphLabel.textColor = tokens.secondaryText.color.nsColor(for: appearance)
        titleLabel.font = .token(.label, zoom: zoom)
        titleLabel.textColor = tokens.primaryText.color.nsColor(for: appearance)
        titleLabel.stringValue = payload.title
        summaryLabel.font = .token(.caption, zoom: zoom)
        summaryLabel.textColor = tokens.secondaryText.color.nsColor(for: appearance)
        summaryLabel.stringValue = hasSummary ? (payload.summary ?? "") : ""
        summaryLabel.isHidden = !hasSummary

        let textWidth = max(titleLabel.intrinsicContentSize.width,
                            hasSummary ? summaryLabel.intrinsicContentSize.width : 0)
        naturalCardWidth = ceil(textLeading + textWidth + CGFloat(zoom.scaled(Space.m)))
        toolTip = hasSummary ? payload.title + "\n" + (payload.summary ?? "") : payload.title
        applyAccessibility(payload)
        needsLayout = true
    }

    func applyAccessibility(_ payload: AgentTaskReferencePayload) {
        setAccessibilityLabel("Board task, \(payload.title)")
        setAccessibilityValue(payload.hasSummary ? payload.summary : nil)
    }

    private var textLeading: CGFloat {
        CGFloat(zoom.scaled(Space.s)) + glyphWidth + CGFloat(zoom.scaled(Space.xs))
    }
    private var glyphWidth: CGFloat { CGFloat(zoom.scaled(14)) }

    override func layout() {
        super.layout()
        let height = Self.cardHeight(hasSummary: hasSummary, zoom: zoom)
        let width = min(bounds.width, naturalCardWidth, Self.maximumCardWidth(zoom: zoom))
        card.frame = NSRect(x: 0, y: max(0, floor((bounds.height - height) / 2)), width: max(0, width), height: height)

        let textX = textLeading
        let textWidth = max(0, width - textX - CGFloat(zoom.scaled(Space.s)))
        let lineHeight = CGFloat(zoom.scaled(17))
        let titleY = hasSummary ? CGFloat(zoom.scaled(5)) : floor((height - lineHeight) / 2)
        // `card` is not flipped: y grows upward inside it.
        glyphLabel.frame = NSRect(x: CGFloat(zoom.scaled(Space.s)), y: height - titleY - lineHeight,
                                  width: glyphWidth, height: lineHeight)
        titleLabel.frame = NSRect(x: textX, y: height - titleY - lineHeight, width: textWidth, height: lineHeight)
        summaryLabel.frame = NSRect(x: textX, y: height - titleY - lineHeight * 2, width: textWidth, height: lineHeight)
    }
}
