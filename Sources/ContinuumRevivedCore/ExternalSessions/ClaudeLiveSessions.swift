import Foundation

// The process table and the CLIs' home folders are a Mac's; Core also builds for iOS.
#if os(macOS)

/// Live Claude sessions, from `~/.claude/sessions/<pid>.json`.
///
/// The files are undocumented, so everything here is conservative. Proven on
/// Dylan's machine (`.plans/79-session-handoff/README.md`):
/// - `kind: bg` is Claude's own background host (`claude bg-spare`). Skipped.
/// - A file outlives its process and macOS reuses pids: one pointed at Spotify.
///   `procStart` is written in UTC and matched `ps -o lstart` to the second for
///   every live claude, so a file whose `procStart` is not the real start of
///   the process at that pid is dropped.
/// - The folder also holds `.key` files. They are never opened.
public enum ClaudeLiveSessions {
    /// What one session file says, as far as discovery needs it.
    public struct Record: Equatable, Sendable {
        public var pid: Int32
        public var sessionId: String
        public var cwd: String
        public var name: String?
        public var status: String?
        public var kind: String?
        public var entrypoint: String?
        public var procStart: Date
        public var startedAt: Date?
        public var statusUpdatedAt: Date?
        public var tmux: String?
    }

    /// nil unless the file has a session id, a cwd and a `procStart` this can
    /// read: without `procStart` a stale file cannot be told from a live one.
    public static func parse(_ data: Data, filePid: Int32) -> Record? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sessionId = object["sessionId"] as? String, !sessionId.isEmpty,
              let cwd = object["cwd"] as? String, !cwd.isEmpty,
              let procStartRaw = object["procStart"] as? String,
              let procStart = parseProcStart(procStartRaw) else { return nil }
        if let pid = (object["pid"] as? NSNumber)?.int32Value, pid != filePid { return nil }
        func millis(_ key: String) -> Date? {
            (object[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        return Record(
            pid: filePid, sessionId: sessionId, cwd: cwd,
            name: object["name"] as? String,
            status: object["status"] as? String,
            kind: object["kind"] as? String,
            entrypoint: object["entrypoint"] as? String,
            procStart: procStart,
            startedAt: millis("startedAt"),
            statusUpdatedAt: millis("statusUpdatedAt") ?? millis("updatedAt"),
            tmux: object["tmux"] as? String)
    }

    /// `Mon Oct 19 20:27:04 2026`, in UTC — `ps -o lstart`'s shape, which pads a
    /// one-digit day with a second space.
    public static func parseProcStart(_ raw: String) -> Date? {
        let normalized = raw.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return procStartFormatter.date(from: normalized)
    }

    private static let procStartFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()

    public static func status(_ raw: String?) -> ExternalSessionStatus {
        guard let raw = raw?.lowercased() else { return .unknown }
        if raw == "busy" { return .busy }
        if raw == "idle" { return .idle }
        if ["wait", "permission", "input", "action", "approval"].contains(where: raw.contains) { return .waiting }
        return .unknown
    }

    /// `procStart` has whole seconds; the kernel's start has microseconds.
    static let startTolerance: TimeInterval = 2

    /// The live sessions among `records`.
    ///
    /// - Parameters:
    ///   - fileCount: how many `.json` files there were. Files that exist and
    ///     none of which parse mean the format changed: `unreadable`, no rows.
    ///   - title: Claude's own title for a session (from its transcript), else nil.
    public static func sessions(
        records: [Record],
        fileCount: Int,
        processes: [ProcessSample],
        hostPid: Int32,
        homeURL: URL,
        title: (Record, URL) -> String? = { _, _ in nil }
    ) -> (sessions: [ExternalAgentSession], unreadable: Bool) {
        if fileCount > 0 && records.isEmpty { return ([], true) }
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var sessions: [ExternalAgentSession] = []
        var seen: Set<String> = []
        for record in records.sorted(by: { $0.pid < $1.pid }) {
            guard record.kind != "bg",
                  let process = byPid[record.pid],
                  abs(process.startedAt.timeIntervalSince(record.procStart)) < startTolerance,
                  seen.insert(record.sessionId).inserted else { continue }
            let host: ExternalSessionHost
            if record.entrypoint == "claude-desktop" {
                host = .app("Claude app")
            } else {
                host = ExternalSessionHostClassifier.host(
                    forPid: record.pid, byPid: byPid, hostPid: hostPid,
                    tmuxTarget: record.tmux, isSDKRunner: record.entrypoint == "sdk-cli")
            }
            let transcript = ClaudeSessionTranscriptReader.sessionFileURL(
                homeURL: homeURL, cwd: record.cwd, sessionId: record.sessionId)
            let status = status(record.status)
            sessions.append(ExternalAgentSession(
                provider: .claude, sessionId: record.sessionId, pid: record.pid, cwd: record.cwd,
                title: title(record, transcript) ?? record.name,
                status: status,
                startedAt: record.startedAt ?? record.procStart,
                statusSince: record.statusUpdatedAt,
                lastActivity: record.statusUpdatedAt,
                host: host, transcriptURL: transcript))
        }
        return (sessions, false)
    }

    /// The session's title from its transcript's tail: the newest title a
    /// person gave it (`custom-title`), else Claude's own (`ai-title`).
    public static func title(fromTranscriptLines lines: [String]) -> String? {
        var custom: String?
        var generated: String?
        for line in lines where line.contains("-title\"") {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "custom-title": custom = (object["customTitle"] as? String) ?? custom
            case "ai-title": generated = (object["aiTitle"] as? String) ?? generated
            default: break
            }
        }
        let title = (custom ?? generated)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
    }
}
#endif
