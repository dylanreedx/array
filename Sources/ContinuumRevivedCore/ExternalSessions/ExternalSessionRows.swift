import ContinuumRevivedAgentUI
import CryptoKit
import Foundation

/// Sessions from other apps as ordinary sidebar rows (`mocks/4-sidebar-inline.png`).
///
/// One session is never two rows: a session an Array agent owns — a runner
/// carrying its tag, or a session id one of its records names — is that
/// agent's row and is left out here.
public enum ExternalSessionRows {
    /// A project the session's folder may belong to.
    public struct Project: Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var rootPath: String
        public var workspaceId: UUID?

        public init(id: UUID, name: String, rootPath: String, workspaceId: UUID?) {
            self.id = id
            self.name = name
            self.rootPath = rootPath
            self.workspaceId = workspaceId
        }
    }

    public struct Context: Equatable, Sendable {
        public var projects: [Project]
        public var currentWorkspaceId: UUID?
        public var currentWorkspaceName: String?
        /// The projects of the workspace on screen.
        public var currentWorkspaceProjectIds: Set<UUID>
        /// Session ids Array's own agents hold (Claude session ids, Codex threads).
        public var ownedSessionIds: Set<String>
        /// Array shell tiles' titles, for `Shell 2`.
        public var shellTileTitles: [UUID: String]

        public init(
            projects: [Project], currentWorkspaceId: UUID?, currentWorkspaceName: String?,
            currentWorkspaceProjectIds: Set<UUID>, ownedSessionIds: Set<String>, shellTileTitles: [UUID: String]
        ) {
            self.projects = projects
            self.currentWorkspaceId = currentWorkspaceId
            self.currentWorkspaceName = currentWorkspaceName
            self.currentWorkspaceProjectIds = currentWorkspaceProjectIds
            self.ownedSessionIds = ownedSessionIds
            self.shellTileTitles = shellTileTitles
        }
    }

    /// The row id for a session: stable for its key, and outside the keyspace
    /// of agent ids (random v4 UUIDs) by construction.
    public static func rowId(forSessionKey key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("array.external-session:\(key)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // name-based
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Whether a session is a row of its own, rather than an Array agent's.
    public static func isListed(_ session: ExternalAgentSession, ownedSessionIds: Set<String>) -> Bool {
        !session.host.isArrayAgent && !ownedSessionIds.contains(session.sessionId)
    }

    public static func rows(
        from snapshot: ExternalSessionSnapshot, context: Context, now: Date
    ) -> [AgentInboxRow] {
        let roots = context.projects.map { ($0, canonical($0.rootPath)) }
        return snapshot.sessions
            .filter { isListed($0, ownedSessionIds: context.ownedSessionIds) }
            .map { session in
                let cwd = canonical(session.cwd)
                let project = roots
                    .filter { cwd == $0.1 || cwd.hasPrefix($0.1.hasSuffix("/") ? $0.1 : $0.1 + "/") }
                    .max { $0.1.count < $1.1.count }?.0
                let inWorkspace = project.map { context.currentWorkspaceProjectIds.contains($0.id) } ?? false
                let state: InboxState
                switch session.status {
                case .busy: state = .working
                case .waiting: state = .input
                case .idle, .unknown: state = .ready
                }
                let turnStart = session.status == .busy ? (session.statusSince ?? session.lastActivity) : nil
                return AgentInboxRow(
                    id: rowId(forSessionKey: session.id),
                    title: session.title ?? (session.provider == .claude ? "Claude session" : "Codex session"),
                    projectName: project?.name ?? (session.cwd as NSString).lastPathComponent,
                    projectId: project?.id,
                    directoryName: project == nil ? (session.cwd as NSString).lastPathComponent : nil,
                    workspaceName: inWorkspace ? context.currentWorkspaceName : nil,
                    workspaceId: inWorkspace ? context.currentWorkspaceId : project?.workspaceId,
                    state: state,
                    model: session.provider == .claude ? "claude" : "openai-codex",
                    elapsed: turnStart.map { max(0, now.timeIntervalSince($0)) },
                    elapsedStartedAt: turnStart,
                    lastActiveAt: session.lastActivity,
                    createdAt: session.startedAt,
                    settlementBlocked: true,
                    harness: session.provider == .claude ? "Claude Code" : "Codex",
                    whereMarker: marker(for: session, context: context, now: now),
                    externalSession: InboxExternalSession(
                        sessionKey: session.id,
                        isProminent: session.status.isLive && inWorkspace,
                        canMoveHere: true,
                        // Claude forks with `--fork-session`; Codex has no fork Array drives yet.
                        canCopy: session.provider == .claude && session.transcriptURL != nil))
            }
    }

    /// `cmux`, `Claude app`, `tmux`, `Shell 2`, `Codex app · 4m ago`.
    public static func marker(
        for session: ExternalAgentSession, context: Context, now: Date
    ) -> InboxWhereMarker {
        switch session.host {
        case let .app(name):
            var text = name
            if session.status == .unknown, let last = session.lastActivity {
                text += " · \(AgentBackgroundJobText.uptime(since: last, now: now)) ago"
            }
            return InboxWhereMarker(
                symbol: ExternalSessionHost.terminalApps.contains(name) ? "terminal" : "macwindow", text: text)
        case .tmux:
            return InboxWhereMarker(symbol: "terminal", text: "tmux")
        case let .arrayShellTile(tileId):
            return InboxWhereMarker(
                symbol: "terminal", text: tileId.flatMap { context.shellTileTitles[$0] } ?? "Shell")
        case .arrayTerminalFace, .arrayManaged:
            return InboxWhereMarker(symbol: "terminal", text: "Terminal")
        case .unknown:
            return InboxWhereMarker(symbol: "questionmark.square.dashed", text: "elsewhere")
        }
    }

    /// The marker an Array agent's own row carries while its tile shows the
    /// real CLI.
    public static let terminalFaceMarker = InboxWhereMarker(symbol: "terminal", text: "Terminal")

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
