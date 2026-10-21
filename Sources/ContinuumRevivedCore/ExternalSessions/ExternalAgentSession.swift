import Foundation

// Plan: .plans/79-session-handoff/README.md ("The ownership rule").
//
// Every Claude and Codex session running on this Mac, where it lives, and who
// owns it. A session has exactly one owner at a time — an Array agent tile, an
// Array shell tile, or another app — and the sidebar keys its rows by session
// id, so one session can never be two rows.

public enum ExternalSessionProvider: String, Codable, Equatable, Hashable, Sendable {
    case claude
    case codex
}

public enum ExternalSessionStatus: String, Equatable, Sendable {
    /// Running a turn.
    case busy
    /// Stopped on the person: a permission prompt or a question.
    case waiting
    /// At its prompt.
    case idle
    /// The source cannot say (a Codex app thread).
    case unknown

    /// Live or waiting on you: what the default sidebar scope lists.
    public var isLive: Bool { self == .busy || self == .waiting }
}

/// Where a session runs.
public enum ExternalSessionHost: Equatable, Hashable, Sendable {
    /// Another app: its display name (`cmux`, `Claude app`, `Ghostty`).
    case app(String)
    /// Someone else's tmux. The terminal showing it is not in the process chain.
    case tmux
    /// `claude` typed into an Array shell tile. nil when the tile cannot be told
    /// (a shell outside tmux, or a shared base session's pane no tile claims).
    case arrayShellTile(tileId: UUID?)
    /// An Array agent tile in its Terminal face (`ARRAY_AGENT_FACE=terminal`).
    case arrayTerminalFace(agentId: String)
    /// An Array managed runner (`ARRAY_AGENT_ID` without the face). nil for a
    /// runner from an Array build that did not tag its CLIs yet.
    case arrayManaged(agentId: String?)
    case unknown

    /// An Array agent owns it: it is that agent's row, never a row of its own.
    public var isArrayAgent: Bool {
        switch self {
        case .arrayTerminalFace, .arrayManaged: return true
        case .app, .tmux, .arrayShellTile, .unknown: return false
        }
    }

    /// The `.app` bundle names Array itself ships as.
    static let arrayAppNames: Set<String> = ["Array", "Array Dev"]

    /// The name a person knows an app by, from its `.app` bundle name. macOS's
    /// Terminal is "Terminal.app" because "Terminal" is an Array tile's face.
    public static func displayName(forAppName app: String) -> String {
        switch app {
        case "Terminal": return "Terminal.app"
        case "iTerm", "iTerm2": return "iTerm"
        case "Visual Studio Code", "Code": return "VS Code"
        case "Claude": return "Claude app"
        case "Codex", "ChatGPT": return "Codex app"
        default: return app
        }
    }

    /// Apps that are terminals, so the marker draws a terminal glyph rather than
    /// a window. Generic glyphs only (BUILD.md decision 1).
    static let terminalApps: Set<String> = [
        "Ghostty", "Terminal.app", "iTerm", "Warp", "cmux", "WezTerm", "Alacritty", "kitty", "Hyper", "Tabby",
    ]
}

public struct ExternalAgentSession: Equatable, Sendable, Identifiable {
    public var provider: ExternalSessionProvider
    /// Claude's session id, or Codex's thread id.
    public var sessionId: String
    public var pid: Int32?
    public var cwd: String
    /// Claude's own title for it, or the Codex thread name; nil when neither has one.
    public var title: String?
    public var status: ExternalSessionStatus
    public var startedAt: Date
    /// When the current status began: a busy session's turn start.
    public var statusSince: Date?
    public var lastActivity: Date?
    public var host: ExternalSessionHost
    /// The CLI's own session file, which Watch and Copy read.
    public var transcriptURL: URL?

    /// Unique across providers. The sidebar's row key.
    public var id: String { "\(provider.rawValue):\(sessionId)" }

    public init(
        provider: ExternalSessionProvider, sessionId: String, pid: Int32?, cwd: String, title: String?,
        status: ExternalSessionStatus, startedAt: Date, statusSince: Date? = nil, lastActivity: Date? = nil,
        host: ExternalSessionHost, transcriptURL: URL?
    ) {
        self.provider = provider
        self.sessionId = sessionId
        self.pid = pid
        self.cwd = cwd
        self.title = title
        self.status = status
        self.startedAt = startedAt
        self.statusSince = statusSince
        self.lastActivity = lastActivity
        self.host = host
        self.transcriptURL = transcriptURL
    }
}

