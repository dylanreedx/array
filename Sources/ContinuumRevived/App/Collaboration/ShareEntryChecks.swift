import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ObjectiveC

/// `.plans/105-collaboration/IN-CANVAS.md` round 2, part 3: every Share entry
/// point, driven the user's way. Presses and drags go through `NSApp.sendEvent`
/// into the production mount (header Share, sidebar hover and row menu, the S
/// key and a marquee), and the popover's Copy, lifetime, Remove and Revoke are
/// pressed in its own panel. Parts 1 and 2 are the fakes below; Copy writes to
/// a private named pasteboard, never the general one.
@MainActor
enum ShareEntryChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(description: label) }
        print("PASS share entry: \(label)")
    }

    private static func eventually(_ label: String, _ value: () -> Bool) async throws {
        for _ in 0..<300 {
            if value() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(description: "timeout: \(label)")
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    /// The check app is inactive, so AppKit would eat each press as an
    /// activation click; the user's app is active when they click.
    private static func acceptFirstMouseEverywhere() {
        guard let method = class_getInstanceMethod(NSView.self, #selector(NSView.acceptsFirstMouse(for:))) else { return }
        let always: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        method_setImplementation(method, imp_implementationWithBlock(always))
    }

    // MARK: Parts 1 and 2, recorded

    final class FakeLinks: ShareLinkServing {
        typealias Lifetime = Collaboration.ShareLinkLifetime
        var created: [(area: UUID, slug: String, lifetime: Lifetime)] = []
        var revoked: [UUID] = []
        var removed: [SharedArea.ID<SharedArea.Person>] = []
        var access: [UUID: Collaboration.ShareLinkAccess] = [:]
        /// The next mint refuses, as the relay does for a slug in use.
        var refuseNext: (any Error)?
        private var count = 0

        func createShareLink(area areaId: UUID, slug: String, lifetime: Lifetime) async throws -> Collaboration.ShareLink {
            if let refusal = refuseNext { refuseNext = nil; throw refusal }
            created.append((areaId, slug, lifetime))
            count += 1
            return Collaboration.ShareLink(id: UUID(), area: .init(areaId), slug: slug,
                                           token: "checkToken_\(count)_abcdefgh", lifetime: lifetime, createdAt: Date())
        }
        func revokeLink(area: UUID, link: UUID) async throws { revoked.append(link) }
        func removeAccess(area: UUID, link: UUID, person: SharedArea.ID<SharedArea.Person>) async throws { removed.append(person) }
        func listAccess(area: UUID) async throws -> [Collaboration.ShareLinkAccess] { Array(access.values) }
    }

    final class FakeZones: SharedZoneCreating {
        var calls: [(tiles: [UUID], name: String, share: SharedZoneShare)] = []
        var cancelled: [UUID] = []
        func createSharedZone(fromTiles tileIds: [UUID], name: String) async throws -> SharedZoneShare {
            let share = SharedZoneShare(areaId: UUID(), zoneId: UUID(), objects: [:])
            calls.append((tileIds, name, share))
            return share
        }
        func cancelSharedZone(areaId: UUID) async { cancelled.append(areaId) }
    }

    // MARK: Run

    static func run() async throws {
        acceptFirstMouseEverywhere()
        let agentA = TileInsertSlideChecks.tileA, agentB = TileInsertSlideChecks.tileB
        let noteC = TileInsertSlideChecks.tileC, agentD = TileInsertSlideChecks.tileD
        let fixture = try TileInsertSlideChecks.makeFixture("share-entry")
        defer { fixture.dispose() }
        let workspaceStore = WorkspaceStore(workspaceId: WorkspaceInvariantsFixture.workspaceA,
                                            applicationSupportDirectory: fixture.appSupport)
        var document = try workspaceStore.load()
        if let index = document.zones.firstIndex(where: { $0.zoneId == WorkspaceInvariantsFixture.zoneA1 }) {
            document.zones[index].size = ZoneSize(width: 2400, height: 1200)
        }
        try workspaceStore.save(document)
        let root = fixture.projectRoots[WorkspaceInvariantsFixture.projectA1]!
        let projectStore = ProjectStore(projectRoot: root)
        var state = try projectStore.loadCanvas()
        for (id, frame, agent) in [
            (agentA, TileFrame(x: 600, y: 520, width: 360, height: 260), true),
            (agentB, TileFrame(x: 1300, y: 520, width: 360, height: 260), true),
            (noteC, TileFrame(x: 2000, y: 520, width: 600, height: 260), false),
            (agentD, TileFrame(x: 600, y: 900, width: 360, height: 260), true),
        ] {
            let index = state.tiles.firstIndex { $0.id == id }!
            if agent {
                state.tiles[index].kind = .managedAgent
                state.tiles[index].metadata = TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: ".")
            }
            state.tiles[index].frame = frame
        }
        try projectStore.saveCanvas(state)
        var agents: [AgentID] = []
        let appSupport = fixture.appSupport
        fixture.configureMount = { delegate, _ in
            delegate.agentSupervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: appSupport),
                makeRunner: { _ in ScriptedAgentRunner(script: [], holdUntilStopped: true) })
            for (id, name) in [(agentA, "Map the checkout state machine"), (agentB, "Audit the receipt email path"),
                               (agentD, "Fix the saved-card toggle")] {
                agents.append(delegate.agentSupervisor.spawn(
                    role: nil, prompt: nil, cwd: root, harness: .claudeCode,
                    model: "fixture/share", thinking: "medium",
                    projectId: WorkspaceInvariantsFixture.projectA1, projectRoot: root,
                    tileId: id, displayName: name))
            }
        }
        try fixture.mount()
        let mounted = try fixture.requireMounted("share entry")
        let canvas = mounted.canvas
        let app = mounted.delegate
        TileInsertSlideChecks.pin(canvas, autoLayout: false)
        canvas.setViewport(CanvasViewport(x: 300, y: 250, zoom: 1))
        let window = KeyWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        defer { window.orderOut(nil) }
        app.userCommandWindowProvider = { [weak window] in window }
        defer { app.userCommandWindowProvider = { NSApp.keyWindow } }
        for (tile, agent) in zip([agentA, agentB, agentD], agents) { app.wireManagedAgentTile(tile, agentID: agent) }
        canvas.layoutSubtreeIfNeeded()

        let links = FakeLinks(), zones = FakeZones()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.arrayapp.share-entry-check.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        app.qaInstallShareEntry(links: links, zones: zones, pasteboard: pasteboard)
        app.shareEntry.presentsOffscreenForQA = true
        defer { app.shareEntry.dismiss() }

        func mouse(_ type: NSEvent.EventType, _ point: NSPoint, in target: NSWindow) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1)
            else { throw Failure(description: "could not synthesise \(type)") }
            return event
        }
        /// A click on `view` where the user would click: the release is queued
        /// first so a control that tracks the press in its own loop finds it.
        func click(_ view: NSView, drawnIn host: NSView? = nil) throws {
            // A resting tile draws its band controls itself, detached: the
            // press lands on the band, which wakes them and passes it on.
            let anchor = view.window == nil ? host : view
            guard let anchor, let target = anchor.window else { throw Failure(description: "\(type(of: view)) is not in a window") }
            let centre = NSPoint(x: view.frame.midX, y: view.frame.midY)
            let point = anchor === view ? view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                : anchor.convert(centre, to: nil)
            NSApp.postEvent(try mouse(.leftMouseUp, point, in: target), atStart: false)
            NSApp.sendEvent(try mouse(.leftMouseDown, point, in: target))
            while let pending = NSApp.nextEvent(matching: [.leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(pending)
            }
        }
        func key(_ characters: String, keyCode: UInt16) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
            else { throw Failure(description: "could not synthesise key \(characters)") }
            // The window's own routing to its first responder: an inactive check
            // app has no real key window for NSApp to hand a key event to.
            window.sendEvent(event)
        }
        func key(for tile: UUID) -> SharedAreaPublication.SourceKey {
            .init(projectID: WorkspaceInvariantsFixture.projectA1, tileID: tile)
        }
        var popover: ShareLinkPopoverView {
            get throws {
                guard app.shareEntry.isPresented, let view = app.shareEntry.presentedView else {
                    throw Failure(description: "the share popover is not open")
                }
                view.layoutSubtreeIfNeeded()
                return view
            }
        }
        let renders = ProcessInfo.processInfo.environment["CONTINUUM_COLLABORATION_RENDER_DIR"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent("share-entry", isDirectory: true) }
        func still(_ name: String) throws {
            guard let renders else { return }
            try writeStill(name, canvas: canvas, window: window, panel: app.shareEntry.qaPanel, to: renders)
        }

        // 1. The header's Share, clicked, opens the popover on that agent.
        guard let tileA = canvas.tileView(for: agentA), let shareA = tileA.qaTitleBarShareControl else {
            throw Failure(description: "agent A's header shows no Share button")
        }
        try still("1-header")
        try click(shareA, drawnIn: tileA.qaTitleBarView)
        let agentPopover = try popover
        try expect(agentPopover.session.target.origin == .agent
            && agentPopover.session.target.keys == [key(for: agentA)]
            && agentPopover.session.target.name == "Map the checkout state machine",
            "a click on the header's Share opens the popover for that one agent, as .tiles of its own tile")
        try expect(links.created.isEmpty && zones.calls.isEmpty,
            "opening the popover shares nothing: no area, no link, no tile moved")
        if let panel = app.shareEntry.qaPanel {
            let button = window.convertToScreen(shareA.convert(shareA.bounds, to: nil))
            try expect(abs(panel.frame.minX + ChoicePanelShadowView.margin - button.minX) < 2
                && panel.frame.maxY - ChoicePanelShadowView.margin <= button.minY,
                "the popover hangs from the Share button it was opened by")
        }
        try expect(agentPopover.slugField.stringValue == "map-the-checkout-state-machine",
            "the slug starts from the agent's name")
        try stillPopover("2-agent-draft", agentPopover, to: renders)

        // 2. A taken name: the link fails, the popover says so, the tiles go
        //    back and nothing reaches the pasteboard.
        pasteboard.clearContents()
        links.refuseNext = ShareLinkFailure.slugTaken
        try click(agentPopover.copyButton)
        try await eventually("refused Copy settles") { agentPopover.session.failure != nil && !agentPopover.session.isWorking }
        try expect(zones.calls.count == 1 && zones.cancelled == [zones.calls[0].share.areaId]
            && agentPopover.session.link == nil && pasteboard.string(forType: .string) == nil
            && agentPopover.session.failure == ShareLinkFailure.slugTaken.errorDescription,
            "a slug the relay refuses is shown in the popover, the zone is undone and nothing is copied")
        try stillPopover("2b-agent-slug-taken", agentPopover, to: renders)

        // 3. Copy shares, then puts the link on the (private) pasteboard.
        try click(agentPopover.copyButton)
        try await eventually("Copy finishes") { agentPopover.session.copied }
        let firstLink = agentPopover.session.link
        try expect(zones.calls.count == 2 && zones.calls[1].tiles == [agentA]
            && zones.calls[1].name == "Map the checkout state machine",
            "Copy first makes the agent a one-tile shared zone named after it")
        try expect(links.created.count == 1 && links.created[0].area == zones.calls[1].share.areaId
            && links.created[0].slug == "map-the-checkout-state-machine" && links.created[0].lifetime == .once,
            "then mints the link on that zone's area with the slug and Works once")
        try expect(pasteboard.string(forType: .string) == firstLink?.url.absoluteString
            && agentPopover.copyButton.presentation.title == "Copied",
            "Copy writes the link to the pasteboard and the button reads Copied")
        try stillPopover("3-agent-copied", agentPopover, to: renders)

        // 4. Lifetime: a real press opens the ChoiceButton's list inside the
        //    popover; picking Until revoked replaces the unopened link.
        try click(agentPopover.lifetimeChoice)
        try expect(agentPopover.lifetimeChoice.qaIsPopoverPresented && app.shareEntry.isPresented,
            "the lifetime list opens on a press without closing the share popover")
        try expect(agentPopover.lifetimeChoice.choosePresentedItemForQA(id: Collaboration.ShareLinkLifetime.untilRevoked.rawValue),
            "Until revoked can be chosen from the list")
        try await eventually("lifetime reissue") { links.created.count == 2 && !agentPopover.session.isWorking }
        try expect(links.revoked == [firstLink!.id] && links.created[1].lifetime == .untilRevoked
            && links.created[1].area == firstLink?.area.rawValue && agentPopover.session.link?.lifetime == .untilRevoked
            && agentPopover.lifetimeChoice.selectedID == Collaboration.ShareLinkLifetime.untilRevoked.rawValue,
            "choosing Until revoked revokes the unopened link and mints its replacement through the controller")
        try expect(app.shareEntry.isPresented, "the share popover stays open after the lifetime pick")

        // 5. Revoke, pressed in the popover's panel.
        let revoked = agentPopover.session.link!.id
        try click(agentPopover.currentRevokeButton)
        try await eventually("revoke") { links.revoked.count == 2 && !agentPopover.session.isWorking }
        try expect(links.revoked.last == revoked && agentPopover.session.link == nil
            && agentPopover.copyButton.presentation.title == "New link",
            "Revoke link calls revokeLink for the live link and the popover offers New link")
        try stillPopover("4-agent-revoked", agentPopover, to: renders)
        app.shareEntry.dismiss()

        // 6. The sidebar row: hover Share, then the row menu's Share….
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 380, height: 400))
        inbox.prefersReducedMotion = { true }
        inbox.hoverCardEnabled = false
        inbox.onRevealRow = { _ in }
        inbox.onRowAction = { action, ids in _ = app.performInboxRowAction(action, on: ids) }
        inbox.wiredRowActions = AppDelegate.wiredInboxRowActions
        inbox.presentsPopoversOffscreenForQA = true
        let sidebarWindow = KeyWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        sidebarWindow.isReleasedWhenClosed = false
        sidebarWindow.contentView = inbox
        sidebarWindow.orderFrontOffscreenForChecks()
        defer { sidebarWindow.orderOut(nil) }
        inbox.setScope(.all)
        let now = Date()
        inbox.reload(rows: [(agents[1], "Audit the receipt email path"), (agents[2], "Fix the saved-card toggle")].map { agent, title in
            AgentInboxRow(id: agent.rawValue, title: title, projectName: "checkout-web", projectId: WorkspaceInvariantsFixture.projectA1,
                workspaceName: "A", workspaceId: WorkspaceInvariantsFixture.workspaceA, state: .ready, lifecycle: .active,
                model: "claude-opus-5-5", branch: "checkout/retry", elapsed: nil, elapsedStartedAt: nil,
                lastActiveAt: now, depth: 0, createdAt: now, parentId: nil, harness: "Claude Code",
                terminalEvent: nil, terminalIsUnread: false, identityColor: nil, selfReport: nil, hasTile: true, isPinned: false)
        })
        inbox.layoutForQA()
        guard let rowB = inbox.ownershipCellForQA(id: agents[1].rawValue) else { throw Failure(description: "no sidebar row for agent B") }
        rowB.layoutSubtreeIfNeeded()
        let rowCentre = rowB.convert(NSPoint(x: rowB.bounds.midX, y: rowB.bounds.midY), to: nil)
        inbox.mouseMoved(with: try mouse(.mouseMoved, rowCentre, in: sidebarWindow))
        inbox.layoutForQA(); rowB.layoutSubtreeIfNeeded()
        guard let hoverShare = rowB.hoverShareButtonForQA else { throw Failure(description: "hovering the row shows no Share") }
        try click(hoverShare)
        let sidebarPopover = try popover
        try expect(sidebarPopover.session.target.keys == [key(for: agentB)] && sidebarPopover.session.target.origin == .agent,
            "a click on the row's hover Share opens the popover for that agent")
        if let panel = app.shareEntry.qaPanel, let tileB = canvas.tileView(for: agentB) {
            let tile = window.convertToScreen(tileB.convert(tileB.bounds, to: nil))
            try expect(panel.frame.insetBy(dx: ChoicePanelShadowView.margin, dy: ChoicePanelShadowView.margin).minX - tile.minX < 2
                && abs(panel.frame.minX + ChoicePanelShadowView.margin - tile.minX) < 2,
                "the sidebar's popover is anchored to the agent's tile on the canvas, not to the row")
        }
        app.shareEntry.dismiss()
        inbox.mouseExited(with: try mouse(.mouseMoved, .zero, in: sidebarWindow))
        let rowD = inbox.ownershipCellForQA(id: agents[2].rawValue)!
        let rowDPoint = rowD.convert(NSPoint(x: rowD.bounds.midX, y: rowD.bounds.midY), to: nil)
        NSApp.sendEvent(try mouse(.rightMouseDown, rowDPoint, in: sidebarWindow))
        NSApp.sendEvent(try mouse(.rightMouseUp, rowDPoint, in: sidebarWindow))
        try expect(inbox.rowMenuTitlesForQA.first == "Share…", "the row menu leads with Share…")
        guard let list = inbox.rowMenuListForQA else { throw Failure(description: "the row menu has no list") }
        list.choose(id: InboxRowAction.share.rawValue)
        try expect(app.shareEntry.presentedView?.session.target.keys == [key(for: agentD)],
            "the row menu's Share… opens the same popover for that agent")
        app.shareEntry.dismiss()

        // 7. The Share tool: S arms it; a marquee over A, B and part of C
        //    selects exactly A and B as it goes; release opens the area popover.
        try expect(FloatingToolbarView.visibleItems(defaults: UserDefaults(suiteName: "share-entry-\(UUID())")!)
            .contains { $0.item.title == "Share" && $0.shortcut == "S" }
            && CommandRegistry.paletteActions().contains(.shareArea),
            "Share is on the toolbar beside Zone with the S key, and in the palette")
        window.makeFirstResponder(canvas)
        try key("s", keyCode: 1)
        guard let tool = app.qaShareToolView, tool.superview === canvas else {
            throw Failure(description: "S on the canvas did not arm the Share tool")
        }
        tool.layoutSubtreeIfNeeded()
        let viewport = canvas.viewport
        func screen(_ x: Double, _ y: Double) -> NSPoint {
            canvas.convert(CanvasEngine.worldToScreen(.init(x: x, y: y), viewport: viewport), to: nil)
        }
        let start = screen(560, 480), middle = screen(1200, 800), end = screen(2100, 820)
        NSApp.sendEvent(try mouse(.leftMouseDown, start, in: window))
        NSApp.sendEvent(try mouse(.leftMouseDragged, middle, in: window))
        try expect(canvas.tileSelection.ids == [agentA] && canvas.tileSelection.qaOverlay?.qaDrawnRingCount == 1
            && canvas.tileSelection.qaOverlay?.handles.isEmpty == true,
            "mid-drag, the one tile the marquee fully covers already wears a ring, with no group handles")
        NSApp.sendEvent(try mouse(.leftMouseDragged, end, in: window))
        try expect(canvas.tileSelection.ids == [agentA, agentB] && canvas.tileSelection.qaOverlay?.qaDrawnRingCount == 2,
            "the marquee rings only what it fully covers: the partly covered note stays out")
        try still("5-marquee")
        NSApp.sendEvent(try mouse(.leftMouseUp, end, in: window))
        let areaPopover = try popover
        try expect(app.qaShareToolView == nil && areaPopover.session.target.origin == .area
            && areaPopover.session.target.keys == [key(for: agentA), key(for: agentB)],
            "release retires the tool and opens the area popover on exactly the covered tiles")
        try stillPopover("6-area-draft", areaPopover, to: renders)
        try still("6-area-anchored")
        try click(areaPopover.copyButton)
        try await eventually("area copy") { areaPopover.session.copied }
        try expect(zones.calls.last.map { $0.tiles == [agentA, agentB] } == true
            && links.created.last?.area == zones.calls.last?.share.areaId,
            "the area's Copy makes the dragged tiles, in reading order, the shared zone and mints its link")

        // 8. After use: "Used", the person, Remove and New link.
        let spent = areaPopover.session.link!
        let sam = Collaboration.ShareLinkPerson(person: .init(), label: "Sam", admittedAt: Date(timeIntervalSince1970: 1_900_000_080), active: true)
        links.access[spent.id] = Collaboration.ShareLinkAccess(id: spent.id, area: spent.area, slug: spent.slug,
            lifetime: .once, status: .used, createdAt: Date(), people: [sam])
        app.shareEntry.dismiss()
        try expect(canvas.tileSelection.ids.isEmpty, "closing the area popover clears the marquee's rings")
        _ = app.qaPerformPaletteAction(.shareArea)
        guard let rearmed = app.qaShareToolView else { throw Failure(description: "the palette's Share… did not arm the tool") }
        NSApp.sendEvent(try mouse(.leftMouseDown, start, in: window))
        NSApp.sendEvent(try mouse(.leftMouseDragged, end, in: window))
        NSApp.sendEvent(try mouse(.leftMouseUp, end, in: window))
        _ = rearmed
        let reopened = try popover
        try await eventually("access refresh") { reopened.session.people == [sam] }
        reopened.layoutSubtreeIfNeeded()
        try expect(reopened.session.link == spent && reopened.copyButton.presentation.title == "New link"
            && reopened.removeButtons.count == 1 && reopened.currentRevokeButton.accessory.title == "Revoke everyone's access",
            "reopened, a spent Works once link reads Used with Sam, Remove and New link")
        try stillPopover("7-area-used", reopened, to: renders)
        try click(reopened.removeButtons[0])
        try await eventually("remove") { links.removed == [sam.person] && !reopened.session.isWorking }
        try expect(reopened.session.people.isEmpty, "Remove calls removeAccess for that person")
        let mintedBefore = links.created.count
        try click(reopened.copyButton)
        try await eventually("new link") { links.created.count == mintedBefore + 1 && !reopened.session.isWorking }
        try expect(links.created.last?.area == spent.area.rawValue && reopened.session.link != spent,
            "New link mints a fresh link on the same area")
        app.shareEntry.dismiss()
        print("Share entry checks passed: header, sidebar hover and menu, S and palette, marquee with live rings, Copy on a private pasteboard, lifetime, Remove, Revoke and New link through the controller. Parts 1 and 2 recorded by fakes.")
    }

    // MARK: Stills

    /// The popover alone, in light and dark.
    private static func stillPopover(_ name: String, _ view: ShareLinkPopoverView, to directory: URL?) throws {
        guard let directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let copy = ShareLinkPopoverView(session: view.session)
            let size = copy.preferredSize
            let probe = try UIProbe.render(.init(id: "share-entry.\(name)", size: NSSize(width: size.width + 32, height: size.height + 32),
                                                 appearance: appearance), make: { copy })
            guard let png = probe.hostRep.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: directory.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png"))
        }
        view.session.onChange = { [weak view] in view?.render() }
    }

    /// The canvas, with the popover's panel composited where it sits, in light
    /// and dark.
    private static func writeStill(_ name: String, canvas: CanvasNSView, window: NSWindow, panel: NSPanel?, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = window.appearance
        defer { window.appearance = original; panel?.appearance = original }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            panel?.appearance = window.appearance
            canvas.layoutSubtreeIfNeeded()
            canvas.display()
            guard let canvasRep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { continue }
            canvas.cacheDisplay(in: canvas.bounds, to: canvasRep)
            let image = NSImage(size: canvas.bounds.size)
            image.lockFocusFlipped(false)
            canvasRep.draw(in: NSRect(origin: .zero, size: canvas.bounds.size))
            if let panel, panel.isVisible, let content = panel.contentView {
                content.layoutSubtreeIfNeeded(); content.display()
                if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    let origin = NSPoint(x: panel.frame.minX - window.frame.minX, y: panel.frame.minY - window.frame.minY)
                    rep.draw(in: NSRect(origin: origin, size: content.bounds.size), from: .zero, operation: .sourceOver,
                             fraction: 1, respectFlipped: true, hints: nil)
                }
            }
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: directory.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png"))
        }
    }
}
