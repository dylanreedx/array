import Foundation

#if os(macOS)

/// The one gate every automated check that drives a real tmux server must pass
/// first — three sections of `ContinuumRevivedCoreChecks` and the app's live
/// tmux integration self-check.
///
/// Those sections issue `new-session`, `list-sessions`, `kill-session`,
/// `kill-window`. On the DEFAULT socket that server is the one
/// hosting a running Array's terminal tiles, and pulling its sessions kills those
/// tiles, which closes the last window, which quits the app: a clean exit that
/// writes no crash report and is indistinguishable from a crash from the outside.
/// That happened twice on 2026-08-12 while Dylan was working, caused by these
/// checks.
///
/// AGENTS.md ("Never touch the live tmux server from automated checks") requires a
/// disposable socket namespace, an unset inherited client env, and a VERIFIED
/// socket path — and says a check that cannot honor that must be left unverified
/// rather than touch the live server. So this fails closed in both directions: no
/// disposable `TMUX_TMPDIR`, no tmux; and no proof tmux actually opened its socket
/// in there, still no tmux. `scripts/run-matrix.sh` exports the namespace for the
/// whole matrix, so the isolated path is the one that normally runs.
public enum TmuxIsolation {
    public enum Outcome {
        /// Safe to drive: tmux exists AND opened its socket inside the disposable dir.
        case ready(tmuxPath: String, socketDir: String, socketPath: String)
        /// tmux is not installed. Sections report this as `tmux_absent`.
        case tmuxAbsent
        /// Refusing: the namespace is missing, not disposable, or not honored.
        case notIsolated(reason: String)
    }

    /// `TMUX_TMPDIR` pointing somewhere disposable, with no inherited tmux client.
    /// An inherited `TMUX` means we are running INSIDE someone's tmux, which is
    /// exactly the session we must not disturb.
    public static func disposableSocketDir(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let dir = environment["TMUX_TMPDIR"],
              !dir.isEmpty,
              dir.hasPrefix("/tmp/") || dir.hasPrefix("/private/tmp/") || dir.hasPrefix("/var/folders/"),
              environment["TMUX"] == nil
        else { return nil }
        return dir
    }

    public static func resolve() -> Outcome {
        guard let socketDir = disposableSocketDir() else {
            return .notIsolated(reason: "TMUX_TMPDIR is unset or not disposable")
        }
        guard let tmuxPath = TmuxLocator.resolve() else { return .tmuxAbsent }
        guard let socketPath = startedServerSocketPath(tmuxPath: tmuxPath, socketDir: socketDir) else {
            return .notIsolated(reason: "tmux did not open its socket inside \(socketDir)")
        }
        return .ready(tmuxPath: tmuxPath, socketDir: socketDir, socketPath: socketPath)
    }

    /// Asks tmux itself which socket it is talking to, and returns it only when it
    /// is inside `socketDir`. The env var is an instruction, not a fact; an
    /// instruction tmux declined would otherwise read as isolation while every
    /// later command went to the live server. `start-server` creates no sessions
    /// and mutates nothing, and `display-message -p` is a read — so asking is safe
    /// even when the answer turns out to be "the live one".
    ///
    /// Both sides are canonicalized before comparing: tmux reports the `/private`
    /// form of `/tmp` and `/var` while the environment carries the short form, and
    /// Foundation's `resolvingSymlinksInPath()` normalizes toward the SHORT one —
    /// it strips `/private` rather than adding it, so canonicalizing only the
    /// directory silently never matches.
    private static func startedServerSocketPath(tmuxPath: String, socketDir: String) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["start-server", ";", "display-message", "-p", "#{socket_path}"]
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let reported = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reported.isEmpty else { return nil }
        let canonicalDir = URL(fileURLWithPath: socketDir, isDirectory: true).resolvingSymlinksInPath().path
        let canonicalSocket = URL(fileURLWithPath: reported).resolvingSymlinksInPath().path
        guard canonicalSocket.hasPrefix(canonicalDir + "/") else { return nil }
        return reported
    }
}

#endif
