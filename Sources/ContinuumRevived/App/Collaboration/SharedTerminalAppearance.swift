import AppKit
import CoreImage
import IOSurface
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// `--shared-terminal-render-check <dir>` (`.plans/114-terminal-sharing`): a
/// teammate's shared terminal as the guest sees it, in light and dark, off
/// screen. The screen is built by the host's own code (`TerminalLiveSource.vt`)
/// from a captured pane, then streamed output follows; a real Ghostty surface
/// draws it. Fails unless the guest's surface has the host's grid exactly,
/// shows the host's lines where the host has them, draws in the host's
/// palette whatever this Mac's appearance, and the tile chrome follows it.
@MainActor
enum SharedTerminalAppearance {
    static let size = NSSize(width: 1000, height: 560)
    /// A host palette unlike Ghostty's defaults, so a pixel proves where it came from.
    static let palette = Collaboration.LiveTile.TerminalPalette(
        foreground: "#d8dee9", background: "#1b2333", cursor: "#f5c06f",
        colors: ["#3b4252", "#e0566b", "#7cc38e", "#ebcb8b", "#5e9de0", "#b48ead", "#88c0d0", "#e5e9f0",
                 "#4c566a", "#f07c8c", "#9fdcab", "#f2d9a6", "#81a1c1", "#c9a6c2", "#8fbcbb", "#eceff4"])
    static let columns = 64, rows = 16

    static func screen() -> TerminalTmuxTap.Screen {
        let esc = "\u{1b}["
        var lines = Array(repeating: "", count: rows)
        lines[0] = "avery@studio ~/checkout % swift test"
        lines[1] = "Building for debugging..."
        lines[2] = "\(esc)32m✔\(esc)39m CheckoutStateTests \(esc)2m(0.012s)\(esc)22m"
        lines[3] = "\(esc)31m✘ WalletTests.testDeclined\(esc)39m"
        lines[4] = "\(esc)1;37;41m FAIL \(esc)0m Executed 42 tests, with 1 failure"
        lines[5] = "avery@studio ~/checkout % "
        return .init(columns: columns, rows: rows, cursorX: 26, cursorY: 5, cursorVisible: true, alternate: false,
                     scrollTop: 0, scrollBottom: rows - 1, originMode: false, wrap: true, insert: false,
                     cursorShape: "block", cursorBlinking: false, history: ["older line one", "older line two"], lines: lines, saved: [])
    }

    static func state() -> Collaboration.LiveTile.State {
        let run = UUID()
        let base = Collaboration.LiveTile.TerminalFrame(stream: run, sequence: 1, kind: .keyframe, columns: columns, rows: rows,
                                                       bytes: TerminalLiveSource.vt(screen(), history: true), palette: palette)
        let more = Collaboration.LiveTile.TerminalFrame(stream: run, sequence: 2, kind: .output, columns: columns, rows: rows,
                                                       bytes: Data("git status\r\n\u{1b}[33mmodified:\u{1b}[0m   Wallet.swift\r\navery@studio ~/checkout % ".utf8))
        let screen = Collaboration.LiveTile.TerminalScreen(base: base, output: [more])
        return .init(generation: UUID(), revision: 1, payload: .terminal(.init(title: "zsh", text: "", columns: columns, rows: rows, screen: screen)))
    }

    static let expected = ["older line two", "avery@studio ~/checkout % swift test", "Building for debugging...", "✔ CheckoutStateTests (0.012s)",
                           "✘ WalletTests.testDeclined", " FAIL  Executed 42 tests, with 1 failure", "avery@studio ~/checkout % git status",
                           "modified:   Wallet.swift", "avery@studio ~/checkout %"]

