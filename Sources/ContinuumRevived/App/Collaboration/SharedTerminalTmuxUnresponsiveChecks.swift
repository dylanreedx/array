import AppKit
import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient

/// `--shared-terminal-tmux-unresponsive-check` (`.plans/114-terminal-sharing`):
/// sharing a terminal must not freeze the app when tmux never answers.
///
/// Found 2 November 2026: starting a terminal's share looked up the tile's
/// tmux pane with `tmux display-message`, on the main thread, with no
/// deadline. A brand-new tmux server can hold its first client for as long as
/// nobody answers (Dylan's `~/.tmux.conf` runs tpm; a macOS consent prompt for
/// a config in ~/Documents does the same), and the whole app froze. The
/// journeys missed it because they start tmux with `-f /dev/null`.
///
/// A stand-in `tmux` that never answers plays the held server; no real tmux
/// runs, so no tmux server is touched. Drives the production host path:
/// `LiveTileHost.start()` over a `TerminalLiveSource` built as
/// `makeLiveTileSource` builds it. A watchdog off the main thread fails the
/// check the moment the main thread stops answering for 5 s.
@MainActor
enum SharedTerminalTmuxUnresponsiveChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(description: label) }
        print("PASS shared terminal tmux unresponsive: \(label)")
    }

    /// `TerminalTmuxTap.locateDeadline`, written out so this check also builds
    /// against the code from before the deadline existed (and fails).
    static let deadline: TimeInterval = 3

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-share-tmux-unresponsive-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeTmux = bin.appendingPathComponent("tmux")
        // Any command waits forever, as a client does whose server is held.
        try "#!/bin/sh\nwhile :; do /bin/sleep 1; done\n".write(to: fakeTmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeTmux.path)
        func standInsRunning() -> Bool {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-f", bin.path + "/"]
            pgrep.standardOutput = FileHandle.nullDevice
            try? pgrep.run(); pgrep.waitUntilExit()
            return pgrep.terminationStatus == 0
        }

        // The watchdog: the main thread ticks a clock; a thread of its own
        // fails the check if the clock stops for 5 s.
        let clock = MainClock()
        let ticker = Timer(timeInterval: 0.05, repeats: true) { _ in clock.tick() }
        RunLoop.main.add(ticker, forMode: .common)
        defer { ticker.invalidate() }
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                if clock.sinceTick > 5 {
                    fputs("FAIL: sharing a terminal froze the main thread for 5 s waiting on tmux that never answered\n", stderr)
                    Foundation.exit(1)
                }
            }
        }

        // The production source and host. The controller never connects (its
        // transport refuses), so only the tap is exercised.
        let tile = UUID()
        let identity = Collaboration.Identity(person: .init(), device: UUID())
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://shared-terminal-tmux.example.test")!)
        let credentials = CollaborationCredentialStore(vault: MemoryVault(), bundleIdentifier: nil)
        let scope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
        try credentials.save(.init(identity: identity, token: "scripted-shared-terminal-only"), for: scope)
        let area = SharedArea.ID<SharedArea.Area>()
        let cache = try SharedAreaLocalStore(applicationSupportRoot: root.appendingPathComponent("support"), bundleIdentifier: nil,
                                             endpoint: endpoint, person: identity.person, area: area)
        let controller = try SharedAreaController(localStore: cache, credentialStore: credentials, credentialScope: scope,
            bundleIdentifier: nil, transportFactory: { _, _, _ in throw Failure(description: "offline") })
        let visible = "host$ make test\nall green"
        let source = TerminalLiveSource(text: { visible }, title: { "Avery's Terminal" }, palette: nil,
                                        tapTarget: { (fakeTmux.path, tile) })
        let binding = SharedAreaLocalSourceBinding(object: .init(), binding: .init(), host: .init(), projectID: UUID(), tileID: tile)
        let host = LiveTileHost(binding: binding, source: source, controller: controller)

        let started = Date()
        host.start()
        let startTook = Date().timeIntervalSince(started)
        try require(startTook < 0.5, String(format: "starting the share returned in %.2f s, not after tmux answered", startTook))

        // The main thread keeps answering while tmux doesn't.
        var tap = ""
        let waitStarted = Date()
        while Date().timeIntervalSince(waitStarted) < deadline + 4 {
            tap = source.facts["streamTap"] as? String ?? ""
            if tap == "tmux not answering" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let waited = Date().timeIntervalSince(waitStarted)
        try require(tap == "tmux not answering", "the share gives up on tmux and says so (tap: \(tap))")
        try require(waited >= deadline - 0.5 && waited < deadline + 2,
                    String(format: "it gave up at its %.0f s deadline (%.1f s)", deadline, waited))
        try require(clock.longestGap < 0.5, String(format: "the main thread never stalled meanwhile (longest gap %.2f s)", clock.longestGap))

        // The share keeps going on the visible text.
        guard case .terminal(let terminal)? = await source.payload(eventsThrough: 0) else {
            throw Failure(description: "the share published nothing while tmux was held")
        }
        try require(terminal.text == visible && terminal.screen == nil && terminal.title == "Avery's Terminal",
                    "meanwhile the share carries the terminal's visible text")

        // Nothing is left waiting on the held tmux.
        try await Task.sleep(for: .milliseconds(1500))
        try require(!standInsRunning(), "the unanswered tmux client was stopped, not left behind")
        host.stop()
        try await Task.sleep(for: .milliseconds(300))
        try require(!standInsRunning() && clock.longestGap < 0.5, "stopping the share leaves nothing running")
    }

    private final class MainClock: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        private var longest: TimeInterval = 0
        func tick() {
            lock.lock(); let now = Date(); longest = max(longest, now.timeIntervalSince(last)); last = now; lock.unlock()
        }
        var sinceTick: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
        var longestGap: TimeInterval { lock.lock(); defer { lock.unlock() }; return max(longest, Date().timeIntervalSince(last)) }
    }

    private final class MemoryVault: CollaborationCredentialVault, @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Data] = [:]
        func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
        func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
        func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
    }
}
