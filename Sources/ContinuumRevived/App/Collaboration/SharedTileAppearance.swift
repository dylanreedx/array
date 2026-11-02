import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// `--shared-tile-render-check <dir>` (`.plans/105-collaboration/SHARE-KINDS.md`):
/// a teammate's shared note, file, diff, browser and terminal as the guest sees
/// them, then one stopped and one placeholder, in light and dark, off screen.
/// Fails when a body shows nothing or a tab does not name its owner.
@MainActor
enum SharedTileAppearance {
    static let size = NSSize(width: 1900, height: 1060)

    private final class Canvas: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { SurfaceToken.canvas.color.nsColor(in: self).setFill(); bounds.fill() }
    }

    static func page() -> Data {
        let image = NSImage(size: NSSize(width: 800, height: 520), flipped: true) { rect in
            NSColor.white.setFill(); rect.fill()
            NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.97, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 800, height: 64).fill()
            ("localhost:3000 · Checkout" as NSString).draw(at: NSPoint(x: 24, y: 22),
                withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.black])
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: NSRect(x: 40, y: 120, width: 220, height: 64), xRadius: 10, yRadius: 10).fill()
            ("Pay now" as NSString).draw(at: NSPoint(x: 104, y: 140),
                withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .medium), .foregroundColor: NSColor.white])
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return Data() }
        return jpeg
    }

    static func surface() -> (NSView, [SharedTileNSView]) {
        let canvas = Canvas(frame: NSRect(origin: .zero, size: size))
        canvas.wantsLayer = true
        let host = SharedArea.ID<SharedArea.Person>()
        let colour = SharedAreaPersonColour.color(for: host, host: host)
        var replica = Collaboration.NoteText.Replica(replica: "render")
        _ = replica.edit(to: "Checkout plan\n\n- Wallets get their own path\n- Declined goes back to Payment\n\nSam: add Apple Pay first")
        let generation = UUID()
        let payloads: [(Collaboration.LiveTile.Kind, Collaboration.LiveTile.Payload?, SharedAgentTileNSView.State)] = [
            (.note, .note(.init(title: "Checkout plan", snapshot: replica.snapshot, eventsThrough: 0)), .live),
            (.file, .file(.init(name: "CheckoutState.swift", language: "swift",
                                text: "enum CheckoutState {\n    case cart, address, payment\n    case wallet\n    case authorising, paid\n    case declined, abandoned\n}\n",
                                digest: "x", byteCount: 118, notice: nil)), .live),
            (.diff, .diff(.init(title: "Changes", diff: "diff --git a/CheckoutState.swift b/CheckoutState.swift\n@@ -2,4 +2,5 @@\n     case cart, address, payment\n+    case wallet\n     case authorising, paid\n-    case failed\n+    case declined, abandoned\n",
                                digest: "y", files: 1, truncated: false)), .live),
            (.browser, .browser(.init(url: "http://localhost:3000/checkout", title: "Checkout", reach: .private,
                                      frame: .init(jpeg: page(), width: 800, height: 520, sequence: 1))), .live),
            (.terminal, .terminal(.init(title: "zsh", text: "$ swift test\nBuilding for debugging...\nTest Suite 'All tests' passed\n     Executed 42 tests, with 0 failures\n$ ",
                                        columns: 40, rows: 5)), .live),
            (.note, .note(.init(title: "Checkout plan", snapshot: replica.snapshot, eventsThrough: 0)), .stopped("Dylan stopped sharing")),
            (.browser, nil, .placeholder("Shared by Dylan · sign in to see it")),
        ]
        var tiles: [SharedTileNSView] = []
        for (index, entry) in payloads.enumerated() {
            let reference = SharedAgentTileReference(areaId: UUID(), objectId: UUID(), hostName: "Dylan", hostPerson: host.rawValue,
                                                     liveKind: entry.0.rawValue)
            let tile = Tile(id: UUID(), kind: .sharedTile, title: "Shared \(LiveTileBodyView.noun(entry.0))",
                            frame: .init(x: 0, y: 0, width: 440, height: 460), zPosition: .fromLegacyRank(1), runtimeRef: nil,
                            metadata: .init(sharedTile: reference))
            let view = SharedTileNSView(tile: tile)
            let column = index % 4, row = index / 4
            view.frame = NSRect(x: 20 + CGFloat(column) * 470, y: 30 + CGFloat(row) * 510, width: 440, height: 460)
            if let payload = entry.1 { view.body?.show(.init(generation: generation, revision: 1, payload: payload)) }
            view.apply(entry.2, hostName: "Dylan", colour: colour)
            canvas.addSubview(view)
            tiles.append(view)
        }
        return (canvas, tiles)
    }

    static func render(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var backgrounds: [NSColor] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let (view, tiles) = surface()
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            window.orderFrontOffscreenForChecks()
            try await Task.sleep(for: .milliseconds(300))
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            for tile in tiles {
                let body = tile.body
                let named = tile.qaOwnershipTabText?.contains("Dylan's \(tile.ownedNoun)") == true
                let shows = tile.qaPlaceholderText != nil || (body?.qaCaption.isEmpty == false
                    && (tile.liveKind == .browser ? body?.qaFrameSequence == 1 : body?.qaText.isEmpty == false))
                guard named, shows else {
                    throw SharedAreaCheckRig.Failure(description: "\(tile.liveKind?.rawValue ?? "?") shows nothing or no owner: tab \(tile.qaOwnershipTabText ?? "none")")
                }
            }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SharedAreaCheckRig.Failure(description: "no bitmap") }
            view.cacheDisplay(in: view.bounds, to: rep)
            // Inside the note body, under its caption: the tile surface itself.
            if let colour = rep.colorAt(x: 60, y: 300) { backgrounds.append(colour) }
            guard let png = rep.representation(using: .png, properties: [:]) else { throw SharedAreaCheckRig.Failure(description: "no png") }
            let name = "shared-tiles-\(appearance == .aqua ? "light" : "dark").png"
            try png.write(to: directory.appendingPathComponent(name))
            print("WROTE \(directory.appendingPathComponent(name).path)")
            window.orderOut(nil)
        }
        guard backgrounds.count == 2, let light = backgrounds.first?.usingColorSpace(.sRGB), let dark = backgrounds.last?.usingColorSpace(.sRGB),
              light.brightnessComponent > dark.brightnessComponent + 0.2 else {
            throw SharedAreaCheckRig.Failure(description: "the shared tiles do not follow the appearance: \(backgrounds)")
        }
        print("PASS shared tiles: every kind shows its content and names its owner, in light and dark")
    }
}
