import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// Mode B ops for `scripts/check-multiplayer-journey.py --mode b`: the portal.
/// Each goes through the path a person takes: the Share tool's marquee dragged
/// with real mouse events, the popover's Copy clicked, a note typed into,
/// pointer moves posted to the app's own queue, and the portal's hover button
/// clicked.
extension MultiplayerDriver {
    private var canvas: CanvasNSView? { delegate?.canvasView }

    // MARK: What this person sees

    var portalRecord: Tile? { canvas?.allWorkspaceTiles().first { $0.kind == .sharedPortal } }
    var portalView: SharedPortalTileNSView? { portalRecord.flatMap { canvas?.tileView(for: $0.id) as? SharedPortalTileNSView } }
    var portalSession: SharedPortalTileSession? { portalRecord.flatMap { delegate?.sharedPortalTileSessions[$0.id] } }

    func portalReady(minimumItems: Int) -> Bool {
        guard let session = portalSession, let view = portalView, case .live = view.state else { return false }
        return session.body.items.count >= minimumItems
    }

    private func rectJSON(_ rect: SharedArea.Rect) -> [String: Double] {
        ["x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height]
    }
    private func rectJSON(_ rect: NSRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
    }

    /// The guest's portal, in one read.
    func portalSnapshot() -> [String: Any] {
        guard let delegate, let canvas, let runtime = delegate.sharedAreaRuntime else { return [:] }
        var result: [String: Any] = [:]
        let records = canvas.allWorkspaceTiles()
        result["tileKinds"] = records.map(\.kind.rawValue)
        result["portalTiles"] = records.filter { $0.kind == .sharedPortal }.map(\.id.uuidString)
        result["sharedAgentTiles"] = records.filter { $0.kind == .sharedAgent }.map(\.id.uuidString)
        result["zones"] = runtime.document.zones.map { $0.zoneId.uuidString }
        result["armedZone"] = runtime.document.lastActiveZoneId?.uuidString ?? ""
        result["agentRecords"] = delegate.agentSupervisor.records.count
        let viewport = canvas.viewport
        result["visibleWorld"] = ["x": viewport.x, "y": viewport.y,
                                  "width": Double(canvas.bounds.width) / viewport.zoom, "height": Double(canvas.bounds.height) / viewport.zoom]
        guard let record = portalRecord else { return result }
        let world = canvas.allTilesInWorldFrames().first { $0.id == record.id }?.frame
        result["portalTile"] = record.id.uuidString
        result["portalWorld"] = frameJSON(world) ?? [:]
        result["portalZone"] = record.zoneId?.uuidString ?? ""
        if let zone = record.zoneId, let placement = runtime.document.zones.first(where: { $0.zoneId == zone }) {
            result["portalZoneWorld"] = ["x": placement.origin.x, "y": placement.origin.y,
                                         "width": placement.size.width, "height": placement.size.height]
        }
        if let besides = records.first(where: { $0.kind == .sharedAgent }) {
            result["besideWorld"] = frameJSON(canvas.allTilesInWorldFrames().first { $0.id == besides.id }?.frame) ?? [:]
            result["besideZone"] = besides.zoneId?.uuidString ?? ""
        }
        guard let view = portalView else { return result }
        result["portalTab"] = view.qaOwnershipTabText ?? ""
        result["portalState"] = "\(view.state)"
        result["portalFooter"] = view.qaFooterText
        result["portalPlaceholder"] = view.qaPlaceholderText ?? ""
        result["portalOutlineDashed"] = view.ownershipMark?.dashed ?? false
        result["portalHasSession"] = view.session != nil
        guard let session = portalSession else { return result }
        let body = session.body
        let camera = body.camera
        result["camera"] = ["x": camera.x, "y": camera.y, "zoom": camera.zoom]
        result["cameraPersisted"] = record.metadata.sharedPortal?.camera.map { ["x": $0.x, "y": $0.y, "zoom": $0.zoom] } ?? [:]
        result["bodySize"] = ["width": Double(body.bounds.width), "height": Double(body.bounds.height)]
        result["manifestName"] = session.manifest?.name ?? ""
        result["follow"] = body.qaFollowTitle ?? ""
        result["following"] = body.isFollowing
        var items: [[String: Any]] = []
        for (object, entry) in session.entries.sorted(by: { $0.key.rawValue.uuidString < $1.key.rawValue.uuidString }) {
            var item: [String: Any] = ["object": object.rawValue.uuidString, "kind": entry.kind.rawValue, "title": entry.title]
            if let rect = body.rects[object] { item["area"] = rectJSON(rect) }
            if let frame = body.displayedFrame(for: object) { item["shown"] = rectJSON(frame) }
            if let view = body.item(object) {
                item["facts"] = view.qaFacts
                item["state"] = "\(view.itemState)"
                item["hover"] = view.hoverActions.map(\.title)
            }
            items.append(item)
        }
        result["items"] = items
        let me = session.controller.identity.device
        result["peers"] = session.controller.presence.filter { $0.identity.device != me }.map { peer -> [String: Any] in
            var value: [String: Any] = ["label": peer.label ?? ""]
            if let cursor = peer.cursor { value["cursor"] = ["x": cursor.x, "y": cursor.y] }
            return value
        }
        result["reads"] = session.reads
        return result
    }

    /// The sharer's portal, as this Mac hosts it and as the relay holds it.
    func hostPortalSnapshot() async -> [String: Any] {
        guard let delegate, let canvas, let runtime = delegate.sharedAreaRuntime,
              let session = delegate.hostedPortalSessions.values.first else { return ["hosting": false] }
        var result: [String: Any] = ["hosting": true, "area": session.area.uuidString, "name": session.entry.name,
                                     "zones": runtime.document.zones.map { $0.zoneId.uuidString },
                                     "published": session.publishedRevisions, "places": session.placedCommands]
        let world = Dictionary(uniqueKeysWithValues: canvas.allTilesInWorldFrames().map { ($0.id, $0.frame) })
        result["shared"] = session.entry.tiles.map { shared -> [String: Any] in
            ["tile": shared.tile.uuidString, "object": shared.object.uuidString, "kind": shared.kind.rawValue,
             "world": frameJSON(world[shared.tile]) ?? [:], "tab": canvas.tileView(for: shared.tile)?.qaOwnershipTabText ?? ""]
        }
        result["origin"] = ["x": session.entry.origin.x, "y": session.entry.origin.y]
        let me = session.controller.identity.device
        result["peers"] = session.controller.presence.filter { $0.identity.device != me }.map { peer -> [String: Any] in
            var value: [String: Any] = ["label": peer.label ?? ""]
            if let cursor = peer.cursor { value["cursor"] = ["x": cursor.x, "y": cursor.y] }
            return value
        }
        result["viewport"] = ["x": canvas.viewport.x, "y": canvas.viewport.y, "zoom": canvas.viewport.zoom,
                              "width": Double(canvas.bounds.width) / canvas.viewport.zoom, "height": Double(canvas.bounds.height) / canvas.viewport.zoom]
        // The relay's own copy, through a fresh reader.
        if let model = try? delegate.collaborationAccountModel(), let controller = try? model.makeSharedAreaController(area: session.area) {
            await controller.open()
            if let document = controller.document {
                result["areaItems"] = document.items.map { ["object": $0.id.rawValue.uuidString, "kind": $0.kind.rawValue] }
                result["positions"] = Dictionary(uniqueKeysWithValues: document.positions.map { ($0.object.rawValue.uuidString, rectJSON($0.rect)) })
                var revisions: [String: Int] = [:]
                var payloadPaths: [String: [String]] = [:]
                if let transport = controller.artifactTransport {
                    for item in document.items where item.kind == .artifact {
                        let state = try? await transport.artifactState(object: item.id.rawValue)
                        revisions[item.id.rawValue.uuidString] = state?.revisions.count ?? 0
                        payloadPaths[item.id.rawValue.uuidString] = state?.latest?.manifest.entries.map(\.path) ?? []
                    }
                }
                result["revisions"] = revisions
                result["payloadPaths"] = payloadPaths
            }
            await controller.close()
        }
        return result
    }

    // MARK: Ops

    func performPortal(_ op: String, _ request: [String: Any]) async throws -> [String: Any] {
        guard let delegate, let canvas else { throw Failure(description: "no canvas") }
        let tileArg = (request["tile"] as? String).flatMap(UUID.init(uuidString:))
        switch op {
        case "spawnPortalTiles":
            // The host's tiles for mode B: an agent, two notes, a public and a
            // localhost browser, and a terminal, in the armed zone.
            func spawned(_ make: () -> Void) throws -> UUID {
                let before = Set(canvas.allWorkspaceTiles().map(\.id))
                make()
                guard let id = canvas.allWorkspaceTiles().map(\.id).first(where: { !before.contains($0) }) else {
                    throw Failure(description: "a tile did not spawn")
                }
                return id
            }
            guard let spawner = delegate.spawnerForFilesystemCreation() else { throw Failure(description: "no spawner") }
            let agent = try spawned { _ = delegate.spawnManagedAgentForHarness(.claudeCode) }
            var notes: [UUID] = []
            for (index, text) in ((request["notes"] as? [String]) ?? ["Note one", "Note two"]).enumerated() {
                guard case .spawned(_, let tileId) = spawner.spawnNote(title: "Note \(index + 1)") else { throw Failure(description: "note did not spawn") }
                if let view = canvas.tileView(for: tileId) as? NoteTileNSView { view.textView.string = text; view.textView.didChangeText() }
                notes.append(tileId)
            }
            let publicURL = request["publicURL"] as? String ?? "https://example.com/"
            let localURL = request["localURL"] as? String ?? "http://127.0.0.1:9/"
            let publicBrowser = try spawned { _ = spawner.spawnBrowser(url: publicURL) }
            let localBrowser = try spawned { _ = spawner.spawnBrowser(url: localURL) }
            // No tmux: the parked preview app's terminal only has to exist as
            // a tile; a portal carries nothing of it.
            fputs("portal journey: spawning the terminal\n", stderr)
            let terminal = try spawned { _ = spawner.spawnTerminal(profileId: "shell", allowTmuxPersistence: false) }
            fputs("portal journey: spawned the six tiles\n", stderr)
            return ["agent": agent.uuidString, "notes": notes.map(\.uuidString), "publicBrowser": publicBrowser.uuidString,
                    "localBrowser": localBrowser.uuidString, "terminal": terminal.uuidString]

        case "spawnNote":
            guard let spawner = delegate.spawnerForFilesystemCreation(),
                  case .spawned(_, let tileId) = spawner.spawnNote(title: request["title"] as? String ?? "Late note") else {
                throw Failure(description: "note did not spawn")
            }
            return ["tile": tileId.uuidString]

        case "portalShare":
            // Step 1-2: S arms the Share tool; a marquee dragged over exactly
            // these tiles; release opens the popover; Copy.
            let ids = Set(((request["tiles"] as? [String]) ?? []).compactMap(UUID.init(uuidString:)))
            let world = canvas.allTilesInWorldFrames().filter { ids.contains($0.id) }.map(\.frame)
            guard world.count == ids.count, !ids.isEmpty else { throw Failure(description: "tiles missing") }
            let union = world.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }.reduce(CGRect.null) { $0.union($1) }
            // Everything in view at once, so the marquee is one drag.
            canvas.setViewport(CanvasViewport(x: Double(union.minX) - 60, y: Double(union.minY) - 60,
                zoom: min(1, Double(canvas.bounds.width) / Double(union.width + 160), Double(canvas.bounds.height) / Double(union.height + 160))))
            canvas.layoutSubtreeIfNeeded()
            delegate.armShareTool()
            guard let tool = delegate.qaShareToolView else { throw Failure(description: "the Share tool did not arm") }
            tool.layoutSubtreeIfNeeded()
            let viewport = canvas.viewport
            func screen(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                canvas.convert(CanvasEngine.worldToScreen(.init(x: x, y: y), viewport: viewport), to: nil)
            }
            let start = screen(union.minX - 20, union.minY - 20), end = screen(union.maxX + 20, union.maxY + 20)
            NSApp.sendEvent(try ShareEntryChecks.mouse(.leftMouseDown, start, in: window))
            NSApp.sendEvent(try ShareEntryChecks.mouse(.leftMouseDragged, NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), in: window))
            NSApp.sendEvent(try ShareEntryChecks.mouse(.leftMouseDragged, end, in: window))
            NSApp.sendEvent(try ShareEntryChecks.mouse(.leftMouseUp, end, in: window))
            try await eventually("the area popover") { delegate.shareEntry.isPresented }
            guard let popover = delegate.shareEntry.presentedView else { throw Failure(description: "no popover") }
            popover.layoutSubtreeIfNeeded()
            let rows = popover.qaItemRows, title = popover.titleLabelText
            let target = popover.session.target.tileIDs.map(\.uuidString)
            let worldBefore = canvas.allTilesInWorldFrames().map { [$0.id.uuidString: frameJSON($0.frame) ?? [:]] }
            if request["copy"] as? Bool ?? true {
                if let slug = request["slug"] as? String { popover.slugField.stringValue = slug; popover.session.setSlug(slug) }
                try ShareEntryChecks.click(popover.copyButton)
                let session = popover.session
                try await eventually("Copy finished", timeout: 90) { !session.isWorking && (session.link != nil || session.failure != nil) }
                guard let link = session.link else { throw Failure(description: "share failed: \(session.failure ?? "no link")") }
                shareSession = session
                delegate.shareEntry.dismiss()
                // The host publishes the manifest and content once it starts.
                try await eventually("the portal host started", timeout: 30) {
                    delegate.hostedPortalSessions.values.first.map { $0.publishedRevisions > 0 } ?? false
                }
                return ["rows": rows, "title": title, "target": target, "url": link.url.absoluteString,
                        "pasteboard": pasteboard.string(forType: .string) ?? "", "worldBefore": worldBefore]
            }
            return ["rows": rows, "title": title, "target": target]

        case "hostPortal":
            return await hostPortalSnapshot()

        case "portal":
            return portalSnapshot()

        case "moveTile":
            // A tile moved on the host's canvas, committed as a drag commits it.
            guard let tile = tileArg, var record = canvas.tileRecord(for: tile) else { throw Failure(description: "missing tile") }
            record.frame.x += request["dx"] as? Double ?? 0
            record.frame.y += request["dy"] as? Double ?? 0
            canvas.updateTile(record)
            return ["world": frameJSON(canvas.worldFrame(forTileFrame: record.frame, tileId: tile)) ?? [:]]

        case "moveTileTo":
            // Puts a tile at a world point (its top-left), for "drag a private
            // tile into the shared region".
            guard let tile = tileArg, var record = canvas.tileRecord(for: tile) else { throw Failure(description: "missing tile") }
            let world = canvas.worldFrame(forTileFrame: record.frame, tileId: tile)
            record.frame.x += (request["x"] as? Double ?? world.x) - world.x
            record.frame.y += (request["y"] as? Double ?? world.y) - world.y
            canvas.updateTile(record)
            let pill = canvas.tileView(for: tile)?.subviews.compactMap { $0 as? SharedPortalAddPill }.first
            return ["world": frameJSON(canvas.worldFrame(forTileFrame: record.frame, tileId: tile)) ?? [:], "addPill": pill?.title ?? ""]

        case "addToShare":
            // The pill's press: the explicit "Add to share".
            guard let tile = tileArg else { throw Failure(description: "missing tile") }
            guard let pill = canvas.tileView(for: tile)?.subviews.compactMap({ $0 as? SharedPortalAddPill }).first else {
                throw Failure(description: "no Add to share on the tile")
            }
            try ShareEntryChecks.click(pill)
            try await eventually("the tile joined the portal", timeout: 60) { delegate.hostedPortalArea(forTile: tile) != nil }
            return [:]

        case "editNote":
            guard let tile = tileArg, let view = canvas.tileView(for: tile) as? NoteTileNSView else { throw Failure(description: "no note") }
            view.textView.string = request["text"] as? String ?? ""
            view.textView.didChangeText()
            return [:]

        case "hostHover":
            // The sharer's pointer over a shared tile, as mouse-moved events
            // the presence publisher's monitor reads.
            guard let tile = tileArg, let world = canvas.allTilesInWorldFrames().first(where: { $0.id == tile })?.frame,
                  let session = delegate.hostedPortalSessions.values.first else { throw Failure(description: "missing tile") }
            canvas.centerOnTile(tile)
            for _ in 0..<150 where canvas.isCameraInMotion { try await Task.sleep(for: .milliseconds(16)) }
            let fx = request["fx"] as? Double ?? 0.5, fy = request["fy"] as? Double ?? 0.5
            let point = CGPoint(x: world.x + world.width * fx, y: world.y + world.height * fy)
            var area = CGPoint.zero
            for step in 0..<12 {
                let p = CGPoint(x: point.x + Double(step), y: point.y)
                let location = canvas.convert(CanvasEngine.worldToScreen(p, viewport: canvas.viewport), to: nil)
                try post(.mouseMoved, at: location)
                area = CGPoint(x: Double(p.x) - session.entry.origin.x, y: Double(p.y) - session.entry.origin.y)
                try await Task.sleep(for: .milliseconds(30))
            }
            return ["area": ["x": Double(area.x), "y": Double(area.y)]]

        case "portalHover":
            // The guest's pointer over an item inside the portal.
            guard let session = portalSession, let object = objectArg(request, session) else { throw Failure(description: "no portal item") }
            canvas.centerOnTile(session.tileId)
            for _ in 0..<150 where canvas.isCameraInMotion { try await Task.sleep(for: .milliseconds(16)) }
            canvas.layoutSubtreeIfNeeded()
            let body = session.body
            guard let frame = body.displayedFrame(for: object) else { throw Failure(description: "item not shown") }
            let fx = request["fx"] as? Double ?? 0.5, fy = request["fy"] as? Double ?? 0.5
            var area = CGPoint.zero
            for step in 0..<12 {
                let local = NSPoint(x: frame.minX + frame.width * fx + CGFloat(step), y: frame.minY + frame.height * fy)
                try post(.mouseMoved, at: body.convert(local, to: nil))
                body.hover(at: local)
                area = body.areaPoint(forScreenPoint: local)
                try await Task.sleep(for: .milliseconds(30))
            }
            return ["area": ["x": Double(area.x), "y": Double(area.y)], "hover": body.qaHoverActionTitles]

        case "openBeside":
            // Step 7: hover the agent, click "Open beside".
            guard let session = portalSession, let object = objectArg(request, session) else { throw Failure(description: "no portal agent") }
            canvas.centerOnTile(session.tileId)
            for _ in 0..<150 where canvas.isCameraInMotion { try await Task.sleep(for: .milliseconds(16)) }
            canvas.layoutSubtreeIfNeeded()
            let body = session.body
            guard let frame = body.displayedFrame(for: object) else { throw Failure(description: "item not shown") }
            body.hover(at: NSPoint(x: frame.midX, y: frame.midY))
            guard let button = body.subviews.compactMap({ $0 as? ComposerActionButton }).first(where: { !$0.isHidden && $0.presentation.title == "Open beside" }) else {
                throw Failure(description: "no Open beside on hover: \(body.qaHoverActionTitles)")
            }
            let before = Set(canvas.allWorkspaceTiles().filter { $0.kind == .sharedAgent }.map(\.id))
            try ShareEntryChecks.click(button)
            try await eventually("the agent opened beside the portal", timeout: 30) {
                canvas.allWorkspaceTiles().contains { $0.kind == .sharedAgent && !before.contains($0.id) }
            }
            return ["tile": canvas.allWorkspaceTiles().first { $0.kind == .sharedAgent && !before.contains($0.id) }?.id.uuidString ?? ""]

        case "portalPan":
            guard let body = portalSession?.body else { throw Failure(description: "no portal") }
            if let factor = request["zoom"] as? Double { body.zoom(by: factor, around: NSPoint(x: body.bounds.midX, y: body.bounds.midY)) }
            body.pan(dx: request["dx"] as? Double ?? 0, dy: request["dy"] as? Double ?? 0)
            return ["camera": ["x": body.camera.x, "y": body.camera.y, "zoom": body.camera.zoom]]

        case "portalFollow":
            guard let body = portalSession?.body else { throw Failure(description: "no portal") }
            try await eventually("Follow is offered", timeout: 30) { body.qaFollowTitle?.hasPrefix("Follow") == true }
            guard let button = body.subviews.compactMap({ $0 as? ComposerActionButton }).first(where: { !$0.isHidden && $0.presentation.title.hasPrefix("Follow") }) else {
                throw Failure(description: "no Follow button")
            }
            try ShareEntryChecks.click(button)
            try await eventually("following", timeout: 10) { body.isFollowing }
            return ["camera": ["x": body.camera.x, "y": body.camera.y, "zoom": body.camera.zoom]]

        case "hostCamera":
            // The sharer's camera, for following: pans to a world rect.
            guard let x = request["x"] as? Double, let y = request["y"] as? Double else { throw Failure(description: "missing point") }
            canvas.setViewport(CanvasViewport(x: x, y: y, zoom: request["zoom"] as? Double ?? canvas.viewport.zoom))
            delegate.portalCameraApplied(user: true)
            // Publish the new view the way a pointer move does.
            let location = canvas.convert(NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil)
            try post(.mouseMoved, at: location)
            return [:]

        case "portalAccess":
            // Step 9: the popover, from Share on a shared tile.
            guard let tile = tileArg else { throw Failure(description: "missing tile") }
            let popover = try await Self.openHeaderShare(tile: tile, delegate: delegate)
            try await eventually("the popover lists someone", timeout: 30) {
                popover.layoutSubtreeIfNeeded(); return !popover.qaPeopleRows.isEmpty
            }
            return ["rows": popover.qaPeopleRows, "removeButtons": popover.removeButtons.count, "title": popover.titleLabelText,
                    "area": popover.session.area?.uuidString ?? ""]

        default:
            throw Failure(description: "unknown op \(op)")
        }
    }

    private func objectArg(_ request: [String: Any], _ session: SharedPortalTileSession) -> SharedArea.ID<SharedArea.Object>? {
        if let raw = request["object"] as? String, let id = UUID(uuidString: raw) { return .init(id) }
        if let kind = request["kind"] as? String {
            return session.entries.first { $0.value.kind.rawValue == kind }?.key
        }
        return nil
    }

    private func post(_ type: NSEvent.EventType, at location: NSPoint) throws {
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0) else { throw Failure(description: "no mouse event") }
        NSApp.postEvent(event, atStart: false)
    }
}
