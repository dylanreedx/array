import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import QuartzCore

/// The agent's icon on its tile, and the grab handle that moves the tile.
///
/// The character always sits on its own opaque plate, never on the bar or the
/// canvas: the identity colour when the agent has one, otherwise a neutral that
/// stands clear of the bar in both appearances. Every style sits on the title's
/// line, at the start of the title bar, sized from the title so it never
/// outweighs it at any zoom (`AgentCharacterConfig.BubbleStyle`):
/// - **Inline**: a rounded square (square at Sharp corners).
/// - **Squircle**: a superellipse, the app-icon shape.
/// - **Orb**: a circle in glass: the art seated, undistorted, in glass, an edge vignette over it, a translucent rim and a specular
///   highlight above, over the opaque plate. Working, a light travels round
///   its rim.
/// - **Minimal**: a flat squircle, an even full border, the token background
///   and the provider mark inside it. Working, a highlight sweeps round the
///   whole border; the mark itself never moves.
///
/// Hosted by a view in the world plane (`TileAgentBubbleView`) stacked above
/// every tile, so nothing on its tile or a neighbour's draws over it.
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

    /// The plate's measurements. It is sized from the title, never from the
    /// bar or the chrome floor on its own: it grows and shrinks with the title
    /// and is never taller than the bar.
    enum Plate {
        /// The plate's side as a multiple of the title's point size: about the
        /// title's line.
        static let titleRatio: CGFloat = 4.0 / 3.0
        /// The least margin it keeps inside the bar, above and below, at chrome
        /// scale 1.
        static let barInset: CGFloat = 2
        /// Where it starts from the tile's left edge at chrome scale 1: clear
        /// of the tile's rounded corner.
        static let leading: CGFloat = 6
        /// The art's typical pose as a fraction of the side: nearly all of it.
        /// The character fills its plate and its motion frames are cropped by
        /// it, rather than the art shrinking to fit them; just short of the
        /// edge, so a face at the side of a pose stays in.
        static let artFit: CGFloat = 0.92
        /// The clear space every selection ring keeps from the plate, on screen.
        static let ringBreathing: CGFloat = 2.5
        /// Inline's corner radius as a fraction of the side.
        static let inlineRadius: CGFloat = 0.2
        /// The squircle's superellipse exponent.
        static let squircleExponent: CGFloat = 3.6

        /// Whether the style hangs off the tile's top-left corner rather than
        /// sitting on the title's line: the Orb and the Squircle do.
        static func hangs(_ style: Style) -> Bool { style != .inline }
        /// A hanging plate's side as a multiple of the title's point size.
        static let hangRatio: CGFloat = 1.75
        /// The Orb's art, as a fraction of the plate: seated inside the glass.
        static let orbArtScale: CGFloat = 0.74
        /// The circle the Orb's art is clipped to, inset by this fraction of the side.
        static let orbArtInset: CGFloat = 0.07
        /// A hanging plate's side never exceeds this multiple of the bar.
        static let hangMaxBarRatio: CGFloat = 1.3
        /// How much of a hanging plate's side lies past the tile's top and left
        /// edges: its centre just outside the corner, so its inside quarter
        /// curves clear of the title at its normal start.
        static let hangOverflow: CGFloat = 0.55

        /// The plate's outline in a flipped `box`, outset by `outset`.
        /// Hit-testing, painting and the selection ring's cut all use this one
        /// shape. Inline is square at Sharp corners (`tileRadius` 0); the
        /// squircle and the orb keep their shapes.
        static func path(_ style: Style, in box: CGRect, tileRadius: CGFloat, outset: CGFloat = 0) -> CGPath {
            let r = box.insetBy(dx: -outset, dy: -outset)
            guard r.width > 0, r.height > 0 else { return CGPath(rect: r, transform: nil) }
            switch style {
            case .orb:
                return CGPath(ellipseIn: r, transform: nil)
            case .squircle, .minimalSquircle:
                return superellipse(in: r, exponent: squircleExponent)
            case .inline:
                guard tileRadius > 0 else { return CGPath(rect: r, transform: nil) }
                let radius = min(r.width / 2, r.height / 2, min(box.width, box.height) * inlineRadius + outset)
                return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
        }

        private static func superellipse(in r: CGRect, exponent n: CGFloat) -> CGPath {
            let p = CGMutablePath()
            let a = r.width / 2, b = r.height / 2
            let steps = 96
            for i in 0..<steps {
                let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
                let c = cos(t), s = sin(t)
                let x = r.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
                let y = r.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
                if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
            p.closeSubpath()
            return p
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
    /// The tile's corner radius (0 at Sharp) and the chrome scale.
    private(set) var tileRadius: CGFloat = 10
    private(set) var chromeScale: CGFloat = 1
    /// The pointer is over the plate: the orb's glass leans in.
    private(set) var isHovered = false
    /// Whether the orb wears its glass at rest, or only while hovered (a flat
    /// plate at rest).
    nonisolated(unsafe) static var orbGlassAtRest = true

    /// Minimal's provider mark, inside the plate. Never animated.
    private let markLayer = CALayer()
    private var markSource: NSImage?
    private var markCache: (source: ObjectIdentifier, color: NSColor, image: CGImage)?
    /// QA: where the provider mark sits in this layer.
    var qaMarkFrame: CGRect { markLayer.frame }
    var qaMarkAnimationKeys: [String] { markLayer.animationKeys() ?? [] }
    var qaMarkShown: Bool { !markLayer.isHidden && markLayer.contents != nil }

    /// The provider mark Minimal draws in its plate; nil for every other style.
    func setMark(_ image: NSImage?) {
        guard image !== markSource else { return }
        markSource = image
        repaint()
    }

    /// The tokens the bubble paints from, resolved by its host for the current
    /// appearance (the layer itself never reads an appearance).
    struct Palette: Equatable {
        var dark: Bool
        var tileChrome: NSColor
        var tileBody: NSColor
        var textPrimary: NSColor
        var textSecondary: NSColor
        var providerForeground: NSColor
    }
    private var palette: Palette?

    /// The orb's soft shadow, cast from the plate's path (a masked layer cannot cast one).
    private let shadowCaster = CALayer()
    /// The plate: one opaque fill, edge to edge.
    private let plate = CAGradientLayer()
    private let plateMask = CAShapeLayer()
    /// Clips the working light to the plate.
    private let clip = CALayer()
    private let clipMask = CAShapeLayer()
    /// The agent's colour washed through the plate; the working wash.
    private let wash = CAGradientLayer()
    /// The working light that moves (Duplex breathes it, Sheen sweeps it).
    private let sheen = CAGradientLayer()
    /// The plate's hairline edge (Inline and Squircle).
    private let ring = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    /// Classic: a light that travels round the plate's edge. The edge masks a
    /// host that holds still; only the light inside it turns.
    private let orbitHost = CALayer()
    private let orbitMask = CAShapeLayer()
    private let orbit = CAGradientLayer()
    /// Keeps the art on the plate: the character is cropped to its shape.
    private let artClip = CALayer()
    private let artMask = CAShapeLayer()
    /// The orb's glass, over the art: a lens edge that deepens towards the
    /// rim, a translucent rim lit from the top left, and a specular highlight.
    /// All of it sits inside the opaque plate, so nothing behind shows through.
    private let glass = CALayer()
    private let glassMask = CAShapeLayer()
    private let lens = CAGradientLayer()
    private let rim = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let specular = CAGradientLayer()
    private let specularMask = CAShapeLayer()
    /// The globe's slow current: a soft conic wash turning inside the liquid
    /// while the agent works; hidden and unanimated at rest.
    private let swirl = CAGradientLayer()

    static let motionKeyPrefix = "tileAgentBubble."
    /// Seconds for the rim light to travel once round the Orb or Minimal's edge.
    static let rimPeriod: CFTimeInterval = 5
    /// Seconds for the globe's current to turn once.
    static let churnPeriod: CFTimeInterval = 16

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
        for layer in [shadowCaster, plate, plateMask, clip, clipMask, wash, sheen, ring, ringMask,
                      orbitHost, orbitMask, orbit, artClip, artMask, glass, glassMask, lens, rim, rimMask,
                      specular, specularMask, swirl] as [CALayer] {
            layer.actions = Self.still
        }
        isHidden = true
        shadowCaster.shadowColor = NSColor.black.cgColor
        orbit.type = .conic
        lens.type = .radial
        specular.type = .axial
        swirl.type = .conic
        swirl.isHidden = true
        // A mask paints only its alpha; black is just "opaque".
        for mask in [plateMask, clipMask, artMask, glassMask] { mask.fillColor = NSColor.black.cgColor }
        for mask in [ringMask, orbitMask, rimMask, specularMask] {
            mask.fillColor = nil
            mask.strokeColor = NSColor.black.cgColor
        }
        plate.mask = plateMask
        clip.mask = clipMask
        ring.mask = ringMask
        orbitHost.mask = orbitMask
        glass.mask = glassMask
        specular.mask = specularMask
        rim.mask = rimMask
        addSublayer(shadowCaster)
        addSublayer(plate)
        addSublayer(clip)
        clip.addSublayer(wash)
        clip.addSublayer(swirl)
        clip.addSublayer(sheen)
        addSublayer(artClip)
        artClip.addSublayer(sprite)
        addSublayer(markLayer)
        markLayer.actions = Self.still
        markLayer.contentsGravity = .resizeAspect
        markLayer.isHidden = true
        addSublayer(glass)
        glass.addSublayer(lens)
        glass.addSublayer(rim)
        glass.addSublayer(specular)
        addSublayer(ring)
        addSublayer(orbitHost)
        orbitHost.addSublayer(orbit)
    }

    // MARK: State

    func setStyle(_ style: Style) {
        guard style != bubbleStyle else { return }
        bubbleStyle = style
        repaint()
        // The hover look belongs to the style: an Orb's swell never outlives it,
        // and a plate hovered as it becomes an Orb swells at once.
        applyHoverLook(animated: false)
        setNeedsLayout()
        onShapeChange?()
    }

    /// The tile's corner radius and the chrome scale the plate is drawn at.
    func setGeometry(tileRadius: CGFloat, scale: CGFloat) {
        guard tileRadius != self.tileRadius || scale != chromeScale else { return }
        let reshaped = (tileRadius > 0) != (self.tileRadius > 0)
        self.tileRadius = tileRadius
        chromeScale = scale
        setNeedsLayout()
        if reshaped { onShapeChange?() }
    }
    /// Told when the plate's outline changes without its box moving (a style
    /// or corner style change): its host tells the rings that cut around it.
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

    /// The pointer entered or left the plate. The orb's glass fades in (when it
    /// is not worn at rest) and its edge swells a little; the other plates hold
    /// still.
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        applyHoverLook(animated: true)
    }

    /// How much a hovered Orb swells; every other plate holds its size.
    static let orbHoverSwell: CGFloat = 1.04
    /// The plate's scale now: the Orb's swell while hovered, else 1. Its hit
    /// shape follows it (`TileNSView.agentBubbleContains`).
    var hoverSwell: CGFloat { bubbleStyle == .orb && isHovered ? Self.orbHoverSwell : 1 }

    /// The glass and the swell for the current style and hover, from both.
    private func applyHoverLook(animated: Bool) {
        let glassOpacity: Float = bubbleStyle == .orb && (Self.orbGlassAtRest || isHovered) ? 1 : 0
        let swell = CATransform3DMakeScale(hoverSwell, hoverSwell, 1)
        CATransaction.begin()
        defer { CATransaction.commit() }
        guard animated, bubbleStyle == .orb else {
            CATransaction.setDisableActions(true)
            glass.removeAnimation(forKey: Self.motionKeyPrefix + "hover.glass")
            removeAnimation(forKey: Self.motionKeyPrefix + "hover.swell")
            glass.opacity = glassOpacity
            transform = swell
            return
        }
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = glass.presentation()?.opacity ?? glass.opacity
        glass.opacity = glassOpacity
        glass.add(fade, forKey: Self.motionKeyPrefix + "hover.glass")
        // The swell is a critically damped spring (damping = 2·√(k·m)): it
        // settles without overshoot, a little quicker in than out, and starts
        // from wherever the presentation is so a flick in and out never snaps.
        let from = (presentation()?.value(forKeyPath: "transform.scale.x") as? CGFloat) ?? (isHovered ? 1 : Self.orbHoverSwell)
        let stiffness: CGFloat = isHovered ? 520 : 380
        let grow = CASpringAnimation(keyPath: "transform.scale")
        grow.mass = 1
        grow.stiffness = stiffness
        grow.damping = 2 * stiffness.squareRoot()
        grow.fromValue = from
        grow.toValue = hoverSwell
        grow.duration = grow.settlingDuration
        transform = swell
        add(grow, forKey: Self.motionKeyPrefix + "hover.swell")
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
        return Plate.path(bubbleStyle, in: box, tileRadius: tileRadius)
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let box = CGRect(origin: .zero, size: bounds.size)
        let side = min(box.width, box.height)
        for layer in [shadowCaster, plate, clip, ring, orbitHost, artClip, glass] as [CALayer] { layer.frame = box }
        for mask in [plateMask, clipMask, ringMask, orbitMask, artMask, glassMask] { mask.frame = box }
        let shape = platePath
        shadowCaster.shadowPath = shape
        shadowCaster.shadowRadius = max(0.5, side * 0.06)
        shadowCaster.shadowOffset = CGSize(width: 0, height: -max(0.5, side * 0.03))
        plateMask.path = shape
        clipMask.path = shape
        artClip.mask = artMask
        artMask.path = shape
        glassMask.path = shape
        // The liquid is taller than the plate so its surface can slosh without
        // ever baring an edge; the plate's circle crops it.
        wash.frame = bubbleStyle == .orb ? box.insetBy(dx: 0, dy: -side * 0.08) : box
        let reach = side * 1.5
        swirl.frame = CGRect(x: box.midX - reach / 2, y: box.midY - reach / 2, width: reach, height: reach)
        sheen.frame = workingStyle == "sheen"
            ? CGRect(x: box.minX - box.width, y: box.minY, width: box.width * 0.7, height: box.height) : box
        // A hairline edge, inside the plate (a mask strokes both ways; the
        // outer half is cut by nothing, so keep it to the line's width).
        ringMask.path = shape
        ringMask.lineWidth = max(0.5, side / 16)
        // The glass: the lens fills the plate; the rim is a band just inside
        // the edge; the specular sits high on the left.
        lens.frame = box
        rim.frame = box
        rimMask.frame = box
        let rimWidth = max(0.75, side * (bubbleStyle == .orb ? 0.07 : 0.085))
        rimMask.path = Plate.path(bubbleStyle, in: box.insetBy(dx: rimWidth / 2, dy: rimWidth / 2), tileRadius: tileRadius)
        rimMask.lineWidth = rimWidth
        specular.frame = CGRect(x: box.minX + side * 0.14, y: box.minY + side * 0.07,
                                width: side * 0.5, height: side * 0.3)
        // The orbit's light: a conic gradient big enough to cover the plate at
        // any angle, turning inside the edge's mask.
        let diagonal = (box.width * box.width + box.height * box.height).squareRoot()
        orbit.frame = CGRect(x: box.midX - diagonal / 2, y: box.midY - diagonal / 2, width: diagonal, height: diagonal)
        orbitMask.path = shape
        orbitMask.lineWidth = max(1.25, side * 0.08) * 2
        markLayer.frame = box.insetBy(dx: side * 0.23, dy: side * 0.23)
        artClip.sublayerTransform = CATransform3DIdentity
        if bubbleStyle == .orb || bubbleStyle == .minimalSquircle {
            // The rim light's track: a hairline just inside the edge, lit by a
            // band that turns inside it.
            let width = bubbleStyle == .orb ? max(1.25, side * 0.07) : max(0.65, side / 28)
            let path = Plate.path(bubbleStyle, in: box.insetBy(dx: width / 2, dy: width / 2), tileRadius: tileRadius)
            ringMask.path = path
            orbitMask.path = path
            ringMask.lineWidth = width
            orbitMask.lineWidth = width * 1.4
        }
        if bubbleStyle == .orb {
            // Treatment A: the art sits inside the glass, clipped to a circle
            // inset from the rim, with the specular above it.
            let k = Plate.orbArtScale
            artClip.sublayerTransform = CATransform3DMakeScale(k, k, 1)
            artMask.path = CGPath(ellipseIn: box.insetBy(dx: side * Plate.orbArtInset, dy: side * Plate.orbArtInset), transform: nil)
            // A crisp curved highlight on the upper left: a short arc of the
            // glass's own curve, stroked with a round cap and fading out.
            specular.frame = box
            specularMask.frame = box
            let arc = CGMutablePath()
            let radius = side * 0.36
            arc.addArc(center: CGPoint(x: box.midX, y: box.midY), radius: radius,
                       startAngle: 192 * .pi / 180, endAngle: 262 * .pi / 180, clockwise: false)
            specularMask.path = arc
            specularMask.lineWidth = max(1, side * 0.05)
            specularMask.lineCap = .round
        }
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
        let orb = bubbleStyle == .orb
        let minimal = bubbleStyle == .minimalSquircle
        orbitHost.isHidden = true
        sheen.isHidden = true
        wash.type = .axial
        wash.locations = nil
        wash.startPoint = CGPoint(x: 0.5, y: 0)
        wash.endPoint = CGPoint(x: 0.5, y: 1)
        wash.colors = flat(NSColor.clear)

        // An opaque plate the art sits on, edge to edge. In the agent's colour,
        // stronger than the bar's 30 % wash so it stands clear of a tinted bar;
        // with no colour, a neutral clearly lighter (dark) or darker (light)
        // than the bar.
        // Minimal is the flat token background, never an identity colour.
        let fill = minimal ? srgb(palette.tileBody).withAlphaComponent(1)
                           : Self.plateFill(tint: tinted, chrome: chrome, dark: dark)
        plate.colors = flat(fill)
        plate.startPoint = CGPoint(x: 0.5, y: 0)
        plate.endPoint = CGPoint(x: 0.5, y: 1)
        // Inline and Squircle: a hairline edge, no shadow. The orb: glass, and
        // a soft shadow under it.
        ring.isHidden = orb
        ring.colors = flat(dark ? NSColor.white.withAlphaComponent(tinted == nil ? 0.16 : 0.2)
                                : NSColor.black.withAlphaComponent(tinted == nil ? 0.14 : 0.12))
        shadowCaster.isHidden = !orb
        shadowCaster.shadowOpacity = Float(dark ? 0.45 : 0.18)
        glass.isHidden = !orb
        // The glass's target opacity for the style and hover: the same value
        // a hover fade animates to, so setting it never fights the fade.
        glass.opacity = orb && (Self.orbGlassAtRest || isHovered) ? 1 : 0
        swirl.isHidden = true
        if orb {
            // A globe: dark glass in a thin dark metal rim, holding a liquid in
            // the agent's colour, deep at the bottom and edges, bright towards
            // the middle and the surface. The character sits in the liquid,
            // under the glass's vignette and highlight.
            let liquid = tint != nil ? hue : srgb(palette.textSecondary)
            let empty = mix(liquid, .black, 0.9)
            let surface = mix(liquid, .white, 0.5)
            wash.type = .axial
            wash.startPoint = CGPoint(x: 0.5, y: 0)
            wash.endPoint = CGPoint(x: 0.5, y: 1)
            wash.colors = [empty, empty, mix(liquid, .black, 0.55), surface, mix(liquid, .white, 0.14),
                           mix(liquid, .black, 0.2), mix(liquid, .black, 0.7), mix(liquid, .black, 0.9)].map(\.cgColor)
            wash.locations = [0, 0.2, 0.225, 0.245, 0.3, 0.52, 0.85, 1]
            // Brighter toward the middle of the liquid.
            sheen.isHidden = false
            sheen.type = .radial
            sheen.startPoint = CGPoint(x: 0.5, y: 0.55)
            sheen.endPoint = CGPoint(x: 1, y: 1.05)
            sheen.colors = [mix(liquid, .white, 0.35).withAlphaComponent(0.55).cgColor,
                            liquid.withAlphaComponent(0).cgColor]
            sheen.locations = [0, 1]
            // The glass's thickness: clear in the middle, near black at the edge.
            lens.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0).cgColor,
                           NSColor.black.withAlphaComponent(0.8).cgColor]
            lens.locations = [0, 0.42, 1]
            lens.startPoint = CGPoint(x: 0.5, y: 0.5)
            lens.endPoint = CGPoint(x: 1, y: 1)
            // The rim: dark metal, lit from the top left, a weaker return below right.
            rim.colors = [NSColor(white: 0.62, alpha: 1).cgColor, NSColor(white: 0.2, alpha: 1).cgColor,
                          NSColor(white: 0.07, alpha: 1).cgColor, NSColor(white: 0.3, alpha: 1).cgColor]
            rim.locations = [0, 0.35, 0.7, 1]
            rim.startPoint = CGPoint(x: 0.15, y: 0)
            rim.endPoint = CGPoint(x: 0.85, y: 1)
            // The specular: a crisp curved highlight, brightest at its upper left.
            specular.colors = [NSColor.white.withAlphaComponent(0.85).cgColor, NSColor.white.withAlphaComponent(0.25).cgColor]
            specular.startPoint = CGPoint(x: 0.2, y: 0.1)
            specular.endPoint = CGPoint(x: 0.6, y: 0.6)
            // The current: soft arms of light turning through the liquid.
            let arm = mix(liquid, .white, 0.5).withAlphaComponent(0.13).cgColor, none = liquid.withAlphaComponent(0).cgColor
            swirl.colors = [none, arm, none, arm, none, arm, none]
            swirl.locations = [0, 0.1, 0.3, 0.5, 0.68, 0.84, 1]
            swirl.startPoint = CGPoint(x: 0.5, y: 0.5)
            swirl.endPoint = CGPoint(x: 0.5, y: 0)
            swirl.isHidden = !working
        }

        // Working, Inline and Squircle take the sidebar's light; the Orb and
        // Minimal run their own light round the rim, below.
        if working && !orb && !minimal {
            switch workingStyle {
            case "gradient":
                let alpha: CGFloat = dark ? 0.42 : 0.3
                wash.colors = [hue.withAlphaComponent(alpha).cgColor, hue.withAlphaComponent(alpha * 0.35).cgColor,
                               hue.withAlphaComponent(0).cgColor]
                wash.locations = [0, 0.35, 0.8]
                wash.startPoint = CGPoint(x: 0, y: 0.5)
                wash.endPoint = CGPoint(x: 1, y: 0.5)
            case "sheen":
                wash.colors = flat(hue.withAlphaComponent(dark ? 0.3 : 0.2))
                sheen.isHidden = false
                sheen.type = .axial
                sheen.startPoint = CGPoint(x: 0, y: 0)
                sheen.endPoint = CGPoint(x: 1, y: 1)
                let light = palette.textPrimary
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
                wash.colors = [hue.withAlphaComponent(dark ? 0.5 : 0.36).cgColor,
                               hue.withAlphaComponent(dark ? 0.12 : 0.08).cgColor]
                sheen.isHidden = false
                sheen.type = .radial
                sheen.startPoint = CGPoint(x: 0.85, y: 0.85)
                sheen.endPoint = CGPoint(x: 0, y: 0)
                sheen.colors = [hue.withAlphaComponent(dark ? 0.6 : 0.45).cgColor, hue.withAlphaComponent(0).cgColor]
            }
        }
        if orb || minimal {
            // The rim light: a hairline track just inside the edge, a band of
            // light turning inside it while the agent works.
            let light = tint ?? palette.textPrimary
            ring.isHidden = orb
            ring.opacity = 1
            ring.colors = flat(orb ? light.withAlphaComponent(0.22)
                                   : palette.textSecondary.withAlphaComponent(dark ? 0.60 : 0.65))
            orbitHost.isHidden = orb || !working
            orbit.startPoint = CGPoint(x: 0.5, y: 0.5)
            orbit.endPoint = CGPoint(x: 0.5, y: 0)
            orbit.colors = [light.withAlphaComponent(0.15).cgColor, light.withAlphaComponent(0.25).cgColor,
                            light.withAlphaComponent(0.95).cgColor, light.withAlphaComponent(0.25).cgColor,
                            light.withAlphaComponent(0.15).cgColor]
            orbit.locations = [0, 0.45, 0.68, 0.9, 1]
        }
        // Minimal: the provider mark in the token foreground, flat on the plate.
        markLayer.isHidden = !minimal || markSource == nil
        if minimal, let source = markSource {
            markLayer.contents = Self.tintedMark(source, color: palette.providerForeground, cache: &markCache)
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

    /// The template mark filled with `color`, as a bitmap the render server draws
    /// as is. Rebuilt only when the mark or its colour changes.
    private static func tintedMark(_ source: NSImage, color: NSColor,
                                   cache: inout (source: ObjectIdentifier, color: NSColor, image: CGImage)?) -> CGImage? {
        if let cache, cache.source == ObjectIdentifier(source), cache.color == color { return cache.image }
        let side: CGFloat = 128
        let result = NSImage(size: NSSize(width: side, height: side))
        result.lockFocus()
        source.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        color.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill(using: .sourceIn)
        result.unlockFocus()
        guard let image = result.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        cache = (ObjectIdentifier(source), color, image)
        return image
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
        for layer in [wash, sheen, orbit, ring, swirl] { layer.removeAllAnimations() }
        motionSignature = signature
        guard moving else { return }
        if bubbleStyle == .orb {
            // The globe's churn: the current turns once in 16 s and the liquid
            // rises and settles by a hair every 5 s. Render-server animations on
            // the shared clock; nothing per frame, nothing at rest.
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = 2 * Double.pi
            turn.duration = Self.churnPeriod
            turn.repeatCount = .infinity
            turn.beginTime = Self.beginTime(period: Self.churnPeriod, phase: phase, in: swirl)
            swirl.add(turn, forKey: Self.motionKeyPrefix + "churn.current")
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -bounds.height * 0.02
            rise.toValue = bounds.height * 0.02
            rise.duration = 2.5
            rise.autoreverses = true
            rise.repeatCount = .infinity
            rise.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            rise.beginTime = Self.beginTime(period: 5, phase: phase, in: wash)
            wash.add(rise, forKey: Self.motionKeyPrefix + "churn.surface")
            Self.motionInstallCount += 1
            return
        }
        if bubbleStyle == .minimalSquircle {
            // The rim light: one turn every 5 s, on the shared clock so a
            // re-install never jumps. A render-server animation: nothing per frame.
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = 2 * Double.pi
            turn.duration = Self.rimPeriod
            turn.repeatCount = .infinity
            turn.beginTime = Self.beginTime(period: Self.rimPeriod, phase: phase, in: orbit)
            orbit.add(turn, forKey: Self.motionKeyPrefix + "rim")
            Self.motionInstallCount += 1
            return
        }
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
    var qaParts: (plateShown: Bool, ringShown: Bool, glassShown: Bool, orbitShown: Bool, sheenShown: Bool) {
        (!plate.isHidden, !ring.isHidden, !glass.isHidden && glass.opacity > 0, !orbitHost.isHidden || !swirl.isHidden, !sheen.isHidden)
    }
    var qaAnimationKeys: [String] {
        [wash, sheen, orbit, ring, swirl].flatMap { $0.animationKeys() ?? [] }
    }
    /// The real middle-glow geometry and gradient configuration, for transitions.
    var qaSheenFrame: CGRect { sheen.frame }
    var qaSheenStops: (colors: Int, locations: Int?) {
        (sheen.colors?.count ?? 0, sheen.locations?.count)
    }
    /// The offsets installed on the liquid's current animation, not a recomputed plan.
    var qaLiquidSurfaceOffsets: (from: CGFloat, to: CGFloat)? {
        guard let animation = wash.animation(forKey: Self.motionKeyPrefix + "churn.surface") as? CABasicAnimation,
              let from = animation.fromValue as? NSNumber, let to = animation.toValue as? NSNumber else { return nil }
        return (CGFloat(from.doubleValue), CGFloat(to.doubleValue))
    }
    /// QA: whether the art is clipped to the plate.
    var qaArtClippedToPlate: Bool { artClip.mask === artMask && artMask.path != nil }
    /// QA: the outline the plate is actually masked to, in this layer.
    var qaPlateMaskPath: CGPath? { plateMask.path }
    /// QA: the plate's fill stops, which must all be opaque.
    var qaPlateColors: [CGColor] { (plate.colors as? [CGColor]) ?? [] }
}

/// The bubble's host and the plate's cursor: a small view in the world plane,
/// beside its tile rather than inside it, so nothing on any tile — its own
/// controls, a neighbour overlapping it, a neighbour's chrome — ever draws over
/// the icon.
///
/// The canvas stacks every bubble above every tile (`reorderTileSubviews`). The
/// tile places it (`TileNSView.placeAgentBubble`) whenever its frame, its
/// superview or its bubble changes. A press on the plate hit-tests to the tile
/// itself, so the tile's own drag handles it.
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

    /// Fit the bubble to this view. By bounds and position, never frame: the
    /// orb swells under the pointer with a transform.
    func adoptBubble() {
        guard let host = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if bubble.superlayer !== host { host.addSublayer(bubble) }
        let inLayer = convertToLayer(bounds)
        let size = CGRect(origin: .zero, size: inLayer.size)
        let centre = CGPoint(x: inLayer.midX, y: inLayer.midY)
        if bubble.bounds != size { bubble.bounds = size }
        if bubble.position != centre { bubble.position = centre }
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
        bubble.setHovered(false)
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
    /// in the plane's coordinates.)
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let tile, let superview else { return nil }
        guard tile.agentBubbleContains(tile.convert(point, from: superview)) else { return nil }
        return tile.pinnedHeaderPressTarget ?? tile
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        // Include the box's maximum edges too (NSRect excludes them, while the
        // plate's hit-test includes its outline), and a hovered Orb's swell.
        let reach = 1 + bounds.width * (TileAgentBubbleLayer.orbHoverSwell - 1) / 2
        let area = NSTrackingArea(rect: bounds.insetBy(dx: -reach, dy: -reach),
                                  options: [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .activeInActiveApp],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { setCursor(for: event) }
    override func cursorUpdate(with event: NSEvent) { setCursor(for: event) }
    override func mouseEntered(with event: NSEvent) { setCursor(for: event) }
    override func mouseExited(with event: NSEvent) { bubble.setHovered(false) }

    /// The tile's own answer at that point: the open hand on the plate, and
    /// outside it whatever the tile shows there (resize, header, nothing).
    private func setCursor(for event: NSEvent) {
        guard let tile else { return }
        let point = tile.convert(event.locationInWindow, from: nil)
        bubble.setHovered(tile.agentBubbleContains(point))
        tile.agentBubbleCursor(at: point).set()
    }
}
