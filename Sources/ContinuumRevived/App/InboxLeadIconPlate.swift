import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import QuartzCore

/// DESIGN ROUND ONLY (array/sidebar-character-expander). Never merged as is.
///
/// A lead row's agent icon, moved to the row's leading edge and made the fold
/// control. It is the tile header's own renderer — `TileAgentBubbleLayer` around a
/// `CharacterSpriteLayer`, in the tile's chosen Inline / Squircle / Orb / Minimal
/// plate — not a new drawing. With agent icons off the classic fold control stays.
///
/// The temporary QA switch is `ARRAY_SIDEBAR_LEAD_ICON` = `settle` | `halo` | `lift`
/// (anything else is off). Each is one motion for the same click.
enum InboxLeadIconVariant: String {
    case off, settle, halo, lift

    @MainActor static var current: InboxLeadIconVariant = {
        ProcessInfo.processInfo.environment["ARRAY_SIDEBAR_LEAD_ICON"].flatMap(InboxLeadIconVariant.init(rawValue:)) ?? .off
    }()

    static let expandDuration: CFTimeInterval = 0.32
    static let collapseDuration: CFTimeInterval = 0.26
    /// Soft start, long quiet landing, no overshoot (the fold control's curve).
    nonisolated(unsafe) static let timing = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0.28, 1)
}

@MainActor
final class InboxLeadIconPlate: NSView {
    static let side: CGFloat = 26

    private let sprite = CharacterSpriteLayer()
    private let bubble: TileAgentBubbleLayer
    /// What the motion animates: the plate and its halo together.
    private let host = CALayer()
    private let halo = CAShapeLayer()
    private var artFrame: CGRect = .zero
    private(set) var expanded = false
    private(set) var hovered = false
    private var lastKey: String?
    /// The helper count, on the plate's lower right corner.
    private let badge = NSTextField(labelWithString: "")
    private static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    var badgeText: String { badge.isHidden ? "" : badge.stringValue }

