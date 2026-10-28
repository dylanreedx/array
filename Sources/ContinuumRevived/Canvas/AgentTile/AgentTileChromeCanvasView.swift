import AppKit
import ObjectiveC

/// Draws a detached tree of real AppKit views into one context, at whatever
/// scale that context has — the views' own drawing code, run again, never a
/// cached picture of it.
///
/// Why this exists: a resting agent tile's chrome is ~140 views, and a canvas
/// zoom makes AppKit re-lay out and re-display every one of them per camera
/// step. The chrome tree stays fully alive — the tile keeps writing its labels,
/// pickers and buttons exactly as before — but while the tile rests it is
/// out of the canvas's window (in a hidden one), so no camera step reaches it. One view then draws
/// the whole tree, by asking each view to draw itself into that one view's
/// backing store. A zoom raises that store's `contentsScale` and the same calls
/// run again, sharp: text through `NSCell`/CoreText, SF Symbols through their
/// vector reps, fills and borders as paths.
///
/// What it draws for each visible view, in AppKit's own order: the layer's
/// background (with its corner radius), the view's own content, its subviews,
/// then the layer's border. Content is the cell for `NSTextField`/`NSButton`,
/// the image (tinted) for `NSImageView`, and `draw(_:)` for any view that
/// overrides it. Views whose content lives only in hand-built sublayers are
/// drawn through `CALayer.render(in:)`, which for shape and text layers is
/// vector too.
/// A view that draws itself and says what its picture is made of. Its value
/// joins the fingerprint, and its `needsDisplay` is not read: in the resting
/// host's window a view with its own layer keeps that flag set however often it
/// is cleared, which redrew the whole resting chrome on every streamed chunk.
@MainActor
protocol NativeVectorDrawnContent: NSView {
    var drawnContentFingerprint: Int { get }
}

@MainActor
enum NativeViewVectorRenderer {
    /// Draws `view`, placed by its frame, into `context`, whose user space is
    /// `view.superview`'s coordinate space with flippedness `parentIsFlipped`.
    static func draw(_ view: NSView, in context: CGContext, parentIsFlipped: Bool,
                     skipping skip: ((NSView) -> Bool)? = nil) {
        guard !view.isHidden, view.alphaValue > 0.001 else { return }
        if let skip, skip(view) { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: view.frame.minX, y: view.frame.minY)
        if view.isFlipped != parentIsFlipped {
            context.translateBy(x: 0, y: view.frame.height)
            context.scaleBy(x: 1, y: -1)
        }
        drawContents(of: view, in: context, skipping: skip)
    }

    /// Draws `view` in its OWN coordinate space (the context's user space is
    /// already the view's bounds space).
    static func drawContents(of view: NSView, in context: CGContext, skipping skip: ((NSView) -> Bool)? = nil) {
        if view.bounds.origin != .zero {
            context.translateBy(x: -view.bounds.minX, y: -view.bounds.minY)
        }
        let layer = view.layer
        let alpha = view.alphaValue * CGFloat(layer?.opacity ?? 1)
        let transparent = alpha < 0.999
        if transparent {
            context.setAlpha(alpha)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        let shape = layer.map { outline(of: view.bounds, layer: $0) }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let layer, let background = layer.backgroundColor, background.alpha > 0, let shape {
                context.addPath(shape)
                context.setFillColor(background)
                context.fillPath()
            }
            let clips = (layer?.masksToBounds ?? false) || view.clipsToBounds || view is NSClipView
            if clips, let shape {
                context.saveGState()
                context.addPath(shape)
                context.clip()
            }
            let drawsChildren = drawOwnContent(of: view, in: context)
            if drawsChildren {
                drawLooseSublayers(of: view, in: context)
                for child in view.subviews {
                    draw(child, in: context, parentIsFlipped: view.isFlipped, skipping: skip)
                }
            }
            if clips, shape != nil { context.restoreGState() }
            if let layer, layer.borderWidth > 0, let border = layer.borderColor, border.alpha > 0, let shape {
                // Core Animation fills the ring between the outline and the outline
                // inset by the width; a centred stroke rasterizes lighter.
                let width = layer.borderWidth
                let inner = view.bounds.insetBy(dx: width, dy: width)
                context.addPath(shape)
                if inner.width > 0, inner.height > 0 {
                    context.addPath(roundedPath(inner, radius: max(0, layer.cornerRadius - width),
                                                corners: layer.maskedCorners, flipped: view.isFlipped))
                }
                context.setFillColor(border)
                context.fillPath(using: .evenOdd)
            }
        }
        if transparent { context.endTransparencyLayer() }
    }

