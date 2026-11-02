import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

// `scripts/check-multiplayer-journey.py --mode terminal`
// (`.plans/114-terminal-sharing/README.md`): what a shared terminal shows the
// guest, and how late. Every time is this Mac's wall clock, which both apps
// share, so a host's `sentAt` and a guest's `seenAt` subtract directly.
extension MultiplayerDriver {
    func performTerminal(_ op: String, _ request: [String: Any]) async throws -> [String: Any]? {
        switch op {
        case "termSend":
            // Typed into the host's terminal the way the composer types: the
            // text, then Return. `sentAt` is taken just before the keystrokes.
            guard let tile = (request["tile"] as? String).flatMap(UUID.init(uuidString:)),
                  let view = delegate?.canvasView?.tileView(for: tile) as? TerminalTileNSView else { throw Failure(description: "no host terminal") }
            let sentAt = Date().timeIntervalSince1970
            _ = view.runtime.sendInsertedText(request["text"] as? String ?? "")
            if request["return"] as? Bool != false { view.runtime.sendReturn() }
            return ["sentAt": sentAt]

        case "termHost":
            guard let tile = (request["tile"] as? String).flatMap(UUID.init(uuidString:)),
                  let view = delegate?.canvasView?.tileView(for: tile) as? TerminalTileNSView else { throw Failure(description: "no host terminal") }
            var result: [String: Any] = ["text": view.runtime.visibleText(), "tab": view.qaOwnershipTabText ?? ""]
            if let theme = (view.runtime as? GhosttyTerminalRuntime)?.resolvedThemeSnapshot {
                result["palette"] = Array(theme.paletteHex.prefix(16)); result["background"] = theme.backgroundHex ?? ""
            }
            if let badge = view.subviews.compactMap({ $0 as? SharedTerminalLiveBadge }).first {
                result["badge"] = SharedTerminalLiveBadge.text
                result["stopControl"] = badge.stopButton.superview === badge && !badge.stopButton.isHidden
            }
            if let host = delegate?.sharedAreaHostSessions.values.compactMap({ $0.liveTileHosts.values.first { $0.binding.tileID == tile } }).first {
                result["published"] = host.publishedCount
                result["hostError"] = host.lastError ?? ""
                result.merge(terminalHostFacts(host.source)) { _, new in new }
            }
            if let path = request["still"] as? String { result["still"] = try writeStill(of: view, to: path) }
            return result

        case "termStopSharing":
            // The badge's Stop sharing, pressed where a person presses it.
            guard let tile = (request["tile"] as? String).flatMap(UUID.init(uuidString:)),
                  let view = delegate?.canvasView?.tileView(for: tile),
                  let badge = view.subviews.compactMap({ $0 as? SharedTerminalLiveBadge }).first else { throw Failure(description: "no Live badge") }
            try ShareEntryChecks.click(badge.stopButton)
            try await eventually("the share stops", timeout: 20) { view.subviews.compactMap({ $0 as? SharedTerminalLiveBadge }).isEmpty }
            return [:]

        case "termWatch":
            // Polls the guest's screen every 2 ms until `marker` shows, so the
            // arrival is timed to the frame it was drawn in, not the script's poll.
            let marker = request["marker"] as? String ?? ""
            let deadline = Date().addingTimeInterval(request["timeout"] as? Double ?? 30)
            while Date() < deadline {
                if let view = guestTerminalTile(), guestScreenText(view).contains(marker) {
                    return ["seenAt": Date().timeIntervalSince1970, "text": guestScreenText(view)]
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            return ["seenAt": NSNull(), "text": guestTerminalTile().map(guestScreenText) ?? ""]

        case "termRecord":
            // How often the guest's picture of the terminal changed: every
            // update applied, sampled every 2 ms for `seconds`.
            // With `marker`, also when it first showed (the driver answers one
            // request at a time, so a separate watch would wait for this one),
            // and the recording ends half a second after it.
            let seconds = request["seconds"] as? Double ?? 3
            let marker = request["marker"] as? String
            var deadline = Date().addingTimeInterval(seconds)
            var changes: [Double] = []
            var seenAt: Double?
            var last = guestTerminalTile().map(guestUpdateCount) ?? 0
            while Date() < deadline {
                try await Task.sleep(for: .milliseconds(2))
                guard let view = guestTerminalTile() else { continue }
                let now = guestUpdateCount(view)
                if now != last { changes.append(Date().timeIntervalSince1970); last = now }
                if seenAt == nil, let marker, guestScreenText(view).contains(marker) {
                    seenAt = Date().timeIntervalSince1970
                    deadline = min(deadline, Date().addingTimeInterval(0.5))
                }
            }
            return ["changes": changes, "seenAt": seenAt ?? NSNull(), "text": guestTerminalTile().map(guestScreenText) ?? ""]

        case "termGuest":
            guard let view = guestTerminalTile() else { return ["present": false] }
            var result: [String: Any] = ["present": true, "text": guestScreenText(view), "tab": view.qaOwnershipTabText ?? "",
                                         "title": view.tile.title, "caption": view.body?.qaCaption ?? ""]
            result.merge(guestTerminalFacts(view)) { _, new in new }
            if request["scrollback"] as? Bool == true { result["scrollback"] = view.body?.qaTerminalMirror?.qaScrollbackText ?? "" }
            if let path = request["still"] as? String { result["still"] = try writeStill(of: view, to: path) }
            if let colours = request["colours"] as? [String], let path = result["still"] as? [String: Any], let file = path["path"] as? String {
                result["colourPixels"] = Self.countPixels(png: file, near: colours)
            }
            return result

        default:
            return nil
        }
    }

    /// The newest `.sharedTile` terminal on this canvas.
    func guestTerminalTile() -> SharedTileNSView? {
        guard let canvas = delegate?.canvasView else { return nil }
        let records = canvas.allWorkspaceTiles().filter { $0.kind == .sharedTile && $0.metadata.sharedTile?.liveKind == "terminal" }
        return records.max { $0.zPosition < $1.zPosition }.flatMap { canvas.tileView(for: $0.id) as? SharedTileNSView }
    }

    /// What the guest's terminal shows as text.
    /// The mirror's screen when the host streams; the text view's otherwise.
    func guestScreenText(_ view: SharedTileNSView) -> String {
        view.body?.qaTerminalMirror?.qaScreenRows ?? view.body?.qaText ?? ""
    }
    /// Increments every time the guest's terminal picture changed.
    func guestUpdateCount(_ view: SharedTileNSView) -> UInt64 {
        view.body?.qaTerminalMirror?.updates ?? view.body?.state?.revision ?? 0
    }
    func guestTerminalFacts(_ view: SharedTileNSView) -> [String: Any] {
        var facts: [String: Any] = ["revision": Int(view.body?.state?.revision ?? 0), "mirror": view.body?.qaTerminalMirror != nil]
        if let mirror = view.body?.qaTerminalMirror {
            let delays = mirror.recentDelays.sorted()
            facts.merge(["grid": mirror.qaGrid.map { "\($0.columns)x\($0.rows)" } ?? "", "hostGrid": "\(mirror.columns)x\(mirror.rows)",
                         "lane": mirror.laneState, "laneFrames": mirror.laneFrames, "resets": mirror.resets, "framesApplied": mirror.framesApplied,
                         "bytesApplied": mirror.bytesApplied, "gaps": mirror.qaGaps, "sequence": Int(mirror.qaFollowerSequence),
                         "delayMedianMs": delays.isEmpty ? -1 : delays[delays.count / 2], "log": mirror.log]) { _, new in new }
        }
        return facts
    }
    func terminalHostFacts(_ source: LiveTileSource) -> [String: Any] { (source as? TerminalLiveSource)?.facts ?? [:] }

    /// A PNG of `view` as drawn, Ghostty's IOSurface layers included (which
    /// `cacheDisplay` cannot see).
    func writeStill(of view: NSView, to path: String) throws -> [String: Any] {
        guard let rep = SharedTerminalStill.bitmap(of: view) else { throw Failure(description: "no bitmap") }
        let terminals = SharedTerminalStill.descendants(of: view).filter { $0 is GhosttyTerminalView }.count
        guard let data = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "no png") }
        try data.write(to: URL(fileURLWithPath: path))
        return ["path": path, "width": rep.pixelsWide, "height": rep.pixelsHigh, "terminalLayers": terminals]
    }

    /// Pixels within a small distance of each `#rrggbb`, in a PNG.
    static func countPixels(png path: String, near colours: [String]) -> [String: Int] {
        guard let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [:] }
        let targets = colours.compactMap { hex -> (String, Int, Int, Int)? in
            let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard value.count == 6, let raw = Int(value, radix: 16) else { return nil }
            return (hex, (raw >> 16) & 0xff, (raw >> 8) & 0xff, raw & 0xff)
        }
        var counts = Dictionary(uniqueKeysWithValues: targets.map { ($0.0, 0) })
        let bpp = cg.bitsPerPixel / 8, row = cg.bytesPerRow
        let bgr = cg.bitmapInfo.contains(.byteOrder32Little)
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let p = bytes + y * row + x * bpp
                let (r, g, b) = bgr ? (Int(p[2]), Int(p[1]), Int(p[0])) : (Int(p[0]), Int(p[1]), Int(p[2]))
                for target in targets where abs(r - target.1) + abs(g - target.2) + abs(b - target.3) <= 24 { counts[target.0, default: 0] += 1 }
            }
        }
        return counts
    }
}
