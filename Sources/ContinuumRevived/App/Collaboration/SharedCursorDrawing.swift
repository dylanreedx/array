import AppKit

/// Content-independent backing for the moving pointer and its name only.
@MainActor
enum SharedCursorDrawing {
    static func draw(at point: NSPoint, name: String, colour: NSColor,
                     surface: NSColor, ink: NSColor, font: NSFont) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        let cursor = NSBezierPath()
        cursor.move(to: point)
        cursor.line(to: .init(x: point.x + 5, y: point.y + 17))
        cursor.line(to: .init(x: point.x + 10, y: point.y + 11))
        cursor.line(to: .init(x: point.x + 17, y: point.y + 10))
        cursor.close()
        cursor.lineJoinStyle = .round
        surface.setStroke(); cursor.lineWidth = 3; cursor.stroke()
        colour.setFill(); cursor.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let size = (name as NSString).size(withAttributes: attributes)
        let plate = NSRect(x: point.x + 20, y: point.y - 6, width: ceil(size.width) + 12, height: ceil(size.height) + 6)
        let path = NSBezierPath(roundedRect: plate, xRadius: 5, yRadius: 5)
        surface.setFill(); path.fill()
        // Clear the shadow before drawing the fine border and glyphs.
        NSShadow().set()
        ink.withAlphaComponent(0.3).setStroke(); path.lineWidth = 1; path.stroke()
        (name as NSString).draw(at: .init(x: plate.minX + 6, y: plate.minY + 3), withAttributes: attributes)
    }
}
