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
        case "failed": action = "Context compaction failed"
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

@MainActor
private final class CompactionBoundaryView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(text: String, phase: String?, context: AgentRenderContext) {
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
        toolTip = text.contains("≈") ? "Provider-reported estimate" : nil
        setAccessibilityLabel(text)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
    }
}
