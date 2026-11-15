import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import QuartzCore

/// The agent's icon on its tile, and the grab handle that moves the tile.
///
/// The character always sits on its own opaque plate, never on the bar or the
/// canvas: the identity colour when the agent has one, otherwise a neutral that
/// stands clear of the bar in both appearances. Two places, one layer
/// (`AgentCharacterConfig.BubbleStyle`):
/// - **Inline**: a rounded square at the start of the title bar, a little less
///   than the bar tall. Hosted in the bar, clipped by it, so it never leaves
///   the tile.
/// - **Squircle** (and **Orb**, the squircle in glass): a rounded square tucked
///   into the tile's top-left corner, 4 pt past its top and left edges, its
///   top-left corner concentric with the tile's. Hosted by a view in the world
///   plane (`TileAgentBubbleView`) so it can break the corner.
///
/// One `CALayer` subtree, never drawn: no layout pass, no `draw(_:)`, nothing
/// AppKit hit-tests, and nothing a camera step touches. Every part is geometry
/// the render server draws itself (gradients, shape masks, a shadow with an
/// explicit path), so it is sharp at every zoom with no re-rasterization, and
/// the only motion — the working light — is render-server animation on the
/// sidebar's clock.
///
/// Every colour is a gradient stop or a mask, never a layer fill or border: the
/// bubble paints the agent's identity colour, which is not a tile token, so it
/// must stay out of the token gate's colour slots (`UIProbeAppearance`). Shape
/// layers here are masks only, painted black.
final class TileAgentBubbleLayer: CALayer {
    typealias Style = AgentCharacterConfig.BubbleStyle

    /// The squircle's measurements at chrome scale 1.
    enum Squircle {
        /// The plate's side.
        static let side: CGFloat = 28
        /// How far it hangs past the tile's top and left edges.
        static let overflow: CGFloat = 4
        /// The radius of the three corners that do not follow the tile's.
        static let cornerRadius: CGFloat = 8
        /// The art's typical pose as a fraction of the side.
        static let artFit: CGFloat = 0.8
        /// The art drops a little, towards the title's row.
        static let artDrop: CGFloat = 1
        /// The clear space every selection ring keeps from the plate, on screen.
        static let ringBreathing: CGFloat = 2.5

        /// The plate's outline in a flipped `box`, outset by `outset`: the
        /// top-left concentric with a tile corner of `tileRadius`, the others
        /// `cornerRadius × scale`; square at Sharp. Hit-testing, painting and the
        /// selection ring's cut all use this one shape.
        static func path(in box: CGRect, tileRadius: CGFloat, scale: CGFloat, outset: CGFloat = 0) -> CGPath {
            let (corner, other) = radii(side: min(box.width, box.height), tileRadius: tileRadius, scale: scale)
            let rounded = tileRadius > 0
            return roundedPath(box.insetBy(dx: -outset, dy: -outset),
                               topLeft: corner + (rounded ? outset : 0), other: other + (rounded ? outset : 0))
        }

        /// The top-left radius, concentric with the tile's corner (its radius
        /// plus the overflow), and the other three. A large tile radius (the
        /// Rounded style) keeps the top-left concentric and takes the room from
        /// its neighbours, which never go below a quarter of the side's spare.
        static func radii(side: CGFloat, tileRadius: CGFloat, scale: CGFloat) -> (corner: CGFloat, other: CGFloat) {
            guard tileRadius > 0, side > 0 else { return (0, 0) }
            let corner = min(side * 0.85, tileRadius + overflow * scale)
            let other = min(cornerRadius * scale, side - corner, side / 2)
            return (corner, max(0, other))
        }

