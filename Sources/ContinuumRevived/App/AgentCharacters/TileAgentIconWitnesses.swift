import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Dylan's three rules for the tile icon, as witnesses over the real tiles of
/// `--tile-agent-bubble-check`, in every style:
/// 1. Sized from the title: inside the title bar, never taller than it, and no
///    taller than the title's line (4/3 of its point size), at 125%, 50% and
///    30%. The chrome floor may hold the title up; the icon may not outgrow it.
/// 2. Opaque: the plate's own layer tree, rendered over black and over white,
///    shows neither anywhere inside its installed outline, in both appearances.
/// 3. On top: a neighbour stacked above the icon's tile, overlapping the plate,
///    never covers it. The plate still paints there, and a press there is the
///    icon's tile's.
///
/// Written against API the icon has had since it shipped (the plate's frame,
/// its host view, its installed mask), so the same code reads the branch
/// before this change: there it is RED.
@MainActor
enum TileAgentIconWitnesses {
    typealias Style = AgentCharacterConfig.BubbleStyle
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    private static func pump(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private static func show(_ style: Style, _ views: [ManagedAgentTileNSView], _ canvas: CanvasNSView,
                             _ defaults: UserDefaults) throws {
        defaults.set(style.rawValue, forKey: AgentCharacterConfig.bubbleStyleKey)
        SettingChangeEvent.post(SettingID(rawValue: AgentCharacterConfig.bubbleStyleKey))
        try expect(pump(until: {
            canvas.layoutSubtreeIfNeeded()
            return views.allSatisfy { view in
                view.layoutSubtreeIfNeeded()
                guard view.qaAgentBubble?.bubbleStyle == style, view.agentBubbleFrame != nil,
                      let host = view.agentBubbleView else { return false }
                return host.layer?.superlayer != nil && host.bubble.superlayer === host.layer
            }
        }), "\(style.title) reaches every tile")
    }

    private static func settle(_ canvas: CanvasNSView, _ views: [ManagedAgentTileNSView], zoom: Double) {
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
        canvas.layoutSubtreeIfNeeded()
        for view in views { view.layoutSubtreeIfNeeded() }
        canvas.layoutSubtreeIfNeeded()
        CATransaction.flush()
    }

    static func check(views: [ManagedAgentTileNSView], canvas: CanvasNSView, plane: CanvasWorldPlaneView,
                      window: NSWindow, defaults: UserDefaults) throws -> String {
        defer {
            window.appearance = nil
            settle(canvas, views, zoom: 1)
        }
        var tallest: CGFloat = 0
        for style in Style.allCases {
            try show(style, views, canvas, defaults)
            // 1. Sized from the title, at Dylan's zooms.
            for zoom in [1.25, 0.5, 0.3] {
                settle(canvas, views, zoom: zoom)
                for (index, view) in views.enumerated() {
                    let label = "\(style.title) zoom \(zoom) tile \(index)"
                    guard let frame = view.agentBubbleFrame else { throw Failure(description: "\(label): no icon") }
                    let pixel = 1 / (window.backingScaleFactor * zoom) + 0.01
                    let bar = view.chromeBarHeight, line = view.qaTitleFontWorldSize * 4 / 3
                    try expect(frame.minY >= -pixel && frame.maxY <= bar + pixel,
                               "\(label): the icon \(frame) leaves its \(bar) pt title bar")
                    try expect(frame.height <= bar + pixel,
                               "\(label): the icon is \(frame.height) pt, taller than its \(bar) pt title bar")
                    try expect(frame.height <= line + pixel,
                               "\(label): the icon is \(frame.height) pt, taller than its title's \(line) pt line")
                    tallest = max(tallest, frame.height / bar)
                }
            }
            // 2. Opaque, in both appearances, at both ends of the zoom range.
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                window.appearance = NSAppearance(named: appearance)
                for zoom in [1.25, 0.3] {
                    settle(canvas, views, zoom: zoom)
                    for (index, view) in views.enumerated() {
                        let label = "\(style.title) \(appearance == .aqua ? "light" : "dark") zoom \(zoom) tile \(index)"
                        try expectOpaque(view, label: label)
                    }
                }
            }
            window.appearance = nil
            // 3. On top of a neighbour stacked above its tile.
            try expectOnTop(views: views, canvas: canvas, plane: plane, style: style)
        }
        return "tile icon witnesses: every style title-sized (at most \(Int((tallest * 100).rounded()))% of the bar), opaque, on top: PASS"
    }

