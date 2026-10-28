import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore

/// Pixels of a production tile: transcript ink must never reach
/// the header or composer, even when a row only partly intersects the viewport.
@MainActor
enum TranscriptViewportClippingChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static var usesWindowServer: Bool?

    /// Prefer the screen composite. Restricted/headless agents may not capture
    /// their own window; replay the production view drawing into a bitmap then.
    /// The bitmap includes both bars, so an escaped draw still fails this check.
    static func render(_ tile: NSView) throws -> TileChromeCanvasChecks.Pixels {
        if usesWindowServer == nil {
            usesWindowServer = tile.window.map {
                CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID($0.windowNumber),
                                        [.boundsIgnoreFraming, .bestResolution]) != nil
            } ?? false
            print("transcript viewport capture: \(usesWindowServer == true ? "window-server composite" : "offline production view drawing (window capture unavailable)")")
            if usesWindowServer == false {
                print("MATRIX-NOTE: viewport pixels verified through production drawing; WindowServer composite unavailable")
            }
        }
        if usesWindowServer == true { return try TileChromeCanvasChecks.render(tile) }
        tile.layoutSubtreeIfNeeded()
        tile.window?.displayIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let scale = 2 * tile.frame.width / tile.bounds.width
        let width = Int((tile.bounds.width * scale).rounded())
        let height = Int((tile.bounds.height * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "could not allocate the viewport witness bitmap")
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NativeViewVectorRenderer.drawContents(of: tile, in: context)
        guard let image = context.makeImage(), let data = context.data else {
            throw Failure(description: "the viewport witness returned no bitmap")
        }
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        // Pixels.scale describes physical pixels per displayed point. Fractional
        // canvas zoom is already represented in the image and comparison rect.
        return TileChromeCanvasChecks.Pixels(width: width, height: height, bytes: bytes, scale: 2, image: image)
    }

    static func run() throws {
        let key = AgentTranscriptCanvasView.rendererEnvironmentKey
        let previous = ProcessInfo.processInfo.environment[key]
        let previousPointer = ManagedAgentTileNSView.qaPointerInside
        let previousButtons = ManagedAgentTileNSView.chromePressedMouseButtons
        ManagedAgentTileNSView.qaPointerInside = { _ in false }
        ManagedAgentTileNSView.chromePressedMouseButtons = { 0 }
        setenv(key, "canvas", 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
            ManagedAgentTileNSView.qaPointerInside = previousPointer
            ManagedAgentTileNSView.chromePressedMouseButtons = previousButtons
        }
        var failures: [String] = []
        var cases = 0
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let (tile, window) = TileChromeCanvasChecks.makeTile(appearance: appearance)
            defer { window.orderOut(nil) }
            guard let surface = tile.qaCanvasTranscript, tile.qaChromeCanvas != nil else {
                throw Failure(description: "the production tile did not install the drawn transcript/chrome")
            }
            // Attachment cards exercise the tall shape shown in the reported
            // top-edge regression; prose/code exercise partial glyphs and fills.
            let attachment = AgentPromptImageAttachment(
                metadata: AgentImageAttachmentMetadata(id: AgentImageAttachmentID(rawValue: "viewport-image")!,
                    displayName: "Viewport image.png", contentType: "image/png", pixelWidth: 400, pixelHeight: 300),
                fileURL: URL(fileURLWithPath: "/tmp/array-viewport-fixture-unavailable.png"))
            tile.appendUserPrompt(AgentPrompt(text: "Inspect these cards", imageAttachments: [attachment]))
            tile.ingest(.turnStarted(threadId: "chrome", turnId: "viewport"))
            let paragraphs = (0..<18).map {
                "Paragraph \($0): **visible transcript text** must stay inside its own viewport. "
                + "Scrolling a partially visible line must preserve both bars."
            }.joined(separator: "\n\n")
            tile.ingest(.contentDelta(threadId: "chrome", turnId: "viewport", streamKind: .assistant,
                delta: paragraphs + "\n\n```swift\n" + String(repeating: "let value = 123\n", count: 24) + "```"))
            tile.ingest(.turnCompleted(threadId: "chrome", turnId: "viewport", outcome: .completed, errorMessage: nil))
            tile.appendUserPrompt(AgentPrompt(text: "Another attachment", imageAttachments: [attachment]))
            surface.flushPendingVisualUpdate()
            tile.layoutSubtreeIfNeeded()
            try expect(surface.qaMaximumScrollOffset > 500, "the fixture must overflow to exercise scrolling")
            let logical = tile.bounds
            for zoom: CGFloat in [1, 0.73] {
                let blockLayouts = surface.qaBlockLayoutCount
                let fullLayouts = surface.qaFullRelayoutCount
                tile.setFrameSize(NSSize(width: logical.width * zoom, height: logical.height * zoom))
                tile.bounds = logical
                tile.layoutSubtreeIfNeeded()
                for resting in [true, false] {
                    ManagedAgentTileNSView.qaPointerInside = { _ in !resting }
                    if resting {
                        window.makeFirstResponder(nil)
                        tile.restChromeIfIdle()
                    } else { tile.wakeChrome() }
                    try expect(tile.isChromeResting == resting, "the fixture tested the wrong chrome state")
                    for offset in [CGFloat(29), surface.qaMaximumScrollOffset / 2 + 7,
                                   surface.qaMaximumScrollOffset - 31] {
                        surface.scrollTranscript(toY: offset)
                        try expect(abs(surface.qaScrollOffset - offset) < 0.01, "the transcript did not scroll")
                        surface.isHidden = false
                        surface.needsDisplay = true
                        let shown = try render(tile)
                        try expect(surface.qaBlockLayoutCount == blockLayouts && surface.qaFullRelayoutCount == fullLayouts,
                                   "a camera zoom or scroll remeasured the transcript")
                        surface.isHidden = true
                        let hidden = try render(tile)
                        surface.isHidden = false
                        let viewport = surface.convert(surface.bounds, to: tile)
                        // The crop is scaled into tile coordinates for fractional
                        // canvas zoom, as the shared diff helper expects.
                        let scaledViewport = NSRect(x: viewport.minX * zoom, y: viewport.minY * zoom,
                            width: viewport.width * zoom, height: viewport.height * zoom)
                        let outside = TileChromeCanvasChecks.diff(shown, hidden, excluding: scaledViewport.insetBy(dx: -1, dy: -1))
                        let all = TileChromeCanvasChecks.diff(shown, hidden, excluding: nil)
                        let label = "\(appearance.rawValue) zoom=\(zoom) resting=\(resting) offset=\(offset)"
                        try expect(all.fraction > 0.001, "\(label): no transcript pixels changed; vacuous witness")
                        if outside.fraction > 0 {
                            failures.append("\(label): transcript changed \(outside.fraction * 100)% of protected pixels")
                        }
                        if let directory = ProcessInfo.processInfo.environment["TRANSCRIPT_VIEWPORT_PNG_DIR"] {
                            let url = URL(fileURLWithPath: directory, isDirectory: true)
                            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                            try NSBitmapImageRep(cgImage: shown.image).representation(using: .png, properties: [:])?
                                .write(to: url.appendingPathComponent("viewport-\(cases).png"))
                        }
                        cases += 1
                    }
                }
            }
            // A manually added sublayer bypasses draw(_:). Put the real gyro
            // across the viewport edge and freeze its animation for comparison.
            surface.setTurnInFlight(true)
            surface.setThinkingIndicatorVisible(true)
            let gyro = surface.qaGyroLayer
            gyro.speed = 0
            gyro.timeOffset = 0.5
            gyro.isHidden = false
            gyro.frame = CGRect(x: 30, y: -20, width: 40, height: 40)
            let shown = try render(tile)
            gyro.isHidden = true
            let hidden = try render(tile)
            let viewport = surface.convert(surface.bounds, to: tile)
            let zoom = tile.frame.width / tile.bounds.width
            let rect = NSRect(x: viewport.minX * zoom, y: viewport.minY * zoom,
                width: viewport.width * zoom, height: viewport.height * zoom)
            let outside = TileChromeCanvasChecks.diff(shown, hidden, excluding: rect.insetBy(dx: -1, dy: -1))
            try expect(TileChromeCanvasChecks.diff(shown, hidden, excluding: nil).fraction > 0,
                       "the gyro drew nothing; vacuous sublayer witness")
            if outside.fraction > 0 { failures.append("\(appearance.rawValue): gyro escaped the viewport") }
            surface.setThinkingIndicatorVisible(false)
            surface.setTurnInFlight(false)
        }
        try expect(failures.isEmpty, failures.joined(separator: "\n"))
        print("transcript viewport: \(cases) scroll/appearance/zoom/chrome cases and gyro sublayers contained")
    }
}