        private static func roundedPath(_ r: CGRect, topLeft tl: CGFloat, other: CGFloat) -> CGPath {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - other, y: r.minY))
            if other > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + other), radius: other) }
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - other))
            if other > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - other, y: r.maxY), radius: other) }
            p.addLine(to: CGPoint(x: r.minX + other, y: r.maxY))
            if other > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - other), radius: other) }
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
            if tl > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + tl, y: r.minY), radius: tl) }
            p.closeSubpath()
            return p
        }
    }

    /// Inline's measurements at chrome scale 1.
    enum Inline {
        /// The plate's margin inside the bar, above and below.
        static let inset: CGFloat = 2
        /// Where the plate starts from the tile's left edge: clear of the
        /// tile's rounded corner.
        static let leading: CGFloat = 6
        /// The plate's corner radius (square at Sharp).
        static let cornerRadius: CGFloat = 6
        /// The art's typical pose as a fraction of the plate's side.
        static let artFit: CGFloat = 0.8

        static func path(in box: CGRect, tileRadius: CGFloat, scale: CGFloat) -> CGPath {
            let radius = tileRadius > 0 ? min(box.width / 2, box.height / 2, cornerRadius * scale) : 0
            return CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
    }

    /// The agent's icon. Its host shows and steps it; the bubble only frames it.
    let sprite: CharacterSpriteLayer

    private(set) var bubbleStyle: Style = AgentCharacterConfig.defaultBubbleStyle
    /// The agent's identity colour, unmuted; nil for an agent with none.
    private(set) var tint: NSColor?
    /// Whether the working look is on (the host applies the sidebar's rule).
    private(set) var isWorking = false
    /// The sidebar's active style (`SidebarActiveIndicatorStyle.rawValue`): the
    /// working look borrows its light.
    private(set) var workingStyle = SidebarActiveIndicatorStyle.fallback.rawValue
    private(set) var phase: Double = 0
    /// The tile's corner radius and the chrome scale, for the squircle's shape.
    private(set) var tileRadius: CGFloat = 10
    private(set) var chromeScale: CGFloat = 1

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

    /// The plate's shadow, cast from the plate's path (a masked layer cannot cast one).
    private let shadowCaster = CALayer()
    /// The plate: a flat fill (Squircle) or a bezel lit from above (Orb).
    private let plate = CAGradientLayer()
    private let plateMask = CAShapeLayer()
    /// Clips the inner light to the plate (inside the Orb's bezel); inline, to
    /// a soft disc behind the art.
    private let clip = CALayer()
    private let clipMask = CAShapeLayer()
    /// Orb only: the glassy sphere inside the bezel, lit from below.
    private let sphere = CAGradientLayer()
    /// The agent's colour washed through the plate; the working wash.
    private let wash = CAGradientLayer()
    /// The working light that moves (Duplex breathes it, Sheen sweeps it).
    private let sheen = CAGradientLayer()
    /// Orb only: the gloss across the plate's top.
    private let gloss = CAGradientLayer()
    /// The plate's hairline edge.
    private let ring = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    /// Classic: a light that travels round the plate's edge. The edge masks a
    /// host that holds still; only the light inside it turns.
    private let orbitHost = CALayer()
    private let orbitMask = CAShapeLayer()
    private let orbit = CAGradientLayer()
    /// Keeps the art on the plate.
    private let artClip = CALayer()
    private let artMask = CAShapeLayer()

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
        "borderWidth": NSNull(), "transform": NSNull(), "contents": NSNull(), "sublayers": NSNull(),
        "path": NSNull(), "lineWidth": NSNull(), "mask": NSNull()]

    private func configure() {
        actions = Self.still
        for layer in [shadowCaster, plate, plateMask, clip, clipMask, sphere, wash, sheen, gloss, ring, ringMask,
                      orbitHost, orbitMask, orbit, artClip, artMask] as [CALayer] {
            layer.actions = Self.still
        }
        // Over the tile's title bar and body, under nothing else on the tile.
        zPosition = 50
        isHidden = true
        shadowCaster.shadowColor = NSColor.black.cgColor
        sphere.type = .radial
        gloss.type = .axial
        orbit.type = .conic
        // A mask paints only its alpha; black is just "opaque".
        for mask in [plateMask, clipMask, artMask] { mask.fillColor = NSColor.black.cgColor }
        for mask in [ringMask, orbitMask] {
            mask.fillColor = nil
            mask.strokeColor = NSColor.black.cgColor
        }
        plate.mask = plateMask
        clip.mask = clipMask
        ring.mask = ringMask
        orbitHost.mask = orbitMask
        addSublayer(shadowCaster)
        addSublayer(plate)
        addSublayer(clip)
        clip.addSublayer(sphere)
        clip.addSublayer(wash)
        clip.addSublayer(sheen)
        clip.addSublayer(gloss)
        addSublayer(ring)
        addSublayer(orbitHost)
        orbitHost.addSublayer(orbit)
        addSublayer(artClip)
        artClip.addSublayer(sprite)
    }

    // MARK: State

    func setStyle(_ style: Style) {
        guard style != bubbleStyle else { return }
        bubbleStyle = style
        repaint()
        setNeedsLayout()
    }

    /// The tile's corner radius and the chrome scale the squircle is drawn at.
    func setGeometry(tileRadius: CGFloat, scale: CGFloat) {
        guard tileRadius != self.tileRadius || scale != chromeScale else { return }
        self.tileRadius = tileRadius
        chromeScale = scale
        setNeedsLayout()
        onShapeChange?()
    }
    /// Told when the plate's outline changes without its box moving (a corner
    /// style change): its host tells the rings that cut around it.
    var onShapeChange: (() -> Void)?

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

    /// The plate's outline in this layer's (flipped) coordinates.
    var platePath: CGPath {
        let box = CGRect(origin: .zero, size: bounds.size)
        return bubbleStyle.breaksCorner
            ? Squircle.path(in: box, tileRadius: tileRadius, scale: chromeScale)
            : Inline.path(in: box, tileRadius: tileRadius, scale: chromeScale)
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let box = CGRect(origin: .zero, size: bounds.size)
        let s = chromeScale
        let orb = bubbleStyle == .orb
        for layer in [shadowCaster, plate, clip, ring, orbitHost, artClip] as [CALayer] { layer.frame = box }
        for mask in [plateMask, clipMask, ringMask, orbitMask, artMask] { mask.frame = box }
        let shape = platePath
        shadowCaster.shadowPath = shape
        shadowCaster.shadowRadius = (orb ? 3 : 2) * s
        shadowCaster.shadowOffset = CGSize(width: 0, height: (orb ? -1.5 : -1) * s)
        plateMask.path = shape
        artClip.mask = artMask
        artMask.path = shape
        // The Orb's bezel: thin and even all round.
        let bezel = orb ? max(1.25, (box.width * 0.075).rounded(.toNearestOrAwayFromZero)) : 0
        let inner = box.insetBy(dx: bezel, dy: bezel)
        clipMask.path = orb
            ? Squircle.path(in: inner, tileRadius: max(0, tileRadius - bezel), scale: s)
            : shape
        sphere.frame = inner
        wash.frame = inner
        sheen.frame = workingStyle == "sheen"
            ? CGRect(x: inner.minX - inner.width, y: inner.minY, width: inner.width * 0.7, height: inner.height) : inner
        // The gloss: a soft cap across the plate's upper half (the layer is
        // geometry-flipped with its host, so "upper" is low y).
        let capInset = inner.width * 0.16
        gloss.frame = CGRect(x: inner.minX + capInset, y: inner.minY + inner.height * 0.06,
                             width: inner.width - 2 * capInset, height: inner.height * 0.44)
        gloss.cornerRadius = gloss.frame.height / 2
        // A hairline edge; the Orb's sits between the bezel and the glass.
        ringMask.path = orb ? clipMask.path : shape
        ringMask.lineWidth = orb ? max(0.75, s) : max(0.5, s) * 2
        // The orbit's light: a conic gradient big enough to cover the plate at
        // any angle, turning inside the edge's mask.
        let diagonal = (box.width * box.width + box.height * box.height).squareRoot()
        orbit.frame = CGRect(x: box.midX - diagonal / 2, y: box.midY - diagonal / 2, width: diagonal, height: diagonal)
        orbitMask.path = shape
        orbitMask.lineWidth = max(1.25, box.width * 0.06) * 2
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
        let chrome = srgb(palette.tileChrome)
        // The agent's colour, or a quiet neutral for an agent without one.
        let hue = srgb(tint ?? palette.textSecondary)
        let tinted = tint.map(srgb)
        let working = isWorking
        // Inline sits in the bar: a plate on it, no shadow under it.
        shadowCaster.isHidden = !bubbleStyle.breaksCorner
        plate.isHidden = false
        ring.isHidden = false
        artClip.mask = artMask
        orbitHost.isHidden = true
        sphere.isHidden = true
        gloss.isHidden = true
        sheen.isHidden = true
        wash.isHidden = false
        wash.type = .axial
        wash.locations = nil
        wash.startPoint = CGPoint(x: 0.5, y: 0)
        wash.endPoint = CGPoint(x: 0.5, y: 1)
        wash.colors = flat(NSColor.clear)
        plate.startPoint = CGPoint(x: 0.5, y: 0)
        plate.endPoint = CGPoint(x: 0.5, y: 1)

        switch bubbleStyle {
        case .inline, .squircle:
            // An opaque plate the art sits on. In the agent's colour, stronger
            // than the bar's 30 % wash so it stands clear of a tinted bar; with
            // no colour, a neutral clearly lighter (dark) or darker (light)
            // than the bar. A hairline edge, almost no shadow.
            plate.colors = flat(Self.plateFill(tint: tinted, chrome: chrome, dark: dark))
            ring.colors = flat(dark ? NSColor.white.withAlphaComponent(tinted == nil ? 0.14 : 0.18)
                                    : NSColor.black.withAlphaComponent(tinted == nil ? 0.12 : 0.1))
            shadowCaster.shadowOpacity = Float(dark ? 0.3 : 0.08)
        case .orb:
            // A glass plate in a thin bezel: deep at the rim, an inner glow low
            // in the body, a gloss across the top.
            let base = tinted ?? srgb(palette.textSecondary)
            let deep = mix(base, .black, dark ? 0.6 : 0.5)
            let core = mix(base, .white, working ? 0.45 : 0.22)
            let bezelTop = dark ? mix(chrome, .white, 0.22) : mix(chrome, .white, 0.85)
            let bezelBottom = dark ? mix(chrome, .black, 0.35) : mix(chrome, .black, 0.22)
            plate.colors = [bezelTop.cgColor, bezelBottom.cgColor]
            shadowCaster.shadowOpacity = Float(dark ? 0.5 : 0.22)
            sphere.isHidden = false
            sphere.colors = [core.cgColor, base.cgColor, deep.cgColor]
            sphere.locations = [0, 0.48, 1]
            // Lit from below the centre, like light held inside the glass.
            sphere.startPoint = CGPoint(x: 0.5, y: 0.68)
            sphere.endPoint = CGPoint(x: 1.15, y: 1.25)
            gloss.isHidden = false
            gloss.colors = [NSColor.white.withAlphaComponent(dark ? 0.42 : 0.55).cgColor,
                            NSColor.white.withAlphaComponent(0).cgColor]
            gloss.startPoint = CGPoint(x: 0.5, y: 0)
            gloss.endPoint = CGPoint(x: 0.5, y: 1)
            ring.colors = flat(NSColor.black.withAlphaComponent(dark ? 0.45 : 0.22))
        }

        // Working, both plates take the sidebar's light.
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
                orbitHost.isHidden = false
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

    /// The plate's opaque fill: the identity colour, or a contrasting neutral.
    /// A coloured plate stands clear of its bar, which wears the same colour
    /// washed at 30 % (`ManagedAgentTileNSView.identityBarAlpha`): it starts
    /// stronger than the wash and steps darker (light) or lighter (dark) until
    /// the two differ by `plateContrast`, so pale hues (mint, yellow) hold too.
    static func plateFill(tint: NSColor?, chrome: NSColor, dark: Bool) -> NSColor {
        let chrome = srgb(chrome).withAlphaComponent(1)
        guard let tint = tint.map({ srgb($0).withAlphaComponent(1) }) else {
            return dark ? mix(chrome, .white, 0.24) : mix(chrome, .black, 0.16)
        }
        let bar = mix(chrome, tint, ManagedAgentTileNSView.identityBarAlpha)
        var plate = dark ? mix(chrome, tint, 0.62) : mix(.white, tint, 0.85)
        let away: NSColor = dark ? .white : .black
        for _ in 0..<12 where contrast(plate, bar) < plateContrast {
            plate = mix(plate, away, 0.08)
        }
        return plate
    }

    /// The WCAG contrast a coloured plate keeps from its tinted bar.
    static let plateContrast: CGFloat = 1.45

    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            let c = srgb(color)
            let linear = [c.redComponent, c.greenComponent, c.blueComponent]
                .map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private static func srgb(_ color: NSColor) -> NSColor { color.usingColorSpace(.sRGB) ?? color }

    private static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        srgb(a).blended(withFraction: t, of: srgb(b)) ?? a
    }

    private func srgb(_ color: NSColor) -> NSColor { Self.srgb(color) }
    private func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor { Self.mix(a, b, t) }

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
            // The sidebar's light round the card, round the plate: 3 s a turn.
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
    var qaParts: (plateShown: Bool, ringShown: Bool, sphereShown: Bool, glossShown: Bool, orbitShown: Bool, sheenShown: Bool) {
        (!plate.isHidden, !ring.isHidden, !sphere.isHidden, !gloss.isHidden, !orbitHost.isHidden, !sheen.isHidden)
    }
    var qaAnimationKeys: [String] {
        [wash, sheen, orbit].flatMap { $0.animationKeys() ?? [] }
    }
    /// QA: whether the art is clipped to the plate.
    var qaArtClippedToPlate: Bool { artClip.mask === artMask && artMask.path != nil }
    /// QA: the outline the plate is actually masked to, in this layer.
    var qaPlateMaskPath: CGPath? { plateMask.path }
    /// QA: the plate's fill stops, which must all be opaque.
    var qaPlateColors: [CGColor] { (plate.colors as? [CGColor]) ?? [] }
}

