import Foundation

// The process table and the CLIs' home folders are a Mac's; Core also builds for iOS.
#if os(macOS)

/// Live Codex sessions. Modest on purpose ("we can wrinkle out codex later"):
/// correct and conservative beats clever.
///
/// Codex keeps no file per running process, so there are two sources:
/// - **CLI sessions**: a process scan for an interactive `codex`. Its thread is
///   the rollout it holds open, else the newest rollout written in its folder
///   since it started. One with no rollout yet (no message sent) is not listed.
/// - **Codex app threads**: the app runs every thread inside one `codex
///   app-server`, so which are open cannot be told. Threads the app wrote
///   recently are listed instead, with no status (`Codex app · 4m ago`).
///
/// Rollouts Array wrote (`originator: array`) are its own agents' and are never
/// listed; neither are sub-agent threads (`parent_thread_id`).
enum CodexLiveSessions {
    struct Rollout: Equatable {
        var url: URL
        var modified: Date
        var meta: CodexRolloutLocator.SessionMeta
    }

    static let desktopOriginator = "Codex Desktop"
    static let arrayOriginator = "array"
    /// How long an app thread stays listed after its last write.
    static let appThreadWindow: TimeInterval = 30 * 60
    /// A CLI thread written this recently is mid-turn.
    static let busyWindow: TimeInterval = 10

    /// Subcommands that are not a person at a prompt.
    static let nonInteractive: Set<String> = [
        "app-server", "exec", "e", "mcp", "mcp-server", "login", "logout", "proto", "completion",
        "debug", "apply", "a", "sandbox", "cloud", "features", "help", "--help", "-h", "--version", "-V",
    ]

    /// An interactive `codex` (the native binary, not its node wrapper).
    static func isInteractiveCLI(_ sample: ProcessSample) -> Bool {
        let name = (sample.executablePath as NSString).lastPathComponent
        guard name == "codex" || name.hasPrefix("codex-") else { return false }
        return !sample.arguments.dropFirst().contains(where: nonInteractive.contains)
    }

    static func sessions(
        processes: [ProcessSample],
        hostPid: Int32,
        rollouts: [Rollout],
        sessionsRoot: URL,
        threadNames: [String: String],
        now: Date,
        processCwd: (Int32) -> String?,
        openFiles: (Int32) -> [String]
    ) -> [ExternalAgentSession] {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let byPath = Dictionary(rollouts.map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { a, _ in a })
        let listable = rollouts.filter {
            $0.meta.id != nil && $0.meta.originator != arrayOriginator && $0.meta.parentThreadId == nil
        }
        var sessions: [ExternalAgentSession] = []
        var claimed: Set<String> = []

        // A wrapper and the binary it execs are both `codex`; the deepest one
        // is the one doing the work.
        let cli = processes.filter(isInteractiveCLI)
        let cliPids = Set(cli.map(\.pid))
        let hasCLIChild = Set(cli.compactMap { cliPids.contains($0.parentPid) ? $0.parentPid : nil })
        let rootPath = sessionsRoot.standardizedFileURL.path + "/"
        for process in cli.sorted(by: { $0.pid < $1.pid }) where !hasCLIChild.contains(process.pid) {
            let cwd = processCwd(process.pid)
            let held = openFiles(process.pid).lazy
                .filter { $0.hasPrefix(rootPath) && ($0 as NSString).lastPathComponent.hasPrefix("rollout-") }
                .compactMap { byPath[URL(fileURLWithPath: $0).standardizedFileURL.path] }
                .first
            let rollout = held ?? listable
                .filter { $0.meta.cwd == cwd && $0.modified >= process.startedAt && !claimed.contains($0.meta.id ?? "") }
                .max { $0.modified < $1.modified }
            guard let rollout, let threadId = rollout.meta.id, rollout.meta.originator != arrayOriginator,
                  claimed.insert(threadId).inserted else { continue }
            let busy = now.timeIntervalSince(rollout.modified) < busyWindow
            sessions.append(ExternalAgentSession(
                provider: .codex, sessionId: threadId, pid: process.pid, cwd: cwd ?? rollout.meta.cwd,
                title: threadNames[threadId],
                status: busy ? .busy : .idle,
                startedAt: rollout.meta.timestamp,
                statusSince: busy ? nil : rollout.modified,
                lastActivity: rollout.modified,
                host: ExternalSessionHostClassifier.host(
                    forPid: process.pid, byPid: byPid, hostPid: hostPid, tmuxTarget: nil, isSDKRunner: false),
                transcriptURL: rollout.url))
        }

        for rollout in listable where rollout.meta.originator == desktopOriginator {
            guard let threadId = rollout.meta.id, !claimed.contains(threadId),
                  now.timeIntervalSince(rollout.modified) < appThreadWindow else { continue }
            claimed.insert(threadId)
            sessions.append(ExternalAgentSession(
                provider: .codex, sessionId: threadId, pid: nil, cwd: rollout.meta.cwd,
                title: threadNames[threadId], status: .unknown,
                startedAt: rollout.meta.timestamp, lastActivity: rollout.modified,
                host: .app("Codex app"), transcriptURL: rollout.url))
        }
        return sessions
    }

    /// `session_index.jsonl`: one `{id, thread_name, updated_at}` per rename;
    /// the last line for an id wins.
    static func threadNames(fromIndexLines lines: [String]) -> [String: String] {
        var names: [String: String] = [:]
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = object["id"] as? String,
                  let name = (object["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            names[id] = name
        }
        return names
    }
}
#endif
