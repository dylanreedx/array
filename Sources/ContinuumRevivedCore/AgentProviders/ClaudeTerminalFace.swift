import Foundation

// Session handoff (`.plans/79-session-handoff`), stream D: one agent tile, two
// faces. The Array face is the native transcript and composer; the Terminal
// face is the real `claude` TUI on the same conversation, in a Ghostty surface
// inside the same tile. This file is the platform-neutral half: what the face
// launches, where it left the conversation, and what claude says about the
// process while it runs. The view half is `ManagedAgentTileNSView`.

/// Which face an agent tile shows.
public enum AgentTileFace: String, Codable, Equatable, Sendable {
    case array
    case terminal
}

/// User-wide visibility of the optional Terminal toggle, independent of the
/// tile's current face. Menus and shortcuts remain available when hidden.
public enum AgentTerminalFaceConfig {
    public static let showToggleKey = "array.agent.terminalFace.showToggle"
    public static let defaultShowToggle = true

    public static func showsToggle(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showToggleKey) == nil ? defaultShowToggle : defaults.bool(forKey: showToggleKey)
    }
}

/// A tile in its Terminal face, persisted on the tile so a relaunch reattaches.
///
/// Present only while the tile shows the Terminal face. `sessionFileOffset` is
/// the byte length of the session file at the moment of the flip: everything
/// the Array face's transcript holds ends there, so flipping back appends only
/// what lies after it.
public struct AgentTerminalFaceState: Codable, Equatable, Sendable {
    /// The conversation the Terminal face resumed.
    public var sessionId: String
    /// The directory claude was started in. Claude names its project folder
    /// after it, so it locates the session file.
    public var cwd: String
    public var sessionFileOffset: UInt64
    /// The session claude last reported, when `/clear` or `/resume` moved it
    /// off `sessionId`. Its file is read from the start; the mark stays in
    /// `sessionId`'s.
    public var latestSessionId: String?

    public init(sessionId: String, cwd: String, sessionFileOffset: UInt64, latestSessionId: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.sessionFileOffset = sessionFileOffset
        self.latestSessionId = latestSessionId
    }

    /// Every session the face has been on, oldest first.
    public var sessionIds: [String] {
        [sessionId] + (latestSessionId.map { $0 == sessionId ? [] : [$0] } ?? [])
    }
}

public enum ClaudeTerminalFace {
    /// The face's marker in the claude process's environment, beside
    /// `AgentProcessAttribution.ownerEnvironmentKey`. Session discovery reads
    /// the pair to classify the process as this tile's Terminal face, never as
    /// a session running somewhere else.
    public static let faceEnvironmentKey = "ARRAY_AGENT_FACE"
    public static let faceEnvironmentValue = "terminal"

    #if os(macOS)
    /// The interactive claude the Terminal face runs, as one argv.
    ///
    /// The executable is the one the managed runner resolves
    /// (`ClaudeAgentRunner.liveResolvedCommand`), and HOME and CLAUDE_CONFIG_DIR
    /// are left alone, so it is the same CLI with the same login and settings.
    /// `/usr/bin/env` carries the agent's tags because the face runs inside
    /// tmux, whose server hands a new session ITS OWN environment, not the
    /// client's.
    public static func launchArguments(
        claude: PiAgentRunner.ResolvedCommand,
        sessionId: String,
        conversationExists: Bool,
        model: String,
        effort: String?,
        processOwner: String,
        path: String,
        forkSession: Bool = false
    ) -> [String] {
        let environment = [
            "\(AgentProcessAttribution.ownerEnvironmentKey)=\(processOwner)",
            "\(faceEnvironmentKey)=\(faceEnvironmentValue)",
            "\(PiAgentRunner.arrayHostedEnvironmentKey)=1",
            "PATH=\(path)",
        ]
        // An agent that has never had a turn has no conversation to resume yet:
        // `--resume` would exit at once with "No conversation found".
        // A pending fork (Copy before its first turn, a `/clear` rotation) names
        // a session another process may still write: claude forks it into a
        // new one rather than continuing it.
        let session = forkSession ? ["--resume", sessionId, "--fork-session"]
            : conversationExists ? ["--resume", sessionId] : ["--session-id", sessionId]
        return ["/usr/bin/env"] + environment + [claude.executable] + claude.prefixArgs
            + session + ["--model", model] + (effort.map { ["--effort", $0] } ?? [])
    }

    #endif

    // MARK: - The session file

    #if os(macOS)
    /// `<home>/.claude/projects/<encoded cwd>/<sessionId>.jsonl`.
    public static func sessionFileURL(claudeHome: URL, cwd: String, sessionId: String) -> URL {
        ClaudeSessionTranscriptReader.sessionFileURL(homeURL: claudeHome, cwd: cwd, sessionId: sessionId)
    }
    #endif

