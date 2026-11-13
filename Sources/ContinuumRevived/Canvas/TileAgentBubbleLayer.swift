import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import QuartzCore

/// The agent's icon on its tile: a bubble in the tile's top-right corner, in the
/// agent's identity colour, that is also a grab handle for the tile.
///
/// One `CALayer` subtree on the tile's own layer, never a view: no layout pass,
/// no `draw(_:)`, nothing AppKit hit-tests, and nothing a camera step touches.
/// Every part is geometry the render server draws itself (gradients, corner
/// radii, a border-mask ring, a shadow with an explicit path), so it is sharp at
/// every zoom with no re-rasterization, and the only motion — the working light —
/// is render-server animation on the sidebar's clock.
///
/// Every colour is a gradient stop or a mask, never a layer fill or border: the
/// bubble paints the agent's identity colour, which is not a tile token, so it
/// must stay out of the token gate's colour slots (`UIProbeAppearance`).
final class TileAgentBubbleLayer: CALayer {
    typealias Style = AgentCharacterConfig.BubbleStyle

    /// The agent's icon. Its host shows and steps it; the bubble only frames it.
    let sprite: CharacterSpriteLayer

    private(set) var bubbleStyle: Style = .minimal
    /// The agent's identity colour, unmuted; nil for an agent with none.
    private(set) var tint: NSColor?
    /// Whether the working look is on (the host applies the sidebar's rule).
    private(set) var isWorking = false
    /// The sidebar's active style (`SidebarActiveIndicatorStyle.rawValue`): the
    /// working look borrows its light.
    private(set) var workingStyle = SidebarActiveIndicatorStyle.fallback.rawValue
    private(set) var phase: Double = 0

    /// The tokens the bubble paints from, resolved by its host for the current
    /// appearance (the layer itself never reads an appearance).
    struct Palette: Equatable {
        var dark: Bool
        var tileChrome: NSColor
        var tileBody: NSColor
        var textPrimary: NSColor
        var textSecondary: NSColor
    }
    private var palette: Palette?

    /// The disc and its shadow.
    private let disc = CAGradientLayer()
    /// Clips the inner light to the circle.
    private let clip = CALayer()
    /// Orb only: the glassy sphere inside the bezel, lit from below.
    private let sphere = CAGradientLayer()
    /// The agent's colour washed through the bubble; the working wash.
    private let wash = CAGradientLayer()
    /// The working light that moves (Duplex breathes it, Sheen sweeps it).
    private let sheen = CAGradientLayer()
    /// Orb only: the gloss across the sphere's top.
    private let gloss = CAGradientLayer()
    /// The even ring, in the agent's colour.
    private let ring = CAGradientLayer()
    private let ringMask = CALayer()
    /// Classic: a light that travels round the ring.
    private let orbit = CAGradientLayer()
    private let orbitMask = CALayer()

    static let motionKeyPrefix = "tileAgentBubble."

    init(sprite: CharacterSpriteLayer) {
        self.sprite = sprite
        super.init()
        configure()
    }

    override init(layer: Any) {
        sprite = CharacterSpriteLayer()
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    nonisolated(unsafe) private static let still: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "hidden": NSNull(), "cornerRadius": NSNull(),
        "colors": NSNull(), "locations": NSNull(), "startPoint": NSNull(), "endPoint": NSNull(), "opacity": NSNull(),
        "shadowPath": NSNull(), "shadowOpacity": NSNull(), "shadowRadius": NSNull(), "shadowOffset": NSNull(),
        "borderWidth": NSNull(), "transform": NSNull(), "contents": NSNull(), "sublayers": NSNull()]

    private func configure() {
        actions = Self.still
        for layer in [disc, clip, sphere, wash, sheen, gloss, ring, ringMask, orbit, orbitMask] as [CALayer] {
            layer.actions = Self.still
        }
        // Over the tile's title bar and body, under nothing else on the tile.
        zPosition = 50
        isHidden = true
        disc.shadowColor = NSColor.black.cgColor
        clip.masksToBounds = true
        sphere.type = .radial
        gloss.type = .axial
        orbit.type = .conic
        ring.mask = ringMask
        orbit.mask = orbitMask
        // A mask paints only its alpha; black is just "opaque".
        ringMask.borderColor = NSColor.black.cgColor
        orbitMask.borderColor = NSColor.black.cgColor
        addSublayer(disc)
        addSublayer(clip)
        clip.addSublayer(sphere)
        clip.addSublayer(wash)
        clip.addSublayer(sheen)
        clip.addSublayer(gloss)
        addSublayer(ring)
        addSublayer(orbit)
        addSublayer(sprite)
    }