public struct ExternalSessionSnapshot: Equatable, Sendable {
    public var sessions: [ExternalAgentSession]
    /// Claude's session files exist and none of them parsed: their format has
    /// changed, so the Claude half shows nothing rather than wrong rows.
    public var claudeUnreadable: Bool

    public init(sessions: [ExternalAgentSession], claudeUnreadable: Bool = false) {
        self.sessions = sessions
        self.claudeUnreadable = claudeUnreadable
    }

    public static let empty = ExternalSessionSnapshot(sessions: [])

    public func session(id: String) -> ExternalAgentSession? { sessions.first { $0.id == id } }
}

/// Which app or terminal a process runs in, from its ancestry.
enum ExternalSessionHostClassifier {
    static func host(
        forPid pid: Int32,
        byPid: [Int32: ProcessSample],
        hostPid: Int32,
        tmuxTarget: String?,
        isSDKRunner: Bool,
        arrayShellPanes: [String: UUID] = [:]
    ) -> ExternalSessionHost {
        // 1. Array's own tag, on the process or its nearest tagged ancestor —
        //    the rule `AgentProcessAttribution.owners` uses, stopping at this app.
        var cursor = pid
        for _ in 0..<64 {
            guard let sample = byPid[cursor] else { break }
            if let tag = sample.ownerTag, !tag.isEmpty {
                return sample.ownerFace == "terminal"
                    ? .arrayTerminalFace(agentId: tag) : .arrayManaged(agentId: tag)
            }
            guard sample.parentPid > 1, sample.parentPid != hostPid, sample.parentPid != cursor else { break }
            cursor = sample.parentPid
        }
        // 2. The first tmux server or `.app` above it. A session in tmux ends at
        //    the server, so the terminal showing it is never in the chain.
        var parent = byPid[pid]?.parentPid ?? 0
        for _ in 0..<64 {
            guard parent > 1, let sample = byPid[parent] else { break }
            if isTmux(sample) { return tmuxHost(tmuxTarget, arrayShellPanes: arrayShellPanes) }
            if let app = OtherListeningApps.appName(sample.executablePath) {
                if ExternalSessionHost.arrayAppNames.contains(app) {
                    // Under Array with no tag: an untagged runner from an older
                    // build, or `claude` in a shell tile that is not in tmux.
                    return isSDKRunner ? .arrayManaged(agentId: nil) : .arrayShellTile(tileId: nil)
                }
                return .app(ExternalSessionHost.displayName(forAppName: app))
            }
            guard sample.parentPid != parent else { break }
            parent = sample.parentPid
        }
        if tmuxTarget != nil { return tmuxHost(tmuxTarget, arrayShellPanes: arrayShellPanes) }
        return .unknown
    }

    static func isTmux(_ sample: ProcessSample) -> Bool {
        let name = ((sample.arguments.first ?? sample.executablePath) as NSString).lastPathComponent
        return name.hasPrefix("tmux") || (sample.executablePath as NSString).lastPathComponent == "tmux"
    }

    /// `Array:@64.%67` is `session:@window.%pane`. Array's own session names say
    /// which tile they are; anyone else's is just tmux. A project's shared base
    /// session (`array-proj-…`) holds every shell tile of that project, one
    /// window each, so its name says no tile: the pane does, through
    /// `arrayShellPanes` (pane id → the shell tile whose window it is). Pane ids
    /// are only unique within one server, so they are trusted only under an
    /// Array session name.
    static func tmuxHost(_ target: String?, arrayShellPanes: [String: UUID] = [:]) -> ExternalSessionHost {
        guard let target, let session = target.split(separator: ":", maxSplits: 1).first else { return .tmux }
        let named = TmuxSession.arraySession(named: String(session))
        guard named.isArray else { return .tmux }
        if let tileId = named.tileId { return .arrayShellTile(tileId: tileId) }
        let pane = target.split(separator: ".").last.map(String.init)
        return .arrayShellTile(tileId: pane.flatMap { arrayShellPanes[$0] })
    }
}
