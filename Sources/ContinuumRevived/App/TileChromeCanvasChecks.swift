import AppKit
import ObjectiveC
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// `--tile-chrome-canvas-check`: the resting agent tile behind
/// `ARRAY_TRANSCRIPT_RENDERER=canvas` (`AgentTileChromeCanvasView`), driven
/// through a REAL `ManagedAgentTileNSView` and the real event path
/// (`NSApp.sendEvent`, which is where the hit-test wake reads its event).
///
/// What it holds:
/// - with the switch off nothing changes: the body is the content view;
/// - a resting tile is at most `restingViewBudget` views, all of them drawing
///   views (tile, chrome canvas, transcript canvas, title bar, corner overlay,
///   awareness border);
/// - the resting picture and the live picture of the same tile differ by at most
///   `restVersusLiveBudget` of their pixels, and the resting picture and TODAY's
///   tile (switch off) differ by at most `restVersusTodayBudget` outside the
///   transcript (whose renderer differs by design);
/// - a state change while resting (another model and effort, through
///   `applyProviderSettings`) reaches the drawn chrome;
/// - a canvas zoom redraws the chrome at 2x and 4x with no body layout;
/// - a press on the drawn composer focuses the real text view and typed keys
///   reach the draft; losing focus rests the tile again, still showing the draft;
/// - a press on a drawn picker opens the real `ChoicePopoverController`;
/// - presses on the drawn ⋯ and × dispatch their real actions.
///
/// - an appearance flip while resting reaches the detached body.
///
/// Every picture is the window server's composite (`CGWindowListCreateImage`):
/// re-rendering the layer tree (`CALayer.render(in:)`) reads AppKit's text
/// backing stores differently and reported a 0.38% difference the screen does
/// not show.
///
/// `TILE_CHROME_CANVAS_PNG_DIR=<dir>` also writes light and dark renders of a
/// resting tile, drawn and today; `TILE_CHROME_CANVAS_DEBUG_DIR=<dir>` writes the
/// resting, live and today pictures and a mask of the pixels that differ. The
/// matrix sets neither.
@MainActor
enum TileChromeCanvasChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// tile + chrome canvas + transcript canvas + title bar + corner overlay +
    /// awareness border. Each one draws; nothing below them is in the window.
    static let restingViewBudget = 6
    /// Share of pixels allowed to differ by more than `channelTolerance`.
    /// Measured: 0.006% resting vs live and 0.014% resting vs today (antialiasing
    /// at a few glyph and ring edges). 0.03% is ~300 pixels of a 920x1120 render:
    /// one stale label (a model name) is ~1,500, so a budget near 0.2% would let
    /// the stale-chrome assertions pass with the chrome wrong.
    static let restVersusLiveBudget = 0.0003
    static let restVersusTodayBudget = 0.0003
    static let channelTolerance = 24

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func pump(_ seconds: TimeInterval = 0.12) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The user's window is key and their app active when they click; the check
    /// app is neither, so (as `--canvas-pointer-path-check` and the film harness
    /// do) the window says it is key and every view takes the first mouse, and
    /// AppKit delivers the press instead of eating it as an activation click.
    final class KeyableFixtureWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    private static func acceptFirstMouseEverywhere() {
        // NSTextView answers for itself, so it is swizzled too.
        for cls in [NSView.self, NSTextView.self] {
            guard let method = class_getInstanceMethod(cls, #selector(NSView.acceptsFirstMouse(for:))) else { continue }
            let always: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
            method_setImplementation(method, imp_implementationWithBlock(always))
        }
    }

    static func run() throws {
        acceptFirstMouseEverywhere()
        ManagedAgentTileNSView.chromePressedMouseButtons = { 0 }
        let key = AgentTranscriptCanvasView.rendererEnvironmentKey
        let previous = ProcessInfo.processInfo.environment[key]
        defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }
        guard UserDefaults.standard.string(forKey: AgentTranscriptCanvasView.rendererDefaultsKey) != "canvas" else {
            throw Failure(description: "the renderer default is set to canvas in this domain; the comparison needs today's tile")
        }

        unsetenv(key)
        let (today, todayWindow) = makeTile()
        defer { todayWindow.orderOut(nil) }
        try expect(today.qaChromeCanvas == nil && today.contentView === today.qaChromeBody,
                   "with the switch off the body must stay the content view")
        let todayCount = census(today).total
        let todayPixels = try render(today)

        setenv(key, "canvas", 1)
        let (tile, window) = makeTile()
        defer { window.orderOut(nil) }
        guard let chrome = tile.qaChromeCanvas else {
            throw Failure(description: "with ARRAY_TRANSCRIPT_RENDERER=canvas the tile installed no chrome canvas")
        }

        // Resting census.
        try expect(tile.isChromeResting, "an idle tile with the pointer elsewhere must rest")
        let resting = census(tile)
        try expect(resting.total <= restingViewBudget,
                   "a resting tile must be at most \(restingViewBudget) views, has \(resting.total): "
                   + resting.classes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        try expect(tile.qaChromeBody.window == nil, "the resting body must be out of the window")

        // Pixels: resting vs live, same tile; resting vs today.
        let restPixels = try render(tile)
        try expect(chrome.qaDrawCount > 0, "the resting chrome never drew")
        let wakeStart = ProcessInfo.processInfo.systemUptime
        tile.wakeChrome()
        let wakeMs = (ProcessInfo.processInfo.systemUptime - wakeStart) * 1_000
        let livePixels = try render(tile)
        let liveCount = census(tile).total
        let restVsLive = diff(restPixels, livePixels, excluding: nil)
        if let debug = ProcessInfo.processInfo.environment["TILE_CHROME_CANVAS_DEBUG_DIR"] {
            let url = URL(fileURLWithPath: debug, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, pixels) in [("today", todayPixels), ("rest", restPixels), ("live", livePixels)] {
                try NSBitmapImageRep(cgImage: pixels.image).representation(using: .png, properties: [:])?
                    .write(to: url.appendingPathComponent("\(name).png"))
            }
            var mask = restPixels.bytes
            for i in stride(from: 0, to: mask.count, by: 4) {
                var worst = 0
                for c in 0..<4 { worst = max(worst, abs(Int(restPixels.bytes[i + c]) - Int(livePixels.bytes[i + c]))) }
                let v: UInt8 = worst > channelTolerance ? 255 : 0
                mask[i] = v; mask[i + 1] = 0; mask[i + 2] = 0; mask[i + 3] = 255
            }
            let provider = CGDataProvider(data: Data(mask) as CFData)!
            let image = CGImage(width: restPixels.width, height: restPixels.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: restPixels.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: url.appendingPathComponent("rest-vs-live.png"))
        }
        try expect(restVsLive.fraction <= restVersusLiveBudget,
                   "resting and live pictures differ in \(percent(restVsLive.fraction)) of pixels (max channel \(restVsLive.maxDelta)); budget \(percent(restVersusLiveBudget))")
        let transcriptRect = chrome.convert(chrome.transcriptFrame, to: tile)
        let restVsToday = diff(todayPixels, restPixels, excluding: transcriptRect)
        try expect(restVsToday.fraction <= restVersusTodayBudget,
                   "the resting tile and today's tile differ in \(percent(restVsToday.fraction)) of pixels outside the transcript (max channel \(restVsToday.maxDelta)); budget \(percent(restVersusTodayBudget))")
        let restStart = ProcessInfo.processInfo.systemUptime
        try expect(tile.restChromeIfIdle(), "an idle live tile must rest when asked")
        let restMs = (ProcessInfo.processInfo.systemUptime - restStart) * 1_000

        // A state change while resting reaches the drawn chrome, through the
        // tile's own production seam: another model and another effort.
        let footer = tile.qaProviderFooterForChecks
        let settings = tile.qaProviderSettings
        // Draw the resting state first, so the change below has to invalidate
        // on its own rather than ride the rest's own pending display.
        let beforeChange = try render(tile)
        let otherModel = footer.modelButton.items.filter(\.enabled).map(\.id).first { $0 != settings.model }
        let otherThinking = AgentModelConfig.thinkingOptions.first { $0 != settings.thinking } ?? settings.thinking
        tile.applyProviderSettings(AgentModelConfig.Resolution(model: otherModel ?? settings.model, thinking: otherThinking))
        try expect(tile.isChromeResting, "a model change must not wake the tile")
        let changedRest = try render(tile)
        tile.wakeChrome()
        let changedLive = try render(tile)
        let changed = diff(changedRest, changedLive, excluding: nil)
        try expect(changed.fraction <= restVersusLiveBudget,
                   "after a model change while resting, the drawn chrome is stale: \(percent(changed.fraction)) of pixels differ")
        let titleBand = NSRect(x: 0, y: 0, width: tile.bounds.width, height: tile.chromeBarHeight)
        try expect(diff(beforeChange, changedRest, excluding: titleBand).fraction > 0,
                   "the settings change drew nothing different below the title bar; the staleness assertion is vacuous")
        tile.applyProviderSettings(settings)
        tile.restChromeIfIdle()

        // An appearance change while resting reaches the detached body.
        window.appearance = NSAppearance(named: .darkAqua)
        try expect(tile.isChromeResting, "an appearance change must not wake the tile")
        let darkRest = try render(tile)
        tile.wakeChrome()
        let darkLive = try render(tile)
        let dark = diff(darkRest, darkLive, excluding: nil)
        try expect(dark.fraction <= restVersusLiveBudget,
                   "after a switch to dark while resting, resting and live differ in \(percent(dark.fraction)) of pixels")
        try expect(diff(restPixels, darkRest, excluding: nil).fraction > 0.5,
                   "the dark resting tile still looks light")
        window.appearance = NSAppearance(named: .aqua)
        tile.restChromeIfIdle()

        // Zoom: the canvas scales the tile's frame over fixed bounds.
        let logical = tile.bounds
        let backing = window.backingScaleFactor
        // Settle whatever the rest left pending, so the count is the zoom's alone.
        tile.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let chromeLayouts = chrome.qaLayoutCount
        for scale: CGFloat in [2, 4] {
            let zoom = scale / backing
            let draws = chrome.qaDrawCount
            tile.setFrameSize(NSSize(width: logical.width * zoom, height: logical.height * zoom))
            tile.bounds = logical
            tile.layoutSubtreeIfNeeded()
            // As `--transcript-canvas-check` does: an offscreen fixture has to ask
            // for the display pass a real camera step gets from AppKit.
            chrome.needsDisplay = true
            window.displayIfNeeded()
            chrome.layer?.displayIfNeeded()
            try expect(chrome.qaDrawCount > draws && abs(chrome.qaLastDrawScale - scale) < 0.01,
                       "at camera zoom \(zoom) the chrome drew \(chrome.qaDrawCount - draws) time(s) at scale \(chrome.qaLastDrawScale); expected \(scale)")
        }
        try expect(chrome.qaLayoutCount == chromeLayouts,
                   "a zoom must not lay out the resting chrome: \(chrome.qaLayoutCount - chromeLayouts) pass(es)")
        tile.setFrameSize(logical.size)
        tile.bounds = logical
        tile.layoutSubtreeIfNeeded()
        try expect(tile.isChromeResting, "a zoom must not wake the tile")

        // A press on the drawn composer focuses the real editor; typing reaches the draft.
        guard let composer = tile.qaComposerForChecks else { throw Failure(description: "the tile has no composer") }
        let composerPoint = windowPoint(of: composer, in: tile)
        click(at: composerPoint, in: window)
        try expect(!tile.isChromeResting, "a press on the drawn composer must wake the tile")
        try expect(window.firstResponder === composer.textView,
                   "a press on the drawn composer must focus the real editor, got \(String(describing: window.firstResponder))")
        for character in ["h", "i"] {
            NSApp.postEvent(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: character == "h" ? 4 : 34)!, atStart: false)
        }
        drainEvents()
        try expect(tile.qaComposerDraftText == "hi", "typed keys must reach the draft, got \(tile.qaComposerDraftText.debugDescription)")
        try expect(!tile.restChromeIfIdle(), "a focused composer must keep the tile live")

        // Losing focus rests it, and the drawn chrome shows the draft.
        window.makeFirstResponder(nil)
        pump(0.5)
        try expect(tile.isChromeResting, "the tile must rest once the composer resigns")
        let draftRest = try render(tile)
        tile.wakeChrome()
        let draftLive = try render(tile)
        let draftDiff = diff(draftRest, draftLive, excluding: nil)
        try expect(draftDiff.fraction <= restVersusLiveBudget,
                   "with a draft, resting and live differ in \(percent(draftDiff.fraction)) of pixels")
        try expect(diff(restPixels, draftRest, excluding: transcriptRect).fraction > 0,
                   "the resting tile drew no draft; the draft assertion is vacuous")
        tile.restChromeIfIdle()

        // What a hover costs: the median of five wake/rest round trips.
        var wakes: [Double] = [], rests: [Double] = []
        for _ in 0..<5 {
            var start = ProcessInfo.processInfo.systemUptime
            tile.wakeChrome()
            window.displayIfNeeded()
            wakes.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            start = ProcessInfo.processInfo.systemUptime
            tile.restChromeIfIdle()
            window.displayIfNeeded()
            rests.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        }
        let wakeMedian = wakes.sorted()[2], restMedian = rests.sorted()[2]

        // A press on a drawn picker opens the real popover.
        let picker = footer.modelButton
        click(at: windowPoint(of: picker, in: tile), in: window)
        try expect(picker.presentedPopoverIsVisible, "a press on the drawn model picker must open its popover")
        try expect(!tile.restChromeIfIdle(), "an open picker must keep the tile live")
        picker.dismissPresentedPopover()
        try expect(tile.restChromeIfIdle(), "the tile must rest once the picker closes")

        // ⋯ and × dispatch their real actions.
        var presentedMenu: NSMenu?
        let previousPresenter = TileNSView.qaMenuPresenter
        TileNSView.qaMenuPresenter = { presentedMenu = $0 }
        defer { TileNSView.qaMenuPresenter = previousPresenter }
        guard let actions = tile.titleBarActionsFrameForQA else { throw Failure(description: "the title bar has no ⋯") }
        try expect(tile.titleBarControlsAreDrawn, "a resting title bar must draw its controls")
        click(at: tile.convert(NSPoint(x: actions.midX, y: actions.midY), to: nil), in: window)
        try expect(presentedMenu != nil, "a press on the drawn ⋯ must open the tile's actions")
        try expect(tile.restChromeIfIdle(), "the tile must rest after ⋯")
        var closed = false
        tile.onClose = { closed = true }
        let close = tile.qaCloseButtonFrame
        click(at: tile.convert(NSPoint(x: close.midX, y: close.midY), to: nil), in: window)
        try expect(closed, "a press on the drawn × must close the tile")

        print("tile chrome canvas: resting \(resting.total) views (live \(liveCount), today \(todayCount)); "
              + "rest vs live \(percent(restVsLive.fraction)) px (max \(restVsLive.maxDelta)); "
              + "rest vs today \(percent(restVsToday.fraction)) px outside the transcript (max \(restVsToday.maxDelta)); "
              + "first wake \(String(format: "%.1f", wakeMs)) ms, rest \(String(format: "%.1f", restMs)) ms; "
              + "median wake+display \(String(format: "%.1f", wakeMedian)) ms, rest+display \(String(format: "%.1f", restMedian)) ms; "
              + "dark flip while resting \(percent(dark.fraction)) px; redrew at 2x and 4x with 0 chrome layouts; composer, picker, ⋯ and × reached through drawn chrome")

        if let directory = ProcessInfo.processInfo.environment["TILE_CHROME_CANVAS_PNG_DIR"] {
            try writeReviewRenders(to: URL(fileURLWithPath: directory, isDirectory: true))
        }
    }

    // MARK: Fixture

    static func makeTile(width: CGFloat = 460, height: CGFloat = 560,
                         appearance: NSAppearance.Name = .aqua) -> (ManagedAgentTileNSView, NSWindow) {
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "chrome-canvas",
            frame: TileFrame(x: 0, y: 0, width: Double(width), height: Double(height)),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")), threadId: "chrome")
        tile.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // Room for the tile at 4x camera zoom on a 1x backing.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width * 4, height: height * 4))
        host.addSubview(tile)
        let window = KeyableFixtureWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        tile.layoutSubtreeIfNeeded()
        pump()
        tile.layoutSubtreeIfNeeded()
        return (tile, window)
    }

    private static func windowPoint(of view: NSView, in tile: ManagedAgentTileNSView) -> NSPoint {
        // A resting view is detached; its frames still hold the body's layout,
        // and the body fills the chrome canvas.
        let rect: NSRect
        if view.window == nil, let chrome = tile.qaChromeCanvas {
            rect = chrome.convert(NativeViewVectorRenderer.convert(view.bounds, from: view, to: tile.qaChromeBody), to: nil)
        } else {
            rect = view.convert(view.bounds, to: nil)
        }
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    /// Through the application's queue, the way a real press arrives:
    /// `nextEvent` makes it `NSApp.currentEvent`, then `NSApp.sendEvent` routes it
    /// (local monitors, window, hit test). A control that tracks the press in its
    /// own loop dequeues the release itself.
    private static func click(at point: NSPoint, in window: NSWindow) {
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        NSApp.postEvent(mouse(.leftMouseDown), atStart: false)
        NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
        drainEvents()
    }

    private static func drainEvents() {
        while let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05),
                                          inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        pump()
    }

    // MARK: Census

    struct Census {
        var total = 0
        var hidden = 0
        var classes: [String: Int] = [:]
    }

    static func census(_ view: NSView) -> Census {
        var result = Census()
        func walk(_ view: NSView, _ hiddenAbove: Bool) {
            result.total += 1
            let hidden = hiddenAbove || view.isHidden
            if hidden { result.hidden += 1 }
            result.classes[String(describing: type(of: view)), default: 0] += 1
            for child in view.subviews { walk(child, hidden) }
        }
        walk(view, false)
        return result
    }

    // MARK: Pixels

    struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        let scale: CGFloat
        let image: CGImage
    }

    /// The window server's own composite of the tile, the pixels a screen
    /// shows — every comparison reads these, never a re-render of the views.
    static func render(_ tile: NSView) throws -> Pixels {
        guard let window = tile.window, let host = window.contentView else { throw Failure(description: "the tile has no window") }
        tile.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        pump(0.2)
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]
        ) else { throw Failure(description: "the window server returned no image of the check's own window") }
        let scale = CGFloat(image.width) / host.bounds.width
        // Image rows run top-down; the host is not flipped.
        let rect = tile.convert(tile.bounds, to: host)
        let crop = CGRect(x: rect.minX * scale, y: (host.bounds.height - rect.maxY) * scale,
                          width: rect.width * scale, height: rect.height * scale).integral
        guard let cropped = image.cropping(to: crop) else { throw Failure(description: "could not crop the tile") }
        let width = cropped.width, height = cropped.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "no bitmap context")
        }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data, let normalized = context.makeImage() else { throw Failure(description: "no image") }
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        return Pixels(width: width, height: height, bytes: bytes, scale: scale, image: normalized)
    }

    struct Difference { let fraction: Double; let maxDelta: Int }

    /// `excluding` is in the tile's (flipped) coordinates.
    static func diff(_ a: Pixels, _ b: Pixels, excluding: NSRect?) -> Difference {
        guard a.width == b.width, a.height == b.height else { return Difference(fraction: 1, maxDelta: 255) }
        var differing = 0, counted = 0, maxDelta = 0
        let skip = excluding.map { NSRect(x: $0.minX * a.scale, y: $0.minY * a.scale,
                                          width: $0.width * a.scale, height: $0.height * a.scale) }
        for y in 0..<a.height {
            for x in 0..<a.width {
                if let skip, skip.contains(NSPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) { continue }
                counted += 1
                let i = (y * a.width + x) * 4
                var worst = 0
                for c in 0..<4 { worst = max(worst, abs(Int(a.bytes[i + c]) - Int(b.bytes[i + c]))) }
                maxDelta = max(maxDelta, worst)
                if worst > channelTolerance { differing += 1 }
            }
        }
        return Difference(fraction: counted == 0 ? 0 : Double(differing) / Double(counted), maxDelta: maxDelta)
    }

    private static func percent(_ value: Double) -> String { String(format: "%.3f%%", value * 100) }

    // MARK: Review renders

    private static func writeReviewRenders(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = AgentTranscriptCanvasView.rendererEnvironmentKey
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for renderer in ["today", "drawn"] {
                if renderer == "drawn" { setenv(key, "canvas", 1) } else { unsetenv(key) }
                let (tile, window) = makeTile(appearance: appearance)
                defer { window.orderOut(nil) }
                tile.setTitleBarIdentity(title: "Riley", providerModel: "anthropic/claude-opus-4")
                tile.qaSetComposerDraftForChecks("Profile the pinch first, then the tiles")
                window.makeFirstResponder(nil)
                pump(0.5)
                if renderer == "drawn" {
                    tile.restChromeIfIdle()
                    try expect(tile.isChromeResting, "the \(name) review tile did not rest")
                }
                let pixels = try render(tile)
                let rep = NSBitmapImageRep(cgImage: pixels.image)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                let url = directory.appendingPathComponent("tile-\(renderer)-\(name).png")
                try png.write(to: url)
                print("tile chrome canvas: wrote \(url.path)")
            }
        }
    }
}
