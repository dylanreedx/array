import AppKit
import ContinuumRevivedAgentUI

/// Each visible slice shares the group's geometry and absolute CA timeline.
/// No timer, layout measurement, or idle-group animation.
@MainActor
final class InboxExpandedGroupLight: NSView {
    private struct DrawingState: Equatable {
        let slice: InboxOwnershipSlice
        let card: CGRect
        let style: String
        let dark: Bool
        let reduced: Bool
    }
    private var drawingState: DrawingState?
    private var focus: CAGradientLayer?
    private var previousStyle = ""
    var reducesMotionForChecks = false { didSet { drawingState = nil; if let last { show(last.0, card: last.1, style: last.2) } } }
    private var last: (InboxOwnershipSlice, CGRect, String)?
    var renderedLayersForChecks: [CALayer] {
        var result: [CALayer] = []
        for root in layer?.sublayers ?? [] {
            result.append(root)
            for child in root.sublayers ?? [] {
                result.append(child)
                result.append(contentsOf: child.sublayers ?? [])
            }
        }
        return result
    }

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = true }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func show(_ slice: InboxOwnershipSlice, card: CGRect, style: String) {
        last = (slice, card, style)
        if !slice.activeGroup || style == "current" {
            if !isHidden { layer?.sublayers?.forEach { $0.removeFromSuperlayer() } }
            isHidden = true
            drawingState = nil
            focus = nil
            return
        }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let reduced = reducesMotionForChecks || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let key = DrawingState(slice: slice, card: card, style: style, dark: dark, reduced: reduced)
        guard drawingState != key else { return }
        drawingState = key
        last = (slice, card, style)
        let presentedFocus = focus?.presentation() as? CAGradientLayer
        let oldFocus: CGPoint? = previousStyle == style ? (presentedFocus?.startPoint ?? focus?.startPoint) : nil
        focus = nil
        previousStyle = style
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        isHidden = !slice.activeGroup || style == "current"
        guard !isHidden, let layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let whole = CALayer(); whole.frame = card; whole.cornerRadius = Radius.card; whole.masksToBounds = true
        layer.addSublayer(whole)
        let colour = slice.sweepColour.map(AgentInboxView.identityDotColour(named:)) ?? TextToken.textPrimary.color.nsColor(in: self)
        let h = max(1, card.height)
        func gradient(_ alpha: CGFloat, radial: Bool = false) -> CAGradientLayer {
            let g = CAGradientLayer(); g.frame = whole.bounds
            g.type = radial ? .radial : .axial
            g.colors = [colour.withAlphaComponent(alpha).cgColor, colour.withAlphaComponent(0).cgColor]
            whole.addSublayer(g); return g
        }
        func fade(_ g: CALayer) {
            let mask = CAGradientLayer(); mask.frame = g.bounds
            mask.startPoint = CGPoint(x: 0.5,y: 0); mask.endPoint = CGPoint(x: 0.5,y: 1)
            mask.colors = [NSColor.black.cgColor,NSColor.black.cgColor,NSColor.clear.cgColor]
            mask.locations = [0, NSNumber(value: Double(min(0.7,slice.leadHeight / h))),1]
            g.mask = mask
        }
        func animate(_ animation: CAAnimation, on target: CALayer, key: String, delay: Double = 0) {
            guard !reduced else { return }
            animation.repeatCount = .infinity
            animation.fillMode = .backwards
            animation.beginTime = InboxOwnershipClock.beginTime(period: animation.duration, phase: slice.sweepPhase ?? 0, in: target) + delay
            target.add(animation, forKey: key)
        }
        switch style {
        case "duplex":
            let a = gradient(dark ? 0.20 : 0.13, radial: true)
            a.startPoint = CGPoint(x: 0.1,y: 0.08); a.endPoint = CGPoint(x: 1.1,y: 0.78)
            let b = gradient(dark ? 0.17 : 0.11, radial: true)
            let y = slice.runningY.map { $0 / h } ?? min(0.9, slice.leadHeight / h * 0.8)
            b.startPoint = CGPoint(x: 0.88,y: y); b.endPoint = CGPoint(x: 0.08,y: y + 0.48)
            focus = b
            let elapsed = slice.focusChangedAt.map { CACurrentMediaTime() - $0 } ?? 0
            let from = slice.focusFrom.map { CGPoint(x: 0.88, y: $0) } ?? oldFocus
            if !reduced, elapsed < 0.6, let from, abs(from.y - y) > 0.001 {
                for (key, from, to) in [("startPoint", from, b.startPoint), ("endPoint", CGPoint(x: from.x - 0.8, y: from.y + 0.48), b.endPoint)] {
                    let settle = CABasicAnimation(keyPath: key)
                    settle.fromValue = NSValue(point: from); settle.toValue = NSValue(point: to)
                    settle.duration = 0.6
                    if let changedAt = slice.focusChangedAt { settle.beginTime = b.convertTime(changedAt, from: nil) }
                    settle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    b.add(settle, forKey: "group.settle." + key)
                }
            }
            let breath = CAKeyframeAnimation(keyPath: "opacity"); breath.values = [0.2,0.85,0.2]; breath.keyTimes = [0,0.5,1]; breath.duration = 4
            breath.timingFunctions = [.init(name: .easeInEaseOut),.init(name: .easeInEaseOut)]
            animate(breath,on:b,key:"group.focus")
            // Keep the diagonal pair anchored horizontally; only the right light
            // eases six points farther down and returns over the existing breath.
            for (key, point) in [("startPoint", b.startPoint), ("endPoint", b.endPoint)] {
                let travel = CAKeyframeAnimation(keyPath: key)
                travel.values = [point, CGPoint(x: point.x, y: point.y + min(6 / h, max(0, 0.88 - y))), point]
                    .map { NSValue(point: $0) }
                travel.keyTimes = [0, 0.5, 1]; travel.duration = 4
                travel.timingFunctions = [.init(name: .easeInEaseOut), .init(name: .easeInEaseOut)]
                animate(travel, on: b, key: "group.travel." + key)
            }

        case "gradient":
            let a: CGFloat = dark ? 0.15 : 0.11
            let g = gradient(a)
            g.colors = [colour.withAlphaComponent(a).cgColor,colour.withAlphaComponent(a * 0.35).cgColor,colour.withAlphaComponent(0).cgColor]
            g.locations = [0,0.2475,0.55]; g.startPoint = CGPoint(x:0,y:0.5);g.endPoint = CGPoint(x:1,y:0.5);fade(g)
            for (key,sign) in [("startPoint",CGFloat(-1)),("endPoint",CGFloat(1))] {
                let orbit = CAKeyframeAnimation(keyPath:key)
                orbit.values = (0...128).map { i in let a = CGFloat(i)/128 * 2 * .pi; return NSValue(point:CGPoint(x:0.5 + sign * 0.5 * cos(a),y:0.5 + sign * 0.5 * sin(a))) }
                orbit.duration = 60; orbit.calculationMode = .linear;animate(orbit,on:g,key:"group.orbit." + key)
            }
        default:
            // Soft lead veil bridges into quieter individually rounded helper panels.
            let veil = gradient(dark ? 0.16 : 0.10); veil.startPoint = CGPoint(x:0.5,y:0);veil.endPoint = CGPoint(x:0.5,y:min(1,(slice.leadHeight + 28)/h))
            veil.colors = [colour.withAlphaComponent(dark ? 0.16 : 0.10).cgColor, colour.withAlphaComponent(dark ? 0.16 : 0.10).cgColor, colour.withAlphaComponent(0).cgColor]
            veil.locations = [0, NSNumber(value: Double(min(0.95, slice.leadHeight / min(h, slice.leadHeight + 28)))), 1]
            let localTop = max(0,slice.offset - 4)
            let panel = CALayer()
            panel.frame = slice.rowIndex == 0 ? CGRect(x:0,y:0,width:card.width,height:slice.leadHeight) : CGRect(x:30,y:localTop,width:card.width - 38,height:InboxOwnershipChrome.subagentHeight - 3)
            panel.cornerRadius = max(2,Radius.card - 2); panel.masksToBounds = true
            if slice.rowIndex > 0 { panel.backgroundColor = colour.withAlphaComponent(dark ? 0.055 : 0.035).cgColor }
            whole.addSublayer(panel)
            let shine = CAGradientLayer();shine.frame = panel.bounds
            let ink = TextToken.textPrimary.color.nsColor(in:self)
            shine.colors = [ink.withAlphaComponent(0).cgColor,ink.withAlphaComponent(dark ? 0.055 : 0.03).cgColor,ink.withAlphaComponent(0).cgColor]
            shine.startPoint = CGPoint(x:0,y:0);shine.endPoint = CGPoint(x:1,y:1);shine.position.x = -card.width;panel.addSublayer(shine)
            let sweep = CAKeyframeAnimation(keyPath:"position.x")
            sweep.values = [-card.width,-card.width,card.width * 2,card.width * 2];sweep.keyTimes = [0,0.12,0.38,1];sweep.duration = 6
            sweep.timingFunctions = [.init(name:.linear),.init(name:.easeInEaseOut),.init(name:.linear)]
            animate(sweep,on:shine,key:"group.sheen",delay:Double(slice.rowIndex) * 0.22)
            let rim = CAShapeLayer();rim.frame = whole.bounds;rim.path = CGPath(roundedRect:whole.bounds.insetBy(dx:0.5,dy:0.5),cornerWidth:Radius.card,cornerHeight:Radius.card,transform:nil)
            rim.fillColor = nil;rim.strokeColor = colour.withAlphaComponent(dark ? 0.10 : 0.075).cgColor;rim.lineWidth = 1;whole.addSublayer(rim)
        }
    }
}