    /// The session file's byte length now, 0 when it does not exist yet.
    public static func sessionFileLength(_ url: URL) -> UInt64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        return size?.uint64Value ?? 0
    }

    /// The complete lines written after `offset`. A partial last line — claude
    /// mid-write — is left for the next read; an offset that is not at a line
    /// start reads from the next one.
    public static func lines(in url: URL, after offset: UInt64) -> [String] {
        QAMainThreadIO.noteFileRead()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // A file shorter than the mark was rewritten; the mark no longer
        // means anything inside it, so read it whole.
        let start = offset <= size ? offset : 0
        // One byte early, to see whether `start` begins a line.
        let lead: UInt64 = start > 0 ? 1 : 0
        guard size > start, (try? handle.seek(toOffset: start - lead)) != nil,
              let data = try? handle.readToEnd() else { return [] }
        return wholeLines(data, opensMidLine: lead == 1 && data.first != UInt8(ascii: "\n"), skip: Int(lead))
    }

    /// The complete lines before `end` — what the Array face held at the flip —
    /// bounded to the last `maxBytes`, as a restore is.
    public static func lines(in url: URL, before end: UInt64, maxBytes: Int = RehydrationLimits().maxBytes) -> [String] {
        QAMainThreadIO.noteFileRead()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let stop = min(end, size)
        let start = stop > UInt64(maxBytes) ? stop - UInt64(maxBytes) : 0
        let lead: UInt64 = start > 0 ? 1 : 0
        guard stop > start, (try? handle.seek(toOffset: start - lead)) != nil,
              let data = try? handle.read(upToCount: Int(stop - start + lead)) else { return [] }
        return wholeLines(data, opensMidLine: lead == 1 && data.first != UInt8(ascii: "\n"), skip: Int(lead))
    }

    /// The whole lines in a byte window, by bytes first: a window that opens
    /// mid-line (possibly mid-character) starts after its first newline, and
    /// a line not yet ended is left out. Decoded leniently, so one bad byte
    /// costs a line, never the window (review #13).
    private static func wholeLines(_ data: Data, opensMidLine: Bool, skip: Int) -> [String] {
        var body = data.dropFirst(skip)
        if opensMidLine {
            guard let newline = body.firstIndex(of: UInt8(ascii: "\n")) else { return [] }
            body = body[body.index(after: newline)...]
        }
        guard let last = body.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        return String(decoding: body[body.startIndex...last], as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// `lines` without any whose `uuid` is in `known`. A fork's file starts as a
    /// copy of the session it forked, so what it shares with that session's
    /// part already on screen is not the Terminal face's to append again.
    public static func lines(_ lines: [String], droppingUUIDsIn known: [String]) -> [String] {
        let uuids = Set(known.compactMap { ManagedTranscriptRehydrator.jsonObject($0)?["uuid"] as? String })
        guard !uuids.isEmpty else { return lines }
        return lines.filter { line in
            guard let uuid = ManagedTranscriptRehydrator.jsonObject(line)?["uuid"] as? String else { return true }
            return !uuids.contains(uuid)
        }
    }

    /// The model the last assistant line ran on, as a catalogue id
    /// (`anthropic/<model>` — `ClaudeCLIBackend.parseInitializeModels`' form).
    /// Verbatim from claude's own file. nil when no assistant line names a
    /// real model (`<synthetic>` is claude answering a slash command itself).
    public static func lastModel(in lines: [String]) -> String? {
        for line in lines.reversed() {
            guard let object = ManagedTranscriptRehydrator.jsonObject(line),
                  object["type"] as? String == "assistant",
                  (object["isSidechain"] as? Bool) != true,
                  let model = (object["message"] as? [String: Any])?["model"] as? String,
                  model.hasPrefix("claude-") else { continue }
            return "anthropic/\(model)"
        }
        return nil
    }

    // MARK: - The input box

    /// Whether claude's input box on `screen` (a pane's text, top to bottom) is
    /// visibly empty: its prompt line is exactly `❯` between two rules of `─`.
    /// Anything else — a draft, a multi-line draft, a placeholder, a dialog,
    /// a screen this cannot read — is not empty: typing a command there would
    /// submit what is already in it as a turn.
    public static func inputBoxIsEmpty(screen lines: [String]) -> Bool {
        func trimmed(_ line: String) -> String { line.trimmingCharacters(in: .whitespaces) }
        func isRule(_ line: String) -> Bool {
            let text = trimmed(line)
            return !text.isEmpty && text.allSatisfy { $0 == "\u{2500}" }
        }
        // The box claude draws now is the bottom one.
        guard let prompt = lines.lastIndex(where: { trimmed($0).hasPrefix("\u{276F}") }) else { return false }
        return trimmed(lines[prompt]) == "\u{276F}"
            && prompt > 0 && isRule(lines[prompt - 1])
            && prompt + 1 < lines.count && isRule(lines[prompt + 1])
    }

    // MARK: - The live process

    /// What claude itself says about one of its running processes, from
    /// `<home>/.claude/sessions/<pid>.json`. Undocumented, so this reads two
    /// fields and nothing else; session discovery (stream A) owns the rest.
    public struct LiveSession: Equatable, Sendable {
        public var sessionId: String
        /// `busy` or `idle`.
        public var status: String?
        public var isBusy: Bool { status == "busy" }
    }

    public static func liveSession(pid: Int32, claudeHome: URL) -> LiveSession? {
        let url = claudeHome
            .appendingPathComponent(".claude/sessions", isDirectory: true)
            .appendingPathComponent("\(pid).json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sessionId = object["sessionId"] as? String, !sessionId.isEmpty,
              (object["pid"] as? NSNumber)?.int32Value ?? pid == pid else { return nil }
        return LiveSession(sessionId: sessionId, status: object["status"] as? String)
    }
}
