import Foundation

public enum LaunchPaletteAction: Equatable, Sendable {
    case newManagedAgent
    /// An agent with no tile at all (P2A.6): it runs, persists and appears in the
    /// supervisor's records without any canvas layout.
    case newHeadlessAgent
    /// P2D.6 — one agent per selected row of the focused ticket-queue tile, each
    /// in its own worktree.
    case fanOutQueueSelection
    case newNote
    case newBrowser
    case openFile
    case openFileTree
    case newDiffReview
    case fitCanvasToAll
    case previousView
    case previousTile
    case previousZone
    case toggleWorkspaceSidebar
    case openURL(String)
    case switchProject(UUID)
    case addProjectToCanvas(UUID)
    case newWorkspace
    case renameWorkspace(UUID)
    case deleteWorkspace(UUID)
    case switchWorkspace(UUID)
    case openInspectorForFocusedBrowser
    case spawnHarnessRole(HarnessRole)
    case jumpToTile(UUID)
    case jumpToZone(UUID)
    case createZone

    public var displayName: String {
        switch self {
        case .newManagedAgent:
            return "New Agent…"
        case .newHeadlessAgent:
            return "New Agent Without a Tile…"
        case .fanOutQueueSelection:
            return "Fan Out Selected Tickets…"
        case .newNote:
            return "New Note"
        case .newBrowser:
            return "New Browser"
        case .openFile:
            return "Open File..."
        case .openFileTree:
            return "Open File Tree..."
        case .newDiffReview:
            return "New Diff Review"
        case .fitCanvasToAll:
            return "Fit Canvas to All"
        case .previousView:
            return "Back to Previous View"
        case .previousTile:
            return "Go to Previous Tile"
        case .previousZone:
            return "Go to Previous Zone"
        case .toggleWorkspaceSidebar:
            return "Toggle Workspace Sidebar"
        case let .openURL(url):
            return "Open \"\(url)\"…"
        case .switchProject:
            return "Switch Project…"
        case .addProjectToCanvas:
            return "Add Project to Canvas…"
        case .newWorkspace:
            return "New Workspace…"
        case .renameWorkspace:
            return "Rename Workspace…"
        case .deleteWorkspace:
            return "Delete Workspace…"
        case .switchWorkspace:
            return "Switch Workspace…"
        case .openInspectorForFocusedBrowser:
            return "Open Inspector for Focused Browser"
        case let .spawnHarnessRole(role):
            return "Run \(role.displayName) Agent…"
        case .jumpToTile:
            return "Jump to Tile…"
        case .jumpToZone:
            return "Jump to Zone…"
        case .createZone:
            return "Create Zone…"
        }
    }

    fileprivate var filterTokens: [String] {
        switch self {
        case .newManagedAgent:
            return ["new", "agent", "managed", "assistant"]
        case .newHeadlessAgent:
            return ["new", "agent", "headless", "tileless"]
        case .fanOutQueueSelection:
            return ["fan", "out", "fanout", "agents", "tickets", "queue", "selected", "batch"]
        case .newNote:
            return ["new", "note"]
        case .newBrowser:
            return ["new", "browser", "web"]
        case .openFile:
            return ["open", "file"]
        case .openFileTree:
            return ["open", "file", "tree"]
        case .newDiffReview:
            return ["new", "diff", "review", "git"]
        case .fitCanvasToAll:
            return ["fit", "zoom", "all", "canvas"]
        case .previousView:
            return ["back", "previous", "view", "camera"]
        case .previousTile:
            return ["go", "previous", "tile", "back"]
        case .previousZone:
            return ["go", "previous", "zone", "back"]
        case .toggleWorkspaceSidebar:
            return ["toggle", "show", "hide", "workspace", "sidebar", "view"]
        case .openURL:
            return ["open", "url", "browser", "web"]
        case .switchProject:
            return ["switch", "project"]
        case .addProjectToCanvas:
            return ["add", "project", "canvas", "zone"]
        case .newWorkspace:
            return ["new", "workspace", "canvas"]
        case .renameWorkspace:
            return ["rename", "workspace", "canvas"]
        case .deleteWorkspace:
            return ["delete", "workspace", "canvas"]
        case .switchWorkspace:
            return ["switch", "workspace", "canvas"]
        case .openInspectorForFocusedBrowser:
            return ["open", "inspector", "focused", "browser", "continuum", "tile"]
        case let .spawnHarnessRole(role):
            return ["run", "spawn", "agent", "harness", "role", role.id, role.displayName.lowercased()]
        case .jumpToTile:
            return ["jump", "tile", "go"]
        case .jumpToZone:
            return ["jump", "zone", "go"]
        case .createZone:
            return ["create", "new", "zone"]
        }
    }
}