    private final class Canvas: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { SurfaceToken.canvas.color.nsColor(in: self).setFill(); bounds.fill() }
    }

    static func render(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ghostty = try GhosttyRuntimeContext()
        defer { ghostty.shutdown() }
        var captions: [NSColor] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let canvas = Canvas(frame: NSRect(origin: .zero, size: size))
            canvas.wantsLayer = true
            let host = SharedArea.ID<SharedArea.Person>()
            let reference = SharedAgentTileReference(areaId: UUID(), objectId: UUID(), hostName: "Avery", hostPerson: host.rawValue, liveKind: "terminal")
            let tile = Tile(id: UUID(), kind: .sharedTile, title: "Avery's Terminal · zsh", frame: .init(x: 0, y: 0, width: 900, height: 480),
                            zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: .init(sharedTile: reference))
            let view = SharedTileNSView(tile: tile)
            view.frame = NSRect(x: 50, y: 40, width: 900, height: 480)
            canvas.addSubview(view)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = canvas
            window.orderFrontOffscreenForChecks()
            view.apply(.live, hostName: "Avery", colour: SharedAreaPersonColour.color(for: host, host: host))
            view.body?.show(state())
            guard let mirror = view.body?.qaTerminalMirror else { throw SharedAreaCheckRig.Failure(description: "a terminal state with a screen drew no mirror") }
            // The surface starts its pipe and draws: wait for the text.
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, !mirror.qaScreenText.contains("Wallet.swift") { try await Task.sleep(for: .milliseconds(50)) }
            try await Task.sleep(for: .milliseconds(300))
            canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded()
            let name = appearance == .aqua ? "light" : "dark"
            let lines = mirror.qaScreenText.split(separator: "\n", omittingEmptySubsequences: false).map { line in String(line.reversed().drop { $0 == " " }.reversed()) }
            let drawn = lines.filter { !$0.isEmpty }
            guard let grid = mirror.qaGrid, grid.columns == columns, grid.rows == rows else {
                throw SharedAreaCheckRig.Failure(description: "\(name): the guest's grid is \(mirror.qaGrid.map { "\($0.columns)x\($0.rows)" } ?? "none"), not the host's \(columns)x\(rows)")
            }
            print("PASS \(name): the guest's surface has the host's grid, \(columns)x\(rows)")
            guard drawn == Array(expected.dropFirst()) else {
                throw SharedAreaCheckRig.Failure(description: "\(name): the guest's screen is not the host's: \(drawn) vs \(Array(expected.dropFirst()))")
            }
            print("PASS \(name): the guest's screen is the host's, line for line, then the streamed output")
            let scrollback = mirror.qaScrollbackText
            guard scrollback.contains("older line two") else { throw SharedAreaCheckRig.Failure(description: "\(name): the screen's history is not in the scrollback") }
            print("PASS \(name): the history above the host's screen is in the guest's scrollback")
            guard let rep = SharedTerminalStill.bitmap(of: canvas), rep.size.width > 0 else { throw SharedAreaCheckRig.Failure(description: "no bitmap") }
            if let png = rep.representation(using: .png, properties: [:]) { try png.write(to: directory.appendingPathComponent("shared-terminal-\(name).png")) }
            let layerContents = mirror.qaTerminalView?.layer?.contents.map { "\(type(of: $0))" } ?? "none"
            print("NOTE \(name): surface layer contents \(layerContents), box \(mirror.qaBoxFrame)")
            let box = mirror.convert(mirror.qaBoxFrame, to: canvas)
            guard box.width <= view.frame.width, box.height > 100 else { throw SharedAreaCheckRig.Failure(description: "\(name): the terminal is not fitted to the tile: \(box)") }
            let scale = rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 2
            func pixels(near hex: String, in rect: NSRect) -> Int {
                let target = NSColor(srgbHex: hex)
                var count = 0
                for y in stride(from: Int(rect.minY * scale), to: Int(rect.maxY * scale), by: 2) {
                    for x in stride(from: Int(rect.minX * scale), to: Int(rect.maxX * scale), by: 2) {
                        guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        if abs(colour.redComponent - target.redComponent) + abs(colour.greenComponent - target.greenComponent)
                            + abs(colour.blueComponent - target.blueComponent) < 0.24 { count += 1 }
                    }
                }
                return count
            }
            if let sample = rep.colorAt(x: Int(box.minX * scale) + 6, y: Int(box.maxY * scale) - 6)?.usingColorSpace(.sRGB) {
                print(String(format: "NOTE \(name): terminal corner pixel %.3f %.3f %.3f (host background \(palette.background!))",
                             sample.redComponent, sample.greenComponent, sample.blueComponent))
            }
            let background = pixels(near: palette.background!, in: box)
            let red = pixels(near: palette.colors[1], in: box), green = pixels(near: palette.colors[2], in: box)
            let total = Int(box.width * scale / 2) * Int(box.height * scale / 2)
            guard background > total / 2, red > 10, green > 3 else {
                throw SharedAreaCheckRig.Failure(description: "\(name): not drawn in the host's palette: background \(background)/\(total), red \(red), green \(green)")
            }
            print("PASS \(name): drawn in the host's palette (background \(background * 100 / max(total, 1))% of the terminal, red \(red), green \(green) samples)")
            if let caption = rep.colorAt(x: Int((view.frame.maxX - 40) * scale), y: Int((view.frame.minY + TileNSView.titleBarHeight + TileNSView.ownershipStripHeight + 10) * scale)) {
                captions.append(caption)
            }
            guard view.qaOwnershipTabText?.hasPrefix("Avery's Terminal") == true else {
                throw SharedAreaCheckRig.Failure(description: "\(name): the tab does not read \"Avery's Terminal\": \(view.qaOwnershipTabText ?? "none")")
            }
            // Read only: a click on the terminal lands on the shield, never the surface.
            let centre = mirror.convert(NSPoint(x: mirror.bounds.midX, y: mirror.bounds.midY), to: nil)
            let hit = window.contentView?.hitTest(window.contentView!.convert(centre, from: nil))
            guard hit is TerminalMirrorShield else { throw SharedAreaCheckRig.Failure(description: "\(name): a click reaches \(hit.map { "\(type(of: $0))" } ?? "nothing")") }
            print("PASS \(name): a click on the terminal reaches no terminal (read only)")
            guard let png = rep.representation(using: .png, properties: [:]) else { throw SharedAreaCheckRig.Failure(description: "no png") }
            let file = directory.appendingPathComponent("shared-terminal-\(name).png")
            try png.write(to: file)
            print("WROTE \(file.path)")
            mirror.tearDown()
            window.orderOut(nil)
            try await Task.sleep(for: .milliseconds(200))
        }
        guard captions.count == 2, let light = captions[0].usingColorSpace(.sRGB), let dark = captions[1].usingColorSpace(.sRGB),
              light.brightnessComponent > dark.brightnessComponent + 0.2 else {
            throw SharedAreaCheckRig.Failure(description: "the tile's chrome does not follow the appearance: \(captions)")
        }
        print("PASS shared terminal: the host's grid, lines and palette, in light and dark; the chrome follows the appearance")
    }
}

