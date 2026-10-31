import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

@MainActor
enum SharedAreaCaptureChecks {
    private struct Failure: Error { let message: String }
    private static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure(message: label) }
        print("PASS collaboration capture: \(label)")
    }
    private static func eventually(_ label: String, _ value: () async -> Bool) async throws {
        for _ in 0..<300 { if await value() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw Failure(message: "timeout: \(label)")
    }
    private static func click(_ label: String, in view: SharedAreaCaptureView) throws {
        guard let control = view.subviews.compactMap({ $0 as? NSControl }).first(where: { $0.accessibilityLabel() == label }),
              control.isEnabled, control.sendAction(control.action, to: control.target) else {
            throw Failure(message: "enabled native review action missing: \(label)")
        }
    }
    private static func choose(_ mode: String, title: String, in view: SharedAreaCaptureView) throws {
        guard let source = view.sourceChoice.items.first(where: { $0.title.contains(title) }) else { throw Failure(message: "missing review source: \(title)") }
        view.sourceChoice.handleSelection(source)
        guard let item = view.modeChoice.items.first(where: { $0.id == mode && $0.enabled }), view.modeChoice.isEnabled else {
            throw Failure(message: "sharing mode unavailable: \(mode)")
        }
        view.modeChoice.handleSelection(item)
    }

    static func run() async throws {
        guard let parent = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else { throw Failure(message: "isolated app support required") }
        let root = URL(fileURLWithPath: parent).appendingPathComponent("capture-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try runSelectionGesture(root: root)
        try runBoundedReview(root: root.appendingPathComponent("bounded-review"))
        try await runRootWorkflow(root: root.appendingPathComponent("root-workflow"))
        let fixture = Fixture()
        let authority = Authority(identity: fixture.identity)
        let pair = try model(root: root, fixture: fixture, authority: authority)
        let model = pair.controller
        await model.open()
        defer { Task { await model.close() } }
        var current = fixture.snapshot()
        var reads = 0
        let coordinator = try SharedAreaCaptureCoordinator(selection: .workspace, controller: model,
            person: fixture.identity.person, host: fixture.host, inventoryProvider: { reads += 1; return current },
            submitter: { await model.submitPublication($0) })
        let view = SharedAreaCaptureView(coordinator: coordinator)
        defer { view.stop() }
        try expect(coordinator.readyCount == 0 && coordinator.pendingCount == 2 && coordinator.excludedCount == 1
            && !coordinator.canConfirm && reads == 1, "opening native review opts in no content and explicitly excludes unsupported tiles")
        try choose("agreement", title: "Planning note", in: view)
        try choose("agent", title: "Owned agent", in: view)
        try expect(coordinator.canConfirm && coordinator.readyCount == 2 && coordinator.pendingCount == 0,
            "explicit native choices include captured note content and a host-owned observation")
        current = fixture.snapshot(text: "Changed after the user reviewed it", generation: "changed")
        try click("Share selection", in: view)
        try await eventually("fresh-source refusal") { coordinator.requiresRefresh }
        try expect(await authority.callCount == 0 && reads == 2,
            "native Confirm rereads current owners and refuses changed text before sending")
        try click("Refresh review", in: view)
        try expect(!coordinator.requiresRefresh && coordinator.review.rows.first(where: { $0.tileKind == .note })?.previewText == "Changed after the user reviewed it",
            "Refresh replaces stale review content before another explicit confirmation")
        await authority.loseNextReply()
        try click("Share selection", in: view)
        try await eventually("unknown publication delivery") { coordinator.state == .uncertain }
        let pending = coordinator.pendingPublication
        let operation = pending?.command.id
        let unknownCalls = await authority.callCount
        try expect(operation != nil && coordinator.canClose && unknownCalls == 1,
            "lost publication reply is durably retained so its review can close without losing recovery")
        try expect(try pair.cache.load()?.sourceBindings.count == 1,
            "private source binding is durable before unknown publication delivery")
        let beforeRetryReads = reads
        await model.close()
        try click("Check delivery", in: view)
        try await eventually("duplicate receipt recovery") { coordinator.state == .published }
        let operations = await authority.operations
        try expect(operations.count == 1 && operations.first == operation
            && reads == beforeRetryReads && model.document?.items.count == 2
            && model.deliveryRecord(for: operation!)?.state == .accepted(1),
            "reopening verifies the durable receipt without recapture, duplicate transport or reallocation")
        let saved = try pair.cache.load()
        guard let binding = saved?.sourceBindings.first else { throw Failure(message: "missing saved source binding") }
        try expect(saved?.resolution(for: binding.object) == .localReference(binding),
            "accepted native publication resolves only through its saved local owner binding")

        // A separate review holds a fixed source owner even if the surrounding
        // app switches workspaces before the user clicks Refresh.
        var alternate = fixture.snapshot()
        let fixed = try SharedAreaCaptureCoordinator(selection: .workspace, controller: model,
            person: fixture.identity.person, host: fixture.host, inventoryProvider: { alternate },
            submitter: { _ in throwawaySubmission() })
        alternate = fixture.snapshot(workspace: UUID())
        do { try fixed.refreshReview(); throw Failure(message: "review followed another workspace") }
        catch SharedAreaCaptureCoordinator.Failure.sourceWorkspaceChanged { print("PASS collaboration capture: review remains bound to its original source workspace") }
        fixed.cancel()
        let finalCalls = await authority.callCount
        try expect(fixed.state == .cancelled && finalCalls == 1,
            "cancelled review submits no publication")

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = try makeAppearanceFixture()
            let probe = try UIProbe.render(.init(id: "collaboration.capture.\(appearance.rawValue)", size: .init(width: 780, height: 800), appearance: appearance), make: { host })
            try expect(probe.view.effectiveAppearance.tokenTheme == (appearance == .aqua ? .light : .dark), "capture review renders in \(appearance.rawValue)")
            if let destination = ProcessInfo.processInfo.environment["CONTINUUM_COLLABORATION_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: destination)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard let png = probe.hostRep.representation(using: .png, properties: [:]) else { throw Failure(message: "capture PNG encoding failed") }
                try png.write(to: directory.appendingPathComponent("capture-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
        await model.close()
        print("Collaboration capture checks passed: native choices/confirmation, current owner read, immutable source workspace and exact uncertain receipt recovery. Scripted authority; no provider or Keychain calls.")
    }

    private static func runSelectionGesture(root: URL) throws {
        let viewport = CanvasViewport(x: -840, y: 260, zoom: 0.5)
        let fixture = Fixture()
        var enclosed = fixture.note.tile, intersecting = fixture.agent.tile
        enclosed.frame = .init(x: -600, y: 400, width: 200, height: 200)
        intersecting.frame = .init(x: -200, y: 400, width: 300, height: 300)
        let original = CanvasState(viewport: viewport, tiles: [enclosed, intersecting], groups: [], lastActiveTileId: fixture.note.tile.id)
        let source = ProjectStore(projectRoot: root.appendingPathComponent("gesture-source"))
        try source.saveCanvas(original)
        let originalBytes = try Data(contentsOf: source.layout.canvasFile)
        let canvas = CanvasNSView(canvasState: original)
        let window = CollaborationWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.close() }
        let overlay = SharedAreaCaptureSelectionView(canvas: canvas)
        canvas.addSubview(overlay); canvas.layoutSubtreeIfNeeded()
        var completed: [SharedArea.Rect] = [], cancellations = 0
        overlay.onComplete = { completed.append($0) }
        overlay.onCancel = { cancellations += 1 }
        func event(_ kind: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            guard let value = NSEvent.mouseEvent(with: kind, location: overlay.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else { throw Failure(message: "capture pointer event unavailable") }
            return value
        }
        // Reverse-direction drag must normalize screen coordinates once into
        // WORLD coordinates. A partial overlap is excluded by Selection.enclosed.
        overlay.mouseDown(with: try event(.leftMouseDown, .init(x: 360, y: 300)))
        overlay.mouseDragged(with: try event(.leftMouseDragged, .init(x: 80, y: 60)))
        overlay.mouseUp(with: try event(.leftMouseUp, .init(x: 80, y: 60)))
        try expect(completed == [.init(x: -680, y: 380, width: 560, height: 480)],
            "actual capture drag normalizes a reversed rectangle through the source camera exactly once")
        let selected = try SharedAreaPublication.prepare(inventory: .init(workspaceID: fixture.workspace, coverage: .completeWorkspace, sources: [
            .init(projectID: fixture.note.projectID, tile: enclosed, contentRevision: "captured"),
            .init(projectID: fixture.agent.projectID, tile: intersecting, agentID: fixture.agent.agentID)
        ]), selection: .enclosed(completed[0]), choices: [], area: .init(), author: fixture.identity.person,
            host: fixture.host, expectedRevision: 0)
        try expect(selected.rows.map(\.source.tileID) == [enclosed.id],
            "dragged capture includes the enclosed WORLD model and excludes a partial overlap")
        let count = completed.count
        overlay.mouseDown(with: try event(.leftMouseDown, .init(x: 60, y: 80)))
        overlay.mouseUp(with: try event(.leftMouseUp, .init(x: 62, y: 82)))
        try expect(completed.count == count, "a click-sized gesture does not publish or create a review")
        overlay.mouseDown(with: try event(.leftMouseDown, .init(x: 60, y: 80)))
        canvas.setViewport(.init(x: viewport.x + 30, y: viewport.y, zoom: viewport.zoom))
        overlay.mouseUp(with: try event(.leftMouseUp, .init(x: 300, y: 280)))
        try expect(completed.count == count, "camera movement during capture refuses a stale screen-space selection")
        canvas.setViewport(viewport)
        guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else {
            throw Failure(message: "capture escape unavailable")
        }
        overlay.keyDown(with: escape)
        try expect(cancellations == 1 && completed.count == count && canvas.canvasState == original
            && (try Data(contentsOf: source.layout.canvasFile)) == originalBytes,
            "Escape cancels capture without moving tiles, changing source membership or saving source files")
    }

    private final class SourceWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
    /// Counts retained controls/content readers rather than asserting a runtime
    /// duration. This exercises pagination, not the maximum source inventory or
    /// private fingerprint cost; those still require scale/real-workspace QA.
    private static func runBoundedReview(root: URL) throws {
        let fixture = Fixture(), authority = Authority(identity: fixture.identity)
        let pair = try model(root: root, fixture: fixture, authority: authority)
        let text = (0..<1_000).map { "Line \($0): Preserve this complete captured agreement." }.joined(separator: "\n")
        try expect(text.utf8.count < 65_536, "long review fixture stays within the admitted note-content budget")
        func coordinator(sourceCount: Int) throws -> SharedAreaCaptureCoordinator {
            var sources = [fixture.note]
            for index in 1..<sourceCount {
                let tileID = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 10))!
                let tile = Tile(id: tileID, kind: .terminal, title: "Private terminal \(index)",
                    frame: .init(x: Double(index % 12) * 300, y: Double(index / 12) * 200, width: 280, height: 180),
                    zPosition: .fromLegacyRank(index + 2), zoneId: fixture.note.tile.zoneId, runtimeRef: nil, metadata: .init())
                sources.append(.init(projectID: fixture.note.projectID, tile: tile))
            }
            let inventory = SharedAreaInventory.Snapshot(inventory: .init(workspaceID: fixture.workspace,
                coverage: .completeWorkspace, sources: sources), noteTexts: [fixture.note.key: text], issues: [])
            let result = try SharedAreaCaptureCoordinator(selection: .workspace, controller: pair.controller,
                person: fixture.identity.person, host: fixture.host, inventoryProvider: { inventory },
                submitter: { _ in throwawaySubmission() })
            try result.setMode(.agreement, for: fixture.note.key)
            return result
        }
        func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap { descendants($0) } }
        func control(_ label: String, in view: SharedAreaCaptureView) throws -> NSControl {
            guard let result = view.subviews.compactMap({ $0 as? NSControl }).first(where: { $0.accessibilityLabel() == label }) else {
                throw Failure(message: "bounded review action absent: \(label)")
            }
            return result
        }
        let small = SharedAreaCaptureView(coordinator: try coordinator(sourceCount: 1))
        small.layoutSubtreeIfNeeded()
        let smallViewCount = descendants(small).count
        small.stop()
        let large = SharedAreaCaptureView(coordinator: try coordinator(sourceCount: 121))
        defer { large.stop() }
        large.layoutSubtreeIfNeeded()
        guard let reader = descendants(large).compactMap({ $0 as? NSTextView }).first,
              let scroll = reader.enclosingScrollView else { throw Failure(message: "bounded review reader missing") }
        let originalReader = ObjectIdentifier(reader)
        try expect(large.coordinator.review.rows.count == 121 && large.sourceChoice.items.count == 40
            && large.coordinator.readyCount == 1 && large.coordinator.excludedCount == 120,
            "121-source review retains all membership while constructing only 40 current picker choices")
        var seen = Set(large.sourceChoice.items.map(\.id)), pages = 1
        while try control("Next", in: large).isEnabled {
            let previous = Set(large.sourceChoice.items.map(\.id))
            try click("Next", in: large)
            let current = Set(large.sourceChoice.items.map(\.id))
            try expect(!current.isEmpty && current.count <= 40 && current.isDisjoint(with: previous)
                && current.isDisjoint(with: seen), "Next exposes another bounded page of actual source identities")
            seen.formUnion(current); pages += 1
            guard pages <= 4 else { throw Failure(message: "capture pagination did not terminate") }
            try expect(descendants(large).compactMap { $0 as? NSTextView }.count == 1
                && descendants(large).contains(where: { ObjectIdentifier($0) == originalReader }),
                "paging reuses its single retained content reader")
        }
        let expected = Set(large.coordinator.review.rows.map { "\($0.source.projectID.uuidString)/\($0.source.tileID.uuidString)" })
        try expect(pages == 4 && large.sourceChoice.items.count == 1 && seen == expected,
            "last page remains reachable and every source identity is reviewable without truncation")
        for _ in 1..<pages { try click("Previous", in: large) }
        try expect(large.modeChoice.selectedID == "agreement" && reader.string == text,
            "returning to the source preserves its explicit choice and complete long note")
        scroll.scrollerStyle = .legacy
        let rendered = try UIProbe.render(.init(id: "collaboration.capture.legacy-long-note", size: .init(width: 680, height: 800), appearance: .aqua), make: { large })
        rendered.view.layoutSubtreeIfNeeded()
        guard let container = reader.textContainer, let manager = reader.layoutManager else { throw Failure(message: "long-note TextKit reader unavailable") }
        manager.ensureLayout(for: container)
        reader.scrollRangeToVisible(.init(location: (text as NSString).length - 1, length: 1))
        try expect(scroll.scrollerStyle == .legacy && scroll.hasVerticalScroller && !scroll.hasHorizontalScroller
            && reader.string == text && abs(reader.frame.width - scroll.contentSize.width) <= 1
            && manager.usedRect(for: container).height > scroll.contentSize.height && scroll.contentView.bounds.minY > 0,
            "legacy scroller constrains the long-note reader to clip width and can reveal its final line")
        try expect(descendants(large).count <= smallViewCount + 8
            && descendants(large).compactMap { $0 as? NSTextView }.count == 1,
            "growing review membership from one to 121 sources does not create one AppKit view per source")
        print("Collaboration capture bounds: 121 sources / 4 pages / at most 40 choices / 1 retained content reader; legacy scrolling checked. No wall-clock or maximum-inventory claim.")
    }
    private static func runRootWorkflow(root: URL) async throws {
        var executorConstructions = 0
        let noteID = UUID()
        let fixture = try WorkspaceAPIChecks.makeFixture(beforeMount: { delegate, directory in
            let store = AgentStore(applicationSupportDirectory: directory.appendingPathComponent("capture-scripted-agents"))
            for record in delegate.qaAgentSupervisor.records.values { try store.upsert(record) }
            delegate.agentSupervisor = AgentSupervisor(store: store, makeRunner: { _ in
                executorConstructions += 1; return ScriptedAgentRunner(script: [])
            })
            _ = delegate.agentSupervisor.restore()
            let source = ProjectStore(projectRoot: directory.appendingPathComponent("Pb"))
            var canvas = try source.loadCanvas()
            let owner = delegate.qaAgentSupervisor.records.values.first(where: { $0.projectRoot == directory.appendingPathComponent("Pb").path && $0.tileId != nil })
            guard let index = canvas.tiles.firstIndex(where: { $0.id == owner?.tileId }),
                  let zone = canvas.tiles[index].zoneId else { throw Failure(message: "source agent tile absent") }
            canvas.tiles[index].kind = .managedAgent; canvas.tiles[index].title = "Source agent"
            canvas.tiles.append(.init(id: noteID, kind: .note, title: "Workflow note",
                frame: .init(x: 3050, y: 680, width: 260, height: 180), zPosition: .fromLegacyRank(5),
                zoneId: zone, runtimeRef: nil, metadata: .init(noteId: noteID)))
            try source.saveCanvas(canvas)
            try source.saveNoteBody(id: noteID, text: "Coordinate the reviewed change here.")
        })
        defer { fixture.runtime.closeAll(); fixture.tearDown() }
        let app = fixture.delegate
        let personal = SourceWindow(contentRect: fixture.canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        personal.isReleasedWhenClosed = false; personal.contentView = fixture.canvas
        app.qaAttachWindowForOfflineCheck(personal)
        app.userCommandWindowProvider = { [weak personal] in personal }
        defer { app.userCommandWindowProvider = { NSApp.keyWindow } }
        personal.orderFrontOffscreenForChecks(); personal.makeKey()
        defer { personal.orderOut(nil) }
        try expect(fixture.runtime.setActiveZone(fixture.zoneB, reason: .explicit), "root workflow arms its explicit source zone before sharing")
        let capturedSources = fixture.canvas.allTilesInWorldFrames().filter { $0.id == fixture.agentTileB || $0.id == noteID }
        guard capturedSources.count == 2, let first = capturedSources.first else { throw Failure(message: "mounted capture sources absent") }
        var captureBounds = NSRect(x: first.frame.x, y: first.frame.y, width: first.frame.width, height: first.frame.height)
        for tile in capturedSources.dropFirst() {
            captureBounds = captureBounds.union(.init(x: tile.frame.x, y: tile.frame.y, width: tile.frame.width, height: tile.frame.height))
        }
        captureBounds = captureBounds.insetBy(dx: -20, dy: -20)
        let captureZoom = min(0.75, (fixture.canvas.bounds.width - 160) / captureBounds.width,
                              (fixture.canvas.bounds.height - 160) / captureBounds.height)
        fixture.canvas.setViewport(.init(x: captureBounds.minX - 80, y: captureBounds.minY - 80, zoom: captureZoom))
        try fixture.runtime.flushMountedWorkspaceState()
        let sourceFiles = [fixture.storePa.layout.canvasFile, fixture.storePb.layout.canvasFile, fixture.storePc.layout.canvasFile,
                           fixture.storePb.layout.noteFile(id: noteID)]
        let originalBytes = try sourceFiles.map { try Data(contentsOf: $0) }
        let originalTiles = fixture.canvas.allTilesInWorldFrames()
        let originalDocument = fixture.runtime.document
        let originalAgents = app.qaAgentSupervisor.records
        let beforeExecutors = executorConstructions
        let authority = Authority(identity: .init(person: .init(), device: UUID()))
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://capture-root.example.test")!)
        let account = try CollaborationAccountController(store: .init(applicationSupportRoot: root, bundleIdentifier: nil),
            credentialStore: .init(vault: MemoryVault(), bundleIdentifier: nil), bundleIdentifier: nil,
            transportFactory: { _, _ in AccountTransport(authority: authority) },
            areaTransportFactory: { _, _, _ in Transport(authority: authority) })
        let savedAccount = try await account.enroll(endpoint: endpoint, code: "scripted-root-enrollment", deviceLabel: "Test Mac", accountLabel: "Test account")
        let hub = app.presentCollaborationHub(model: account)
        defer { hub.window.close() }
        personal.makeKey()
        app.captureAreaToShareFromMenu(nil)
        guard let overlay = app.qaCaptureSelectionView, overlay.superview === fixture.canvas else {
            throw Failure(message: "shipping Capture area did not install its source gesture surface")
        }
        let captureViewport = fixture.canvas.canvasState.viewport
        let start = CanvasEngine.worldToScreen(.init(x: captureBounds.maxX, y: captureBounds.maxY), viewport: captureViewport)
        let end = CanvasEngine.worldToScreen(.init(x: captureBounds.minX, y: captureBounds.minY), viewport: captureViewport)
        func pointer(_ kind: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: kind, location: overlay.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: personal.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else { throw Failure(message: "mounted source capture event unavailable") }
            return event
        }
        overlay.mouseDown(with: try pointer(.leftMouseDown, at: start))
        overlay.mouseDragged(with: try pointer(.leftMouseDragged, at: end))
        overlay.mouseUp(with: try pointer(.leftMouseUp, at: end))
        try expect(app.qaCaptureSelectionView == nil && hub.window.title.contains("Share selection"),
            "production-mounted Capture area pointer path opens the destination hub and retires its gesture surface")
        guard let create = hub.content.subviews.compactMap({ $0 as? NSControl }).first(where: { $0.accessibilityLabel() == "Create workspace" }),
              create.isEnabled, create.sendAction(create.action, to: create.target) else { throw Failure(message: "root hub Create workspace action missing") }
        try await eventually("root capture setup") { app.qaSharedAreaCaptureWindows.count == 1 }
        await app.qaCaptureSetupTask?.value
        guard let review = app.qaSharedAreaCaptureWindows.first, let destination = app.qaSharedAreaZoneSessions.first else {
            throw Failure(message: "root did not mount the destination zone and review")
        }
        // The destination is the area's zone on this canvas, never a window.
        try expect(destination.scene.isZone && destination.scene.superview === fixture.canvas.worldPlane
            && fixture.runtime.sharedAreaZone(for: authority.area.rawValue)?.zoneId == destination.zoneId
            && fixture.runtime.sharedAreaZone(for: authority.area.rawValue)?.projectId == nil
            && !NSApp.windows.contains(where: { $0.contentView?.subviews.contains(where: { $0 is SharedAreaSceneView }) == true }),
            "the hub's destination opens as a projectless zone on the source canvas, with no shared window")
        defer { review.window.close() }
        try expect(review.content.coordinator.controller !== destination.controller && review.content.coordinator.workspaceID == fixture.workspaceWA,
            "shipping destination callback constructs a separate review controller bound to the original source workspace")
        if case .enclosed(let rect) = review.content.coordinator.selection {
            try expect(abs(rect.x - captureBounds.minX) < 0.001 && abs(rect.y - captureBounds.minY) < 0.001
                && abs(rect.width - captureBounds.width) < 0.001 && abs(rect.height - captureBounds.height) < 0.001,
                "production-mounted pointer selection preserves its exact WORLD rectangle through hub and review")
        } else { throw Failure(message: "root pointer capture lost its enclosed selection") }
        destination.close()
        try await eventually("destination closed independently") { destination.controller.status == .closed }
        try expect(review.content.coordinator.controller.status == .connected,
            "closing the destination scene leaves its independent publication review connected")
        try choose("agreement", title: "Workflow note", in: review.content)
        try choose("agent", title: "Source agent", in: review.content)
        try click("Share selection", in: review.content)
        try await eventually("root reviewed publication") { review.content.coordinator.state == .published }
        let cache = try SharedAreaLocalStore(applicationSupportRoot: root, bundleIdentifier: nil, endpoint: endpoint,
            person: savedAccount.identity.person, area: authority.area)
        let saved = try cache.load()
        try expect(saved?.document.items.count == 2 && saved?.document.contexts.first?.text == "Coordinate the reviewed change here."
            && saved?.sourceBindings.first?.agentID == fixture.agentId && saved?.sourceBindings.first?.tileID == fixture.agentTileB,
            "shipping source→hub→destination→review publishes captured content and retains the exact source agent binding")
        let originX = capturedSources.map(\.frame.x).min()!, originY = capturedSources.map(\.frame.y).min()!
        for tile in capturedSources {
            let object = tile.id == fixture.agentTileB ? saved?.sourceBindings.first?.object
                : saved?.document.items.first(where: { $0.kind == .agreement })?.id
            let actual = saved?.document.positions.first(where: { $0.object == object })?.rect
            try expect(actual == .init(x: tile.frame.x - originX, y: tile.frame.y - originY,
                width: tile.frame.width, height: tile.frame.height),
                "captured native layout preserves \(tile.kind.displayName) size and relative WORLD frame exactly once")
        }
        try expect((try sourceFiles.map { try Data(contentsOf: $0) }) == originalBytes
            && fixture.canvas.allTilesInWorldFrames() == originalTiles && withoutSharedZones(fixture.runtime.document) == originalDocument
            && app.qaAgentSupervisor.records == originalAgents && executorConstructions == beforeExecutors,
            "the complete native sharing route preserves source files, WORLD models, workspace ownership and executor census")
        try expect(await authority.hostRegistrations == 1, "root capture registers the owning collaboration host once")
        await review.content.coordinator.controller.close()
    }

    /// The workspace document as the source owned it: the destination's own
    /// projectless zone is the one thing opening an area adds.
    private static func withoutSharedZones(_ document: WorkspaceDocument) -> WorkspaceDocument {
        var copy = document
        copy.zones.removeAll(where: \.isSharedArea)
        return copy
    }

    static func makeAppearanceFixture() throws -> NSView {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-capture-appearance-\(UUID())")
        let fixture = Fixture(), authority = Authority(identity: fixture.identity)
        let pair = try model(root: root, fixture: fixture, authority: authority)
        let coordinator = try SharedAreaCaptureCoordinator(selection: .workspace, controller: pair.controller,
            person: fixture.identity.person, host: fixture.host, inventoryProvider: { fixture.snapshot() },
            submitter: { _ in throwawaySubmission() })
        try coordinator.setMode(.agreement, for: fixture.note.key)
        try coordinator.setMode(.agentObservation, for: fixture.agent.key)
        let wrapper = AppearanceHost(root: root)
        let view = SharedAreaCaptureView(coordinator: coordinator)
        view.frame = wrapper.bounds; view.autoresizingMask = [.width, .height]
        if let note = view.sourceChoice.items.first(where: { $0.title.contains("Planning note") }) { view.sourceChoice.handleSelection(note) }
        wrapper.addSubview(view); wrapper.layoutSubtreeIfNeeded()
        return wrapper
    }
    private static func throwawaySubmission() -> SharedAreaController.Submission { .rejected(.notConnected) }
    private final class AppearanceHost: NSView {
        let ownedRoot: URL
        init(root: URL) { ownedRoot = root; super.init(frame: .init(x: 0, y: 0, width: 780, height: 800)) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        deinit { try? FileManager.default.removeItem(at: ownedRoot) }
    }
    private struct Fixture {
        let identity = Collaboration.Identity(person: .init(), device: UUID())
        let host = SharedArea.ID<SharedArea.Host>()
        let workspace = UUID()
        let note: SharedAreaPublication.SourceTile
        let agent: SharedAreaPublication.SourceTile
        let terminal: SharedAreaPublication.SourceTile
        init() {
            let project = UUID(), zone = UUID()
            note = .init(projectID: project,
                tile: .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, kind: .note, title: "Planning note", frame: .init(x: -600, y: 120, width: 300, height: 210),
                    zPosition: .fromLegacyRank(1), zoneId: zone, runtimeRef: nil, metadata: .init(noteId: UUID())), contentRevision: "initial")
            agent = .init(projectID: project,
                tile: .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, kind: .managedAgent, title: "Owned agent", frame: .init(x: -270, y: 120, width: 320, height: 360),
                    zPosition: .fromLegacyRank(2), zoneId: zone, runtimeRef: nil, metadata: .init()), agentID: .init(rawValue: UUID()))
            terminal = .init(projectID: project,
                tile: .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, kind: .terminal, title: "Private terminal", frame: .init(x: -600, y: 360, width: 300, height: 210),
                    zPosition: .fromLegacyRank(3), zoneId: zone, runtimeRef: nil, metadata: .init()))
        }
        func snapshot(text: String = "Keep the data contract explicit.\n\nDiscuss proposed changes here, then send the agreed revision to your own agent.",
                      generation: String = "initial", workspace override: UUID? = nil) -> SharedAreaInventory.Snapshot {
            let currentNote = SharedAreaPublication.SourceTile(projectID: note.projectID, tile: note.tile, contentRevision: generation)
            return .init(inventory: .init(workspaceID: override ?? workspace, coverage: .completeWorkspace, sources: [currentNote, agent, terminal]),
                noteTexts: [note.key: text], issues: [])
        }
    }
    private static func model(root: URL, fixture: Fixture, authority: Authority) throws -> (controller: SharedAreaController, cache: SharedAreaLocalStore) {
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://capture-review.example.test")!)
        let credentials = CollaborationCredentialStore(vault: MemoryVault(), bundleIdentifier: nil)
        let scope = CollaborationCredentialScope(endpoint: endpoint, identity: fixture.identity)
        try credentials.save(.init(identity: fixture.identity, token: "scripted-capture-only"), for: scope)
        let cache = try SharedAreaLocalStore(applicationSupportRoot: root, bundleIdentifier: nil,
            endpoint: endpoint, person: fixture.identity.person, area: authority.area)
        try cache.save(.init(scope: cache.scope, document: .init(id: authority.area), observedMembershipEpoch: 1))
        let controller = try SharedAreaController(localStore: cache, credentialStore: credentials, credentialScope: scope,
            bundleIdentifier: nil, transportFactory: { _, _, _ in Transport(authority: authority) })
        return (controller, cache)
    }
    private final class MemoryVault: CollaborationCredentialVault, @unchecked Sendable {
        let lock = NSLock(); var values: [String: Data] = [:]
        func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
        func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
        func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
    }
    private actor Connection: SharedAreaControllerConnection {
        let pair = AsyncStream<CollaborationSession.Status>.makeStream()
        func start() async -> AsyncStream<CollaborationSession.Status> { pair.stream }
        func stop() async { pair.continuation.finish() }
    }
    private actor Authority {
        nonisolated let area = SharedArea.ID<SharedArea.Area>()
        let identity: Collaboration.Identity
        var document: SharedArea.Document
        var operations: [SharedArea.ID<SharedArea.Operation>] = []
        var callCount: Int { operations.count }
        var loseReply = false
        var rejectConflict = false
        var hostRegistrations = 0
        init(identity: Collaboration.Identity) { self.identity = identity; document = .init(id: area) }
        func state() -> Collaboration.State { .init(scope: .init(area: area, epoch: 1, role: .owner), document: document) }
        func loseNextReply() { loseReply = true }
        func rejectNextConflict() { rejectConflict = true }
        func registerHost() -> Collaboration.Host { hostRegistrations += 1; return .init(id: .init()) }
        func apply(_ mutation: Collaboration.Mutation) throws -> Collaboration.Receipt {
            operations.append(mutation.command.id)
            if rejectConflict { rejectConflict = false; throw CollaborationClientError.server(status: 409, code: "staleEpoch") }
            let result = try document.apply(mutation.command)
            if loseReply { loseReply = false; throw URLError(.networkConnectionLost) }
            switch result { case .applied(let revision): return .init(revision: revision, duplicate: false); case .duplicate(let revision): return .init(revision: revision, duplicate: true) }
        }
    }
    private struct AccountTransport: CollaborationAccountTransport {
        let authority: Authority
        func redeem(code: String, deviceLabel: String) async throws -> Collaboration.Credential { .init(identity: await authority.identity, token: "scripted-root-capture-only") }
        func identity() async throws -> Collaboration.Identity { await authority.identity }
        func createArea() async throws -> Collaboration.State { await authority.state() }
        func state(area: UUID) async throws -> Collaboration.State {
            guard area == authority.area.rawValue else { throw Failure(message: "unexpected root destination") }
            return await authority.state()
        }
        func accept(code: String) async throws -> Collaboration.Scope { throw Failure(message: "unexpected invitation acceptance") }
        func invite(area: UUID, person: SharedArea.ID<SharedArea.Person>, role: Collaboration.Role) async throws -> Collaboration.Invitation { throw Failure(message: "unexpected invitation") }
        func registerHost() async throws -> Collaboration.Host { await authority.registerHost() }
    }
    private struct Transport: SharedAreaControllerTransport {
        let authority: Authority
        func identity() async throws -> Collaboration.Identity { await authority.identity }
        func state() async throws -> Collaboration.State { await authority.state() }
        func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection { Connection() }
        func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt { try await authority.apply(mutation) }
    }
}
