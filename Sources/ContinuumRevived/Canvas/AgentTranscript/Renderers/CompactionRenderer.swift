import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

@MainActor
final class CompactionRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .compaction

    func makeView() -> NSView { CompactionBoundaryView(frame: .zero) }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? CompactionBoundaryView,
              case .compaction(let payload) = block.payload else { return }
        view.apply(text: Self.label(payload), phase: payload.phase, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        CGFloat(context.pageZoom.scaled(28))
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard case .compaction(let payload) = block.payload else { return }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        view.setAccessibilityLabel(Self.label(payload))
    }

    nonisolated static func label(_ payload: AgentCompactionPayload) -> String {
        let action: String
        switch payload.phase {
        case "failed":
            // The provider's reason when it gave one ("Nothing to compact yet").
            action = payload.errorMessage.map { "Context compaction failed · \($0)" }
                ?? "Context compaction failed"
        case "cancelled": action = "Context compaction cancelled"
        case "indeterminate": action = "Context compaction outcome unknown — queue paused; resume when ready"
        default:
            let automatic: Bool? = {
                switch payload.trigger {
                case "manual": return false
                case "threshold", "overflowRecovery", "providerAutomatic": return true
                default: return payload.automaticCompaction
                }
            }()
            action = automatic == true
                ? "Context compacted automatically"
                : (automatic == false ? "Context compacted manually" : "Context compacted")
        }
        guard let before = payload.preTokens, let after = payload.postTokens else { return action }
        let beforePrefix = payload.preTokensEstimated == true ? "≈" : ""
        let afterPrefix = payload.postTokensEstimated == true ? "≈" : ""
        return "\(action) · \(beforePrefix)\(shortTokens(before)) → \(afterPrefix)\(shortTokens(after))"
    }

    nonisolated private static func shortTokens(_ value: Int) -> String {
        guard abs(value) >= 1_000 else { return String(value) }
        let thousands = Double(value) / 1_000
        return thousands.rounded() == thousands
            ? "\(Int(thousands))k"
            : String(format: "%.1fk", thousands)
    }
}

/// The point the provider cut the context: a quiet hairline either side of a
/// small label, the same decorative line role `ThematicBreakView` uses — a
/// boundary is structure, not news. The label carries the outcome and, only
/// when the provider reported them, the before → after sizes.
///
/// The host paints no fill (CLAUDE.md hazard 8); only the two rules carry a
/// colour, re-applied from `applyTokens()`.
@MainActor
final class CompactionBoundaryView: NSView, TokenThemed {
    private let label = NSTextField(labelWithString: "")
    private let leadingRule = CALayer()
    private let trailingRule = CALayer()
    private var theme: TokenTheme = .dark
    /// Measured once per `apply`, never in `layout()` (performance.md).
    private var labelSize: NSSize = .zero
    private var gap: CGFloat = CGFloat(Space.m)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = nil
        for rule in [leadingRule, trailingRule] {
            rule.masksToBounds = true
            layer?.addSublayer(rule)
        }
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        addSubview(label)
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(text: String, phase: String?, context: AgentRenderContext) {
        theme = context.appearance
        label.stringValue = text
        label.font = .systemFont(ofSize: CGFloat(context.pageZoom.scaled(11)), weight: .medium)
        switch phase {
        case "failed":
            label.textColor = AccentToken.accentFailed.color.nsColor(for: context.appearance)
        case "indeterminate":
            label.textColor = AccentToken.accentApproval.color.nsColor(for: context.appearance)
        default:
            label.textColor = context.tokens.secondaryText.color.nsColor(for: context.appearance)
        }
        // The cell's size, not `intrinsicContentSize`: the latter came back
        // 4-8pt short of what the cell draws (and varies with the order font
        // and string were set), which truncated "Context compacted manu…" in a
        // row with hundreds of points to spare.
        let cellSize = label.cell?.cellSize ?? label.intrinsicContentSize
        labelSize = NSSize(width: ceil(cellSize.width), height: ceil(cellSize.height))
        gap = CGFloat(context.pageZoom.scaled(Space.m))
        // A narrow tile truncates the reason; the full row stays one hover away.
        toolTip = phase == "failed" ? text : (text.contains("≈") ? "Provider-reported estimate" : nil)
        setAccessibilityLabel(text)
        applyTokens()
        needsLayout = true
    }

    /// What a reader actually sees: the label's drawn width against the width
    /// its full text needs, so a witness catches "Context compacted manu…".
    var qaLabelText: String { label.stringValue }
    var qaLabelDrawnWidth: CGFloat { label.frame.width }
    /// The cell's own size for its full string — what drawing needs to avoid
    /// truncating. Deliberately NOT `intrinsicContentSize`, which reports a
    /// few points short (and differs with the order font/string were set).
    var qaLabelNeededWidth: CGFloat { ceil(label.cell?.cellSize.width ?? 0) }

    func applyTokens() {
        let colour = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        leadingRule.backgroundColor = colour
        trailingRule.backgroundColor = colour
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func layout() {
        super.layout()
        let labelWidth = min(ceil(labelSize.width), max(0, bounds.width - 2 * gap))
        let labelFrame = NSRect(
            x: ((bounds.width - labelWidth) / 2).rounded(),
            y: ((bounds.height - labelSize.height) / 2).rounded(),
            width: labelWidth, height: labelSize.height)
        if label.frame != labelFrame { label.frame = labelFrame }
        let height = max(CGFloat(LineWidth.hairline), 1.0 / (window?.backingScaleFactor ?? 2))
        let y = (bounds.height - height) / 2
        let leading = NSRect(x: 0, y: y, width: max(0, labelFrame.minX - gap), height: height)
        let trailing = NSRect(
            x: labelFrame.maxX + gap, y: y,
            width: max(0, bounds.width - labelFrame.maxX - gap), height: height)
        // Unconditional frame writes are performance.md trap 3.
        if leadingRule.frame != leading || trailingRule.frame != trailing {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            leadingRule.frame = leading
            trailingRule.frame = trailing
            CATransaction.commit()
        }
    }
}
