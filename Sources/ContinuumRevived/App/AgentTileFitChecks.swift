import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// `--agent-tile-fit-check`: Dylan's 0.7.40 Codex tile. Zoomed out, the under-bar
// scaled with the title bar without a ceiling, so the Managed pill grew to the
// title's size (about twice the transcript text) in a tall, mostly empty band;
// and the composer's right edge, mic and Send ran past the tile's right edge.
//
// A real managed Codex agent tile, attached to a real supervisor, on a real
// canvas in an offscreen window, swept over canvas zooms, tile widths and the
// three character sizes (Settings › Agent characters › Character
// size, posted through the setting's own change notification). At every point:
// (a) zoomed-out screen text stays at its natural chrome role size (or yields
//     to real width pressure), never exceeding its 100% screen size;
// (b) every pill is whole: shown, inside the under-bar and the tile, text unclipped;
// (c) every composer control (prompt, harness, model, effort, mic, Send) lies
//     fully inside the tile.
// Writes stills of each tile in light and dark, and a sheet per appearance, to
// qa-runs/agent-tile-fit (or $ARRAY_TILE_FIT_OUT).
@MainActor
enum AgentTileFitChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static let zooms: [Double] = [0.25, 0.5, 0.6, 1.0, 1.6, 2.5]
    /// The default tile, two narrow ones, and two of the large Codex tiles on
    /// Dylan's canvas (1318 × 1111 and 1826 × 1606).
    static let sizesOfTiles: [NSSize] = [NSSize(width: 640, height: 520), NSSize(width: 420, height: 520),
                                         NSSize(width: 320, height: 520), NSSize(width: 1320, height: 1110),
                                         NSSize(width: 1830, height: 1600)]
    static var widths: [CGFloat] { sizesOfTiles.map(\.width) }
    /// The narrow tile that also carries a branch and the live indicator.
    static let crowdedWidth: CGFloat = 320
    static let sizes: [(name: String, value: String?)] = [("small", nil), ("medium", "medium"), ("large", "large")]
    static let sizeKey = "agentCharacters.size"
    /// The tile's own text zoom (⌘+ / ⌘−): the default, the screenshot's 110%,
    /// the largest and the smallest rung. The under-bar follows it on purpose.
    static let pageZooms: [Int] = [100, 110, 150, 80]

    static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    static func run() throws -> String {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { failures.append(message()) }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-tile-fit-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ArrayTileFitChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.reduceMotion = { false }
        controller.windowIsVisible = { _ in true }
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        defaults.set(AgentCharacterConfig.Motion.never.rawValue, forKey: AgentCharacterConfig.motionKey)
        controller.adopt(defaults: defaults)
        let out = ProcessInfo.processInfo.environment["ARRAY_TILE_FIT_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("qa-runs/agent-tile-fit", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.codex)
        ManagedAgentTileNSView.qaPointerInside = { _ in false }
        defer { ManagedAgentTileNSView.qaPointerInside = nil }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: support),
            makeRunner: AgentSupervisor.productionRunner,
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: support, debounceInterval: 0),
            transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        defer { supervisor.stopAll() }

        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        canvas.focusBroker = FocusBroker()
        canvas.frame = NSRect(x: 0, y: 0, width: 1600, height: 900)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }

        var tiles: [(width: CGFloat, view: ManagedAgentTileNSView)] = []
        var x: Double = 20
        for tileSize in sizesOfTiles {
            let width = tileSize.width
            let agentID = supervisor.spawn(
                role: nil, prompt: nil, cwd: work, harness: .codex, mode: .managed,
                model: "openai-codex/gpt-6-astra", thinking: "medium", displayName: "Pioneer Lead Orchestrator 0.7.40")
            let tile = Tile(id: UUID(), kind: .managedAgent, title: "Pioneer Lead Orchestrator 0.7.40",
                            frame: TileFrame(x: x, y: 20, width: Double(width), height: Double(tileSize.height)),
                            zPosition: .fromLegacyRank(1), runtimeRef: nil,
                            metadata: TileMetadata(launchProfileId: "managed"))
            x += Double(width) + 40
            let view = ManagedAgentTileNSView(tile: tile)
            canvas.install(tileView: view, for: tile)
            view.attach(agentID: agentID, supervisor: supervisor)
            // The narrowest tile also carries a branch and the live indicator.
            if width == crowdedWidth {
                view.applyBranchContext(AgentRowContext(agentKind: .managed, checkedOutBranch: "array/integration"))
                view.setOwnershipMark(.init(text: "Yours · shared with Sam", colour: .systemPurple, outlined: false))
            }
            tiles.append((width, view))
        }

        func settle() {
            pump(0.1)
            canvas.layoutSubtreeIfNeeded()
            for (_, view) in tiles {
                // Production derives Managed from the record; the fixture's
                // indicator default may be off, so the pill is asked for here.
                view.qaPageZoomHeaderView.showsManaged = true
                view.layoutSubtreeIfNeeded()
            }
            canvas.layoutSubtreeIfNeeded()
        }
        func choose(_ value: String?) {
            if let value { defaults.set(value, forKey: sizeKey) } else { defaults.removeObject(forKey: sizeKey) }
            SettingChangeEvent.post(SettingID(rawValue: sizeKey))
            settle()
        }

        struct Sample { var pillText: CGFloat; var rowHeight: CGFloat; var scale: CGFloat }
        func sample(_ view: ManagedAgentTileNSView, label: String) -> Sample? {
            let header = view.qaPageZoomHeaderView
            guard let badge = header.qaManagedBadge, let scale = view.qaUnderBarScale,
                  let under = view.qaUnderBarFrame else {
                // A crowded row yields Managed first, by design.
                expect(view.bounds.width == crowdedWidth, "\(label): the Managed pill is not shown on the under-bar")
                return nil
            }
            return Sample(pillText: badge.qaTextPointSize * scale, rowHeight: under.height, scale: scale)
        }

        // The natural size at the default text zoom: zoom 1, Small.
        choose(nil)
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        settle()
        let reference = tiles[0].view
        guard let natural = sample(reference, label: "zoom 1 small") else {
            throw Failure(description: failures.joined(separator: "\n"))
        }
        let defaultNatural = natural
        // The title bar's secondary (quiet) text at 100%: 11/12 of the title.
        let titleSecondary1x = reference.qaTitleFontWorldSize * 11 / 12
        expect(natural.pillText <= titleSecondary1x + 0.01,
               "at 100% the Managed text \(natural.pillText) pt is larger than the title bar's secondary text \(titleSecondary1x) pt")

        var rows: [[String: Any]] = []
        var naturals: [String: Any] = [:]
        var stills: [String: [String: NSImage]] = [:]
        for percent in pageZooms {
            for (_, view) in tiles { view.setPageZoom(AgentPageZoom(percent: percent)) }
            // This rung's natural size: zoom 1, Small.
            choose(nil)
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
            settle()
            guard let natural = sample(reference, label: "page \(percent)% zoom 1 small") else { continue }
            naturals["\(percent)"] = ["pillText": natural.pillText, "rowHeight": natural.rowHeight]
            for size in sizes {
                choose(size.value)
                for zoom in zooms {
                    canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
                    settle()
                    // Both states a tile shows: live controls, and the resting
                    // picture of a body parked in the hidden host (every idle tile).
                    for phase in ["live", "resting"] {
                    for (_, view) in tiles {
                        if phase == "live" { view.wakeChrome() } else { _ = view.restChromeIfIdle() }
                    }
                    // A rest asked for while the camera still counts as moving is
                    // deferred (`scheduleChromeRest`); ask again until it lands.
                    let deadline = Date().addingTimeInterval(2)
                    while phase == "resting", tiles.contains(where: { !$0.view.isChromeResting }), Date() < deadline {
                        pump(0.05)
                        for (_, view) in tiles where !view.isChromeResting { _ = view.restChromeIfIdle() }
                    }
                    settle()
                    for (width, view) in tiles {
                        let label = "page \(percent)% \(size.name) zoom \(zoom) width \(Int(width)) \(phase)"
                        if phase == "resting" { expect(view.isChromeResting, "\(label): the tile did not rest") }
                        let bar = view.qaTitleBarFrame
                        var row: [String: Any] = ["page": percent, "size": size.name, "zoom": zoom, "width": width,
                                                  "titleBar": NSStringFromRect(bar), "titleFont": view.qaTitleFontWorldSize]
                        // Screen-space readability and ceiling, measured from the real label.
                        if let s = sample(view, label: label) {
                            let screen = CGFloat(zoom)
                            row["pillText"] = s.pillText; row["rowHeight"] = s.rowHeight; row["underBarScale"] = s.scale
                            row["screenPillText"] = s.pillText * screen
                            row["screenRowHeight"] = s.rowHeight * screen
                            if zoom <= 1 {
                                expect(s.pillText * screen <= natural.pillText + 0.01,
                                       "\(label): screen Managed text exceeds natural chrome role size")
                                expect(s.rowHeight * screen <= natural.rowHeight + 0.5,
                                       "\(label): screen row exceeds natural chrome row")
                                // The role's unscaled label font is the readability floor;
                                // the 100% chrome adds only its existing 28/24 scale.
                                if width >= 320 {
                                    let role = min(natural.pillText, defaultNatural.pillText) / (TileNSView.minScreenGrabPx / TileNSView.titleBarHeight)
                                    expect(s.pillText * screen >= role - 0.01,
                                           "\(label): screen Managed text \(s.pillText * screen) below role font \(role)")
                                }
                            } else {
                                expect(s.pillText <= natural.pillText + 0.01,
                                       "\(label): zoomed-in world font changed")
                            }
                        }
                        // (b) pills whole.
                        let header = view.qaPageZoomHeaderView
                        if header.qaBranch != nil, let scale = view.qaUnderBarScale, zoom <= 1 {
                            let screenFont = header.qaBranchTextPointSize * scale * CGFloat(zoom)
                            let floor = min(NSFont.token(.caption).pointSize,
                                            NSFont.token(.caption, zoom: AgentPageZoom(percent: percent)).pointSize)
                            expect(screenFont >= floor - 0.05,
                                   "\(label): branch screen font \(screenFont) below caption role \(floor)")
                            row["screenBranchText"] = screenFont
                        }
                        if let under = view.qaUnderBarFrame {
                            var pills: [(String, NSRect?, NSView)] = [("managed", header.qaManagedFrame, header)]
                            if width == crowdedWidth { pills.append(("branch", header.qaBranch == nil ? nil : header.qaBranchFrame, header)) }
                            for (name, local, owner) in pills {
                                guard let local, let rect = view.qaUnderBarRect(local, in: owner) else {
                                    expect(name == "managed" && width == crowdedWidth, "\(label): the \(name) pill is not shown"); continue
                                }
                                row[name] = NSStringFromRect(rect)
                                if let body = view.contentView {
                                    expect(rect.maxY <= body.frame.minY + 0.5,
                                           "\(label): \(name) covers body beginning at \(body.frame.minY)")
                                }
                                expect(under.insetBy(dx: -0.5, dy: -0.5).contains(rect), "\(label): \(name) pill \(rect) is outside the under-bar \(under)")
                                expect(rect.minX >= 0 && rect.maxX <= view.bounds.width - 1, "\(label): \(name) pill \(rect) runs past the tile")
                                expect(!rect.intersects(bar), "\(label): \(name) pill \(rect) clips the title bar \(bar)")
                            }
                            if let badge = header.qaManagedBadge { expect(badge.qaTextFits, "\(label): the Managed pill clips its text (\(badge.qaTextFitDescription))") }
                            if let indicator = view.qaLiveIndicatorFrame {
                                row["indicator"] = NSStringFromRect(indicator)
                                expect(under.insetBy(dx: -0.5, dy: -0.5).contains(indicator), "\(label): live indicator \(indicator) is outside the under-bar")
                            }
                        } else {
                            expect(false, "\(label): no under-bar")
                        }
                        // (c) the composer inside the tile.
                        let body = view.qaPageZoomContentRoot
                        let content = view.contentView?.frame ?? .zero
                        expect(abs(body.bounds.width - content.width) < 0.5,
                               "\(label): the body is \(body.bounds.width) wide in a \(content.width) content frame")
                        expect(content.minX >= -0.5 && content.maxX <= view.bounds.width + 0.5,
                               "\(label): the content frame \(content) runs past the tile \(view.bounds)")
                        let controls = view.qaComposerControlFrames
                        let names = Set(controls.map(\.name))
                        // The footer drops effort, then the mic, by measured fit; prompt,
                        // model and Send always stay.
                        for required in ["prompt", "send", "model"] {
                            expect(names.contains(required), "\(label): the composer shows no \(required) control (shown: \(names.sorted()))")
                        }
                        var composer: [String: String] = [:]
                        for (name, frame) in controls {
                            composer[name] = NSStringFromRect(frame)
                            expect(frame.minX >= -0.5 && frame.maxX <= body.bounds.width + 0.5
                                   && frame.minY >= -0.5 && frame.maxY <= body.bounds.height + 0.5,
                                   "\(label): composer \(name) \(frame) is outside the tile's body \(body.bounds.size)")
                        }
                        row["composer"] = composer
                        row["phase"] = phase
                        rows.append(row)
                    }
                    }
                    // Stills: the default-width tile drawn at its world size, so the
                    // pill reads against the body text the way Dylan saw it.
                    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                        window.appearance = NSAppearance(named: appearance)
                        settle()
                        canvas.displayIfNeeded()
                        let tone = appearance == .aqua ? "light" : "dark"
                        for (prefix, view) in [("tile", tiles[0].view), ("big", tiles[3].view)] {
                            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                            view.cacheDisplay(in: view.bounds, to: rep)
                            let name = "\(prefix)-\(percent)-\(size.name)-\(zoom)-\(tone).png"
                            try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name))
                            guard prefix == "tile" else { continue }
                            let image = NSImage(size: view.bounds.size); image.addRepresentation(rep)
                            stills["\(percent)-\(tone)", default: [:]]["\(size.name)@\(zoom)"] = image
                        }
                    }
                    window.appearance = nil
                }
            }
        }
        choose(nil)
        for (tone, images) in stills { try writeSheet(images, tone: tone, to: out.appendingPathComponent("sheet-\(tone).png")) }

        let manifest: [String: Any] = ["check": "agent-tile-fit", "zooms": zooms, "widths": widths,
                                       "natural": naturals, "titleSecondary1x": titleSecondary1x,
                                       "rows": rows, "failures": failures]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("manifest.json"), options: .atomic)
        guard failures.isEmpty else {
            throw Failure(description: "\(failures.count) failures; first:\n" + failures.prefix(12).joined(separator: "\n"))
        }
        return "agent tile fit: \(rows.count) samples (\(pageZooms.count) text zooms × \(sizes.count) character sizes × \(zooms.count) zooms × \(widths.count) tiles × live/resting), cap \(defaultNatural.pillText) pt text / \(defaultNatural.rowHeight) pt row at 100%; \(out.path)"
    }

    /// Rows are zooms, columns are character sizes; each cell is a tile at half its world size.
    private static func writeSheet(_ images: [String: NSImage], tone: String, to url: URL) throws {
        let cell = NSSize(width: 320, height: 260), label: CGFloat = 18, gap: CGFloat = 12
        let size = NSSize(width: CGFloat(sizes.count) * (cell.width + gap) + gap + 60,
                          height: CGFloat(zooms.count) * (cell.height + gap) + gap + label)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (tone.hasSuffix("light") ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.12, alpha: 1)).setFill()
        NSRect(origin: .zero, size: size).fill()
        let ink: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                  .foregroundColor: tone.hasSuffix("light") ? NSColor.black : NSColor.white]
        for (column, entry) in sizes.enumerated() {
            let x = 60 + gap + CGFloat(column) * (cell.width + gap)
            (entry.name as NSString).draw(at: NSPoint(x: x, y: size.height - label), withAttributes: ink)
            for (row, zoom) in zooms.enumerated() {
                let y = size.height - label - CGFloat(row + 1) * (cell.height + gap)
                if column == 0 { ("zoom \(zoom)" as NSString).draw(at: NSPoint(x: 6, y: y + cell.height / 2), withAttributes: ink) }
                images["\(entry.name)@\(zoom)"]?.draw(in: NSRect(x: x, y: y, width: cell.width, height: cell.height))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
