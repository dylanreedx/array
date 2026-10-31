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

        /// The operator's one-time enrollment code for a new person.
        func enroll(_ label: String) throws -> String {
            let run = Process(), out = Pipe()
            run.executableURL = executable
            run.arguments = ["--collaboration-enroll", label]
            run.environment = environment
            run.standardOutput = out
            run.standardError = log
            try run.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            run.waitUntilExit()
            guard run.terminationStatus == 0,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = object["code"] as? String else {
                throw Failure(description: "relay enrollment failed (\(run.terminationStatus))")
            }
            return code
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

    // MARK: Run

    static func run() async throws {
        guard let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
            throw Failure(description: "isolated app support required")
        }
        let root = URL(fileURLWithPath: support).appendingPathComponent("share-entry-relay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let relay = try Relay(root: root.appendingPathComponent("relay"))
        defer { relay.stop() }
        let code = try relay.enroll("QA Dylan")
        try await relay.start()

        let scene = try ShareEntryChecks.mountScene("share-entry-relay")
        defer { scene.close() }
        let canvas = scene.canvas, app = scene.app, window = scene.window
        let agentA = TileInsertSlideChecks.tileA, agentB = TileInsertSlideChecks.tileB
        let home = WorkspaceInvariantsFixture.zoneA1

        // The sender's real collaboration account, enrolled over HTTP.
        let endpoint = try CollaborationServiceEndpoint(URL(string: "http://127.0.0.1:\(relay.port)")!, allowsInsecureLoopback: true)
        let account = try CollaborationAccountController(
            store: .init(applicationSupportRoot: root.appendingPathComponent("account"), bundleIdentifier: nil),
            credentialStore: .init(vault: SharedAreaCheckRig.MemoryVault(), bundleIdentifier: nil), bundleIdentifier: nil)
        _ = try await account.enroll(endpoint: endpoint, code: code, deviceLabel: "QA Mac", accountLabel: "QA Dylan")
        try expect(account.status == .ready, "the sender enrolls against the local relay")
        app.qaAdoptCollaborationAccount(account)

        // Production services; only the pasteboard is private.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.arrayapp.share-entry-relay.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        app.qaInstallShareEntry(pasteboard: pasteboard)
        app.shareEntry.presentsOffscreenForQA = true

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

        // 1. A real Share: header, then Copy.
        let viewA = canvas.tileView(for: agentA)
        let runnersBefore = scene.runnerConstructions()
        let recordA = app.agentSupervisor.records[scene.agents[0]]
        let popoverA = try share(agentA)
        try ShareEntryChecks.click(popoverA.copyButton)
        try await eventually("the first share finishes") { !popoverA.session.isWorking && (popoverA.session.phase != .draft || popoverA.session.failure != nil) }
        try expect(popoverA.session.failure == nil, "the first Copy succeeds against the relay (\(popoverA.session.failure ?? ""))")
        guard let linkA = popoverA.session.link, let areaA = popoverA.session.area,
              let zoneA = app.sharedAreaRuntime?.sharedAreaZone(for: areaA) else {
            throw Failure(description: "share entry (relay): Copy made no link or no shared zone")
        }
        try expect(zoneA.projectId == nil && canvas.lentTile(agentA)?.zoneId == zoneA.zoneId
            && canvas.tileView(for: agentA) === viewA,
            "the agent's tile becomes the shared zone with its own view")
        try expect(scene.runnerConstructions() == runnersBefore
            && app.agentSupervisor.records[scene.agents[0]]?.tileId == recordA?.tileId,
            "the share builds no runner and keeps the agent bound to its tile")
        let published = app.qaSharedAreaZoneSessions.first { $0.areaId == areaA }?.controller.document?.items ?? []
        try expect(published.contains { $0.kind == .agentObservation },
            "the relay's area holds the agent as an observation")
        let copied = pasteboard.string(forType: .string)
        try expect(copied == linkA.url.absoluteString && linkA.slug == "map-the-checkout-state-machine"
            && ShareLinkURL.parse(linkA.url)?.slug == linkA.slug && ShareLinkURL.parse(linkA.url)?.token == linkA.token,
            "Copy puts the relay's link, with its slug and token, on the pasteboard (\(copied ?? "nothing"))")
        let access = try await app.shareLinks.listAccess(area: areaA)
        try expect(access.contains { $0.id == linkA.id && $0.status == .active },
            "the relay lists the minted link as active")
        app.shareEntry.dismiss()

        // 2. A taken name: the relay refuses the link and the tile goes home.
        //    Opening the first share revealed its zone; pan back to B, as a
        //    person would before pressing its Share.
        canvas.setViewport(CanvasViewport(x: 300, y: 250, zoom: 1))
        canvas.layoutSubtreeIfNeeded()
        let viewB = canvas.tileView(for: agentB)
        let frameB = world(agentB)
        let zonesBefore = app.sharedAreaRuntime?.document.zones.filter { $0.projectId == nil }.count
        let popoverB = try share(agentB)
        popoverB.slugField.stringValue = linkA.slug
        try ShareEntryChecks.click(popoverB.copyButton)
        try await eventually("the refused share settles") { !popoverB.session.isWorking && popoverB.session.failure != nil }
        try expect(popoverB.session.failure == ShareLinkFailure.slugTaken.errorDescription && popoverB.session.link == nil,
            "the relay's 409 is shown in the popover")
        try expect(canvas.lentTile(agentB) == nil && canvas.tileRecord(for: agentB)?.zoneId == home
            && canvas.tileView(for: agentB) === viewB && world(agentB) == frameB,
            "the refused share puts the tile back in its home zone, same view, same frame")
        try expect(app.sharedAreaRuntime?.document.zones.filter { $0.projectId == nil }.count == zonesBefore
            && canvas.lentTile(agentA)?.zoneId == zoneA.zoneId,
            "the refused share leaves no zone behind and the first share untouched")
        try expect(pasteboard.string(forType: .string) == linkA.url.absoluteString,
            "a refused share copies nothing")
        _ = window
        print("Share entry relay checks passed: a header Share and Copy against a local continuum-relay make the real shared zone and link, and a slug collision puts the tile back.")
    }
}