    /// One record per parent: a fold rebuilds cells, so the motion's clock is the
    /// parent's, and a replacement cell joins it mid-flight.
    private struct Record { var expanded: Bool; var startedAt: CFTimeInterval }
    private static var records: [UUID: Record] = [:]

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        bubble = TileAgentBubbleLayer(sprite: sprite)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        sprite.hostIsFlipped = true
        host.addSublayer(bubble)
        halo.fillColor = nil
        halo.lineWidth = 1.5
        halo.strokeEnd = 0
        halo.actions = ["strokeEnd": NSNull(), "path": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        host.addSublayer(halo)
        layer?.addSublayer(host)
        badge.font = Self.badgeFont
        badge.alignment = .center
        badge.wantsLayer = true
        badge.isHidden = true
        badge.setAccessibilityElement(false)
        addSubview(badge)
        host.actions = ["transform": NSNull(), "shadowOpacity": NSNull(), "shadowRadius": NSNull(),
                        "position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Show the agent's icon in the tile's style. `atlas` is the one the row's
    /// character resolved; the plan is the row's own state plan.
    func show(plan: AgentCharacterPlan, atlas: AgentCharacterSpriteAtlas, phase: Double, now: Date,
              tint: NSColor?, working: Bool, workingPhase: Double, reduceMotion: @escaping () -> Bool) {
        let controller = AgentCharacterController.shared
        sprite.show(plan, sprite: atlas, phase: phase, now: now)
        if bubble.bubbleStyle != controller.bubbleStyle { bubble.setStyle(controller.bubbleStyle) }
        bubble.reduceMotion = reduceMotion
        bubble.setTint(tint)
        bubble.setWorking(working, style: controller.workingStyle.rawValue, phase: workingPhase)
        applyPalette()
        // The tile's fit: the typical pose fills the plate; frames are cropped by it.
        let scale = CGFloat(controller.theme?.scale ?? 1)
        let frameSize = NSSize(width: CGFloat(atlas.atlas.frameWidth) / scale, height: CGFloat(atlas.atlas.frameHeight) / scale)
        let typical = max(1, atlas.typicalInkSide / scale)
        let body = CGPoint(x: atlas.bodyCentre.x / scale, y: atlas.bodyCentre.y / scale)
        let side = Self.side
        let perArt = side * TileAgentBubbleLayer.Plate.artFit / typical
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        func snap(_ v: CGFloat) -> CGFloat { (v * backing).rounded() / backing }
        artFrame = CGRect(x: snap(side / 2 - body.x * perArt), y: snap(side / 2 - body.y * perArt),
                          width: frameSize.width * perArt, height: frameSize.height * perArt)
        needsLayout = true
        isHidden = false
        bubble.setShown(true)
    }

    func hide() {
        guard !isHidden else { return }
        sprite.clear()
        bubble.setShown(false)
        isHidden = true
    }

    func setPaused(_ paused: Bool) {
        sprite.setPaused(paused)
        bubble.setPaused(paused)
    }

    func applyPalette() {
        let theme = effectiveTokenTheme
        bubble.apply(TileAgentBubbleLayer.Palette(
            dark: theme != .light,
            tileChrome: SurfaceToken.tileChrome.color.nsColor(for: theme),
            tileBody: SurfaceToken.tileBody.color.nsColor(for: theme),
            textPrimary: TextToken.textPrimary.color.nsColor(for: theme),
            textSecondary: TextToken.textSecondary.color.nsColor(for: theme),
            providerForeground: BrandToken.providerForeground.nsColor(for: theme),
            orbRimColors: AgentIconMaterialToken.orbRimCGColors))
        badge.textColor = TextToken.textPrimary.color.nsColor(in: self)
        badge.layer?.backgroundColor = SurfaceToken.tileChrome.color.cgColor(in: self)
        badge.layer?.borderColor = TextToken.textSecondary.color.cgColor(in: self)
    }

    /// The helper count, as a small pill on the plate's lower right. 0 hides it.
    func setCount(_ count: Int) {
        let text = count > 0 ? "\(count)" : ""
        guard badge.stringValue != text || badge.isHidden != text.isEmpty else { return }
        badge.stringValue = text
        badge.isHidden = text.isEmpty
        needsLayout = true
    }

    /// The pointer is over the icon's control: it swells a little.
    func setHovered(_ hovered: Bool, variant: InboxLeadIconVariant) {
        guard hovered != self.hovered else { return }
        let from = (host.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? restScale(variant: variant)
        self.hovered = hovered
        lastKey = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.transform = CATransform3DMakeScale(restScale(variant: variant), restScale(variant: variant), 1)
        CATransaction.commit()
        let swell = CABasicAnimation(keyPath: "transform.scale")
        swell.fromValue = from
        swell.toValue = restScale(variant: variant)
        swell.duration = 0.14
        swell.timingFunction = InboxLeadIconVariant.timing
        host.add(swell, forKey: "hover")
    }

    private func restScale(variant: InboxLeadIconVariant) -> CGFloat {
        (variant == .lift && expanded ? 1.08 : 1) * (hovered ? 1.06 : 1)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPalette()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let box = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        host.frame = box
        bubble.setGeometry(tileRadius: CGFloat(Radius.container), scale: 1)
        bubble.frame = box
        sprite.frame = artFrame
        halo.frame = box
        if !badge.isHidden {
            let size = badge.intrinsicContentSize
            let h: CGFloat = 13
            let w = max(h, ceil(size.width) + 6)
            badge.frame = NSRect(x: Self.side - w + 4, y: Self.side - h + 3, width: w, height: h)
            badge.layer?.cornerRadius = h / 2
            badge.layer?.borderWidth = 0.5
        }
        let path = TileAgentBubbleLayer.Plate.path(bubble.bubbleStyle, in: box.insetBy(dx: -2.5, dy: -2.5),
                                                   tileRadius: CGFloat(Radius.container), outset: 0)
        halo.path = path
        halo.strokeColor = (bubble.tint ?? TextToken.textSecondary.color.nsColor(in: self)).withAlphaComponent(0.7).cgColor
        CATransaction.commit()
        sprite.refreshOrientation()
    }

    // MARK: Expand / collapse

    /// Rest at `expanded`; when it differs from what this parent last showed,
    /// play the variant's motion on the parent's own clock.
    func setExpanded(_ expanded: Bool, parent: UUID, variant: InboxLeadIconVariant, animated: Bool) {
        // Re-applying the same state must not cancel a motion in flight.
        let key = "\(variant.rawValue)-\(expanded)-\(hovered)"
        guard key != lastKey else { return }
        lastKey = key
        self.expanded = expanded
        let previous = Self.records[parent]
        var record = previous ?? Record(expanded: expanded, startedAt: -1)
        if let previous, previous.expanded != expanded, animated {
            record = Record(expanded: expanded, startedAt: CACurrentMediaTime())
        } else if previous == nil || previous?.expanded == expanded {
            record.expanded = expanded
        } else {
            record = Record(expanded: expanded, startedAt: -1)
        }
        Self.records[parent] = record
        rest(variant: variant, expanded: expanded)
        let duration = expanded ? InboxLeadIconVariant.expandDuration : InboxLeadIconVariant.collapseDuration
        guard record.startedAt > 0, CACurrentMediaTime() - record.startedAt < duration else { return }
        play(variant: variant, expanded: expanded, startedAt: record.startedAt, duration: duration)
    }

    private func rest(variant: InboxLeadIconVariant, expanded: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.removeAllAnimations()
        halo.removeAllAnimations()
        halo.strokeEnd = variant == .halo && expanded ? 1 : 0
        let lifted = variant == .lift && expanded
        let scale = restScale(variant: variant)
        host.transform = CATransform3DMakeScale(scale, scale, 1)
        host.shadowColor = NSColor.black.cgColor
        host.shadowOpacity = lifted ? 0.30 : 0
        host.shadowRadius = lifted ? 6 : 0
        host.shadowOffset = CGSize(width: 0, height: -2)
        CATransaction.commit()
    }

    private func play(variant: InboxLeadIconVariant, expanded: Bool, startedAt: CFTimeInterval, duration: CFTimeInterval) {
        func timed<T: CABasicAnimation>(_ animation: T) -> T {
            animation.duration = duration
            animation.beginTime = host.convertTime(startedAt, from: nil)
            animation.fillMode = .backwards
            animation.timingFunction = InboxLeadIconVariant.timing
            return animation
        }
        switch variant {
        case .off: break
        case .settle:
            // A press: the plate dips and settles back as the rows unfold.
            let dip = CAKeyframeAnimation(keyPath: "transform.scale")
            dip.values = [1, 0.86, 1]
            dip.keyTimes = [0, 0.4, 1]
            dip.duration = duration
            dip.beginTime = host.convertTime(startedAt, from: nil)
            dip.timingFunctions = [InboxLeadIconVariant.timing, InboxLeadIconVariant.timing]
            host.add(dip, forKey: "settle")
        case .halo:
            let draw = timed(CABasicAnimation(keyPath: "strokeEnd"))
            draw.fromValue = expanded ? 0 : 1
            draw.toValue = expanded ? 1 : 0
            halo.add(draw, forKey: "halo")
        case .lift:
            let scale = timed(CABasicAnimation(keyPath: "transform.scale"))
            scale.fromValue = expanded ? 1 : 1.08
            scale.toValue = expanded ? 1.08 : 1
            host.add(scale, forKey: "liftScale")
            let shadow = timed(CABasicAnimation(keyPath: "shadowOpacity"))
            shadow.fromValue = expanded ? 0 : 0.30
            shadow.toValue = expanded ? 0.30 : 0
            host.add(shadow, forKey: "liftShadow")
            let radius = timed(CABasicAnimation(keyPath: "shadowRadius"))
            radius.fromValue = expanded ? 0 : 6
            radius.toValue = expanded ? 6 : 0
            host.add(radius, forKey: "liftRadius")
        }
    }
}