public enum CommandCenterAttentionReason: String, Equatable, Sendable {
    case approval
    case input

    public var displayName: String {
        switch self {
        case .approval: return "Approval requested"
        case .input: return "Waiting for your input"
        }
    }
}

/// A navigable tile plus the optional presentation facts already owned by the
/// app. The id/title-only initializer remains source-compatible for older
/// callers and checks; command-center copy never has to infer agent identity
/// from a title such as "Jump to GPT 5.6".
public struct JumpTileRow: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let kind: TileKind?
    public let contextTitle: String?
    public let modelID: String?
    public let modelDisplayName: String?
    public let statusLabel: String?
    public let attentionReason: CommandCenterAttentionReason?

    public init(
        id: UUID,
        title: String,
        kind: TileKind? = nil,
        contextTitle: String? = nil,
        modelID: String? = nil,
        modelDisplayName: String? = nil,
        statusLabel: String? = nil,
        attentionReason: CommandCenterAttentionReason? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.contextTitle = contextTitle
        self.modelID = modelID
        self.modelDisplayName = modelDisplayName
        self.statusLabel = statusLabel
        self.attentionReason = attentionReason
    }
}

public struct JumpZoneRow: Equatable, Sendable {
    public let id: UUID
    public let title: String

    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}

public struct LaunchPaletteProfileRow: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let detail: String
    public let isSelectable: Bool

    public init(id: String, displayName: String, detail: String, isSelectable: Bool) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.isSelectable = isSelectable
    }
}

/// One exact, fully-qualified managed-agent model offered by the command
/// center's shallow New Agent configuration step.
public struct AgentModelPaletteRow: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let providerName: String

    public init(id: String, displayName: String, providerName: String) {
        self.id = id
        self.displayName = displayName
        self.providerName = providerName
    }
}

/// An agent with NO canvas tile, offered so it can still be reached.
///
/// `jumpToTile` is built from tiles on the canvas, so it cannot represent any of
/// these — and "closed" is not the only tile-less lifecycle. An agent is also
/// tile-less while headless (never given a tile), snoozed, or settled;
/// `AgentInventory` unions "tiled or headless" records, and the record's
/// `displayName` deliberately survives its tile because the AGENT is the entity.
/// Keyed by agent id for that reason: there is no tile id to key on.
///
/// This row is the only way to reach any of them once the workspace sidebar's
/// agent inbox is gone (.plans/10-command-center-absorbs-sidebar.md).
public struct TilelessAgentPaletteRow: Equatable, Sendable {
    public let agentId: UUID
    public let displayName: String
    /// Model display name or provider id — the same metadata the inbox row
    /// shows, searchable without becoming part of the command identity.
    public let detail: String?
    /// Closed (`InboxSection.history`) rather than merely tile-less. Decides
    /// History vs the live categories, and it is asked of
    /// `InboxSort.section(for:now:)` at the call site so this type never owns a
    /// second copy of the rule.
    public let isClosed: Bool
    /// Live status word, when the agent has a turn snapshot.
    public let statusLabel: String?
    /// Set when the agent is blocked on the user; promotes the row to Needs You
    /// exactly as it does for a tiled agent.
    public let attentionReason: CommandCenterAttentionReason?