    // MARK: State

    func setStyle(_ style: Style) {
        guard style != bubbleStyle else { return }
        bubbleStyle = style
        repaint()
        setNeedsLayout()
    }

    func setTint(_ tint: NSColor?) {
        guard tint != self.tint else { return }
        self.tint = tint
        repaint()
    }

    func setWorking(_ working: Bool, style: String, phase: Double) {
        guard working != isWorking || style != workingStyle || phase != self.phase else { return }
        isWorking = working
        workingStyle = style
        self.phase = phase
        repaint()
    }

    func apply(_ palette: Palette) {
        guard palette != self.palette else { return }
        self.palette = palette
        repaint()
    }

    /// Shown while the tile has an icon to put in it.
    func setShown(_ shown: Bool) {
        guard shown == isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = !shown
        CATransaction.commit()
        reconcileMotion(force: false)
    }

    /// Held still by the host when nobody can see the tile.
    private(set) var isPaused = false

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        reconcileMotion(force: false)
    }

    // MARK: Geometry

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let box = bounds
        let side = min(box.width, box.height)
        disc.frame = box
        disc.cornerRadius = side / 2
        disc.shadowPath = CGPath(ellipseIn: CGRect(origin: .zero, size: box.size), transform: nil)
        disc.shadowRadius = bubbleStyle == .orb ? max(1.5, side * 0.09) : max(1, side * 0.06)
        disc.shadowOffset = CGSize(width: 0, height: bubbleStyle == .orb ? -side * 0.04 : -side * 0.02)
        // The orb's bezel: thin and even all round.
        let bezel = bubbleStyle == .orb ? max(1.25, (side * 0.075).rounded(.toNearestOrAwayFromZero)) : 0
        clip.frame = box.insetBy(dx: bezel, dy: bezel)
        clip.cornerRadius = clip.frame.width / 2
        let inner = clip.bounds
        sphere.frame = inner
        wash.frame = inner
        sheen.frame = workingStyle == "sheen"
            ? CGRect(x: -inner.width, y: 0, width: inner.width * 0.7, height: inner.height) : inner
        // The gloss: a soft cap across the sphere's upper half (the layer is
        // geometry-flipped with its host, so "upper" is low y).
        let capInset = inner.width * 0.16
        gloss.frame = CGRect(x: capInset, y: inner.height * 0.06, width: inner.width - 2 * capInset, height: inner.height * 0.44)
        gloss.cornerRadius = gloss.frame.height / 2
        let ringWidth = bubbleStyle == .orb ? max(0.75, side * 0.03) : max(1, side * 0.045)
        ring.frame = bubbleStyle == .orb ? clip.frame : box
        ringMask.frame = ring.bounds
        ringMask.cornerRadius = ring.bounds.width / 2
        ringMask.borderWidth = ringWidth
        orbit.frame = box
        orbitMask.frame = orbit.bounds
        orbitMask.cornerRadius = side / 2
        orbitMask.borderWidth = max(1.25, side * 0.06)
        if workingStyle == "sheen" { reconcileMotion(force: true) }
    }

    // MARK: Paint

    private func flat(_ color: NSColor) -> [CGColor] { [color.cgColor, color.cgColor] }

    private func repaint() {
        guard let palette else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let dark = palette.dark
        let chrome = palette.tileChrome
        let body = palette.tileBody
        let neutral = palette.textSecondary
        // The agent's colour, or a quiet neutral for an agent without one.
        let hue = srgb(tint ?? neutral)
        let working = isWorking

        switch bubbleStyle {
        case .minimal:
            disc.colors = flat(tint == nil ? chrome : body)
            disc.shadowOpacity = dark ? 0.5 : 0.18
            sphere.isHidden = true
            gloss.isHidden = true
            ring.colors = flat(hue.withAlphaComponent(tint == nil ? (dark ? 0.5 : 0.4) : (working ? 1 : 0.8)))
        case .orb:
            // A glass sphere in a thin bezel: deep at the rim, an inner glow
            // low in the body, a gloss across the top.
            let base = tint.map(srgb) ?? srgb(palette.textSecondary)
            let deep = mix(base, .black, dark ? 0.6 : 0.5)
            let core = mix(base, .white, working ? 0.45 : 0.22)
            let bezelTop = dark ? mix(chrome, .white, 0.22) : mix(chrome, .white, 0.85)
            let bezelBottom = dark ? mix(chrome, .black, 0.35) : mix(chrome, .black, 0.22)
            disc.colors = [bezelTop.cgColor, bezelBottom.cgColor]
            disc.startPoint = CGPoint(x: 0.5, y: 0)
            disc.endPoint = CGPoint(x: 0.5, y: 1)
            disc.shadowOpacity = dark ? 0.65 : 0.3
            sphere.isHidden = false
            sphere.colors = [core.cgColor, base.cgColor, deep.cgColor]
            sphere.locations = [0, 0.48, 1]
            // Lit from below the centre, like light held inside the glass.
            sphere.startPoint = CGPoint(x: 0.5, y: 0.68)
            sphere.endPoint = CGPoint(x: 1.15, y: 1.25)
            gloss.isHidden = false
            gloss.colors = [NSColor.white.withAlphaComponent(dark ? 0.5 : 0.62).cgColor,
                            NSColor.white.withAlphaComponent(0).cgColor]
            gloss.startPoint = CGPoint(x: 0.5, y: 0)
            gloss.endPoint = CGPoint(x: 0.5, y: 1)
            ring.colors = flat(NSColor.black.withAlphaComponent(dark ? 0.45 : 0.22))
        }
        if bubbleStyle == .minimal {
            disc.startPoint = CGPoint(x: 0.5, y: 0)
            disc.endPoint = CGPoint(x: 0.5, y: 1)
        }

        // The wash: at rest a Minimal bubble wears the agent's colour faintly;
        // working, both styles take the sidebar's light.
        wash.isHidden = false
        sheen.isHidden = true
        orbit.isHidden = true
        wash.type = .axial
        wash.locations = nil
        wash.startPoint = CGPoint(x: 0.5, y: 0)
        wash.endPoint = CGPoint(x: 0.5, y: 1)
        let restAlpha: CGFloat = bubbleStyle == .orb || tint == nil ? 0 : (dark ? 0.24 : 0.16)
        wash.colors = flat(hue.withAlphaComponent(restAlpha))
        if working {
            let lift: CGFloat = bubbleStyle == .orb ? 0.7 : 1
            switch workingStyle {
            case "gradient":
                let alpha = (dark ? 0.42 : 0.3) * lift
                wash.colors = [hue.withAlphaComponent(alpha).cgColor, hue.withAlphaComponent(alpha * 0.35).cgColor,
                               hue.withAlphaComponent(0).cgColor]
                wash.locations = [0, 0.35, 0.8]
                wash.startPoint = CGPoint(x: 0, y: 0.5)
                wash.endPoint = CGPoint(x: 1, y: 0.5)
            case "sheen":
                wash.colors = flat(hue.withAlphaComponent((dark ? 0.3 : 0.2) * lift))
                sheen.isHidden = false
                sheen.type = .axial
                sheen.startPoint = CGPoint(x: 0, y: 0)
                sheen.endPoint = CGPoint(x: 1, y: 1)
                let light = bubbleStyle == .orb ? NSColor.white : palette.textPrimary
                sheen.colors = [light.withAlphaComponent(0).cgColor, light.withAlphaComponent(dark ? 0.35 : 0.28).cgColor,
                                light.withAlphaComponent(0).cgColor]
            case SidebarActiveIndicatorStyle.classic.rawValue:
                orbit.isHidden = false
                orbit.startPoint = CGPoint(x: 0.5, y: 0.5)
                orbit.endPoint = CGPoint(x: 0.5, y: 0)
                orbit.colors = [hue.withAlphaComponent(0).cgColor, hue.withAlphaComponent(0).cgColor,
                                mix(hue, .white, dark ? 0.35 : 0).withAlphaComponent(1).cgColor, hue.withAlphaComponent(0).cgColor]
                orbit.locations = [0, 0.5, 0.9, 1]
            default: // duplex
                wash.type = .radial
                wash.startPoint = CGPoint(x: 0.2, y: 0.2)
                wash.endPoint = CGPoint(x: 1, y: 1)
                wash.colors = [hue.withAlphaComponent((dark ? 0.5 : 0.36) * lift).cgColor,
                               hue.withAlphaComponent((dark ? 0.12 : 0.08) * lift).cgColor]
                sheen.isHidden = false
                sheen.type = .radial
                sheen.startPoint = CGPoint(x: 0.85, y: 0.85)
                sheen.endPoint = CGPoint(x: 0, y: 0)
                let glow = bubbleStyle == .orb ? mix(hue, .white, 0.55) : hue
                sheen.colors = [glow.withAlphaComponent((dark ? 0.6 : 0.45) * lift).cgColor, glow.withAlphaComponent(0).cgColor]
            }
        }
        setNeedsLayout()
        reconcileMotion(force: false)
    }

    private func srgb(_ color: NSColor) -> NSColor { color.usingColorSpace(.sRGB) ?? color }

    private func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        srgb(a).blended(withFraction: t, of: srgb(b)) ?? a
    }

    // MARK: Working motion

    /// What is animating now; nil when the bubble holds still.
    private(set) var motionSignature: String?
    var isMoving: Bool { motionSignature != nil }
    /// Every motion install, across all bubbles: a witness counts these.
    nonisolated(unsafe) static var motionInstallCount = 0

    /// Set by the host from the characters' own Reduce Motion reading.
    var reduceMotion: () -> Bool = { false } {
        didSet { reconcileMotion(force: false) }
    }

    /// `InboxOwnershipClock.beginTime`, on this layer's clock: every layer given
    /// the same phase shows the same pose at the same instant, so a tile's light
    /// and its sidebar row's run in step and a re-install never jumps.
    private static func beginTime(period: CFTimeInterval, phase: Double, in layer: CALayer) -> CFTimeInterval {
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        return now - (now + phase * period).truncatingRemainder(dividingBy: period)
    }

    private func reconcileMotion(force: Bool) {
        let moving = isWorking && !isPaused && !isHidden && !reduceMotion()
        let signature = moving ? "\(workingStyle):\(bubbleStyle):\(bounds.size)" : nil
        guard force || signature != motionSignature else { return }
        for layer in [wash, sheen, orbit] { layer.removeAllAnimations() }
        motionSignature = signature
        guard moving else { return }
        let inner = clip.bounds
        switch workingStyle {
        case "gradient":
            // The sidebar's minute-long orbit of the light's axis.
            for (key, sign) in [("startPoint", CGFloat(-1)), ("endPoint", CGFloat(1))] {
                let turn = CAKeyframeAnimation(keyPath: key)
                turn.values = (0...64).map { step in
                    let angle = CGFloat(step) / 64 * 2 * .pi
                    return NSValue(point: NSPoint(x: 0.5 + sign * 0.5 * cos(angle), y: 0.5 + sign * 0.5 * sin(angle)))
                }
                turn.calculationMode = .linear
                turn.duration = 60
                turn.repeatCount = .infinity
                turn.beginTime = Self.beginTime(period: 60, phase: phase, in: wash)
                wash.add(turn, forKey: Self.motionKeyPrefix + key)
            }
        case "sheen":
            let sweep = CAKeyframeAnimation(keyPath: "position.x")
            let from = -inner.width * 0.35, to = inner.width * 1.35
            sweep.values = [from, from, to, to]
            sweep.keyTimes = [0, 0.15, 0.45, 1]
            sweep.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut),
                                     CAMediaTimingFunction(name: .linear)]
            sweep.duration = 6
            sweep.repeatCount = .infinity
            sweep.beginTime = Self.beginTime(period: 6, phase: phase, in: sheen)
            sheen.add(sweep, forKey: Self.motionKeyPrefix + "sheen")
        case SidebarActiveIndicatorStyle.classic.rawValue:
            // The sidebar's light round the card, round the bubble: 3 s a turn.
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 3
            spin.repeatCount = .infinity
            spin.beginTime = Self.beginTime(period: 3, phase: phase, in: orbit)
            orbit.add(spin, forKey: Self.motionKeyPrefix + "orbit")
        default:
            // Duplex: the light breathes, 6 s a breath.
            let breathe = CAKeyframeAnimation(keyPath: "opacity")
            breathe.values = [0.2, 0.85, 0.2]
            breathe.keyTimes = [0, 0.5, 1]
            breathe.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            breathe.duration = 6
            breathe.repeatCount = .infinity
            breathe.beginTime = Self.beginTime(period: 6, phase: phase, in: sheen)
            sheen.add(breathe, forKey: Self.motionKeyPrefix + "breathe")
        }
        Self.motionInstallCount += 1
    }

    /// QA: the parts' state, for the witnesses.
    var qaParts: (ringShown: Bool, sphereShown: Bool, glossShown: Bool, orbitShown: Bool, sheenShown: Bool) {
        (!ring.isHidden, !sphere.isHidden, !gloss.isHidden, !orbit.isHidden, !sheen.isHidden)
    }
    var qaAnimationKeys: [String] {
        [wash, sheen, orbit].flatMap { $0.animationKeys() ?? [] }
    }
}