    /// The plate's own layer tree over two backdrops: inside its outline, no
    /// backdrop may show.
    static func expectOpaque(_ view: ManagedAgentTileNSView, label: String) throws {
        // As the next commit would: a style or size change lays the plate out
        // again before anything is drawn.
        view.qaAgentBubble?.layoutIfNeeded()
        guard let host = view.agentBubbleView, let hostLayer = host.layer, let bubble = view.qaAgentBubble,
              let outline = bubble.qaPlateMaskPath else { throw Failure(description: "\(label): no plate") }
        let box = CGRect(origin: .zero, size: host.bounds.size)
        guard box.width > 0 else { throw Failure(description: "\(label): an empty plate") }
        // Four render pixels a point (at least 64 across), the outline's own
        // anti-aliased edge left out.
        let scale = max(4, 64 / box.width)
        let edge = outline.copy(strokingWithWidth: max(1.5, 3 / scale), lineCap: .round, lineJoin: .round, miterLimit: 10)
        func render(over colour: CGColor) throws -> [UInt8] {
            let width = Int((box.width * scale).rounded(.up)), height = Int((box.height * scale).rounded(.up))
            var data = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure(description: "\(label): no render context")
            }
            context.setFillColor(colour)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            hostLayer.render(in: context)
            return data
        }
        // The provider foreground token is black in light and white in dark:
        // every channel differs by 255, so any show-through is at full scale.
        let black = try render(over: BrandToken.providerForeground.cgColor(for: .light))
        let white = try render(over: BrandToken.providerForeground.cgColor(for: .dark))
        let width = Int((box.width * scale).rounded(.up)), height = Int((box.height * scale).rounded(.up))
        // Either row order: the render's rows may run either way up.
        func bleed(flipped: Bool) -> (Int, Int) {
            var largest = 0, inside = 0
            for y in 0..<height {
                for x in 0..<width {
                    let p = CGPoint(x: (CGFloat(x) + 0.5) / scale,
                                    y: (flipped ? CGFloat(height - y) - 0.5 : CGFloat(y) + 0.5) / scale)
                    guard outline.contains(p), !edge.contains(p) else { continue }
                    inside += 1
                    let i = (y * width + x) * 4
                    for c in 0..<3 { largest = max(largest, abs(Int(black[i + c]) - Int(white[i + c]))) }
                }
            }
            return (largest, inside)
        }
        let (a, b) = (bleed(flipped: false), bleed(flipped: true))
        try expect(a.1 > 0, "\(label): fixture: the outline covers no pixel")
        let through = min(a.0, b.0)
        try expect(through <= 2, "\(label): what lies behind the plate shows through it (largest channel change \(through))")
    }

    /// A neighbour above the icon's tile, overlapping its plate: the plate still
    /// paints over it, and a press there is the icon's tile's.
    static func expectOnTop(views: [ManagedAgentTileNSView], canvas: CanvasNSView, plane: CanvasWorldPlaneView,
                            style: Style) throws {
        settle(canvas, views, zoom: 1)
        let subject = views[0], neighbour = views[1]
        let home = neighbour.frame.origin
        defer {
            neighbour.setFrameOrigin(home)
            settle(canvas, views, zoom: 1)
        }
        guard let plate = subject.agentBubbleFrame, let bubble = subject.qaAgentBubble else {
            throw Failure(description: "\(style.title): no plate to cover")
        }
        let centre = plane.convert(NSPoint(x: plate.midX, y: plate.midY), from: subject)
        // The neighbour's top-left sits up and left of the plate's centre, so
        // its title bar runs straight over the plate, clear of its own icon.
        neighbour.setFrameOrigin(NSPoint(x: centre.x - 60, y: centre.y - 14))
        canvas.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let tiles = plane.subviews.filter { $0 is TileNSView }
        try expect((tiles.firstIndex(of: neighbour) ?? -1) > (tiles.firstIndex(of: subject) ?? Int.max)
                   && neighbour.frame.contains(centre),
                   "\(style.title): fixture: the neighbour is stacked above the tile and over its plate")
        let region = plane.convert(plate, from: subject).insetBy(dx: plate.width * 0.25, dy: plate.height * 0.25)
        func render() throws -> [UInt8] {
            guard let planeLayer = plane.layer else { throw Failure(description: "no plane layer") }
            let width = Int((region.width * 2).rounded(.up)), height = Int((region.height * 2).rounded(.up))
            var data = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure(description: "no render context")
            }
            context.scaleBy(x: 2, y: 2)
            context.translateBy(x: -region.minX, y: -region.minY)
            planeLayer.render(in: context)
            return data
        }
        let shown = try render()
        CATransaction.begin(); CATransaction.setDisableActions(true); bubble.opacity = 0; CATransaction.commit()
        let faded = try render()
        CATransaction.begin(); CATransaction.setDisableActions(true); bubble.opacity = 1; CATransaction.commit()
        let change = zip(shown, faded).map { abs(Int($0) - Int($1)) }.max() ?? 0
        try expect(change >= 48, "\(style.title): a neighbour stacked above its tile covers the icon (largest channel change \(change))")
        if let frameView = canvas.superview {
            let hit = canvas.hitTest(frameView.convert(plane.convert(centre, to: nil), from: nil))
            try expect(hit === subject,
                       "\(style.title): a press on the icon under a neighbour hit \(String(describing: hit.map { type(of: $0) }))")
        }
    }
}
