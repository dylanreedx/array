import ContinuumRevivedCore
import Foundation

/// The app-wide PATH story (go-live Phase 4): launched from Finder, the
/// process PATH is the thin launchd default, so `.tool` resolution and every
/// spawned tile/tmux/editor child misses user-level installs of
/// claude/codex/nvim.
///
/// Two stages:
/// 1. `bootstrap()` — synchronous and cheap (string ops plus a few stats):
///    appends the well-known install dirs to the process PATH and exports the
///    result with `setenv`, so everything that inherits the real environ —
///    Ghostty ptys, tmux, `Process` spawns — is fixed in one move. Must run
///    before anything reads `ProcessInfo.processInfo.environment`:
///    NSProcessInfo caches on first access, so an earlier reader would keep
///    the thin PATH for the process lifetime. `bootstrap()` itself reads
///    `getenv` for the same reason.
/// 2. `startLoginShellUpgrade()` — the bounded (1s) `$SHELL -ilc` probe off
///    the main thread; on success the login-shell PATH (ground truth for
///    dotfile-managed installs) leads the merge and is exported again.
///    Children born after the upgrade inherit it via environ, but Swift-side
///    ProcessInfo readers keep the bootstrap snapshot — which is why
///    resolution call sites read `environment()` instead of ProcessInfo.
final class ToolEnvironment: @unchecked Sendable {
    static let shared = ToolEnvironment()

    private let lock = NSLock()
    private var path: String?
    private var upgradeStarted = false

    /// Process environment with the best-known PATH — the seam resolution
    /// call sites use instead of `ProcessInfo.processInfo.environment`.
    func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let path = lock.withLock({ path }) {
            environment["PATH"] = path
        }
        return environment
    }

    func bootstrap() {
        let base = getenv("PATH").map { String(cString: $0) } ?? ""
        let augmented = ToolSearchPath.appending(
            extraDirs: ToolSearchPath.liveWellKnownDirectories(),
            to: base
        )
        setenv("PATH", augmented, 1)
        lock.withLock { path = augmented }
    }

    func startLoginShellUpgrade() {
        let shouldStart = lock.withLock {
            if upgradeStarted { return false }
            upgradeStarted = true
            return true
        }
        guard shouldStart else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard let login = AgentNameOneShot.loginShellPath(environment: self.environment()) else { return }
            let merged = ToolSearchPath.merged(
                loginShellPath: login,
                processPath: self.lock.withLock { self.path } ?? "",
                wellKnown: ToolSearchPath.liveWellKnownDirectories()
            )
            // setenv on the main actor: environ mutation isn't thread-safe
            // against concurrent reads, and tile spawns originate there.
            await MainActor.run {
                setenv("PATH", merged, 1)
            }
            self.lock.withLock { self.path = merged }
        }
    }
}
