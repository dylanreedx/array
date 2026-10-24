import AppKit
import ContinuumRevivedAgentUI

/// A review sheet, not a witness: candidate subagent indicators drawn inside a
/// mock folded-parent card with the sidebar's own tokens and fonts, in each
/// state and appearance. `--sidebar-indicator-options-check` writes
/// `qa-runs/sidebar-indicator-options/options.png`.
@MainActor
enum SidebarIndicatorOptions {
    enum Option: String, CaseIterable {
        case triangle = "Triangle (now)"
        case row = "Row of dots"
        case tree = "Tiny tree"
        case stack = "Mini stack"
        case ring = "Progress ring"
    }

    enum State: String, CaseIterable {
        case idle = "All idle"
        case working = "2 of 3 working"
        case hover = "Hover"
        case open = "Open (2 of 3)"
    }

    static func write(to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try render(cellWidth: 300, zoom: 2, to: directory.appendingPathComponent("options.png"))
        // The glyph and count alone, enlarged.
        try render(cellWidth: 64, zoom: 5, to: directory.appendingPathComponent("options-closeup.png"))
        try SidebarStackOptions.write(to: directory)
        return directory.appendingPathComponent("options.png")
    }

    private static func render(cellWidth: CGFloat, zoom: CGFloat, to url: URL) throws {
        let cell = NSSize(width: cellWidth, height: 52), labelW: CGFloat = 104, header: CGFloat = 22
        let rows = Option.allCases.count * 2
        let size = NSSize(width: labelW + cell.width * CGFloat(State.allCases.count),
                          height: header + cell.height * CGFloat(rows))
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor(white: 0.42, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: zoom > 2 ? 7 : 10, weight: .semibold),
                                                       .foregroundColor: NSColor.white]
            for (column, state) in State.allCases.enumerated() {
                draw(state.rawValue, at: NSPoint(x: labelW + CGFloat(column) * cell.width + 6, y: 5), attrs)
            }
            var row = 0
            for option in Option.allCases {
                for theme in [TokenTheme.light, .dark] {
                    let y = header + CGFloat(row) * cell.height
                    draw("\(option.rawValue)\n\(theme == .dark ? "dark" : "light")", at: NSPoint(x: 6, y: y + 12), attrs)
                    for (column, state) in State.allCases.enumerated() {
                        let rect = NSRect(x: labelW + CGFloat(column) * cell.width, y: y,
                                          width: cell.width, height: cell.height)
                        NSGraphicsContext.saveGraphicsState()
                        NSBezierPath(rect: rect).addClip()
                        drawCard(option, state, theme, in: rect)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    row += 1
                }
            }
            return true
        }
        let pixels = NSSize(width: size.width * zoom, height: size.height * zoom)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { throw NSError(domain: "options", code: 1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "options", code: 2) }
        try png.write(to: url)
    }

    private static func draw(_ text: String, at point: NSPoint, _ attrs: [NSAttributedString.Key: Any]) {
        (text as NSString).draw(at: point, withAttributes: attrs)
    }

    private static func mix(_ alpha: CGFloat, _ theme: TokenTheme) -> NSColor {
        let base = SidebarSurfaceRole.rowBase.color.resolved(for: theme)
        let fg = TextToken.textPrimary.color.resolved(for: theme)
        return TokenColor(fg.composited(over: base, alpha: alpha)).nsColor(for: theme)
    }

    /// A folded parent's card as it rests on its sheets (~11%), its hover step
    /// above that, or an open parent on the 3.5% wash.
    private static func drawCard(_ option: Option, _ state: State, _ theme: TokenTheme, in cell: NSRect) {
        SidebarSurfaceRole.rowBase.color.nsColor(for: theme).setFill()
        cell.fill()
        let card = cell.insetBy(dx: 4, dy: 4)
        let face: CGFloat = state == .open ? 0.035 : (state == .hover ? 0.17 : 0.112)
        mix(face, theme).setFill()
        NSBezierPath(roundedRect: card, xRadius: CGFloat(Radius.card), yRadius: CGFloat(Radius.card)).fill()
        if state != .open {
            // The tucked peeks below the card.
            for depth in [2, 1] {
                let inset = CGFloat(6 * depth)
                mix(depth == 1 ? 0.08 : 0.055, theme).setFill()
                NSBezierPath(rect: NSRect(x: card.minX + inset, y: card.maxY, width: card.width - inset * 2,
                                          height: CGFloat(3 * depth))).fill()
            }
        }
        let centre = NSPoint(x: card.minX + 16, y: card.midY)
        let primary = TextToken.textPrimary.color.nsColor(for: theme)
        let secondary = TextToken.textSecondary.color.nsColor(for: theme)
        let ink = state == .hover ? primary : secondary
        if state == .hover {
            SidebarControlRole.hover.color.nsColor(for: theme).setFill()
            NSBezierPath(ovalIn: NSRect(x: centre.x - 11, y: centre.y - 11, width: 22, height: 22)).fill()
        }
        if state == .open {
            LineToken.border.color.nsColor(for: theme).setFill()
            NSRect(x: centre.x - 0.5, y: centre.y + 6, width: 1, height: cell.maxY - centre.y - 6).fill()
        }
        let working = state == .idle ? 0 : 2
        glyph(option, open: state == .open, hovered: state == .hover, working: working,
              centre: centre, ink: ink, theme: theme)
        let countAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: Typography.style(for: .label).size, weight: .medium),
            .foregroundColor: ink]
        let count = "3" as NSString
        let countSize = count.size(withAttributes: countAttrs)
        count.draw(at: NSPoint(x: centre.x + 10, y: centre.y - countSize.height / 2), withAttributes: countAttrs)
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.token(.title), .foregroundColor: primary]
        let title = "Plan richer file tile previews" as NSString
        let titleSize = title.size(withAttributes: titleAttrs)
        title.draw(at: NSPoint(x: centre.x + 24, y: centre.y - titleSize.height / 2), withAttributes: titleAttrs)
    }

    private static func dot(_ at: NSPoint, _ diameter: CGFloat, filled: Bool, _ ink: NSColor) {
        let rect = NSRect(x: at.x - diameter / 2, y: at.y - diameter / 2, width: diameter, height: diameter)
        if filled {
            ink.setFill()
            NSBezierPath(ovalIn: rect).fill()
        } else {
            ink.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    private static func line(_ a: NSPoint, _ b: NSPoint, _ ink: NSColor, width: CGFloat = 1) {
        ink.setStroke()
        let path = NSBezierPath()
        path.move(to: a)
        path.line(to: b)
        path.lineWidth = width
        path.lineCapStyle = .round
        path.stroke()
    }

    /// y DOWN offsets from `centre`.
    private static func glyph(_ option: Option, open: Bool, hovered: Bool, working: Int,
                              centre c: NSPoint, ink: NSColor, theme: TokenTheme) {
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: c.x + x, y: c.y + y) }
        let spread: CGFloat = hovered ? 1.08 : 1
        switch option {
        case .triangle:
            let pts = open ? [p(0, -4.5), p(0, 1.5), p(0, 7.5)]
                : [p(0, -3.6 * spread), p(-3.9 * spread, 2.7 * spread), p(3.9 * spread, 2.7 * spread)]
            for (i, pt) in pts.enumerated() { dot(pt, 4, filled: i < working, ink) }
        case .row:
            let pts = open ? [p(0, -4.5), p(0, 1), p(0, 6.5)]
                : [p(-4.6 * spread, 0), p(0, 0), p(4.6 * spread, 0)]
            for (i, pt) in pts.enumerated() { dot(pt, 3.6, filled: i < working, ink) }
        case .tree:
            let parent = p(0, open ? -5 : -4.6)
            dot(parent, 3.4, filled: true, ink)
            if open {
                line(p(0, -3.2), p(0, 7), ink.withAlphaComponent(0.7))
                for (i, y) in [CGFloat(1), 5.5].enumerated() {
                    line(p(0, y), p(3, y), ink.withAlphaComponent(0.7))
                    dot(p(4.6, y), 3, filled: i < working, ink)
                }
            } else {
                let xs: [CGFloat] = [-4.6 * spread, 0, 4.6 * spread]
                let bar: CGFloat = 0.4
                line(p(0, -2.9), p(0, bar), ink.withAlphaComponent(0.7))
                line(p(xs[0], bar), p(xs[2], bar), ink.withAlphaComponent(0.7))
                for (i, x) in xs.enumerated() {
                    line(p(x, bar), p(x, 2.6), ink.withAlphaComponent(0.7))
                    dot(p(x, 4.2), 3, filled: i < working, ink)
                }
            }
        case .stack:
            func card(_ rect: NSRect, filled: Bool) {
                let path = NSBezierPath(roundedRect: rect, xRadius: 1.8, yRadius: 1.8)
                if filled { ink.setFill(); path.fill() } else { ink.setStroke(); path.lineWidth = 1; path.stroke() }
            }
            if open {
                card(NSRect(x: c.x - 4, y: c.y - 6.5, width: 8, height: 5), filled: working > 0)
                card(NSRect(x: c.x - 4, y: c.y + 1, width: 8, height: 5), filled: working > 1)
            } else {
                let lift: CGFloat = hovered ? 1 : 0
                card(NSRect(x: c.x - 2.5 + lift, y: c.y - 5 - lift, width: 8, height: 6).insetBy(dx: 0.5, dy: 0.5),
                     filled: working > 1)
                card(NSRect(x: c.x - 5.5, y: c.y - 1.5, width: 8, height: 6).insetBy(dx: 0.5, dy: 0.5),
                     filled: working > 0)
            }
        case .ring:
            let r: CGFloat = hovered ? 5.6 : 5.2
            let track = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ink.withAlphaComponent(0.45).setStroke()
            track.lineWidth = 1.2
            track.stroke()
            if working > 0 {
                let arc = NSBezierPath()
                // Clockwise from 12 o'clock in a y-down context.
                arc.appendArc(withCenter: c, radius: r, startAngle: -90, endAngle: -90 + 360 * CGFloat(working) / 3)
                ink.setStroke()
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                arc.stroke()
            }
        }
    }
}

