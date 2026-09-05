import AppKit
import ContinuumRevivedCore

/// KB-01. The insertion preview inside a lane.
///
/// Deliberately the SAME visual language as the canvas's own drag phantom
/// (`DragGhostOverlayView`): the accent wash, the accent border at 2pt, the
/// 0.14s fade-and-scale on appear, and — the part that makes it feel alive —
/// the 0.16s eased position TRAIL so the phantom lags slightly behind the card
/// as you ride a neighbour's edge instead of rigidly snapping to it.
///
/// Dragging a tile and dragging a task are the same gesture at two scales, so
/// they get the same preview. A second, different-looking preview for cards
/// would be a new visual idea for a verb the app already has one for.
@MainActor
final class BoardCardGhostView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 2
        isHidden = true
        applyAccent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Draw only — never consume mouse events. A preview that swallowed the
    /// pointer would end the drag it is previewing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func applyAccent() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).appResolvedCGColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).appResolvedCGColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAccent()
    }

    /// Show or move the phantom. The frame is set synchronously so it stays
    /// correct and deterministic; the smoothing is purely presentational.
    func show(at frame: NSRect) {
        let appearing = isHidden
        let previousCentre = layer?.presentation()?.position
            ?? CGPoint(x: self.frame.midX, y: self.frame.midY)
        isHidden = false
        let moved = self.frame != frame
        self.frame = frame
        guard let layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if appearing {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.96
            scale.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [fade, scale]
            group.duration = 0.14
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(group, forKey: "ghostAppear")
        } else if moved {
            // Animate FROM where the phantom currently appears TO the new slot;
            // each move interrupts the last, producing a continuous trailing lag
            // rather than a series of jumps.
            let trail = CABasicAnimation(keyPath: "position")
            trail.fromValue = NSValue(point: previousCentre)
            trail.duration = BoardDragConfig.displacementDuration
            trail.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(trail, forKey: "ghostTrail")
        }
    }

    func hide() {
        layer?.removeAllAnimations()
        isHidden = true
    }
}
