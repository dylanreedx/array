import Foundation

// Plan: .plans/79-session-handoff/README.md, phase 2 (edge cases 1, 7, 8, 13).
//
// What Array does with a session another app holds: watch it, wait to continue
// it here, or — when it is one of Array's own agents' — pause until the other
// process lets go. One rule decides all three: a session is held elsewhere
// while discovery reports a process holding it that is NOT one of Array's own
// agents. Array's own processes carry its tag (`ARRAY_AGENT_ID`), so they are
// never "elsewhere", and a false pause on them is the one outcome this file
// exists to make impossible.

/// An agent record standing in for a session another app holds.
public struct AgentExternalSessionLink: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// Read-only: the tile follows the session as the other app writes it.
        case watching
        /// Move here: the tile continues the session once the other app lets go.
        case movingHere
    }

    public var mode: Mode
    public var provider: ExternalSessionProvider
    public var sessionId: String
    /// Where it runs, as the sidebar marker says it (`cmux`, `Claude app`).
    /// Kept so a relaunch can say it before discovery has looked.
    public var hostName: String
    /// The CLI's own session file, which the tile renders and follows.
    public var transcriptPath: String?
    /// Discovery saw a process holding the session, so its exit can be seen.
    /// A Codex app thread has none: the app runs every thread in one server,
    /// so Array cannot tell when one closes.
    public var tracksProcess: Bool

    public init(
        mode: Mode, provider: ExternalSessionProvider, sessionId: String, hostName: String,
        transcriptPath: String?, tracksProcess: Bool
    ) {
        self.mode = mode
        self.provider = provider
        self.sessionId = sessionId
        self.hostName = hostName
        self.transcriptPath = transcriptPath
        self.tracksProcess = tracksProcess
    }

    /// `ExternalAgentSession.id`: the sidebar's row key for the session.
    public var sessionKey: String { "\(provider.rawValue):\(sessionId)" }
}

public enum ExternalSessionHandoff {
    /// Who holds a session, as far as discovery can say.
    public enum Holding: Equatable, Sendable {
        /// A process that is not one of Array's agents holds it.
        case heldElsewhere(ExternalAgentSession)
        /// Nothing outside Array holds it now.
        case released
        /// Discovery cannot say: it has not looked yet, Claude's files stopped
        /// parsing, or the holder is a Codex app thread whose close is invisible.
        /// Nothing changes on an unknown — moving a session in on a guess would
        /// put a second writer on it.
        case unknown
    }

    /// The process holding `sessionId` outside Array, if any. Array's own
    /// agents — a tagged runner, an untagged runner from an older build, a
    /// tile's Terminal face — are never a holder.
    public static func holder(
        provider: ExternalSessionProvider, sessionId: String, in snapshot: ExternalSessionSnapshot
    ) -> ExternalAgentSession? {
        snapshot.sessions.first {
            $0.provider == provider && $0.sessionId == sessionId && !$0.host.isArrayAgent
        }
    }

    public static func holding(
        _ link: AgentExternalSessionLink, in snapshot: ExternalSessionSnapshot, discovered: Bool
    ) -> Holding {
        if let held = holder(provider: link.provider, sessionId: link.sessionId, in: snapshot) {
            return .heldElsewhere(held)
        }
        guard discovered, link.tracksProcess,
              !(link.provider == .claude && snapshot.claudeUnreadable) else { return .unknown }
        return .released
    }

    /// Edge case 1: a process outside Array holding one of an Array agent's own
    /// sessions. Only a live process counts — a Codex app thread is listed by
    /// recency, not because anything holds it.
    public static func pausingHolder(
        provider: ExternalSessionProvider, sessionIds: Set<String>, in snapshot: ExternalSessionSnapshot
    ) -> ExternalAgentSession? {
        snapshot.sessions.first {
            $0.provider == provider && sessionIds.contains($0.sessionId) && $0.pid != nil && !$0.host.isArrayAgent
        }
    }

    /// The name a banner uses for where a session runs: the sidebar marker's
    /// text without its age.
    public static func hostName(of session: ExternalAgentSession) -> String {
        switch session.host {
        case let .app(name): return name
        case .tmux: return "tmux"
        case .arrayShellTile: return "a shell tile"
        case .arrayTerminalFace, .arrayManaged: return "Array"
        case .unknown: return "another app"
        }
    }

    /// The Claude desktop app closes a session from its own window, not with
    /// `/exit` (edge case 13).
    public static func isDesktopApp(_ hostName: String) -> Bool {
        hostName == "Claude app" || hostName == "Codex app"
    }
}

/// Reading a session file the way a follower must: only whole lines, and an
/// offset that lands just past the last one, so a line the CLI is still
/// writing is read once, complete, on a later pass — never half now and lost.
public enum SessionFileTail {
    /// The complete lines from `offset` to the last newline, and the offset just
    /// past it. A file shorter than `offset` was rewritten, so it is read whole.
    public static func lines(in url: URL, from offset: UInt64) -> (lines: [String], end: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = offset <= size ? offset : 0
        guard size > start, (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start)) else { return ([], start) }
        return complete(data, from: start)
    }

    /// The last `maxBytes` of the file, up to its last newline: the opening
    /// read of a follower. `truncated` says earlier history was left out.
    public static func tail(in url: URL, maxBytes: Int) -> (lines: [String], truncated: Bool, end: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], false, 0) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard size > start, (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start)) else { return ([], false, start) }
        var (lines, end) = complete(data, from: start)
        // A window that starts mid-file starts mid-line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return (lines, start > 0, end)
    }

    /// The byte length now; 0 when the file does not exist yet. A stat, cheap
    /// enough for a follower to ask every second or two.
    public static func length(_ url: URL) -> UInt64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        return size?.uint64Value ?? 0
    }

    private static func complete(_ data: Data, from start: UInt64) -> (lines: [String], end: UInt64) {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], start) }
        let whole = data[data.startIndex...lastNewline]
        let text = String(decoding: whole, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return (lines, start + UInt64(whole.count))
    }
}