// MARK: - Mini stack iterations

/// Mini-stack candidates with real knockouts: each nearer card cuts a gap out
/// of the cards behind it (drawn in a transparency layer with a `.clear`
/// blend), so the pieces read as separate. `--sidebar-indicator-options-check`
/// writes `stack-options.png` and `stack-options-closeup.png` beside the others.
@MainActor
enum SidebarStackOptions {
    enum Shape: String, CaseIterable {
        case pair = "Two cards"
        case trio = "Three cards"
        case deck = "Vertical deck"
    }

    enum State: String, CaseIterable {
        case idle = "All idle"
        case some = "1 of 3 working"
        case most = "2 of 3 working"
        case all = "All working"
        case hover = "Hover"
        case spread = "Open: spread"
        case head = "Open: head"
    }

    static let gap: CGFloat = 1.3
    static let radius: CGFloat = 1.8

    static func write(to directory: URL) throws {
        try render(cellWidth: 260, zoom: 2, to: directory.appendingPathComponent("stack-options.png"))
        try render(cellWidth: 60, zoom: 6, to: directory.appendingPathComponent("stack-options-closeup.png"))
    }

    private static func render(cellWidth: CGFloat, zoom: CGFloat, to url: URL) throws {
        let cell = NSSize(width: cellWidth, height: 52), labelW: CGFloat = 84, header: CGFloat = 22
        let rows = Shape.allCases.count * 2
        let size = NSSize(width: labelW + cell.width * CGFloat(State.allCases.count),
                          height: header + cell.height * CGFloat(rows))
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor(white: 0.42, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: zoom > 2 ? 5.5 : 9, weight: .semibold), .foregroundColor: NSColor.white]
            for (column, state) in State.allCases.enumerated() {
                (state.rawValue as NSString).draw(at: NSPoint(x: labelW + CGFloat(column) * cell.width + 4, y: 6),
                                                  withAttributes: attrs)
            }
            var row = 0
            for shape in Shape.allCases {
                for theme in [TokenTheme.light, .dark] {
                    let y = header + CGFloat(row) * cell.height
                    ("\(shape.rawValue)\n\(theme == .dark ? "dark" : "light")" as NSString)
                        .draw(at: NSPoint(x: 6, y: y + 12), withAttributes: attrs)
                    for (column, state) in State.allCases.enumerated() {
                        let rect = NSRect(x: labelW + CGFloat(column) * cell.width, y: y,
                                          width: cell.width, height: cell.height)
                        NSGraphicsContext.saveGraphicsState()
                        NSBezierPath(rect: rect).addClip()
                        drawCard(shape, state, theme, in: rect)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    row += 1
                }
            }
            return true
        }
        let pixels = NSSize(width: size.width * zoom, height: size.height * zoom)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { throw NSError(domain: "stack", code: 1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "stack", code: 2) }
        try png.write(to: url)
    }

    private static func mix(_ alpha: CGFloat, _ theme: TokenTheme) -> NSColor {
        let base = SidebarSurfaceRole.rowBase.color.resolved(for: theme)
        let fg = TextToken.textPrimary.color.resolved(for: theme)
        return TokenColor(fg.composited(over: base, alpha: alpha)).nsColor(for: theme)
    }

    private static func drawCard(_ shape: Shape, _ state: State, _ theme: TokenTheme, in cell: NSRect) {
        SidebarSurfaceRole.rowBase.color.nsColor(for: theme).setFill()
        cell.fill()
        let open = state == .spread || state == .head
        let card = cell.insetBy(dx: 4, dy: 4)
        mix(open ? 0.035 : (state == .hover ? 0.17 : 0.112), theme).setFill()
        NSBezierPath(roundedRect: card, xRadius: CGFloat(Radius.card), yRadius: CGFloat(Radius.card)).fill()
        if !open {
            for depth in [2, 1] {
                let inset = CGFloat(6 * depth)
                mix(depth == 1 ? 0.08 : 0.055, theme).setFill()
                NSRect(x: card.minX + inset, y: card.maxY, width: card.width - inset * 2, height: CGFloat(3 * depth)).fill()
            }
        }
        let c = NSPoint(x: card.minX + 16, y: card.midY)
        let primary = TextToken.textPrimary.color.nsColor(for: theme)
        let secondary = TextToken.textSecondary.color.nsColor(for: theme)
        let ink = state == .hover ? primary : secondary
        if state == .hover {
            SidebarControlRole.hover.color.nsColor(for: theme).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22)).fill()
        }
        let working: Int
        switch state {
        case .idle: working = 0
        case .some: working = 1
        case .all: working = 3
        default: working = 2
        }
        if open {
            LineToken.border.color.nsColor(for: theme).setFill()
            let laneTop = state == .spread ? c.y + 7.2 : c.y + 1.8
            NSRect(x: c.x - 0.5, y: laneTop, width: 1, height: cell.maxY - laneTop).fill()
        }
        drawGlyph(shape, state, working: working, centre: c, ink: ink)
        let countAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: Typography.style(for: .label).size, weight: .medium),
            .foregroundColor: ink]
        let count = "3" as NSString
        let countSize = count.size(withAttributes: countAttrs)
        count.draw(at: NSPoint(x: c.x + 10, y: c.y - countSize.height / 2), withAttributes: countAttrs)
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.token(.title), .foregroundColor: primary]
        let title = "Plan richer file tile previews" as NSString
        let titleSize = title.size(withAttributes: titleAttrs)
        title.draw(at: NSPoint(x: c.x + 24, y: c.y - titleSize.height / 2), withAttributes: titleAttrs)
    }

    /// Cards back to front (rects y DOWN from the centre); the first `filled`
    /// cards from the FRONT are filled. Each card knocks a `gap` out of the
    /// cards already drawn behind it.
    private static func drawGlyph(_ shape: Shape, _ state: State, working: Int, centre c: NSPoint, ink: NSColor) {
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: c.x + x, y: c.y + y, width: w, height: h)
        }
        let hover: CGFloat = state == .hover ? 0.8 : 0
        var back: [NSRect]   // back to front
        switch state {
        case .spread:
            back = [r(-4.5, 3.4, 9, 3), r(-4.5, -1.3, 9, 3), r(-4.5, -6, 9, 3)]
        case .head:
            back = [r(-5, -5, 10, 6.6)]
        default:
            switch shape {
            case .pair:
                back = [r(-2.2 + hover, -5.6 - hover, 8, 6.2), r(-5.8, -1.6, 8, 6.2)]
            case .trio:
                let s: CGFloat = 2.3 + hover * 0.6
                back = [r(-1.4 + s, -6.6 + 0.2, 6.6, 5), r(-3.6 + s * 0.5 + 0.6, -4.1 + s * 0.5 + 0.1, 6.6, 5),
                        r(-5.8 + 0.2, -1.6 + 0.6, 6.6, 5)]
                back = [r(-1.0 + hover, -6.4 - hover, 6.6, 5), r(-3.4, -3.9, 6.6, 5), r(-5.8 - hover, -1.4 + hover, 6.6, 5)]
            case .deck:
                back = [r(-2.6, 0.6 + hover * 1.2, 5.2, 5), r(-4.2, -1.6 + hover * 0.6, 8.4, 5), r(-6, -4.6, 12, 6.4)]
            }
        }
        let count = back.count
        // How many of the cards, counted from the front, are filled.
        let filled: Int = {
            guard working > 0 else { return 0 }
            if state == .head { return 1 }
            return min(count, max(1, Int((Double(count) * Double(working) / 3).rounded())))
        }()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for (index, rect) in back.enumerated() {
            let fromFront = count - 1 - index
            let isFilled = fromFront < filled
            if index > 0 {
                // Knock the gap out of everything behind this card.
                ctx.setBlendMode(.clear)
                NSBezierPath(roundedRect: rect.insetBy(dx: -gap, dy: -gap),
                             xRadius: radius + gap, yRadius: radius + gap).fill()
                ctx.setBlendMode(.normal)
            }
            if isFilled {
                ink.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            } else {
                ink.setStroke()
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
                path.lineWidth = 1
                path.stroke()
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
