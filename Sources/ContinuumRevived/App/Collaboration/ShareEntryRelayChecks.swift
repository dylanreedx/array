import AppKit
import Darwin
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// A real Share, end to end, against a local `continuum-relay`: the header's
/// Share and the popover's Copy are clicked through `NSApp.sendEvent`, and from
/// there everything is production. `AppDelegate.createSharedZone` creates the
/// area on the relay, publishes, opens its zone and lends the tile with its own
/// view; `ShareLinkCoordinator.createShareLink` mints on the relay. A second
/// share asks for a name the relay already has live, and its 409 must put the
/// tile back. Only the pasteboard (a private one) and the credential vault (in
/// memory) are not the user's.
@MainActor
enum ShareEntryRelayChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(description: "share entry (relay): " + label) }
        print("PASS share entry (relay): \(label)")
    }

    private static func eventually(_ label: String, timeout: TimeInterval = 30, _ value: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if value() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: "share entry (relay): timeout: \(label)")
    }

    // MARK: The local relay

    /// `continuum-relay` on loopback with its own databases and keys, the way
    /// `scripts/check-collaboration-pair.py` runs it.
    private final class Relay {
        let process = Process()
        let port: Int
        let environment: [String: String]
        let executable: URL
        private let log: FileHandle

        init(root: URL) throws {
            executable = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("continuum-relay")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw Failure(description: "build continuum-relay beside Array before this witness (\(executable.path))")
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            port = try Self.freePort()
            func key() -> String { Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString() }
            var env = ProcessInfo.processInfo.environment.filter { name, _ in
                !name.hasPrefix("RELAY_") && !name.hasPrefix("APNS_") && !name.lowercased().hasSuffix("_proxy")
                    && name != "TMUX" && name != "TMUX_PANE"
            }
            env["RELAY_HOST"] = "127.0.0.1"
            env["PORT"] = String(port)
            env["RELAY_ADMIN_PORT"] = String(try Self.freePort())
            env["RELAY_DATABASE_PATH"] = root.appendingPathComponent("relay.sqlite").path
            env["RELAY_MASTER_KEY"] = key()
            env["RELAY_COLLABORATION_DATABASE_PATH"] = root.appendingPathComponent("collaboration.sqlite").path
            env["RELAY_COLLABORATION_MASTER_KEY"] = key()
            environment = env
            let logURL = root.appendingPathComponent("relay.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            log = try FileHandle(forWritingTo: logURL)
        }

        func start() async throws {
            process.executableURL = executable
            process.environment = environment
            process.standardOutput = log
            process.standardError = log
            try process.run()
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                guard process.isRunning else { throw Failure(description: "the local relay exited before it was ready") }
                if Self.accepts(port) { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw Failure(description: "the local relay did not listen on \(port)")
        }

        func stop() {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? log.close()
        }

        private static func loopback(_ port: Int) -> sockaddr_in {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            return address
        }

        static func freePort() throws -> Int {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure(description: "no socket for a free port") }
            defer { close(fd) }
            var address = loopback(0)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0 else { throw Failure(description: "could not bind a free port") }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            return Int(UInt16(bigEndian: address.sin_port))
        }

        static func accepts(_ port: Int) -> Bool {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var address = loopback(port)
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            } == 0
        }
    }

    static func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    // MARK: Run

    static func run() async throws {
        guard let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
            throw Failure(description: "isolated app support required")
        }
        let root = URL(fileURLWithPath: support).appendingPathComponent("share-entry-relay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let relay = try Relay(root: root.appendingPathComponent("relay"))
        defer { relay.stop() }
        try await relay.start()

        let scene = try ShareEntryChecks.mountScene("share-entry-relay")
        defer { scene.close() }
        let canvas = scene.canvas, app = scene.app, window = scene.window
        let agentA = TileInsertSlideChecks.tileA, agentB = TileInsertSlideChecks.tileB
        let home = WorkspaceInvariantsFixture.zoneA1

        // The sender has NO collaboration account: no operator code, no key.
        // The first Share signs them up at the default relay (here, the local
        // one in place of the channel's) with only the name they type.
        let endpoint = try CollaborationServiceEndpoint(URL(string: "http://127.0.0.1:\(relay.port)")!, allowsInsecureLoopback: true)
        let account = try CollaborationAccountController(
            store: .init(applicationSupportRoot: root.appendingPathComponent("account"), bundleIdentifier: nil),
            credentialStore: .init(vault: SharedAreaCheckRig.MemoryVault(), bundleIdentifier: nil), bundleIdentifier: nil)
        try expect(account.accounts.isEmpty && account.status == .signedOut, "the sender starts with no collaboration account")
        app.qaAdoptCollaborationAccount(account)
        app.qaAttachWindowForOfflineCheck(window)
        app.shareLinks.defaultEndpoint = { endpoint }

        // Production services; only the pasteboard is private.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.arrayapp.share-entry-relay.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        app.qaInstallShareEntry(pasteboard: pasteboard)
        app.shareEntry.presentsOffscreenForQA = true
        /// The production name sheet on the canvas window, answered as a
        /// person would: type the name, press Continue.
        var namesAsked = 0
        func answerNameSheet(_ name: String) {
            guard let sheet = window.attachedSheet,
                  let field = Self.views(NSTextField.self, in: sheet.contentView).first(where: { $0.accessibilityLabel() == "Your name" }),
                  let button = Self.views(NSButton.self, in: sheet.contentView).first(where: { $0.title == "Continue" }) else { return }
            namesAsked += 1
            field.stringValue = name
            button.performClick(nil)
        }

        func world(_ id: UUID) -> TileFrame? { canvas.allTilesInWorldFrames().first { $0.id == id }?.frame }
        func share(_ tile: UUID) throws -> ShareLinkPopoverView {
            guard let view = canvas.tileView(for: tile), let button = view.qaTitleBarShareControl else {
                throw Failure(description: "share entry (relay): \(tile) shows no header Share")
            }
            try ShareEntryChecks.click(button, drawnIn: view.qaTitleBarView)
            guard app.shareEntry.isPresented, let popover = app.shareEntry.presentedView else {
                throw Failure(description: "share entry (relay): the header Share opened no popover")
            }
            popover.layoutSubtreeIfNeeded()
            return popover
        }

        // 1. Header share (SHARE-REDESIGN acceptance, mode A step 1): the
        //    popover opens anchored to T; nothing is published and T has not moved.
        let viewA = canvas.tileView(for: agentA)
        let runnersBefore = scene.runnerConstructions()
        let recordA = app.agentSupervisor.records[scene.agents[0]]
        let frameA0 = world(agentA)
        let zonesBefore0 = app.sharedAreaRuntime?.document.zones.count
        let popoverA = try share(agentA)
        try expect(popoverA.session.target.isSingleAgent && popoverA.session.area == nil
            && app.shareEntry.qaAnchorView === viewA && account.activeAccount == nil,
            "step 1: the header Share opens the popover on T, and nothing is published yet")
        try expect(world(agentA) == frameA0 && canvas.tileRecord(for: agentA)?.zoneId == home,
            "step 1: T has not moved")
        app.shareEntry.dismiss()

        // 2. Sidebar share: the row's Share opens the same popover, on T.
        try expect(app.performInboxRowAction(.share, on: [scene.agents[0].rawValue]), "step 2: the sidebar row offers Share")
        try await eventually("step 2: the sidebar's popover") { app.shareEntry.isPresented }
        try expect(app.shareEntry.qaAnchorView === canvas.tileView(for: agentA)
            && app.shareEntry.presentedView?.session.target.tileIDs == [agentA],
            "step 2: the sidebar's Share opens the same popover, anchored to T on the canvas")
        app.shareEntry.dismiss()

        // 3. Copy: a link on the pasteboard; the relay's area holds exactly
        //    T's observation; T's zone and frame are unchanged; no new zone.
        let popoverA2 = try share(agentA)
        try ShareEntryChecks.click(popoverA2.copyButton)
        try await eventually("the first share finishes") {
            answerNameSheet("QA Dylan")
            return !popoverA2.session.isWorking && (popoverA2.session.phase != .draft || popoverA2.session.failure != nil)
        }
        try expect(popoverA2.session.failure == nil, "the first Copy succeeds against the relay (\(popoverA2.session.failure ?? ""))")
        try expect(namesAsked == 1 && account.status == .ready && account.activeAccount?.label == "QA Dylan"
            && account.activeAccount?.endpoint == endpoint.canonicalString && account.accounts.count == 1,
            "the first Share on a Mac with no account signs up at the default relay with one name sheet: no code, no key")
        guard let linkA = popoverA2.session.link, let areaA = popoverA2.session.area else {
            throw Failure(description: "share entry (relay): Copy made no link")
        }
        let copied = pasteboard.string(forType: .string)
        try expect(copied == linkA.url.absoluteString && linkA.slug == "map-the-checkout-state-machine"
            && ShareLinkURL.parse(linkA.url)?.slug == linkA.slug && ShareLinkURL.parse(linkA.url)?.token == linkA.token,
            "step 3: Copy puts the relay's link, with its slug and token, on the pasteboard (\(copied ?? "nothing"))")
        let areaController = try account.makeSharedAreaController(area: areaA)
        await areaController.open()
        let published = areaController.document?.items ?? []
        await areaController.close()
        try expect(published.count == 1 && published.first?.kind == .agentObservation,
            "step 3: the relay's area holds exactly one item, T's agent observation (\(published.map(\.kind)))")
        try expect(world(agentA) == frameA0 && canvas.tileRecord(for: agentA)?.zoneId == home
            && canvas.lentTile(agentA) == nil && canvas.tileView(for: agentA) === viewA,
            "step 3: T's zone and world frame are unchanged, and it keeps its own view")
        try expect(app.sharedAreaRuntime?.document.zones.count == zonesBefore0
            && app.sharedAreaRuntime?.sharedAreaZone(for: areaA) == nil && app.qaSharedAreaZoneSessions.isEmpty,
            "step 3: the workspace document has no new zone")
        try expect(scene.runnerConstructions() == runnersBefore
            && app.agentSupervisor.records[scene.agents[0]]?.tileId == recordA?.tileId,
            "the share builds no runner and keeps the agent bound to its tile")
        try expect(app.sharedAreaHostSessions.keys.contains { $0.hasSuffix("/" + areaA.uuidString) }
            && app.hostedAgentArea(forTile: agentA) == areaA,
            "this Mac hosts the shared agent, and remembers which area it is shared through")
        let access = try await app.shareLinks.listAccess(area: areaA)
        try expect(access.contains { $0.id == linkA.id && $0.status == .active },
            "the relay lists the minted link as active")
        try expect(canvas.tileView(for: agentA)?.qaOwnershipTabText == "Yours · shared",
            "T's tab reads \"Yours · shared\" (\(canvas.tileView(for: agentA)?.qaOwnershipTabText ?? "none"))")
        app.shareEntry.dismiss()

        // 3a. A taken name: the relay refuses the link, and the agent is
        //     neither published nor hosted. Nothing moved in the first place.
        canvas.setViewport(CanvasViewport(x: 300, y: 250, zoom: 1))
        canvas.layoutSubtreeIfNeeded()
        let viewB = canvas.tileView(for: agentB)
        let frameB = world(agentB)
        let zonesBefore = app.sharedAreaRuntime?.document.zones.count
        let popoverB = try share(agentB)
        popoverB.slugField.stringValue = linkA.slug
        try ShareEntryChecks.click(popoverB.copyButton)
        try await eventually("the refused share settles") { !popoverB.session.isWorking && popoverB.session.failure != nil }
        try expect(popoverB.session.failure == ShareLinkFailure.slugTaken.errorDescription && popoverB.session.link == nil,
            "the relay's 409 is shown in the popover")
        try expect(namesAsked == 1, "a Mac with an account reuses it: the second Share asks for no name")
        try expect(canvas.tileRecord(for: agentB)?.zoneId == home && canvas.tileView(for: agentB) === viewB
            && world(agentB) == frameB && app.hostedAgentArea(forTile: agentB) == nil,
            "the refused share leaves B where it was and does not host it")
        try expect(app.sharedAreaRuntime?.document.zones.count == zonesBefore && app.hostedAgentArea(forTile: agentA) == areaA,
            "the refused share leaves no zone behind and the first share untouched")
        try expect(pasteboard.string(forType: .string) == linkA.url.absoluteString,
            "a refused share copies nothing")
        _ = window

        // 3. Opening a link: each way it can fail says why, in plain words.
        //    The production opener, a newcomer's own account, the same relay.
        var opened: [UUID] = []
        func open(_ url: URL, as name: String, insecureLoopback: Bool) async throws -> ShareLinkOpener.Outcome {
            let newcomer = try CollaborationAccountController(
                store: .init(applicationSupportRoot: root.appendingPathComponent("newcomer-\(UUID().uuidString)"), bundleIdentifier: nil),
                credentialStore: .init(vault: SharedAreaCheckRig.MemoryVault(), bundleIdentifier: nil), bundleIdentifier: nil)
            let opener = ShareLinkOpener(account: newcomer, signIn: { _ in false }, askName: { _, _ in name },
                                         open: { state, _ in opened.append(state.document.id.rawValue) },
                                         deviceLabel: "QA \(name)'s Mac", allowsInsecureLoopback: insecureLoopback)
            return await opener.open(url)
        }
        let secure = try await open(linkA.url, as: "Sam", insecureLoopback: false)
        try expect(secure == .refused(ShareLinkOpener.message(for: URLError(.secureConnectionFailed), relay: "127.0.0.1:\(relay.port)"))
            && "\(secure)".contains("secure connection"),
            "a link whose relay answers without TLS says the secure connection failed (\(secure))")
        let silent = try Relay.freePort()
        let unreachable = try await open(ShareLinkURL.web(slug: linkA.slug, token: linkA.token, relay: "127.0.0.1:\(silent)"),
                                         as: "Sam", insecureLoopback: true)
        try expect("\(unreachable)".contains("could not reach the relay at 127.0.0.1:\(silent)"),
            "a link whose relay is not running says the relay could not be reached (\(unreachable))")
        // 3b. A shared agent is reachable from the sidebar, and the band's
        //     controls beat its resize edge. A fresh coordinator, as after a relaunch.
        app.qaInstallShareEntry(pasteboard: pasteboard)
        app.shareEntry.presentsOffscreenForQA = true
        try expect(app.performInboxRowAction(.share, on: [scene.agents[0].rawValue]),
            "the sidebar's Share on a shared agent opens it rather than refusing")
        try await eventually("the sidebar's popover for the shared agent") { app.shareEntry.presentedView?.session.target.area == areaA }
        app.shareEntry.dismiss()
        /// A press at a point of the Share button, given in the title bar, the
        /// way a pointer reaches it: through the window.
        /// The top resize band is 8 screen points deep, and Share starts about 3
        /// below the tile's top edge: its top few points sit inside the band at
        /// every zoom up to 1, more as the camera pulls out (measured on these
        /// 360-wide tiles: Share shows from 0.85, top 3.6 vs band 9.4). The
        /// press goes midway between Share's top and the band's bottom, at the
        /// lowest zoom from 0.5 up where Share shows.
        func press(_ tile: UUID) throws -> (zoom: Double, presented: Bool) {
            guard let frame = canvas.navigationTileSnapshot(for: tile)?.worldFrame else {
                throw Failure(description: "share entry (relay): \(tile) is not navigable")
            }
            var found: (zoom: Double, view: TileNSView, bar: NSView, point: NSPoint)?
            for step in 0..<10 where found == nil {
                let zoom = 0.5 + Double(step) * 0.05
                canvas.setViewport(CanvasViewport(x: frame.x - 200, y: frame.y - 200, zoom: zoom))
                canvas.layoutSubtreeIfNeeded()
                guard let view = canvas.tileView(for: tile), let bar = view.qaTitleBarView, let button = view.qaTitleBarShareControl else { continue }
                let bandBottom = view.convert(NSPoint(x: 0, y: view.resizeMarginInLocalCoordinates), to: bar).y
                let barPoint = NSPoint(x: button.frame.midX, y: (button.frame.minY + min(button.frame.maxY, bandBottom)) / 2)
                if view.qaResizeEdge(at: view.convert(barPoint, from: bar)) != nil { found = (zoom, view, bar, barPoint) }
            }
            guard let (zoom, _, bar, barPoint) = found else {
                throw Failure(description: "share entry (relay): no zoom from 0.5 shows \(tile)'s Share under the resize band")
            }
            let windowPoint = bar.convert(barPoint, to: nil)
            NSApp.postEvent(try ShareEntryChecks.mouse(.leftMouseUp, windowPoint, in: window), atStart: false)
            NSApp.sendEvent(try ShareEntryChecks.mouse(.leftMouseDown, windowPoint, in: window))
            while let pending = NSApp.nextEvent(matching: [.leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(pending)
            }
            let presented = app.shareEntry.isPresented
            app.shareEntry.dismiss()
            return (zoom, presented)
        }
        let sharedPress = try press(agentA)
        try expect(sharedPress.presented,
            "at zoom \(sharedPress.zoom) a press on the top of a shared agent's Share, inside the resize band, opens the popover")
        let homePress = try press(agentB)
        try expect(homePress.presented,
            "at zoom \(homePress.zoom) the same press on an unshared agent's Share opens its popover too")
        canvas.setViewport(CanvasViewport(x: 300, y: 250, zoom: 1))
        canvas.layoutSubtreeIfNeeded()

        // 4. A is already shared. After a relaunch (a fresh share coordinator:
        //    no session holds the link's token), its header Share opens that
        //    area's popover rather than a second share.
        canvas.centerOnTile(agentA)
        canvas.layoutSubtreeIfNeeded()
        app.qaInstallShareEntry(pasteboard: pasteboard)
        app.shareEntry.presentsOffscreenForQA = true
        let existing = try share(agentA)
        try expect(existing.session.target.area == areaA && existing.session.phase == .existing(area: areaA)
            && existing.copyButton.presentation.title == "New link",
            "an already-shared agent's header Share opens its area's popover, offering New link")
        try await eventually("the area's links are read") { existing.session.liveRows.map(\.id) == [linkA.id] }
        existing.layoutSubtreeIfNeeded()
        try expect(!existing.revokeButton.isHidden && existing.session.people.isEmpty,
            "with nobody admitted yet it lists the live link and offers Revoke link")

        // 5. Live: Sam opens the link while the popover is open.
        let first = try await open(linkA.url, as: "Sam", insecureLoopback: true)
        try expect(first == .opened(area: areaA) && opened == [areaA], "the Works once link admits its first newcomer")
        let spent = try await open(linkA.url, as: "Priya", insecureLoopback: true)
        try expect(spent == .refused(ShareLinkOpener.refusedMessage), "a spent Works once link says it was already used or revoked")
        try await eventually("the open popover sees Sam join") { existing.session.people.map(\.label) == ["Sam"] }
        existing.layoutSubtreeIfNeeded()
        try expect(existing.revokeButton.isHidden && !existing.revokeEveryoneButton.isHidden && existing.removeButtons.count == 1,
            "without reopening, the popover lists Sam with Remove and offers Revoke everyone's access")
        try await eventually("T's tab names Sam") { canvas.tileView(for: agentA)?.qaOwnershipTabText == "Yours · shared with Sam" }
        try expect(true, "once Sam has joined, T's tab reads \"Yours · shared with Sam\"")
        try ShareEntryChecks.click(existing.copyButton)
        try await eventually("New link on the shared area") { !existing.session.isWorking && existing.session.link != nil }
        let fresh = existing.session.link
        try expect(fresh?.area.rawValue == areaA && fresh?.id != linkA.id && pasteboard.string(forType: .string) == linkA.url.absoluteString,
            "New link mints a second link on the same area (\(existing.session.failure ?? ""))")
        try ShareEntryChecks.click(existing.currentRevokeButton)
        try await eventually("revoke everyone") { !existing.session.isWorking && existing.session.phase == .revoked(area: areaA) }
        let afterRevoke = try await app.shareLinks.listAccess(area: areaA)
        try expect(afterRevoke.allSatisfy { $0.status == .revoked } && afterRevoke.flatMap(\.people).allSatisfy { !$0.active },
            "Revoke everyone's access ends every link on the area and Sam's access")
        app.shareEntry.dismiss()
        let revokable = try await app.shareLinks.createShareLink(area: areaA, slug: "revoked-checkout-link", lifetime: .untilRevoked)
        try await app.shareLinks.revokeLink(area: areaA, link: revokable.id)
        let revoked = try await open(revokable.url, as: "Priya", insecureLoopback: true)
        try expect(revoked == .refused(ShareLinkOpener.refusedMessage), "a revoked link says it was already used or revoked")
        print("Share entry relay checks passed: a header Share and Copy against a local continuum-relay share one agent with no zone and nothing moved, a slug collision shares nothing, and a link that cannot open says why.")
    }
}