    public init(
        agentId: UUID,
        displayName: String,
        detail: String? = nil,
        isClosed: Bool = false,
        statusLabel: String? = nil,
        attentionReason: CommandCenterAttentionReason? = nil
    ) {
        self.agentId = agentId
        self.displayName = displayName
        self.detail = detail
        self.isClosed = isClosed
        self.statusLabel = statusLabel
        self.attentionReason = attentionReason
    }
}

public enum LaunchPaletteRow: Equatable, Sendable {
    case profile(LaunchPaletteProfileRow)
    case agentModel(AgentModelPaletteRow)
    case tilelessAgent(TilelessAgentPaletteRow)
    case action(LaunchPaletteAction)
    case project(ProjectPickerRow)
    case workspace(WorkspaceEntry)
    case workspaceAction(LaunchPaletteAction, WorkspaceEntry)
    case jumpToTile(JumpTileRow)
    case jumpToZone(JumpZoneRow)

    public var displayName: String {
        switch self {
        case let .profile(profile): return profile.displayName
        case let .agentModel(model): return model.displayName
        case let .action(action): return action.displayName
        case let .project(project):
            if project.worktreeOf != nil {
                return "Add \(project.name) Worktree to Canvas"
            }
            return "Add \(project.name) to Canvas"
        case let .workspace(workspace): return "Switch to \(workspace.name) Workspace"
        case let .workspaceAction(action, workspace):
            switch action {
            case .renameWorkspace: return "Rename \(workspace.name) Workspace…"
            case .deleteWorkspace: return "Delete \(workspace.name) Workspace…"
            default: return action.displayName
            }
        case let .jumpToTile(tile): return "Jump to \(tile.title)"
        case let .jumpToZone(zone): return "Jump to \(zone.title)"
        case let .tilelessAgent(agent):
            return agent.isClosed ? "Reopen \(agent.displayName)" : "Open \(agent.displayName)"
        }
    }

    public var isSelectable: Bool {
        switch self {
        case let .profile(profile): return profile.isSelectable
        case .agentModel: return true
        case .tilelessAgent: return true
        case .action: return true
        case let .project(project): return project.isSelectable
        case let .workspace(workspace): return !workspace.projectIds.isEmpty
        case .workspaceAction: return true
        case .jumpToTile: return true
        case .jumpToZone: return true
        }
    }

    fileprivate func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        switch self {
        case let .profile(profile):
            return profile.displayName.lowercased().contains(query)
                || profile.id.lowercased().contains(query)
        case let .agentModel(model):
            let haystacks = [model.displayName, model.id, model.providerName, "agent model provider"].map { $0.lowercased() }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { token in haystacks.contains { $0.contains(token) } }
        case let .tilelessAgent(agent):
            // Section vocabulary as well as the agent's own name, so the block is
            // findable without remembering what the agent was called.
            let vocabulary = agent.isClosed
                ? "history closed reopen agent"
                : "agent open headless no tile"
            let haystacks = [
                agent.displayName, agent.detail ?? "", agent.statusLabel ?? "",
                agent.attentionReason?.displayName ?? "", vocabulary,
            ].map { $0.lowercased() }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { token in haystacks.contains { $0.contains(token) } }
        case let .action(action):
            if action == .previousView || action == .previousTile || action == .previousZone {
                let tokens = query.split(separator: " ").map(String.init)
                guard tokens.contains(where: { ["previous", "prev", "back"].contains($0) }) else { return false }
            }
            let displayName = action.displayName.lowercased()
            if displayName.contains(query) {
                return true
            }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { queryToken in
                action.filterTokens.contains { token in queryToken.contains(token) || token.contains(queryToken) }
            }
        case let .project(project):
            var haystacks = ["add project canvas zone", "switch project", project.name, project.rootPath, project.id.uuidString]
            if let worktreeOf = project.worktreeOf {
                haystacks += ["worktree", worktreeOf.uuidString]
            }
            let normalizedHaystacks = haystacks.map { $0.lowercased() }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { token in normalizedHaystacks.contains { $0.contains(token) } }
        case let .workspace(workspace):
            let haystacks = ["switch workspace canvas", workspace.name, workspace.id.uuidString].map { $0.lowercased() }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { token in haystacks.contains { $0.contains(token) } }
        case let .workspaceAction(action, workspace):
            let haystacks = [action.displayName, workspace.name, workspace.id.uuidString].map { $0.lowercased() }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { token in haystacks.contains { $0.contains(token) } }
        case let .jumpToTile(tile):
            let haystacks = ["jump tile go", tile.title, tile.id.uuidString].map { $0.lowercased() }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { token in haystacks.contains { $0.contains(token) } }
        case let .jumpToZone(zone):
            let haystacks = ["jump zone go", zone.title, zone.id.uuidString].map { $0.lowercased() }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { token in haystacks.contains { $0.contains(token) } }
        }
    }
}

