import Foundation

/// Pure, Codable snapshot of what tmux actually holds at a given moment: which sessions
/// exist, which windows live inside each session, and each window's single pane identity,
/// working directory, and foreground command. This is the reconciliation oracle — the
/// measured ground truth against which Continuum's persisted descriptors are diffed.
///
/// This type is purely definitional: no `Process`, no shell, no `UserDefaults`, no
/// wall-clock. Callers that need a capture timestamp stamp it externally.
public struct SessionTopologySnapshot: Codable, Equatable, Sendable {

    /// The `-F` format string for `tmux list-windows -a -F '...'`. Six tab-separated
    /// fields, in this exact order — the parser's field indices depend on this order.
    public static let tmuxFormatString =
        "#{session_name}\t#{window_id}\t#{pane_id}\t#{pane_current_path}\t#{pane_current_command}\t#{pane_pid}"

    public struct WindowEntry: Codable, Equatable, Sendable {
        public let windowId: String         // "@N" form
        public let paneId: String           // "%N" form
        public let paneCurrentPath: String
        public let paneCurrentCommand: String
        public let panePid: Int32

        public init(
            windowId: String,
            paneId: String,
            paneCurrentPath: String,
            paneCurrentCommand: String,
            panePid: Int32
        ) {
            self.windowId = windowId
            self.paneId = paneId
            self.paneCurrentPath = paneCurrentPath
            self.paneCurrentCommand = paneCurrentCommand
            self.panePid = panePid
        }
    }

    public struct SessionEntry: Codable, Equatable, Sendable {
        public let sessionName: String
        public let windows: [WindowEntry]

        public init(sessionName: String, windows: [WindowEntry]) {
            self.sessionName = sessionName
            self.windows = windows
        }
    }

    public let sessions: [SessionEntry]

    public init(sessions: [SessionEntry]) {
        self.sessions = sessions
    }

    /// Find any window across all sessions by its pane id (e.g. "%7").
    public func window(paneId: String) -> WindowEntry? {
        sessions.lazy.flatMap(\.windows).first { $0.paneId == paneId }
    }

    /// Find a session by its exact name.
    public func session(named name: String) -> SessionEntry? {
        sessions.first { $0.sessionName == name }
    }
}

public extension SessionTopologySnapshot {
    /// Errors covering a genuinely malformed *non-empty* line. Empty or whitespace-only
    /// input is NOT an error — it is a valid zero-session snapshot (the normal "nothing
    /// running" case), so there is no `emptyInput` case here.
    ///
    /// `Codable` and `Sendable` (in addition to `Equatable`) are required by the ticket's
    /// public surface: this error crosses concurrency boundaries (e.g. the substrates
    /// ticket's async `TmuxControl.readTopology()` throws it from an actor-isolated call),
    /// and both conformances synthesize for free on a String-payload enum.
    enum ParseError: Error, Equatable, Codable, Sendable {
        case malformedLine(String)
        case invalidPid(String)
    }

    /// Pure parser: takes the raw multi-line string `tmux list-windows -a -F
    /// tmuxFormatString` emits and returns the snapshot, or throws `ParseError` for a
    /// malformed non-empty line. Zero non-empty lines (including a blank or
    /// whitespace-only string) parses to a zero-session snapshot, not an error.
    static func parse(tmuxOutput: String) throws -> SessionTopologySnapshot {
        let lines = tmuxOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // Group by session name while preserving insertion order.
        var order: [String] = []
        var grouped: [String: [WindowEntry]] = [:]

        for line in lines {
            // omittingEmptySubsequences: false is load-bearing — tmux renders an empty
            // pane_current_command as two adjacent tabs, and the default split would
            // collapse that into five fields, misfiring `malformedLine` on valid output.
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6 else { throw ParseError.malformedLine(line) }

            let (sessionName, windowId, paneId, path, command, pidStr) =
                (fields[0], fields[1], fields[2], fields[3], fields[4], fields[5])

            guard let pid = Int32(pidStr) else { throw ParseError.invalidPid(pidStr) }

            let entry = WindowEntry(
                windowId: windowId,
                paneId: paneId,
                paneCurrentPath: path,
                paneCurrentCommand: command,
                panePid: pid
            )

            if grouped[sessionName] == nil {
                order.append(sessionName)
                grouped[sessionName] = []
            }
            grouped[sessionName]!.append(entry)
        }

        let sessionEntries = order.map { name in
            SessionEntry(sessionName: name, windows: grouped[name]!)
        }
        return SessionTopologySnapshot(sessions: sessionEntries)
    }
}
