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