public enum CommandCenterCategory: String, CaseIterable, Equatable, Sendable {
    case needsYou = "Needs You"
    case recent = "Recent"
    case agentsAndTiles = "Agents & Tiles"
    case workspacesAndProjects = "Workspaces & Projects"
    case actions = "Actions"
    case create = "Create"
    case models = "Choose Model"
    case developer = "Developer"
    /// LAST, deliberately: closed agents are the only rows you go looking for,
    /// so they may never displace one you did not ask for. Same reasoning as the
    /// inbox's collapsed-by-default History header (.plans/05-close-to-history.md).
    case history = "History"
}

/// Product-facing command-center copy and policy. `row` remains the stable
/// dispatch identity; the AppKit surface never has to derive language from an
/// enum case or reverse-map a cleaned-up title.
public struct CommandCenterItem: Equatable, Sendable {
    public let row: LaunchPaletteRow
    public let category: CommandCenterCategory
    public let title: String
    public let subtitle: String?
    public let iconSystemName: String
    public let aliases: [String]
    public let isDefaultVisible: Bool
    public let isSafeRecent: Bool
    public let stableID: String

    public init(
        row: LaunchPaletteRow,
        category: CommandCenterCategory,
        title: String,
        subtitle: String? = nil,
        iconSystemName: String,
        aliases: [String] = [],
        isDefaultVisible: Bool,
        isSafeRecent: Bool,
        stableID: String
    ) {
        self.row = row
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.iconSystemName = iconSystemName
        self.aliases = aliases
        self.isDefaultVisible = isDefaultVisible
        self.isSafeRecent = isSafeRecent
        self.stableID = stableID
    }
}

public struct CommandCenterSection: Equatable, Sendable {
    public let category: CommandCenterCategory
    public let items: [CommandCenterItem]

    public init(category: CommandCenterCategory, items: [CommandCenterItem]) {
        self.category = category
        self.items = items
    }
}

public enum LaunchPaletteModel {
    public static let defaultItemLimit = 12
    public static let recentItemLimit = 5

    public static func makeRows(profiles: [LaunchPaletteProfileRow], projects: [ProjectPickerRow] = [], workspaces: [WorkspaceEntry] = [], contextualActions: [LaunchPaletteAction] = [], harnessRoles: [HarnessRole] = [], jumpTiles: [JumpTileRow] = [], jumpZones: [JumpZoneRow] = [], tilelessAgents: [TilelessAgentPaletteRow] = []) -> [LaunchPaletteRow] {
        profiles.map(LaunchPaletteRow.profile)
            + CommandRegistry.paletteActions().map(LaunchPaletteRow.action)
            + contextualActions.map(LaunchPaletteRow.action)
            + harnessRoles.map { LaunchPaletteRow.action(.spawnHarnessRole($0)) }
            + jumpTiles.map(LaunchPaletteRow.jumpToTile)
            + jumpZones.map(LaunchPaletteRow.jumpToZone)
            + [LaunchPaletteRow.action(.createZone)]
            + workspaces.flatMap { workspace in
            [
                LaunchPaletteRow.workspace(workspace),
                LaunchPaletteRow.workspaceAction(.renameWorkspace(workspace.id), workspace),
                LaunchPaletteRow.workspaceAction(.deleteWorkspace(workspace.id), workspace)
            ]
        } + projects.map(LaunchPaletteRow.project)
            + tilelessAgents.map(LaunchPaletteRow.tilelessAgent)
    }

