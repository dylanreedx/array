import AppKit
import ContinuumRevivedCore

/// `--terminal-tmux-unresponsive-check`: a new terminal must not freeze the app
/// when tmux does not answer.
///
/// Found 2 November 2026 in the multiplayer journey: with tmux persistence on,
/// a terminal spawn hung the app for good. A fresh, ad-hoc-signed build starts a
/// tmux server; the server opens `~/.tmux.conf`, which on Dylan's Mac links into
/// ~/Documents; macOS holds that `open()` on a consent prompt for as long as
/// nobody answers; and `TileSpawner` waits for tmux from the main thread with no
/// deadline. Here a stand-in `tmux` that never answers plays the held server.
/// No real tmux runs, so no tmux server is touched.
///
/// Drives the real spawn path: `TileSpawner.spawnTerminal(profileId:)` with
/// the production `ProcessTmuxControl`. A watchdog off the main thread fails the
/// check if the main thread is still stuck after 20 s.
@MainActor
enum TerminalTmuxUnresponsiveChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(description: label) }
        print("PASS tmux unresponsive: \(label)")
    }

    /// `Self.deadline`, written out so this check also
    /// builds against the code from before the deadline existed (and fails).
    static let deadline: TimeInterval = 5

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-tmux-unresponsive-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin"), projectRoot = root.appendingPathComponent("project")
        // Two stand-ins: an unanswered command keeps its binary "held" for a
        // while, and the spawn must meet a deadline of its own.
        let spawnBin = root.appendingPathComponent("spawn-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: spawnBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Any command waits forever, as a client does whose server is held.
        let fakeTmux = bin.appendingPathComponent("tmux")
        try "#!/bin/sh\nwhile :; do /bin/sleep 1; done\n".write(to: fakeTmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeTmux.path)
        let spawnTmux = spawnBin.appendingPathComponent("tmux")
        try FileManager.default.copyItem(at: fakeTmux, to: spawnTmux)
        func stillRunning() -> Bool {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-f", root.path + "/"]
            pgrep.standardOutput = FileHandle.nullDevice
            try? pgrep.run(); pgrep.waitUntilExit()
            return pgrep.terminationStatus == 0
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            fputs("FAIL: spawning a terminal froze the main thread for 20 s waiting on tmux that never answered\n", stderr)
            Foundation.exit(1)
        }

        // The spawn path, with persistence on and a project session to join.
        let suite = "continuum.tmux-unresponsive-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: TmuxPersistenceConfig.enabledKey)
        defaults.set(spawnTmux.path, forKey: TmuxPersistenceConfig.pathKey)
        let project = Project(id: UUID(), name: "tmux-unresponsive", rootPath: projectRoot.path, createdAt: Date(), updatedAt: Date(),
                              defaultLaunchProfileId: "shell", editorPreference: .auto,
                              settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject,
                                                        terminalClosePolicy: .askWhenRunning))
        let store = ProjectStore(projectRoot: projectRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        canvas.setFrameSize(CGSize(width: 1200, height: 800))
        let spawner = TileSpawner(canvasView: canvas, ghostty: try GhosttyRuntimeContext(), browserEngine: BrowserEngineContext(),
                                  projectStore: store, project: project, defaults: defaults,
                                  tmuxPathResolver: { _ in spawnTmux.path })
        spawner.terminalSessionTargetProvider = { .project(projectId: project.id) }

        let spawnStarted = Date()
        let spawned = spawner.spawnTerminal(profileId: "shell")
        let elapsed = Date().timeIntervalSince(spawnStarted)
        guard case .spawned(let runtime) = spawned else { throw Failure(description: "the terminal did not open: \(spawned)") }
        defer { runtime.terminate(policy: .force) }
        // Its first tmux command meets the deadline; the rest of the pane
        // query fails at once rather than waiting it out again.
        try require(elapsed >= Self.deadline - 0.5 && elapsed < Self.deadline + 3,
                    String(format: "the spawn returned in %.1f s instead of waiting on tmux for good", elapsed))
        try require(runtime.launchProfile.command != spawnTmux.path && !runtime.launchProfile.arguments.contains("attach-session"),
                    "the terminal opened without tmux persistence: \(runtime.launchProfile.command)")
        try require(canvas.allWorkspaceTiles().contains { $0.kind == .terminal }, "its tile is on the canvas")
        try require(!stillRunning(), "no unanswered tmux client is left behind by the spawn")

        // The production control, at its production deadline.
        let control = ProcessTmuxControl(tmuxPath: fakeTmux.path)
        let started = Date()
        let answered = DispatchSemaphore(value: 0)
        let outcome = DirectOutcome()
        Task.detached {
            do { _ = try await control.newSession(name: "array-check", cwd: "/", innerCommand: nil); outcome.set("answered") }
            catch let error as TmuxProcessError { outcome.set(error.exitCode == -2 ? "timedOut" : "failed \(error.exitCode)") }
            catch { outcome.set("\(error)") }
            answered.signal()
        }
        _ = answered.wait(timeout: .now() + 15)
        try require(outcome.value == "timedOut" && Date().timeIntervalSince(started) < Self.deadline + 3,
                    "a tmux command that never answers is stopped at its deadline (\(outcome.value))")
        try require(!stillRunning(), "the unanswered tmux client was stopped, not left behind")

    }

    private final class DirectOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var text = "no answer"
        func set(_ value: String) { lock.lock(); text = value; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }
}
