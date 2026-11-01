import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// `scripts/check-multiplayer-journey.py`: one person in a two-app journey on a
/// real relay. The script writes `req-<n>.json` into the mailbox; this answers
/// `res-<n>.json`. Every op goes through the production path a person's click
/// takes: the header Share and the popover's Copy clicked through
/// `NSApp.sendEvent`, a link opened through `application(_:open:)`, the real
/// composers, and mouse events posted to the app's own queue for the presence
/// publisher's monitor.
///
/// Only a `MultiplayerPreview` with `driver` set runs this: its own dev bundle
/// id, isolated app support, file vault, fake CLIs, a window parked off every
/// display that never activates.
@MainActor
final class MultiplayerDriver {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// The share step, kept small and swappable. Mode A of the share redesign
    /// (`.plans/105-collaboration/SHARE-REDESIGN.md`): the agent header's Share
    /// clicked, then the popover's Copy. One agent is shared with no zone and
    /// nothing on this canvas moves.
    static func share(tile: UUID, slug: String, delegate: AppDelegate) async throws -> (url: URL, session: ShareLinkSession) {
        let popover = try await openHeaderShare(tile: tile, delegate: delegate)
        popover.slugField.stringValue = slug
        popover.session.setSlug(slug)
        try ShareEntryChecks.click(popover.copyButton)
        let session = popover.session
        let deadline = Date().addingTimeInterval(60)
        while session.isWorking || (session.phase == .draft && session.failure == nil) {
            guard Date() < deadline else { throw Failure(description: "Copy did not finish") }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let link = session.link else { throw Failure(description: "share failed: \(session.failure ?? "no link")") }
        return (link.url, session)
    }

    /// The agent header's Share, clicked where a person clicks it.
    static func openHeaderShare(tile: UUID, delegate: AppDelegate) async throws -> ShareLinkPopoverView {
        guard let canvas = delegate.canvasView else { throw Failure(description: "no canvas") }
        canvas.centerOnTile(tile)
        // The click lands where the tile is once the camera has arrived.
        for _ in 0..<150 where canvas.isCameraInMotion { try await Task.sleep(for: .milliseconds(16)) }
        canvas.layoutSubtreeIfNeeded()
        guard let view = canvas.tileView(for: tile), let button = view.qaTitleBarShareControl else {
            throw Failure(description: "the agent header shows no Share")
        }
        try ShareEntryChecks.click(button, drawnIn: view.qaTitleBarView)
        guard delegate.shareEntry.isPresented, let popover = delegate.shareEntry.presentedView else {
            throw Failure(description: "the header Share opened no popover")
        }
        popover.layoutSubtreeIfNeeded()
        return popover
    }

    private static var current: MultiplayerDriver?
    static func start(_ preview: MultiplayerPreview, delegate: AppDelegate, window: NSWindow) {
        let driver = MultiplayerDriver(preview: preview, delegate: delegate, window: window)
        current = driver
        driver.run()
    }

    private let preview: MultiplayerPreview
    private weak var delegate: AppDelegate?
    private let window: NSWindow
    private let mailbox: URL
    private var activity: NSObjectProtocol?
    private var shareSession: ShareLinkSession?
    private var observed: (controller: SharedAreaController, token: UUID)?
    private var lastRemote: [UUID: Collaboration.Point] = [:]
    /// Every teammate cursor position this person's controller received, with
    /// the wall-clock time (both apps share this Mac's clock).
    private var arrivals: [[String: Any]] = []
    /// The share links' private pasteboard: the journey never touches the user's.
    private let pasteboard = NSPasteboard(name: .init("dev.arrayapp.multiplayer-driver.\(UUID().uuidString)"))

    private init(preview: MultiplayerPreview, delegate: AppDelegate, window: NSWindow) {
        self.preview = preview; self.delegate = delegate; self.window = window
        mailbox = URL(fileURLWithPath: preview.driver ?? preview.root, isDirectory: true)
    }

    private func run() {
        // Parked: never on a display, never key. A background app is App-Napped;
        // the journey measures latency, so its timers must not be coalesced.
        window.setFrameOrigin(NSPoint(x: -60_000, y: -60_000))
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Array multiplayer journey")
        if let endpoint = URL(string: preview.endpoint), endpoint.scheme == "http" { delegate?.shareLinks.allowsInsecureLoopback = true }
        delegate?.skipGettingStartedForMultiplayer()
        // The journey's app is never active, so AppKit would take each press
        // as an activation click; a person's app is active when they click.
        // The same swizzle the in-process share checks use.
        ShareEntryChecks.acceptFirstMouseEverywhere()
        delegate?.qaInstallShareEntry(pasteboard: pasteboard)
        delegate?.shareEntry.presentsOffscreenForQA = true
        try? write(["label": preview.label, "pid": Int(ProcessInfo.processInfo.processIdentifier)], to: "ready.json")
        Task { [weak self] in
            var next = 1
            while let self {
                let request = mailbox.appendingPathComponent("req-\(next).json")
                if let data = try? Data(contentsOf: request),
                   let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    var response: [String: Any]
                    do { response = try await perform(body); response["ok"] = true }
                    catch { response = ["ok": false, "error": String(describing: error)] }
                    try? write(response, to: "res-\(next).json")
                    next += 1
                    if body["op"] as? String == "quit" { NSApp.terminate(nil); return }
                    continue
                }
                watchZone()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func write(_ object: [String: Any], to name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: mailbox.appendingPathComponent(name), options: .atomic)
    }

    // MARK: - What this person sees

    private var zone: SharedAreaZoneSession? {
        delegate?.qaSharedAreaZoneSessions.sorted { $0.areaId.uuidString < $1.areaId.uuidString }.first
    }

    /// Records teammate cursors the moment this person's controller has them.
    private func watchZone() {
        guard let controller = zone?.controller, observed?.controller !== controller else { return }
        if let observed { observed.controller.removeChangeObserver(observed.token) }
        let token = controller.addChangeObserver { [weak self, weak controller] in
            guard let self, let controller else { return }
            let now = Date().timeIntervalSince1970
            for peer in controller.presence where peer.identity.device != controller.identity.device {
                guard let cursor = peer.cursor, lastRemote[peer.identity.device] != cursor else { continue }
                lastRemote[peer.identity.device] = cursor
                arrivals.append(["x": cursor.x, "y": cursor.y, "t": now])
            }
        }
        observed = (controller, token)
    }

    private func hostTile(_ id: UUID) -> ManagedAgentTileNSView? {
        if let view = delegate?.canvasView?.tileView(for: id) as? ManagedAgentTileNSView { return view }
        func find(_ view: NSView) -> ManagedAgentTileNSView? {
            if let tile = view as? ManagedAgentTileNSView, tile.tile.id == id { return tile }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    /// Mode A: the one shared agent tile on this canvas.
    private var sharedTileRecord: Tile? {
        delegate?.canvasView?.allWorkspaceTiles().first { $0.kind == .sharedAgent }
    }
    private var sharedTile: SharedAgentTileNSView? {
        sharedTileRecord.flatMap { delegate?.canvasView?.tileView(for: $0.id) as? SharedAgentTileNSView }
    }
    private var sharedSession: SharedAgentTileSession? {
        sharedTileRecord.flatMap { delegate?.sharedAgentTileSessions[$0.id] }
    }
    private var liveView: SharedAgentLiveView? { sharedTile?.live ?? zone?.scene.zoneAgentViews.values.first?.live }

    private func eventually(_ label: String, timeout: TimeInterval = 30, _ value: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !value() {
            guard Date() < deadline else { throw Failure(description: "timeout: \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func frameJSON(_ frame: TileFrame?) -> [String: Double]? {
        frame.map { ["x": $0.x, "y": $0.y, "width": $0.width, "height": $0.height] }
    }

    /// Everything a step asserts about this person's canvas, in one read.
    private func snapshot(tile requested: UUID?) -> [String: Any] {
        guard let delegate, let canvas = delegate.canvasView, let runtime = delegate.sharedAreaRuntime else { return [:] }
        var result: [String: Any] = [:]
        let tiles = canvas.allTilesInWorldFrames()
        let records = canvas.allWorkspaceTiles()
        result["tileKinds"] = records.map(\.kind.rawValue)
        result["sharedAgentTiles"] = records.filter { $0.kind == .sharedAgent }.map(\.id.uuidString)
        result["zones"] = runtime.document.zones.map { $0.zoneId.uuidString }
        result["armedZone"] = runtime.document.lastActiveZoneId?.uuidString ?? ""
        result["agentRecords"] = delegate.agentSupervisor.records.count
        result["sharedZoneSessions"] = delegate.qaSharedAreaZoneSessions.filter { !$0.isClosed }.count
        let viewport = canvas.viewport
        result["visibleWorld"] = ["x": viewport.x, "y": viewport.y,
                                  "width": Double(canvas.bounds.width) / viewport.zoom, "height": Double(canvas.bounds.height) / viewport.zoom]
        if let requested {
            result["tileWorld"] = frameJSON(tiles.first { $0.id == requested }?.frame) ?? [:]
            result["tileZone"] = records.first { $0.id == requested }?.zoneId?.uuidString ?? ""
            result["tab"] = canvas.tileView(for: requested)?.qaOwnershipTabText ?? ""
            if let tile = hostTile(requested) {
                result["hostIsManagedAgentTile"] = true
                result["hostHasRunner"] = delegate.agentSupervisor.agent(forTile: tile.tile.id) != nil
            }
        }
        if let record = sharedTileRecord {
            result["sharedTile"] = record.id.uuidString
            result["sharedTileWorld"] = frameJSON(tiles.first { $0.id == record.id }?.frame) ?? [:]
            result["sharedTileZone"] = record.zoneId?.uuidString ?? ""
            if let zone = record.zoneId, let placement = runtime.document.zones.first(where: { $0.zoneId == zone }) {
                result["sharedTileZoneWorld"] = ["x": placement.origin.x, "y": placement.origin.y,
                                                 "width": placement.size.width, "height": placement.size.height]
            }
            if let view = sharedTile {
                result["sharedTab"] = view.qaOwnershipTabText ?? ""
                result["sharedState"] = "\(view.state)"
                result["sharedFooter"] = view.qaFooterText
                result["sharedPlaceholder"] = view.qaPlaceholderText ?? ""
                result["sharedOutlineDashed"] = view.ownershipMark?.dashed ?? false
                result["sharedHasSession"] = view.session != nil
                // Mode A: the guest has no Stop and no approval control.
                let titles = Self.buttonTitles(in: view)
                result["sharedControls"] = titles
            }
            if let live = liveView {
                result["offersComposer"] = live.offersComposer
                result["controlsText"] = live.controlsText
                result["statusText"] = live.statusText
            }
        }
        return result
    }

    private static func buttonTitles(in view: NSView) -> [String] {
        var titles: [String] = []
        if let button = view as? NSButton { titles.append(button.title) }
        if let button = view as? ComposerActionButton { titles.append(button.presentation.title) }
        if let control = view as? NSControl, let label = control.accessibilityLabel() { titles.append(label) }
        for child in view.subviews { titles += buttonTitles(in: child) }
        return titles
    }

    // MARK: - Ops

    private func perform(_ request: [String: Any]) async throws -> [String: Any] {
        guard let delegate, let op = request["op"] as? String else { throw Failure(description: "missing op") }
        let tileArg = (request["tile"] as? String).flatMap(UUID.init(uuidString:))
        switch op {
        case "spawnAgent":
            guard let canvas = delegate.canvasView else { throw Failure(description: "no canvas") }
            let before = Set(canvas.allWorkspaceTiles().map(\.id))
            guard delegate.spawnManagedAgentForHarness(.claudeCode),
                  let tile = canvas.allWorkspaceTiles().map(\.id).first(where: { !before.contains($0) }) else {
                throw Failure(description: "agent did not spawn")
            }
            return ["tile": tile.uuidString]

        case "snapshot":
            return snapshot(tile: tileArg)

        case "headerShare":
            // Step 1: the popover opens on the tile; nothing is published.
            guard let tile = tileArg else { throw Failure(description: "missing tile") }
            let popover = try await Self.openHeaderShare(tile: tile, delegate: delegate)
            let anchored = delegate.shareEntry.qaAnchorView === delegate.canvasView?.tileView(for: tile)
            let result: [String: Any] = ["presented": delegate.shareEntry.isPresented, "anchoredToTile": anchored,
                                         "published": popover.session.area != nil, "title": popover.titleLabelText]
            delegate.shareEntry.dismiss()
            return result

        case "sidebarShare":
            // Step 2: the row's Share is the row action the hover icon fires.
            guard let tile = tileArg, let agent = delegate.agentSupervisor.agent(forTile: tile) else {
                throw Failure(description: "no agent for tile")
            }
            guard delegate.performInboxRowAction(.share, on: [agent.rawValue]) else { throw Failure(description: "row Share refused") }
            try await eventually("the sidebar's popover") { delegate.shareEntry.isPresented }
            let anchored = delegate.shareEntry.qaAnchorView === delegate.canvasView?.tileView(for: tile)
            let target = delegate.shareEntry.presentedView?.session.target.tileIDs.map(\.uuidString) ?? []
            delegate.shareEntry.dismiss()
            return ["presented": true, "anchoredToTile": anchored, "target": target]

        case "share":
            guard let tile = tileArg ?? (request["tiles"] as? [String])?.first.flatMap(UUID.init(uuidString:)) else {
                throw Failure(description: "missing tile")
            }
            let (url, session) = try await Self.share(tile: tile, slug: request["slug"] as? String ?? "journey", delegate: delegate)
            shareSession = session
            delegate.shareEntry.dismiss()
            var items: [String] = []
            if let area = session.area, let model = try? delegate.collaborationAccountModel() {
                let controller = try model.makeSharedAreaController(area: area)
                await controller.open()
                items = controller.document?.items.map(\.kind.rawValue) ?? []
                await controller.close()
            }
            return ["url": url.absoluteString, "pasteboard": pasteboard.string(forType: .string) ?? "",
                    "areaItems": items, "area": session.area?.uuidString ?? ""]

        case "open":
            // Step 4: the link, opened the way macOS hands it to the app.
            guard let raw = request["url"] as? String, let url = URL(string: raw) else { throw Failure(description: "missing url") }
            let opens = delegate.shareLinks.openCount
            delegate.application(NSApp, open: [url])
            try await eventually("the link finished opening", timeout: 90) { delegate.shareLinks.openCount > opens }
            guard case .opened? = delegate.shareLinks.lastOutcome else {
                return ["outcome": "\(delegate.shareLinks.lastOutcome.map { "\($0)" } ?? "none")"]
            }
            if request["expectTile"] as? Bool ?? true {
                do { try await eventually("the shared agent tile is live") { liveView?.offersComposer == true } }
                catch {
                    let seen = snapshot(tile: nil).filter { ["sharedState", "statusText", "controlsText", "sharedHasSession"].contains($0.key) }
                    throw Failure(description: "the shared agent tile is not live: \(seen)")
                }
            }
            return ["outcome": "opened"]

        case "prompt":
            let text = request["text"] as? String ?? ""
            if let id = tileArg {
                guard let tile = hostTile(id) else { throw Failure(description: "host tile missing") }
                tile.qaSubmitPrompt(text)
            } else {
                try await eventually("the shared view offers its composer") { liveView?.offersComposer == true }
                guard let live = liveView else { throw Failure(description: "no shared agent view") }
                live.composer.apply(AgentComposerDraft(text: text, selection: NSRange(location: (text as NSString).length, length: 0), revision: 1))
                live.qaPressSend()
                // Sent: the composer clears once the relay holds it.
                try await eventually("the prompt left the composer", timeout: 30) { live.composer.draft.text.isEmpty }
            }
            return [:]

        case "promptDirect":
            // The composer's own route, used once the composer is gone
            // (sharing stopped): what the relay says to a prompt now.
            guard let session = sharedSession ?? delegate.sharedAgentTileSessions.values.first,
                  let object = session.item?.id ?? Optional(SharedArea.ID<SharedArea.Object>(session.reference.objectId)) else {
                throw Failure(description: "no shared agent session")
            }
            let outcome = await session.prompter.prompt(object: object, text: request["text"] as? String ?? "")
            return ["outcome": "\(outcome)", "message": session.prompter.message,
                    "phase": session.prompter.receipt.map { "\($0.phase)" } ?? ""]

        case "resendLast":
            // Step 7: the same request, same ID, sent again.
            guard let session = sharedSession, let receipt = session.prompter.receipt else {
                throw Failure(description: "no receipt to resend")
            }
            let command = receipt.command
            let again = Collaboration.AgentPromptRequest(id: command.id, epoch: command.epoch, controlRevision: command.controlRevision,
                hostGeneration: command.hostGeneration, text: command.text, mode: command.mode)
            let second = try await session.prompter.transport.send(object: command.object.rawValue, request: again)
            return ["firstID": command.id.uuidString, "secondID": second.command.id.uuidString,
                    "sameCommand": second.command == command, "phase": "\(second.phase)"]

        case "transcript":
            var result: [String: Any] = [:]
            if let id = tileArg, let tile = hostTile(id) {
                result["host"] = tile.qaTranscriptText
                result["hostSenderCards"] = tile.qaSenderCards
            }
            if let id = tileArg, let agent = delegate.agentSupervisor.agent(forTile: id) {
                // The supervisor's own view, to tell a silent runner from a tile that did not paint.
                result["agentRunning"] = delegate.agentSupervisor.isRunning(agent)
                result["agentFinalText"] = delegate.agentSupervisor.qaFinalAssistantText(for: agent) ?? ""
                result["agentRefusal"] = delegate.agentSupervisor.sendRefusal(for: agent) ?? ""
            }
            if let live = liveView {
                result["shared"] = live.transcriptText
                result["lastPrompt"] = live.lastPromptText
            }
            return result

        case "access":
            // Step 9: the host's popover, reopened from the same icon.
            guard let tile = tileArg else { throw Failure(description: "missing tile") }
            let popover = try await Self.openHeaderShare(tile: tile, delegate: delegate)
            try await eventually("the popover lists someone", timeout: 30) {
                popover.layoutSubtreeIfNeeded(); return !popover.qaPeopleRows.isEmpty
            }
            return ["rows": popover.qaPeopleRows, "removeButtons": popover.removeButtons.count,
                    "revokeEveryone": !popover.revokeEveryoneButton.isHidden]

        case "remove":
            guard let popover = delegate.shareEntry.presentedView, let button = popover.removeButtons.first else {
                throw Failure(description: "no Remove in the open popover")
            }
            let before = popover.session.people.count
            try ShareEntryChecks.click(button)
            try await eventually("Remove finished", timeout: 30) { !popover.session.isWorking && popover.session.people.count < before }
            delegate.shareEntry.dismiss()
            return ["people": popover.session.people.map(\.label)]

        case "newLink":
            // Step 10: a fresh link on the same share, Works once.
            guard let tile = tileArg else { throw Failure(description: "missing tile") }
            let popover = try await Self.openHeaderShare(tile: tile, delegate: delegate)
            let session = popover.session
            if session.lifetime != .once { await session.setLifetime(.once) }
            popover.layoutSubtreeIfNeeded()
            let before = "\(session.phase)", title = popover.copyButton.presentation.title
            try ShareEntryChecks.click(popover.copyButton)
            do {
                try await eventually("the new link", timeout: 30) {
                    !session.isWorking && session.link != nil && session.link?.url.absoluteString != (request["previous"] as? String)
                }
            } catch {
                throw Failure(description: "no new link: before \(before), button \(title), now \(session.phase), failure \(session.failure ?? "none")")
            }
            delegate.shareEntry.dismiss()
            guard let link = session.link else { throw Failure(description: "no new link: \(session.failure ?? "")") }
            return ["url": link.url.absoluteString, "lifetime": link.lifetime.rawValue]

        case "stroke":
            // A straight pointer stroke across this person's shared area, as
            // 60 Hz mouse-moved events through the app's own event queue.
            guard let zone else { throw Failure(description: "no shared zone") }
            let overlay = zone.presencePublisher.overlay, scene = zone.scene
            let from = request["from"] as? [Double] ?? [0.2, 0.5], to = request["to"] as? [Double] ?? [0.8, 0.5]
            let steps = request["steps"] as? Int ?? 90
            let inner = overlay.bounds.insetBy(dx: 30, dy: 30)
            guard inner.width > 40, inner.height > 40 else { throw Failure(description: "shared area too small: \(overlay.bounds)") }
            var posted: [[String: Any]] = []
            for i in 0...steps {
                let f = Double(i) / Double(steps)
                let local = NSPoint(x: inner.minX + inner.width * (from[0] + (to[0] - from[0]) * f),
                                    y: inner.minY + inner.height * (from[1] + (to[1] - from[1]) * f))
                let location = overlay.convert(local, to: nil)
                // The area point the publisher's monitor computes for this event.
                let area = scene.areaPoint(forScreenPoint: scene.convert(location, from: nil))
                guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 0, pressure: 0) else { throw Failure(description: "no mouse event") }
                NSApp.postEvent(event, atStart: false)
                posted.append(["x": Double(area.x), "y": Double(area.y), "t": Date().timeIntervalSince1970])
                try await Task.sleep(for: .milliseconds(16))
            }
            return ["posted": posted]

        case "cursors":
            return ["arrivals": arrivals]

        case "revoke":
            await shareSession?.revoke()
            return [:]

        case "quit":
            return [:]

        default:
            throw Failure(description: "unknown op \(op)")
        }
    }
}