    public static func filterRows(_ rows: [LaunchPaletteRow], query: String) -> [LaunchPaletteRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        let filtered = rows.filter { $0.matches(query: normalized) }
        if let candidate = urlCandidate(from: trimmed) {
            return [.action(.openURL(candidate))] + filtered
        }
        return filtered
    }

    public static func makeSections(
        rows: [LaunchPaletteRow],
        query: String,
        recentIDs: [String] = []
    ) -> [CommandCenterSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            var matchedRows = filterRows(rows, query: trimmed)
            let normalizedTokens = trimmed.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
            for row in rows where !matchedRows.contains(row) {
                let presented = presentation(for: row)
                let haystacks = ([presented.title, presented.subtitle ?? ""] + presented.aliases).map { $0.lowercased() }
                if normalizedTokens.allSatisfy({ token in haystacks.contains(where: { $0.contains(token) }) }) {
                    matchedRows.append(row)
                }
            }
            let items = matchedRows
                .map(presentation(for:))
                .sorted { rankPrecedes($0, $1, query: trimmed) }
            return rankedSections(from: items)
        }

        let allItems = rows.map(presentation(for:))
        let byID = allItems.reduce(into: [String: CommandCenterItem]()) { result, item in
            if result[item.stableID] == nil { result[item.stableID] = item }
        }
        let needsYouItems = Array(allItems.filter { $0.category == .needsYou }.prefix(defaultItemLimit))
        let needsYouIDs = Set(needsYouItems.map(\.stableID))
        let recentItems = Array(sanitizeRecentIDs(recentIDs, rows: rows)
            .compactMap { byID[$0] }
            .filter { !needsYouIDs.contains($0.stableID) }
            .prefix(max(0, defaultItemLimit - needsYouItems.count)))
        var remaining = max(0, defaultItemLimit - needsYouItems.count - recentItems.count)
        var homeItems: [CommandCenterItem] = []
        for category in [CommandCenterCategory.create, .models, .workspacesAndProjects, .actions] {
            let candidates = allItems.filter {
                let candidate = $0
                return candidate.category == category
                    && candidate.isDefaultVisible
                    && !recentItems.contains(where: { $0.stableID == candidate.stableID })
            }
            let slice = Array(candidates.prefix(remaining))
            homeItems.append(contentsOf: slice)
            remaining -= slice.count
            if remaining == 0 { break }
        }