/// The bubble's host and the plate's cursor. A squircle's is a small view in
/// the world plane, beside its tile rather than inside it, so the plate can
/// break the tile's top-left corner: the tile's own layer clips to its rounded
/// rect (and a tidy animates that clip), so nothing inside the tile can
/// overflow it. Inline's sits in the title bar over the plate, so its pointer
/// and cursor beat the tile's resize bands there, as a press does.
///
/// The canvas stacks every bubble above every tile (`reorderTileSubviews`): a
/// badge that breaks its tile's corner must never be cut by a neighbour's
/// chrome, whichever of the two was focused last. The tile places it
/// (`TileNSView.placeAgentBubble`) whenever its frame, its superview or its
/// bubble changes. A press on the plate — inside the tile or outside it —
/// hit-tests to the tile itself, so the tile's own drag handles it.
///
/// Every frame it takes is filed with the plane (`noteAgentBubble`), so a
/// selection ring finds the plates it must stop short of by asking only the
/// cells its stroke crosses, never by walking the plane.
@MainActor
final class TileAgentBubbleView: NSView {
    weak var tile: TileNSView?
    let bubble: TileAgentBubbleLayer
    private var cursorTrackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    init(bubble: TileAgentBubbleLayer, tile: TileNSView) {
        self.bubble = bubble
        self.tile = tile
        super.init(frame: .zero)
        wantsLayer = true
        identifier = NSUserInterfaceItemIdentifier("tile.agentBubble")
        bubble.onShapeChange = { [weak self] in
            guard let self else { return }
            (self.superview as? CanvasWorldPlaneView)?.agentBubbleReshaped(self)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Take the bubble back from the title bar (it hosts it inline) and fit it
    /// to this view.
    func adoptBubble() {
        guard let host = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if bubble.superlayer !== host { host.addSublayer(bubble) }
        let inLayer = convertToLayer(bounds)
        if bubble.frame != inLayer { bubble.frame = inLayer }
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if bubble.superlayer === layer { adoptBubble() }
        noteWithPlane()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        noteWithPlane()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        noteWithPlane()
    }

    override func viewDidHide() {
        super.viewDidHide()
        noteWithPlane()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        noteWithPlane()
    }

    private func noteWithPlane() {
        (superview as? CanvasWorldPlaneView)?.noteAgentBubble(self)
    }

    /// The plate belongs to the tile: a press there is the tile's. (`point` is
    /// in the superview's coordinates, the plane or the bar.)
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let tile, let superview else { return nil }
        return tile.agentBubbleContains(tile.convert(point, from: superview)) ? tile : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        // Include the box's maximum edges too: NSRect excludes them, while the
        // plate's hit-test includes its outline.
        let area = NSTrackingArea(rect: bounds.insetBy(dx: -1, dy: -1),
                                  options: [.mouseMoved, .cursorUpdate, .activeInActiveApp],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { setCursor(for: event) }
    override func cursorUpdate(with event: NSEvent) { setCursor(for: event) }

    /// The tile's own answer at that point: the open hand on the plate, and
    /// outside it whatever the tile shows there (resize, header, nothing).
    private func setCursor(for event: NSEvent) {
        guard let tile else { return }
        tile.agentBubbleCursor(at: tile.convert(event.locationInWindow, from: nil)).set()
    }
}