/// A picture of a view as drawn, Ghostty's IOSurface layers included (which
/// `cacheDisplay` cannot see).
@MainActor
enum SharedTerminalStill {
    static func bitmap(of view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return rep }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        for terminal in descendants(of: view).compactMap({ $0 as? GhosttyTerminalView }) where !terminal.isHiddenOrHasHiddenAncestor {
            guard let contents = terminal.layer?.contents, let surface = (contents as AnyObject) as? IOSurface,
                  let image = CIContext().createCGImage(CIImage(ioSurface: surface), from: CGRect(x: 0, y: 0, width: surface.width, height: surface.height))
            else { continue }
            // Where Core Animation shows the layer, which is what is on screen.
            var rect = terminal.convert(terminal.bounds, to: view)
            if let layer = terminal.layer, let root = view.layer { rect = layer.convert(layer.bounds, to: root) }
            if view.isFlipped || view.layer?.isGeometryFlipped == true { rect.origin.y = view.bounds.height - rect.maxY }
            context.cgContext.draw(image, in: rect)
        }
        return rep
    }
    static func descendants(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(of: $0) } }
}

private extension NSColor {
    convenience init(srgbHex hex: String) {
        let raw = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((raw >> 16) & 0xff) / 255, green: CGFloat((raw >> 8) & 0xff) / 255, blue: CGFloat(raw & 0xff) / 255, alpha: 1)
    }
}