    /// Returns whether the view's subviews still need drawing: controls whose
    /// subviews are AppKit's private rendering of the same content (a label's
    /// `NSTextFieldSimpleLabel`, an image view's simple image view, a button's
    /// title field) are drawn whole here.
    private static func drawOwnContent(of view: NSView, in context: CGContext) -> Bool {
        let graphics = NSGraphicsContext(cgContext: context, flipped: view.isFlipped)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        switch view {
        case let field as NSTextField:
            // A label draws through its private simple-label subview when it has
            // one; drawing that view's own `draw(_:)` keeps its exact baseline.
            if field.subviews.contains(where: { !$0.isHidden && overridesDraw($0) }) { return true }
            field.cell?.draw(withFrame: field.bounds, in: field)
            return false
        case let imageView as NSImageView:
            drawImage(of: imageView, in: context)
            return false
        case let button as NSButton:
            button.cell?.draw(withFrame: button.bounds, in: button)
            return false
        default:
            if overridesDraw(view) {
                view.draw(view.bounds)
            }
            return true
        }
    }

    private static func drawImage(of view: NSImageView, in context: CGContext) {
        guard let image = view.image else { return }
        // The image view's own layout already fitted the image; reuse its rect
        // so the drawn glyph lands on the same pixels.
        let rect = view.subviews.first(where: { !$0.isHidden })?.frame ?? fittedRect(image.size, in: view.bounds)
        guard rect.width > 0, rect.height > 0 else { return }
        let tint: NSColor? = image.isTemplate ? (view.contentTintColor ?? .labelColor) : nil
        if let tint {
            context.saveGState()
            context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
            context.setBlendMode(.sourceIn)
            context.setFillColor(tint.cgColor)
            context.fill(rect)
            context.endTransparencyLayer()
            context.restoreGState()
        } else {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
        }
    }

