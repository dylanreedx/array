import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// `--composer-outline-check`: the composer's outline reads the same on all
/// four edges wherever the canvas puts it.
///
/// A real `AgentComposerView`, rendered at 2x through `cacheDisplay` at a
/// whole-point origin and at a quarter-point one (half a device pixel: almost
/// nothing on a zoomable canvas lands on a whole pixel). Each edge is scanned
/// across, device pixel by device pixel, and its strength is the largest
/// difference from the composer's own fill. At 0.5pt the line was one device
/// pixel, so an offset edge spread it over two half-strength pixels and read
/// fainter than the edge beside it: the uneven outline Dylan reported.
@MainActor
enum ComposerOutlineChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let scale = 2

    static func run() throws -> String {
        var report: [Double] = []
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            for (zoom, offset) in cases {
                var strengths = try edgeStrengths(appearance: appearance, zoom: zoom, offset: offset)
                if strengths.values.min() == 0 {
                    // A capture can land before the window server has the frame.
                    strengths = try edgeStrengths(appearance: appearance, zoom: zoom, offset: offset)
                }
                let weakest = strengths.values.min() ?? 0
                let strongest = strengths.values.max() ?? 0
                let label = "\(appearance == .darkAqua ? "dark" : "light") zoom \(zoom) +\(offset)pt"
                guard weakest > 0 else {
                    throw Failure(description: "\(label): an edge drew no outline at all: \(strengths)")
                }
                let ratio = weakest / strongest
                // At the zooms a tile is read at, the four edges match within a
                // tenth. Zoomed out, a 1pt line is under two device pixels and
                // some unevenness is the cost of not redrawing every tile per
                // zoom step; 0.5pt fell to a quarter there.
                let floor = zoom >= 0.9 ? 0.9 : 0.6
                guard ratio >= floor else {
                    throw Failure(description: "\(label): the outline is uneven, edge strengths \(strengths) (weakest/strongest \(String(format: "%.2f", ratio)), want ≥ \(floor))")
                }
                report.append(ratio)
            }
        }
        return "outline even on all four edges across \(report.count) zoom/offset/appearance cases, weakest/strongest ≥ \(String(format: "%.2f", report.min() ?? 0))"
    }

    /// Canvas zooms a tile lands at, each at a whole-point and an off-pixel origin.
    static let cases: [(CGFloat, CGFloat)] = [1, 0.9, 0.8, 0.7, 0.6].flatMap { zoom in
        [CGFloat(0), 0.1, 0.25, 0.4].map { (zoom, $0) }
    }

    private static func edgeStrengths(appearance: NSAppearance.Name, zoom: CGFloat, offset: CGFloat) throws -> [String: Double] {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 120))
        host.appearance = NSAppearance(named: appearance)
        host.wantsLayer = true
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }

        // The canvas zooms the way `CanvasWorldPlaneView` does: a plane whose
        // bounds are its frame over the zoom, with tiles at world frames.
        let plane = NSView(frame: host.bounds)
        plane.setBoundsSize(NSSize(width: host.bounds.width / zoom, height: host.bounds.height / zoom))
        host.addSubview(plane)
        let composer = AgentComposerView(frame: .zero, variant: .fullTurn)
        plane.addSubview(composer)
        composer.frame = NSRect(x: 20 + offset / zoom, y: 20 + offset / zoom, width: 360, height: 64)
        composer.applyTokens()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        // The window server's own composite of the window, the pixels a screen
        // shows. `cacheDisplay` re-draws the layers itself and snaps the line
        // to whole pixels, so it reads a 0.5pt outline as even when it is not.
        func render() throws -> NSBitmapImageRep {
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            guard let image = CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                [.boundsIgnoreFraming, .bestResolution]
            ) else { throw Failure(description: "the window server returned no image of the check's own window") }
            let rep = NSBitmapImageRep(cgImage: image)
            guard rep.pixelsWide == Int(host.bounds.width) * scale else {
                throw Failure(description: "captured \(rep.pixelsWide)px for \(host.bounds.width)pt; this check needs a \(scale)x backing store, got \(window.backingScaleFactor)x")
            }
            return rep
        }
        // Row 0 is the top of the image; the host is not flipped.
        func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
            rep.colorAt(x: x, y: rep.pixelsHigh - 1 - y) ?? .black
        }
        func channels(_ color: NSColor) -> [Double] {
            [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
        }
        let frame = plane.convert(composer.frame, to: host)
        let midX = Int(frame.midX * CGFloat(scale))
        let midY = Int(frame.midY * CGFloat(scale))
        // Paint the host the composer's own fill, so the only thing near an
        // edge that differs from the fill is the outline.
        let fillColor = pixel(try render(), midX, midY)
        host.layer?.backgroundColor = fillColor.cgColor
        let rep = try render()
        let fill = channels(fillColor)
        func strength(_ points: [(Int, Int)]) -> Double {
            points.map { point in
                zip(channels(pixel(rep, point.0, point.1)), fill).map { abs($0 - $1) }.max() ?? 0
            }.max() ?? 0
        }
        // From 2pt outside to 3pt inside each edge, at the edge's middle.
        let band = (-2 * scale)..<(3 * scale)
        let minX = Int((frame.minX * CGFloat(scale)).rounded(.down))
        let maxX = Int((frame.maxX * CGFloat(scale)).rounded(.up))
        let minY = Int((frame.minY * CGFloat(scale)).rounded(.down))
        let maxY = Int((frame.maxY * CGFloat(scale)).rounded(.up))
        return [
            "left": strength(band.map { (minX + $0, midY) }),
            "right": strength(band.map { (maxX - 1 - $0, midY) }),
            "bottom": strength(band.map { (midX, minY + $0) }),
            "top": strength(band.map { (midX, maxY - 1 - $0) }),
        ]
    }
}
