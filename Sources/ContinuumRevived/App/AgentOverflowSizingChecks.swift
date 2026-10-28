import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Pixel witness reached by the matrix's existing --tile-chrome-scale-check.
/// A correctly sized hit target alone cannot detect tiny painted dots.
@MainActor
enum AgentOverflowSizingChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run(in directory: URL) throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: message) }
        }
        let tile = Tile(id: UUID(), kind: .managedAgent, title: "Agent actions",
                        frame: TileFrame(x: 20, y: 20, width: 900, height: 1000),
                        zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [tile], groups: [], lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        let view = ManagedAgentTileNSView(tile: tile)
        view.enableTitleBarActions()
        canvas.install(tileView: view, for: tile)
        // Both sides of each low-zoom bucket transition, plus normal/large scales.
        let boundaries = (-13...0).map { pow(2.0, Double($0) / 4) }
        let zooms = [0.1, 0.3, 0.5, 0.7, 0.9, 1.0, 1.25, 2.0, 3.0]
            + boundaries.flatMap { [$0 * 0.999, $0 * 1.001] }
        var rows: [[String: Any]] = []
        var cachedImages: [Double: NSImage] = [:]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for zoom in zooms.sorted() {
                canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
                view.layoutSubtreeIfNeeded()
                guard let button = view.titleBarActionsButtonForQA, !button.isHidden else {
                    throw Failure(description: "zoom \(zoom): missing overflow button")
                }
                // Include canvas magnification in the capture density. At 200%
                // a 14-world-point button occupies 28 screen points; a 14-pixel
                // capture would magnify its own rounding error during measurement.
                let density = max(1, zoom) * window.backingScaleFactor
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: Int(ceil(button.bounds.width * density)),
                    pixelsHigh: Int(ceil(button.bounds.height * density)),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                    throw Failure(description: "zoom \(zoom): missing overflow bitmap")
                }
                rep.size = button.bounds.size
                button.layoutSubtreeIfNeeded()
                guard let imageView = button.subviews.compactMap({ $0 as? NSImageView }).first,
                      let image = imageView.image else {
                    throw Failure(description: "missing custom ellipsis image")
                }
                try expect(CanvasSymbolImage.owns(image) && image.isTemplate
                           && image.representations.count == 1 && image.representations.first is NSBitmapImageRep,
                           "ellipsis must retain the shared tintable bitmap cache")
                let bucket = max(1, 1 / TileNSView.chromeScaleBucket(for: zoom))
                if let previous = cachedImages[bucket] {
                    try expect(previous === image, "same chrome bucket replaced the cached bitmap")
                }
                cachedImages[bucket] = image
                let glyphFrame = imageView.frame
                let buttonFrame = button.frame
                view.setPageZoom(AgentPageZoom(percent: view.pageZoom.percent == 80 ? 150 : 80))
                view.layoutSubtreeIfNeeded()
                try expect(imageView.image === image && imageView.frame == glyphFrame && button.frame == buttonFrame,
                           "agent page zoom must leave outer chrome unchanged")
                button.cacheDisplay(in: button.bounds, to: rep)
                var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
                try expect(maxX >= minX && maxY >= minY, "zoom \(zoom): dots painted no pixels")
                let scaleX = button.bounds.width / CGFloat(rep.pixelsWide) * zoom
                let scaleY = button.bounds.height / CGFloat(rep.pixelsHigh) * zoom
                let paintedWidth = CGFloat(maxX - minX + 1) * scaleX
                let paintedHeight = CGFloat(maxY - minY + 1) * scaleY
                // Ellipsis width includes all three dots; diameter must remain legible too.
                try expect(paintedWidth >= 11.5, "zoom \(zoom): painted dots only \(paintedWidth)pt wide")
                try expect(paintedHeight >= 1.7, "zoom \(zoom): painted dots only \(paintedHeight)pt tall")
                try expect(paintedWidth <= max(18, 14 * zoom), "zoom \(zoom): dots oversized: \(paintedWidth)pt")
                try expect(abs(CGFloat(minX + maxX + 1) / 2 - CGFloat(rep.pixelsWide) / 2) * scaleX < 1,
                           "zoom \(zoom): dots are not horizontally centered")
                let verticalOffset = abs(CGFloat(minY + maxY + 1) / 2 - CGFloat(rep.pixelsHigh) / 2) * scaleY
                if verticalOffset >= 1, let png = rep.representation(using: .png, properties: [:]) {
                    try png.write(to: directory.appendingPathComponent("ellipsis-centering-failure.png"))
                }
                try expect(verticalOffset < 1,
                           "zoom \(zoom): dots are not vertically centered (offset=\(verticalOffset), ink=\(minY)...\(maxY), pixels=\(rep.pixelsHigh), button=\(button.bounds), image=\(imageView.frame))")
                let frame = view.titleBarActionsFrameForQA!
                try expect(frame.width * zoom >= 21.9 && frame.height * zoom >= 21.9,
                           "zoom \(zoom): overflow lost its 22pt hit target")
                try expect(!frame.intersects(view.qaCloseButtonFrame), "zoom \(zoom): overflow overlaps close")
                rows.append(["appearance": appearance.rawValue, "zoom": zoom,
                             "paintedWidth": paintedWidth, "paintedHeight": paintedHeight])
                if [0.3, 0.5, 0.7, 1.0, 1.25].contains(zoom),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try png.write(to: directory.appendingPathComponent("ellipsis-\(appearance.rawValue)-\(zoom).png"))
                    let bar = view.qaTitleBarFrame
                    if let barRep = view.bitmapImageRepForCachingDisplay(in: bar) {
                        view.cacheDisplay(in: bar, to: barRep)
                        try barRep.representation(using: .png, properties: [:])?.write(
                            to: directory.appendingPathComponent("bar-\(appearance.rawValue)-\(zoom).png"))
                    }
                }
            }
        }
        var hidden = 0, visible = 0
        for width in [320.0, 480.0] {
            let narrowTile = Tile(id: UUID(), kind: .managedAgent, title: "Narrow agent",
                frame: TileFrame(x: 20, y: 20, width: width, height: 1000),
                zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata())
            let narrow = ManagedAgentTileNSView(tile: narrowTile)
            canvas.install(tileView: narrow, for: narrowTile)
            for zoom in [0.1, 0.3, 0.7, 1.0, 1.25] {
                canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
                narrow.setPageZoom(AgentPageZoom(percent: zoom < 1 ? 80 : 150))
                narrow.layoutSubtreeIfNeeded()
                let controls = narrow.qaBandControlFrames
                for (index, control) in controls.enumerated() {
                    try expect(control.frame.minX >= -0.5 && control.frame.maxX <= width + 0.5,
                               "narrow agent control leaves the bar at width \(width), zoom \(zoom)")
                    for other in controls.dropFirst(index + 1) {
                        try expect(!control.frame.intersects(other.frame), "narrow agent controls overlap")
                    }
                }
                if controls.contains(where: { $0.name == "actions" }) { visible += 1 }
                else {
                    hidden += 1
                    try expect(narrow.titleBarContextMenuForQA().items.contains(where: {
                        $0.title == AgentTileHeaderView.detachActionTitle
                    }), "hidden ellipsis must retain the title-bar context menu")
                }
            }
            canvas.removeTile(id: narrowTile.id)
        }
        try expect(hidden > 0 && visible > 0, "narrow sweep must exercise hidden and visible ellipsis")
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("ellipsis-pixels.json"))
    }
}