    private static func fittedRect(_ size: NSSize, in bounds: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(1, min(bounds.width / size.width, bounds.height / size.height))
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// Sublayers a view added by hand (shape layers, text layers), as opposed
    /// to its subviews' backing layers and AppKit's private content layer.
    private static func drawLooseSublayers(of view: NSView, in context: CGContext) {
        guard let sublayers = view.layer?.sublayers, !sublayers.isEmpty else { return }
        let owned = Set(view.subviews.compactMap { $0.layer.map(ObjectIdentifier.init) })
        for sublayer in sublayers where !sublayer.isHidden && !owned.contains(ObjectIdentifier(sublayer)) {
            let name = String(describing: type(of: sublayer))
            guard !name.hasPrefix("NS"), name != "ContentLayer", name != "_NSViewBackingLayer" else { continue }
            context.saveGState()
            let origin = CGPoint(x: sublayer.position.x - sublayer.anchorPoint.x * sublayer.bounds.width,
                                 y: sublayer.position.y - sublayer.anchorPoint.y * sublayer.bounds.height)
            // A hand-added sublayer is positioned in its view's layer space,
            // which AppKit keeps aligned with the view's own coordinates.
            context.translateBy(x: origin.x, y: origin.y)
            context.translateBy(x: -sublayer.bounds.minX, y: -sublayer.bounds.minY)
            sublayer.render(in: context)
            context.restoreGState()
        }
    }

    /// The values a detached tree's picture and layout derive from, folded into
    /// one number — read straight from the views, with NO layout pass.
    ///
    /// Why: a streaming agent republishes its turn snapshot on every chunk and
    /// re-applies the same labels and colours, which dirties the detached tree's
    /// Auto Layout engine without changing anything. Laying it out to find that
    /// out cost 11 ms per chunk per resting tile (two thirds of a streaming pan's
    /// main thread). Values hashed: visibility, alpha, layer fills and borders,
    /// label text, colour and font, images and tints, control state, text-view
    /// strings. Frames are a function of these and the body's size, except for
    /// constraint constants, whose one writer (page zoom) forces a settle.
    static func fingerprint(_ root: NSView, skipping skip: ((NSView) -> Bool)? = nil) -> Int {
        var hasher = Hasher()
        func visit(_ view: NSView) {
            guard !view.isHidden, view.alphaValue > 0.001 else { hasher.combine(0); return }
            if let skip, skip(view) { return }
            hasher.combine(ObjectIdentifier(view))
            hasher.combine(view.alphaValue)
            // A missing layer hashes as a default one: in the resting host's window
            // AppKit gives views their backing layers at the next commit, and that
            // draws nothing new. A border colour shows only with a border.
            let layer = view.layer
            hasher.combine(layer?.opacity ?? 1)
            hasher.combine(layer?.backgroundColor)
            hasher.combine(layer?.borderWidth ?? 0)
            if let layer, layer.borderWidth > 0 { hasher.combine(layer.borderColor) }
            hasher.combine(layer?.cornerRadius ?? 0)
            switch view {
            case let field as NSTextField:
                hasher.combine(field.stringValue)
                hasher.combine(field.placeholderString)
                hasher.combine(field.textColor)
                hasher.combine(field.font)
                hasher.combine(field.isEnabled)
                return
            case let imageView as NSImageView:
                hasher.combine(imageView.image.map(ObjectIdentifier.init))
                hasher.combine(imageView.contentTintColor)
                return
            case let button as NSButton:
                hasher.combine(button.title)
                hasher.combine(button.state.rawValue)
                hasher.combine(button.isEnabled)
                hasher.combine(button.image.map(ObjectIdentifier.init))
                return
            default:
                if let drawn = view as? NativeVectorDrawnContent { hasher.combine(drawn.drawnContentFingerprint) }
                if let scroll = view as? NSScrollView {
                    hasher.combine(scroll.drawsBackground)
                    hasher.combine(scroll.backgroundColor)
                    hasher.combine(scroll.borderType.rawValue)
                }
                if let clip = view as? NSClipView {
                    hasher.combine(clip.drawsBackground)
                    hasher.combine(clip.backgroundColor)
                }
                if let control = view as? NSControl { hasher.combine(control.isEnabled) }
                if let text = view as? NSTextView { hasher.combine(text.string) }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return hasher.finalize()
    }

    /// Whether a view that draws itself has asked to be drawn again since the
    /// last `markDrawn` — its content is its own, so its own flag is the signal.
    static func selfDrawnNeedsDisplay(_ root: NSView, skipping skip: ((NSView) -> Bool)? = nil) -> Bool {
        guard !root.isHidden else { return false }
        if let skip, skip(root) { return false }
        if root is NSTextField || root is NSImageView || root is NSButton { return false }
        if root is NativeVectorDrawnContent { return false }
        // Only Array's own drawing views are read by their flag. AppKit's (clip and
        // scroll view backgrounds, text views) draw from properties the fingerprint
        // holds, and in the resting host's window their flags stay set however
        // often they are cleared — which redrew the chrome on every streamed chunk.
        if root.needsDisplay, overridesDraw(root), drawsWithOwnCode(root) { return true }
        return root.subviews.contains { selfDrawnNeedsDisplay($0, skipping: skip) }
    }

    /// After a draw: the views that draw themselves have been drawn.
    static func markDrawn(_ root: NSView) {
        if root.needsDisplay { root.needsDisplay = false }
        root.subviews.forEach(markDrawn)
    }

    /// `rect` in `view`'s bounds, expressed in `ancestor`'s bounds, by frame
    /// arithmetic. `NSView.convert` needs a shared window, which a detached
    /// tree does not have.
    static func convert(_ rect: NSRect, from view: NSView, to ancestor: NSView) -> NSRect {
        var rect = rect
        var current = view
        while current !== ancestor, let parent = current.superview {
            let frame = current.frame, bounds = current.bounds
            var y = rect.minY - bounds.minY
            if current.isFlipped != parent.isFlipped { y = bounds.height - y - rect.height }
            rect = NSRect(x: frame.minX + rect.minX - bounds.minX, y: frame.minY + y,
                          width: rect.width, height: rect.height)
            current = parent
        }
        return rect
    }

    /// Whether `draw(_:)` is Array's code rather than inherited from an AppKit class
    /// (a `ComposerTextView` draws as the `NSTextView` it is).
    private static var ownDrawCache: [ObjectIdentifier: Bool] = [:]
    private static func drawsWithOwnCode(_ view: NSView) -> Bool {
        let cls: AnyClass = type(of: view)
        let key = ObjectIdentifier(cls)
        if let cached = ownDrawCache[key] { return cached }
        let appKit = Bundle(for: NSView.self)
        var ancestor: AnyClass? = cls
        while let current = ancestor, Bundle(for: current) != appKit { ancestor = class_getSuperclass(current) }
        let selector = #selector(NSView.draw(_:))
        let own = ancestor.map {
            class_getMethodImplementation(cls, selector) != class_getMethodImplementation($0, selector)
        } ?? true
        ownDrawCache[key] = own
        return own
    }

    private static let baseDraw = class_getMethodImplementation(NSView.self, #selector(NSView.draw(_:)))
    private static var overrideCache: [ObjectIdentifier: Bool] = [:]

    static func overridesDraw(_ view: NSView) -> Bool {
        let cls: AnyClass = type(of: view)
        let key = ObjectIdentifier(cls)
        if let cached = overrideCache[key] { return cached }
        let overrides = class_getMethodImplementation(cls, #selector(NSView.draw(_:))) != baseDraw
        overrideCache[key] = overrides
        return overrides
    }

    private static func outline(of rect: CGRect, layer: CALayer) -> CGPath {
        roundedPath(rect, radius: layer.cornerRadius, corners: layer.maskedCorners, flipped: false)
    }

    private static func roundedPath(_ rect: CGRect, radius: CGFloat, corners: CACornerMask, flipped: Bool) -> CGPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        guard r > 0 else { return CGPath(rect: rect, transform: nil) }
        let all: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        if corners.isSuperset(of: all) {
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        }
        func cornerRadius(_ corner: CACornerMask) -> CGFloat { corners.contains(corner) ? r : 0 }
        let path = CGMutablePath()
        let minYLeft = cornerRadius(.layerMinXMinYCorner), minYRight = cornerRadius(.layerMaxXMinYCorner)
        let maxYLeft = cornerRadius(.layerMinXMaxYCorner), maxYRight = cornerRadius(.layerMaxXMaxYCorner)
        path.move(to: CGPoint(x: rect.minX + minYLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - minYRight, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: minYRight)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - maxYRight))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: maxYRight)
        path.addLine(to: CGPoint(x: rect.minX + maxYLeft, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: maxYLeft)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + minYLeft))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: minYLeft)
        path.closeSubpath()
        return path
    }
}

