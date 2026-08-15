import AppKit

/// Opt-in, screen-space readout of the most recently completed canvas gesture.
///
/// The view has no timer, display link, animation or layout constraints. Its
/// text changes once at gesture completion through `CanvasFrameRecorder`, and
/// it remains static during the next measured gesture so it cannot perturb the
/// frame timings it reports.
@MainActor
final class CanvasFrameHUDView: NSView {
    private let label = NSTextField(labelWithString: "FPS —")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).appResolvedCGColor
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Presentation only: never enters canvas or tile event routing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 8, dy: 3)
    }

    func update(stats: CanvasFrameRecorder.GestureStats) {
        label.stringValue = Self.text(for: stats)
    }

    static func text(for stats: CanvasFrameRecorder.GestureStats) -> String {
        let lateShare = Double(stats.overBudgetFrames) / Double(max(stats.frames, 1)) * 100
        return String(
            format: "%.0f FPS · %.0f%% late · p95 %.1f ms",
            stats.effectiveFps,
            lateShare,
            stats.p95Ms
        )
    }

    // MARK: - Deterministic QA seam
    var qaText: String { label.stringValue }
    var qaIgnoresAccessibility: Bool { !isAccessibilityElement() && !label.isAccessibilityElement() }
}