        var result: [CommandCenterSection] = []
        if !needsYouItems.isEmpty { result.append(CommandCenterSection(category: .needsYou, items: needsYouItems)) }
        if !recentItems.isEmpty { result.append(CommandCenterSection(category: .recent, items: recentItems)) }
        result.append(contentsOf: sections(from: homeItems, order: [.create, .models, .workspacesAndProjects, .actions]))
        return result
    }

    public static func presentation(for row: LaunchPaletteRow) -> CommandCenterItem {
        switch row {
        case let .profile(profile):
            let title = profile.displayName.lowercased() == "shell" ? "Terminal" : profile.displayName
            return item(row, .create, title, profile.detail, "terminal", [profile.id, "launch", "profile"], true, true, "profile:\(profile.id)")
        case let .agentModel(model):
            return item(row, .models, model.displayName, model.providerName, "cpu", [model.id, "agent", "model", "provider"], true, false, "agent-model:\(model.id)")
        case let .project(project):
            let subtitle = project.worktreeOf == nil ? project.rootPath : "Worktree · \(project.rootPath)"
            return item(row, .workspacesAndProjects, project.name, subtitle, "folder", ["project", "canvas", "add"], true, true, "project:\(project.id.uuidString)")
        case let .workspace(workspace):
            let count = workspace.projectIds.count
            return item(row, .workspacesAndProjects, workspace.name, "Workspace · \(count) project\(count == 1 ? "" : "s")", "square.grid.2x2", ["switch", "workspace"], true, true, "workspace:\(workspace.id.uuidString)")
        case let .workspaceAction(action, workspace):
            switch action {
            case .renameWorkspace:
                return item(row, .developer, "Rename \(workspace.name)", "Workspace administration", "pencil", ["workspace"], false, false, "workspace-rename:\(workspace.id.uuidString)")
            case .deleteWorkspace:
                return item(row, .developer, "Delete \(workspace.name)", "Workspace administration", "trash", ["workspace", "remove"], false, false, "workspace-delete:\(workspace.id.uuidString)")
            default:
                return actionPresentation(action, row: row)
            }
        case let .jumpToTile(tile):
            let category: CommandCenterCategory = tile.attentionReason == nil ? .agentsAndTiles : .needsYou
            let kind = tile.kind?.displayName ?? "Tile"
            var subtitleParts: [String] = []
            if let attention = tile.attentionReason { subtitleParts.append(attention.displayName) }
            if let status = tile.statusLabel, tile.attentionReason == nil { subtitleParts.append(status) }
            if let model = tile.modelDisplayName { subtitleParts.append(model) }
            if let context = tile.contextTitle { subtitleParts.append(context) }
            if subtitleParts.isEmpty { subtitleParts.append(kind) }
            let aliases = ["jump", "go", "tile", kind, tile.modelID, tile.modelDisplayName, tile.contextTitle, tile.statusLabel, tile.attentionReason?.displayName]
                .compactMap { $0 }
            let icon = tile.kind == .managedAgent ? "sparkles" : "rectangle.on.rectangle"
            return item(row, category, tile.title, subtitleParts.joined(separator: " · "), icon, aliases, tile.attentionReason != nil, true, "tile:\(tile.id.uuidString)")
        case let .jumpToZone(zone):
            return item(row, .agentsAndTiles, zone.title, "Zone", "square.dashed", ["jump", "go", "zone"], false, true, "zone:\(zone.id.uuidString)")
        case let .tilelessAgent(agent):
            // A CLOSED agent draws in History: it is the block you go looking for,
            // so it is never volunteered onto the empty-query home and is never a
            // safe recent (reopening ends its membership, leaving the recent
            // pointing at a section the agent has left).
            //
            // A merely TILE-LESS agent — headless, snoozed or settled — is live
            // work with nowhere to show, so it draws with the other agents, and is
            // promoted to Needs You when it is blocked on the user exactly as a
            // tiled agent would be. Those ARE default-visible: an agent waiting on
            // you must not be something you have to know to search for.
            let attention = agent.attentionReason
            let category: CommandCenterCategory = agent.isClosed
                ? .history
                : (attention == nil ? .agentsAndTiles : .needsYou)
            let lead = agent.isClosed ? "Closed" : (attention?.displayName ?? agent.statusLabel ?? "No tile")
            let subtitle = [lead, agent.detail].compactMap { $0 }.joined(separator: " · ")
            let icon = agent.isClosed ? "clock.arrow.circlepath" : "sparkles"
            let aliases = agent.isClosed
                ? ["history", "closed", "reopen", "agent"]
                : ["agent", "open", "no tile", "headless", attention?.displayName, agent.statusLabel]
                    .compactMap { $0 }
            return item(row, category, agent.displayName, subtitle, icon, aliases,
                        agent.isClosed ? false : attention != nil, false,
                        "tileless-agent:\(agent.agentId.uuidString)")
        case let .action(action):
            return actionPresentation(action, row: row)
        }
    }

    public static func sanitizeRecentIDs(_ ids: [String], rows: [LaunchPaletteRow]) -> [String] {
        let safe = rows.map(presentation(for:)).filter(\.isSafeRecent).reduce(into: [String: CommandCenterItem]()) { result, item in
            result[item.stableID] = item
        }
        var seen = Set<String>()
        return ids.filter { safe[$0] != nil && seen.insert($0).inserted }.prefix(recentItemLimit).map { $0 }
    }

    public static func recordingRecent(_ row: LaunchPaletteRow, in ids: [String], succeeded: Bool) -> [String] {
        let presented = presentation(for: row)
        guard succeeded, presented.isSafeRecent else { return ids }
        return Array(([presented.stableID] + ids.filter { $0 != presented.stableID }).prefix(recentItemLimit))
    }

    private static func sections(from items: [CommandCenterItem], order: [CommandCenterCategory]) -> [CommandCenterSection] {
        order.compactMap { category in
            let members = items.filter { $0.category == category }
            return members.isEmpty ? nil : CommandCenterSection(category: category, items: members)
        }
    }

    private static func rankedSections(from items: [CommandCenterItem]) -> [CommandCenterSection] {
        var order: [CommandCenterCategory] = []
        var grouped: [CommandCenterCategory: [CommandCenterItem]] = [:]
        for item in items {
            if grouped[item.category] == nil { order.append(item.category) }
            grouped[item.category, default: []].append(item)
        }
        return order.map { CommandCenterSection(category: $0, items: grouped[$0] ?? []) }
    }

    private static func searchRank(for item: CommandCenterItem, query: String) -> (Int, Int, String) {
        let normalized = query.lowercased()
        let title = item.title.lowercased()
        let match: Int
        if title == normalized { match = 0 }
        else if title.hasPrefix(normalized) { match = 1 }
        else if title.contains(normalized) { match = 2 }
        else { match = 3 }
        let category = [CommandCenterCategory.needsYou, .agentsAndTiles, .workspacesAndProjects, .actions, .create, .models, .developer].firstIndex(of: item.category) ?? 99
        return (match, category, title)
    }

    private static func rankPrecedes(_ lhs: CommandCenterItem, _ rhs: CommandCenterItem, query: String) -> Bool {
        let left = searchRank(for: lhs, query: query)
        let right = searchRank(for: rhs, query: query)
        if left.0 != right.0 { return left.0 < right.0 }
        if left.1 != right.1 { return left.1 < right.1 }
        return left.2 < right.2
    }

    private static func actionPresentation(_ action: LaunchPaletteAction, row: LaunchPaletteRow) -> CommandCenterItem {
        switch action {
        case .newManagedAgent: return item(row, .create, "Agent", "Start a focused coding session", "sparkles", ["new", "managed", "assistant"], true, true, "action:new-agent")
        case .newHeadlessAgent: return item(row, .developer, "Background agent", "Run without a canvas tile", "bolt.horizontal", ["headless", "tileless"], false, false, "action:headless-agent")
        case .fanOutQueueSelection: return item(row, .developer, "Fan out selected tickets", "Start one agent per selected ticket", "arrow.triangle.branch", ["queue", "batch"], false, false, "action:fan-out")
        case .newNote: return item(row, .create, "Note", "Add a canvas note", "note.text", ["new"], true, true, "action:new-note")
        case .newBrowser: return item(row, .create, "Browser", "Open a web tile", "globe", ["new", "web"], true, true, "action:new-browser")
        case .openFile: return item(row, .actions, "Open file", "Choose a file in this project", "doc", [], false, true, "action:open-file")
        case .openFileTree: return item(row, .create, "File tree", "Browse project files", "list.bullet.indent", ["open"], true, true, "action:file-tree")
        case .newDiffReview: return item(row, .create, "Diff review", "Review working changes", "plusminus", ["git", "new"], true, true, "action:diff-review")
        case .fitCanvasToAll: return item(row, .actions, "Show entire canvas", "Fit every tile and zone", "arrow.up.left.and.arrow.down.right", ["fit", "zoom", "all"], true, true, "action:fit-canvas")
        case .previousView: return item(row, .actions, "Previous view", "Return to the last canvas view", "arrow.uturn.backward", ["back"], false, true, "action:previous-view")
        case .previousTile: return item(row, .actions, "Previous tile", "Return to the last focused tile", "arrow.left.to.line", ["back", "jump"], false, true, "action:previous-tile")
        case .previousZone: return item(row, .actions, "Previous zone", "Return to the last focused zone", "arrow.left.to.line.compact", ["back", "jump"], false, true, "action:previous-zone")
        case .toggleWorkspaceSidebar: return item(row, .developer, "Activity dock", "Show or hide workspace navigation", "sidebar.left", ["toggle", "sidebar"], false, true, "action:activity-dock")
        case let .openURL(url): return item(row, .actions, "Open \(url)", "Browser", "globe", ["url", "web"], false, true, "url:\(url)")
        case let .switchProject(id): return item(row, .workspacesAndProjects, "Switch project", nil, "folder", [], false, true, "project-switch:\(id.uuidString)")
        case let .addProjectToCanvas(id): return item(row, .workspacesAndProjects, "Add project", "Place on this canvas", "folder.badge.plus", [], false, true, "project-add:\(id.uuidString)")
        case .newWorkspace: return item(row, .create, "Workspace", "Create a spatial workspace", "square.grid.2x2", ["new"], true, true, "action:new-workspace")
        case let .renameWorkspace(id): return item(row, .developer, "Rename workspace", nil, "pencil", [], false, false, "workspace-rename:\(id.uuidString)")
        case let .deleteWorkspace(id): return item(row, .developer, "Delete workspace", nil, "trash", [], false, false, "workspace-delete:\(id.uuidString)")
        case let .switchWorkspace(id): return item(row, .workspacesAndProjects, "Switch workspace", nil, "square.grid.2x2", [], false, true, "workspace-switch:\(id.uuidString)")
        case .openInspectorForFocusedBrowser: return item(row, .developer, "Inspect current browser", "Open Web Inspector", "wrench.and.screwdriver", ["focused"], false, true, "action:browser-inspector")
        case let .spawnHarnessRole(role): return item(row, .developer, role.displayName, "Harness agent", "hammer", ["run", "spawn", "role"], false, false, "harness:\(role.id)")
        case let .jumpToTile(id): return item(row, .agentsAndTiles, "Tile", nil, "rectangle.on.rectangle", ["jump"], false, true, "tile:\(id.uuidString)")
        case let .jumpToZone(id): return item(row, .agentsAndTiles, "Zone", nil, "square.dashed", ["jump"], false, true, "zone:\(id.uuidString)")
        case .createZone: return item(row, .create, "Zone", "Group related canvas work", "square.dashed", ["new", "create"], true, true, "action:create-zone")
        }
    }

    private static func item(_ row: LaunchPaletteRow, _ category: CommandCenterCategory, _ title: String, _ subtitle: String?, _ icon: String, _ aliases: [String], _ defaultVisible: Bool, _ safeRecent: Bool, _ stableID: String) -> CommandCenterItem {
        CommandCenterItem(row: row, category: category, title: title, subtitle: subtitle, iconSystemName: icon, aliases: aliases, isDefaultVisible: defaultVisible, isSafeRecent: safeRecent, stableID: stableID)
    }

    public static func urlCandidate(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }

        if let schemeRange = trimmed.range(of: "://") {
            let scheme = String(trimmed[..<schemeRange.lowerBound])
            guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else { return nil }
            return trimmed
        }

        let host = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
        let hostWithoutPort = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
        guard host.contains(".") || hostWithoutPort == "localhost" else { return nil }
        let scheme = usesLocalHTTP(host: host) ? "http" : "https"
        return "\(scheme)://\(trimmed)"
    }

    private static func usesLocalHTTP(host: String) -> Bool {
        let hostWithoutPort = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
        if hostWithoutPort == "localhost" { return true }
        let octets = hostWithoutPort.split(separator: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard let value = Int(octet), String(value) == octet else { return false }
            return (0 ... 255).contains(value)
        }
    }

    public static func isFileURL(_ fileURL: URL, insideProjectRoot projectRoot: URL) -> Bool {
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let rootComponents = projectRoot.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count else { return false }
        return Array(fileComponents.prefix(rootComponents.count)) == rootComponents
    }
}
