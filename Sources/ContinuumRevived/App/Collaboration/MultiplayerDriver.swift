import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// `scripts/check-multiplayer-journey.py`: one person in a two-app journey on a
/// real relay. The script writes `req-<n>.json` into the mailbox; this answers
/// `res-<n>.json`. Every op goes through the production path a person's click
/// takes: the Share popover's Copy (`ShareLinkSession.copy`), a link opened by
/// the app (`ShareLinkCoordinator.open`), the real composers, and mouse events
/// posted to the app's own queue for the presence publisher's monitor.
///
/// Only a `MultiplayerPreview` with `driver` set runs this: its own dev bundle
/// id, isolated app support, file vault, fake CLIs, a window parked off every
/// display that never activates.
@MainActor
final class MultiplayerDriver {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// The share step, kept small and swappable: the share redesign replaces
    /// this one function and the journey around it stays the same.
    /// Today: the popover's Copy for these tiles, which converts them into a
    /// shared zone on the relay and mints a link.
    static func share(tiles: [UUID], slug: String, delegate: AppDelegate) async throws -> (url: URL, session: ShareLinkSession) {
        guard let target = delegate.shareTarget(tileIds: tiles, origin: tiles.count == 1 ? .agent : .area) else {
            throw Failure(description: "nothing shareable among \(tiles)")
        }
        let session = ShareLinkSession(target: target, links: delegate.shareLinks,
            zones: delegate.sharedZoneCreator ?? delegate,
            pasteboard: NSPasteboard(name: .init("dev.arrayapp.multiplayer-driver.\(UUID().uuidString)")))
        session.setSlug(slug)
        await session.copy()
        guard let link = session.link else { throw Failure(description: "share failed: \(session.failure ?? "no link")") }
        return (link.url, session)
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

    private var liveView: SharedAgentLiveView? { zone?.scene.zoneAgentViews.values.first?.live }

    private func eventually(_ label: String, timeout: TimeInterval = 30, _ value: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !value() {
            guard Date() < deadline else { throw Failure(description: "timeout: \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Ops

    private func perform(_ request: [String: Any]) async throws -> [String: Any] {
        guard let delegate, let op = request["op"] as? String else { throw Failure(description: "missing op") }
        switch op {
        case "spawnAgent":
            guard let canvas = delegate.canvasView else { throw Failure(description: "no canvas") }
            let before = Set(canvas.allWorkspaceTiles().map(\.id))
            guard delegate.spawnManagedAgentForHarness(.claudeCode),
                  let tile = canvas.allWorkspaceTiles().map(\.id).first(where: { !before.contains($0) }) else {
                throw Failure(description: "agent did not spawn")
            }
            return ["tile": tile.uuidString]

        case "share":
            let tiles = (request["tiles"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
            let (url, session) = try await Self.share(tiles: tiles, slug: request["slug"] as? String ?? "journey", delegate: delegate)
            shareSession = session
            try await eventually("the host's shared zone opened") { zone != nil }
            return ["url": url.absoluteString]

        case "open":
            guard let raw = request["url"] as? String, let url = URL(string: raw) else { throw Failure(description: "missing url") }
            let outcome = await delegate.shareLinks.open(url)
            guard case .opened = outcome else { throw Failure(description: "link did not open: \(outcome)") }
            try await eventually("the guest's shared zone shows the agent") { liveView != nil }
            return ["outcome": "opened"]

        case "prompt":
            let text = request["text"] as? String ?? ""
            if let id = (request["tile"] as? String).flatMap(UUID.init(uuidString:)) {
                guard let tile = hostTile(id) else { throw Failure(description: "host tile missing") }
                tile.qaSubmitPrompt(text)
            } else {
                try await eventually("the shared view offers its composer") { liveView?.offersComposer == true }
                guard let live = liveView else { throw Failure(description: "no shared agent view") }
                live.composer.apply(AgentComposerDraft(text: text, selection: NSRange(location: (text as NSString).length, length: 0), revision: 1))
                live.qaPressSend()
            }
            return [:]

        case "transcript":
            var result: [String: Any] = [:]
            if let id = (request["tile"] as? String).flatMap(UUID.init(uuidString:)), let tile = hostTile(id) {
                result["host"] = tile.qaTranscriptText
                result["hostSenderCards"] = tile.qaSenderCards
            }
            if let id = (request["tile"] as? String).flatMap(UUID.init(uuidString:)), let agent = delegate.agentSupervisor.agent(forTile: id) {
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
