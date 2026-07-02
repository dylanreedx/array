import Foundation

// Ticket: docs/38-tickets/12-injectable-substrates.md
//
// The real `TmuxControl` implementation, backed by an actual tmux subprocess via
// `Process`. Kept in its own file so `Foundation.Process` never appears on the
// public surface of `TmuxControl.swift` — every public member of this type still
// only speaks in the protocol's vocabulary (String/Bool/[TmuxSessionInfo]).
//
// `TmuxSession`/`TmuxLocator` (TmuxSession.swift) stay pure and tile-keyed
// (tileId -> session name, LaunchProfile in/out) — they are unchanged by this
// ticket (a hard "Done when" constraint: "TmuxSession.swift and TmuxLocator
// are unchanged"). `TmuxControl.newSession(name:cwd:innerCommand:)` takes a
// caller-supplied `String` session name and returns a captured pane id from a
// headless `-d` spawn — a different shape from `TmuxSession.wrap`, which is
// tile-keyed (`tileId: UUID` -> `LaunchProfile`) and builds an `-A`
// attach-or-create argv meant to be run interactively under a pty (the
// terminal tile's own live process), not captured headless via `Process`.
// Neither `TmuxSession.sessionName(tileId:)` nor `TmuxSession.wrap` can be
// called from here without either adding a `tileId` to this tile-agnostic
// protocol (breaking the protocol shape specified by this same ticket) or
// changing `TmuxSession.swift` (forbidden by the ticket). So
// `ProcessTmuxControl` builds its own argv directly, using the same tmux CLI
// conventions (`-s`/`-c`/`-t` flags) as `TmuxSession`, rather than routing
// through the tile-shaped helpers, whose signatures do not fit a
// tile-agnostic caller.
public struct TmuxProcessError: Error, Equatable {
    public let arguments: [String]
    public let exitCode: Int32
    public let stderr: String
}

public final class ProcessTmuxControl: TmuxControl, @unchecked Sendable {
    private let tmuxPath: String

    public init(tmuxPath: String) {
        self.tmuxPath = tmuxPath
    }

    public func newSession(name: String, cwd: String, innerCommand: [String]?) async throws -> String {
        var arguments = ["new-session", "-d", "-P", "-F", "#{pane_id}", "-s", name, "-c", cwd]
        if let innerCommand, !innerCommand.isEmpty {
            arguments.append(contentsOf: innerCommand)
        }
        let result = try run(arguments)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func newWindow(inSession: String, cwd: String, innerCommand: [String]?) async throws -> String {
        var arguments = ["new-window", "-P", "-F", "#{pane_id}", "-t", inSession, "-c", cwd]
        if let innerCommand, !innerCommand.isEmpty {
            arguments.append(contentsOf: innerCommand)
        }
        let result = try run(arguments)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func killWindow(target: String) async throws {
        _ = try run(["kill-window", "-t", target])
    }

    public func killSession(name: String) async throws {
        _ = try run(["kill-session", "-t", name])
    }

    public func detachSession(name: String) async throws {
        // Best-effort: a session spawned headless (as this ticket's real-path
        // check does) has no attached client, so tmux's "no client attached"
        // failure here is expected, not an error — swallow it rather than
        // surface a false failure for the common no-op case.
        _ = try? run(["detach-client", "-s", name])
    }

    public func sessionExists(name: String) async throws -> Bool {
        runIgnoringFailure(["has-session", "-t", name]).exitCode == 0
    }

    public func isAlive(paneTarget: String) async throws -> Bool {
        // `display-message -t <pane_id>` is unreliable for this: with no client
        // attached (the common headless case), tmux can exit 0 with empty
        // output for a target that no longer exists rather than failing. List
        // every live pane instead and check for an exact match.
        let result = runIgnoringFailure(["list-panes", "-a", "-F", "#{pane_id}"])
        guard result.exitCode == 0 else { return false }  // no server running
        let livePaneIds = result.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return livePaneIds.contains(paneTarget)
    }

    public func paneCurrentPath(paneTarget: String) async throws -> String {
        // Same unreliable-target problem as `isAlive`: `display-message -t
        // <pane_id>` can silently ignore an invalid/stale `-t` when no client
        // is attached. List every pane's id + cwd instead and match exactly.
        let result = try run(["list-panes", "-a", "-F", "#{pane_id}\t#{pane_current_path}"])
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.first.map(String.init) == paneTarget, parts.count == 2 {
                return String(parts[1])
            }
        }
        throw TmuxProcessError(arguments: ["paneCurrentPath", paneTarget], exitCode: -1, stderr: "pane not found: \(paneTarget)")
    }

    public func listSessions() async throws -> [TmuxSessionInfo] {
        let sessionsResult = runIgnoringFailure(["list-sessions", "-F", "#{session_name}"])
        guard sessionsResult.exitCode == 0 else { return [] }  // no server running
        let names = sessionsResult.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        return names.map { name in
            // Panes and windows are not the same thing in tmux — a single
            // window can be split into multiple panes. `windowCount` must
            // reflect actual windows (list-windows), not pane count, or a
            // split window inflates the advertised topology.
            let windowsResult = runIgnoringFailure(["list-windows", "-t", name, "-F", "#{window_id}"])
            let windowCount = windowsResult.exitCode == 0
                ? windowsResult.stdout.split(separator: "\n", omittingEmptySubsequences: true).count
                : 0
            let panesResult = runIgnoringFailure(["list-panes", "-s", "-t", name, "-F", "#{pane_id}"])
            let panes = panesResult.exitCode == 0
                ? panesResult.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                : []
            return TmuxSessionInfo(name: name, windowCount: windowCount, paneTargets: panes)
        }
    }

    // MARK: - Process plumbing (not part of the public surface)

    private struct RunResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func run(_ arguments: [String]) throws -> RunResult {
        let result = runIgnoringFailure(arguments)
        guard result.exitCode == 0 else {
            throw TmuxProcessError(arguments: arguments, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    private func runIgnoringFailure(_ arguments: [String]) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return RunResult(exitCode: -1, stdout: "", stderr: "\(error)")
        }
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return RunResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
