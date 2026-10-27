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
/// detached from the window, so no camera step reaches it. One view then draws
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
///   rails, pickers, footer) is detached from the window and this view draws it
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
        // Detached views resolve colours against the app's appearance unless told.
        body.appearance = effectiveAppearance
        body.removeFromSuperview()
        body.frame = bounds
        body.layoutSubtreeIfNeeded()
        placeTranscript()
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

    /// The tile changed something the body shows. Only a resting body needs to
    /// be told; a live one invalidates itself.
    func invalidateRestingChrome() {
        guard isResting else { return }
        needsLayout = true
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if isResting {
            body.appearance = effectiveAppearance
            needsDisplay = true
        }
    }

    override func layout() {
        qaLayoutCount += 1
        super.layout()
        if body.frame != bounds { body.frame = bounds }
        if isResting { body.layoutSubtreeIfNeeded() }
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
        body.layoutSubtreeIfNeeded()
        let slot = transcriptSlot
        context.saveGState()
        NativeViewVectorRenderer.draw(body, in: context, parentIsFlipped: isFlipped, skipping: { $0 === slot })
        context.restoreGState()
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