/// The content view of an agent tile behind `ARRAY_TRANSCRIPT_RENDERER=canvas`.
///
/// Two states, one picture:
///
/// - **Resting.** The tile's real body (`body`: header, status row, composer,
///   rails, pickers, footer) is in the hidden resting host and this view draws it
///   with `NativeViewVectorRenderer`. The transcript canvas is this view's only
///   subview, framed to the slot the body's stack gives it.
/// - **Live.** The body is installed under the transcript, at the same frame,
///   and this view draws nothing. Every control is the real one.
///
/// The tile moves between them (`ManagedAgentTileNSView.wakeChrome` /
/// `restChromeIfIdle`): the pointer entering, a press, focus or a drag wakes it;
/// leaving with nothing focused rests it. Both states draw the same views with
/// the same code, so the swap is not a visible change.
@MainActor
final class AgentTileChromeCanvasView: NSView {
    let body: NSView
    let transcript: NSView
    let transcriptSlot: TranscriptSlotView
    private(set) var isResting = false
    private(set) var qaDrawCount = 0
    private(set) var qaLastDrawScale: CGFloat = 0
    private(set) var qaRestCount = 0
    private(set) var qaWakeCount = 0
    private(set) var qaLayoutCount = 0

    /// A plain spacer in the body's stack that stands where the transcript would.
    final class TranscriptSlotView: NSView {
        var onFrameChange: (() -> Void)?
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            onFrameChange?()
        }
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            onFrameChange?()
        }
    }

    init(body: NSView, transcript: NSView, transcriptSlot: TranscriptSlotView) {
        self.body = body
        self.transcript = transcript
        self.transcriptSlot = transcriptSlot
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        body.translatesAutoresizingMaskIntoConstraints = true
        body.autoresizingMask = []
        transcript.translatesAutoresizingMaskIntoConstraints = true
        transcript.autoresizingMask = []
        addSubview(body)
        addSubview(transcript, positioned: .above, relativeTo: body)
        transcriptSlot.onFrameChange = { [weak self] in self?.placeTranscript() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    /// The transcript's frame in this view's space, wherever the body is.
    var transcriptFrame: NSRect { transcript.frame }

    func rest() {
        guard !isResting else { return }
        isResting = true
        qaRestCount += 1
        // The host window's appearance is the app's; the body takes the tile's.
        body.appearance = effectiveAppearance
        body.removeFromSuperview()
        Self.restingHost.contentView?.addSubview(body)
        body.frame = bounds
        layOutRestingBody()
        drawnFingerprint = nil
        needsDisplay = true
    }

    func wake() {
        guard isResting else { return }
        isResting = false
        qaWakeCount += 1
        body.appearance = nil
        body.frame = bounds
        addSubview(body, positioned: .below, relativeTo: transcript)
        body.layoutSubtreeIfNeeded()
        placeTranscript()
        needsDisplay = true
    }

    /// The tile changed something the body may show. Marking only: however many
    /// chunks arrive in a frame, the resting body is checked once, in this view's
    /// `layout()` in the next display cycle — and laid out and redrawn only if
    /// what it shows changed. A live body invalidates itself.
    func invalidateRestingChrome() {
        guard isResting else { return }
        restingDirty = true
        needsLayout = true
    }

    /// Something the fingerprint cannot see changed (an appearance, a page-zoom
    /// constant): lay out and redraw at the next display cycle regardless.
    func forceRestingRedraw() {
        guard isResting else { return }
        laidOutFingerprint = nil
        drawnFingerprint = nil
        restingDirty = true
        needsLayout = true
    }

    /// Where every resting body lives: one borderless window that is never
    /// shown, so nothing in it is displayed, hit or composited.
    ///
    /// Why a window and not nowhere: a view tree outside any window has no Auto
    /// Layout engine of its own, so each `layoutSubtreeIfNeeded` built a temporary
    /// one and added every constraint of the ~230-view body again — two thirds of
    /// a resting layout, run whenever a streaming agent's labels changed and at
    /// every turn end. In a window the engine persists and a changed label is an
    /// incremental update.
    static let restingHost: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 4096, height: 4096),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 4096, height: 4096))
        return window
    }()

    private var restingDirty = false
    /// The values the body was last laid out for, and last drawn with; nil forces.
    private var laidOutFingerprint: Int?
    private var drawnFingerprint: Int?
    private(set) var qaUnchangedInvalidations = 0
    private(set) var qaBodyLayoutCount = 0
    private(set) var qaSettleCount = 0

    private func layOutRestingBody() {
        qaBodyLayoutCount += 1
        body.layoutSubtreeIfNeeded()
        // After the pass: a layout may itself hide a control (the mic that does
        // not fit), and the fingerprint is of what was laid out.
        laidOutFingerprint = currentFingerprint
        placeTranscript()
    }

    private var currentFingerprint: Int {
        let slot = transcriptSlot
        var hasher = Hasher()
        hasher.combine(bounds.width)
        hasher.combine(bounds.height)
        hasher.combine(NativeViewVectorRenderer.fingerprint(body, skipping: { $0 === slot }))
        return hasher.finalize()
    }

    /// Once per display cycle at most, from `layout()`.
    private func settleRestingBody() {
        restingDirty = false
        qaSettleCount += 1
        let values = currentFingerprint
        if values != laidOutFingerprint { layOutRestingBody() }
        let slot = transcriptSlot
        if laidOutFingerprint != drawnFingerprint
            || NativeViewVectorRenderer.selfDrawnNeedsDisplay(body, skipping: { $0 === slot }) {
            needsDisplay = true
        } else {
            qaUnchangedInvalidations += 1
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if isResting {
            body.appearance = effectiveAppearance
            forceRestingRedraw()
        }
    }

    override func layout() {
        qaLayoutCount += 1
        super.layout()
        if body.frame != bounds {
            body.frame = bounds
            if isResting { restingDirty = true }
        }
        if isResting, restingDirty { settleRestingBody() }
        placeTranscript()
    }

    /// The transcript sits where the slot is, with each edge held still against
    /// moves of under two device pixels (and under a point).
    ///
    /// Why the hold: a body laid out out of the window (resting) gets exact frames,
    /// and the same body laid out in it (live) gets frames rounded to the device
    /// pixel grid of the tile's CURRENT camera zoom — at zoom 0.37 the slot's
    /// bottom edge landed 0.43 pt higher. A tail-following transcript keeps its
    /// last line on that bottom edge, so every wake, rest, or live re-layout at a
    /// new zoom moved every line by a fraction of a pixel: the 2-3 px shift between
    /// a frame shown mid-zoom and the settled canvas. Rounding differs by a
    /// pixel or so; anything the body really changes (a rail, a line of draft, a
    /// banner) moves an edge by points, and is taken.
    private func placeTranscript() {
        // The slot is laid out in the body's space, and the body fills this view
        // at the origin with the same flippedness, so the rect carries over.
        let target = NativeViewVectorRenderer.convert(transcriptSlot.bounds, from: transcriptSlot, to: body)
        let current = transcript.frame
        guard current != .zero else {
            transcript.frame = target
            return
        }
        // Two pixels, and never under a point: the rounding compounds through the
        // tile, this view, the body and the stack (1.43x measured 0.38 pt, past
        // one 0.35 pt pixel).
        let tolerance = max(2 * devicePixel, 1)
        func hold(_ old: CGFloat, _ new: CGFloat) -> CGFloat { abs(new - old) < tolerance ? old : new }
        let minX = hold(current.minX, target.minX), maxX = hold(current.maxX, target.maxX)
        let minY = hold(current.minY, target.minY), maxY = hold(current.maxY, target.maxY)
        let rect = NSRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        if current != rect { transcript.frame = rect }
    }

    /// One device pixel in this view's units, at the camera zoom it is shown at.
    private var devicePixel: CGFloat {
        let backing = convertToBacking(NSSize(width: 1, height: 1))
        return 1 / max(0.01, min(abs(backing.width), abs(backing.height)))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isResting, let context = NSGraphicsContext.current?.cgContext else { return }
        qaDrawCount += 1
        qaLastDrawScale = layer?.contentsScale ?? 0
        // No layout here: a camera step redraws at a new scale and nothing else,
        // and the frames are the ones `settleRestingBody` laid out for these values.
        let slot = transcriptSlot
        context.saveGState()
        NativeViewVectorRenderer.draw(body, in: context, parentIsFlipped: isFlipped, skipping: { $0 === slot })
        context.restoreGState()
        NativeViewVectorRenderer.markDrawn(body)
        drawnFingerprint = laidOutFingerprint
    }

    /// A press that reached this view while resting (a path that bypassed the
    /// tile's hit-test wake): wake, then deliver the same press to the real view.
    var onRestingPress: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if isResting, let onRestingPress { onRestingPress(event); return }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if isResting, let onRestingPress { onRestingPress(event); return }
        super.rightMouseDown(with: event)
    }
}
