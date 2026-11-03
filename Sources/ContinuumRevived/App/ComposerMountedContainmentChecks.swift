import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

@MainActor
enum ComposerMountedContainmentChecks {
    static func run() throws -> String {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil else {
            throw AgentTileFitChecks.Failure(description: "requires isolated app support")
        }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "mounted composer containment")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let defaults = QAIsolatedDefaults(isolatedSuiteName: "array.qa.composer-containment.\(UUID())")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteDomainName) }
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        defaults.set(AgentCharacterConfig.Motion.never.rawValue, forKey: AgentCharacterConfig.motionKey)
        AgentCharacterController.shared.adopt(defaults: defaults)
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.codex)
        let tileID = UUID()
        let f = try WorkspaceAPIChecks.makeFixture(settings: defaults, beforeMount: { delegate, root in
            let project = UUID(uuidString: "00000000-0000-0000-0000-0000000CA104")!
            let zone = UUID(uuidString: "00000000-0000-0000-0000-0000000CA107")!
            let cwd = root.appendingPathComponent("Pb")
            _ = delegate.qaAgentSupervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .codex, mode: .managed,
                model: AgentCatalogQAFixture.codex.models[0], thinking: "medium", projectId: project, projectRoot: cwd, tileId: tileID)
            let store = ProjectStore(projectRoot: cwd)
            var state = try store.loadCanvas()
            var tile = Tile(id: tileID, kind: .managedAgent, title: "Mounted containment",
                frame: TileFrame(x: 3640, y: 600, width: 640, height: 520), zPosition: .fromLegacyRank(20),
                runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed"))
            tile.zoneId = zone
            state.tiles.append(tile)
            try store.saveCanvas(state)
        })
        defer { f.delegate.qaAgentSupervisor.stopAll(); f.tearDown() }
        guard let tile = f.canvas.tileView(for: tileID) as? ManagedAgentTileNSView else {
            throw AgentTileFitChecks.Failure(description: "production boot mount did not hydrate the persisted agent tile")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 5200, height: 1800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = f.canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("qa-runs/composer-mounted-containment")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var rows: [[String: Any]] = [], failures: [String] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            let tone = appearance == .aqua ? "light" : "dark"
            for size in AgentTileFitChecks.sizes {
                if let value = size.value { defaults.set(value, forKey: AgentTileFitChecks.sizeKey) }
                else { defaults.removeObject(forKey: AgentTileFitChecks.sizeKey) }
                SettingChangeEvent.post(SettingID(rawValue: AgentTileFitChecks.sizeKey))
                for width in [320.0, 420, 640, 960, 1320, 1830] {
                    var model = tile.tile
                    model.frame.width = width
                    f.canvas.updateTile(model, recalculateZoneBounds: true, notifyChange: false)
                    for textZoom in [80, 100, 110, 150] {
                        tile.setPageZoom(AgentPageZoom(percent: textZoom))
                        for zoom in AgentTileFitChecks.zooms {
                            f.canvas.setViewport(.init(x: 3600, y: 500, zoom: zoom))
                            for draft in ["", "A draft with several lines\nSecond line\nThird line"] {
                                tile.wakeChrome()
                                tile.qaSetComposerDraftForChecks(draft)
                                AgentTileFitChecks.pump(0.015)
                                f.canvas.layoutSubtreeIfNeeded()
                                tile.wakeChrome()
                                tile.layoutSubtreeIfNeeded()
                                let label = "\(tone) \(size.name) w\(Int(width)) text\(textZoom) zoom\(zoom) draft=\(!draft.isEmpty)"
                                guard tile.qaPageZoomContentRoot.isDescendant(of: tile) else {
                                    failures.append("\(label): body not live in mounted tile"); continue
                                }
                                var chromeFacts: [String: CGFloat] = [:]
                                let header = tile.qaPageZoomHeaderView
                                if let badge = header.qaManagedBadge, let scale = tile.qaUnderBarScale,
                                   let under = tile.qaUnderBarFrame, zoom <= 1 {
                                    let screenFont = badge.qaTextPointSize * scale * CGFloat(zoom)
                                    let natural = badge.qaTextPointSize * TileNSView.minScreenGrabPx / TileNSView.titleBarHeight
                                    if screenFont > natural + 0.01 {
                                        failures.append("\(label): screen role font \(screenFont) exceeds natural \(natural)")
                                    }
                                    let role = min(badge.qaTextPointSize, NSFont.token(.label).pointSize)
                                    if width >= 320 && screenFont < role - 0.01 {
                                        failures.append("\(label): screen role font \(screenFont) below readable \(role)")
                                    }
                                    if let local = header.qaManagedFrame,
                                       let pill = tile.qaUnderBarRect(local, in: header),
                                       pill.maxY > tile.qaPageZoomContentRoot.convert(tile.qaPageZoomContentRoot.bounds, to: tile).minY + 0.5 {
                                        failures.append("\(label): Managed covers mounted body")
                                    }
                                    chromeFacts = ["screenFont": screenFont, "screenRowHeight": under.height * CGFloat(zoom)]
                                }
                                let nodes = tile.qaMountedComposerContainment
                                for required in ["prompt", "send", "model"] where !nodes.contains(where: { $0.name == required }) {
                                    failures.append("\(label): missing visible \(required)")
                                }
                                var children: [[String: String]] = []
                                for node in nodes {
                                    // A half screen point (one pixel at 2x) covers layout rounding.
                                    let tolerance = 0.5 / max(0.25, zoom)
                                    let fits = !node.clip.isEmpty && node.clip.insetBy(dx: -tolerance, dy: -tolerance).contains(node.frame)
                                    if !fits { failures.append("\(label): \(node.name) frame=\(node.frame), clipped tile rect=\(node.clip)") }
                                    children.append(["name": node.name, "frame": NSStringFromRect(node.frame), "clip": NSStringFromRect(node.clip), "fits": String(fits)])
                                }
                                rows.append(["sample": label, "tile": NSStringFromRect(tile.bounds), "children": children, "chrome": chromeFacts])
                                if width == 420 && textZoom == 110 && zoom == 1 && !draft.isEmpty,
                                   let rep = tile.bitmapImageRepForCachingDisplay(in: tile.bounds) {
                                    tile.cacheDisplay(in: tile.bounds, to: rep)
                                    try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(size.name)-\(tone).png"))
                                }
                            }
                        }
                    }
                }
            }
        }
        // Sensitivity control: a frame beyond a real clip must be rejected,
        // rather than reading already-clipped geometry and passing vacuously.
        guard let send = tile.qaPageZoomActionButton else { throw AgentTileFitChecks.Failure(description: "Send absent for negative control") }
        let original = send.frame
        send.setFrameOrigin(NSPoint(x: original.minX + tile.bounds.width, y: original.minY))
        let escaped = tile.qaMountedComposerContainment.first { $0.name == "send" }
        let caught = escaped.map { !$0.clip.insetBy(dx: -0.5, dy: -0.5).contains($0.frame) } ?? false
        send.frame = original
        if !caught { failures.append("negative control: escaped Send was not detected") }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("geometry.json"))
        try failures.joined(separator: "\n").write(to: out.appendingPathComponent("failures.txt"), atomically: true, encoding: .utf8)
        guard failures.isEmpty else { throw AgentTileFitChecks.Failure(description: "\(failures.count) containment failures; first: \(failures.prefix(8).joined(separator: "\n")); full geometry: \(out.path)") }
        return "Mounted composer containment: \(rows.count) samples passed; boot hydration, all displayed descendants, Send, visible rect + clip ancestors, escaped-Send negative control; geometry: \(out.path)"
    }
}
