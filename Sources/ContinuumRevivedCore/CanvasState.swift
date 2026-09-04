import Foundation

public struct CanvasState: Equatable, Sendable {
    /// v1: original shape. v2: `Tile.zoneId` LWW membership register (ticket 03).
    /// v3: `Tile.zPosition` fractional z-index replaces `Tile.zIndex` (ticket 04).
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public var viewport: CanvasViewport
    public var tiles: [Tile]
    public var groups: [TileGroup]
    public var lastActiveTileId: UUID?

    public init(
        schemaVersion: Int = CanvasState.currentSchemaVersion,
        viewport: CanvasViewport,
        tiles: [Tile],
        groups: [TileGroup],
        lastActiveTileId: UUID?
    ) {
        self.schemaVersion = schemaVersion
        self.viewport = viewport
        self.tiles = tiles
        self.groups = groups
        self.lastActiveTileId = lastActiveTileId
    }
}

extension CanvasState: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, viewport, tiles, groups, lastActiveTileId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(Int.self, forKey: .schemaVersion)
        // Migrate-forward-on-load: any supported older version decodes into the
        // CURRENT in-memory shape (new fields defaulted by Tile's decoder), so it
        // is stamped current here. Future versions keep their stamp so the schema
        // guard (`ProjectStore.checkSchema`) fires instead of silently downgrading.
        schemaVersion = decodedVersion <= CanvasState.currentSchemaVersion
            ? CanvasState.currentSchemaVersion
            : decodedVersion
        viewport = try container.decode(CanvasViewport.self, forKey: .viewport)
        tiles = try container.decode([Tile].self, forKey: .tiles)
        groups = try container.decode([TileGroup].self, forKey: .groups)
        lastActiveTileId = try container.decodeIfPresent(UUID.self, forKey: .lastActiveTileId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Re-stamp on save: the encoder always writes the shape it knows, which is
        // by definition the current schema — never an older stamp a decoded value
        // might still carry. (`max` keeps a future stamp intact so an accidental
        // save of an unmigratable document stays loud on the next load.)
        try container.encode(Swift.max(schemaVersion, CanvasState.currentSchemaVersion), forKey: .schemaVersion)
        try container.encode(viewport, forKey: .viewport)
        try container.encode(tiles, forKey: .tiles)
        try container.encode(groups, forKey: .groups)
        try container.encodeIfPresent(lastActiveTileId, forKey: .lastActiveTileId)
    }
}

public struct CanvasViewport: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var zoom: Double

    public init(x: Double, y: Double, zoom: Double) {
        self.x = x
        self.y = y
        self.zoom = zoom
    }
}

public struct Tile: Equatable, Sendable {
    public let id: UUID
    public var kind: TileKind
    public var title: String
    public var frame: TileFrame
    /// Stacking order as a fractional-index LWW register (ticket 04): a
    /// reorder is a field set on the tile, not a mutation of a shared slot
    /// structure, so concurrent reorders converge. Render/hit-test order is
    /// the (zPosition, id) sort — never array order. This is the field
    /// `Op.setTileZIndex` folds into.
    public var zPosition: FracIndex
    /// Group-zone membership as a last-writer-wins register ON the tile:
    /// nil = ambient (no zone); non-nil = the one zone that owns this tile.
    /// "A tile belongs to at most one zone" is a consequence of the type,
    /// not a post-merge repair. This is the field `Op.setTileZone` folds into.
    public var zoneId: UUID?
    public var runtimeRef: RuntimeRef?
    public var metadata: TileMetadata

    public init(
        id: UUID,
        kind: TileKind,
        title: String,
        frame: TileFrame,
        zPosition: FracIndex,
        zoneId: UUID? = nil,
        runtimeRef: RuntimeRef?,
        metadata: TileMetadata
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.frame = frame
        self.zPosition = zPosition
        self.zoneId = zoneId
        self.runtimeRef = runtimeRef
        self.metadata = metadata
    }

    public func with(zoneId: UUID?) -> Tile {
        var copy = self
        copy.zoneId = zoneId
        return copy
    }
}

extension Tile: Codable {
    private enum CodingKeys: String, CodingKey {
        // `zIndex` is decode-only: the pre-v3 integer rank. Never re-emitted.
        case id, kind, title, frame, zPosition, zIndex, zoneId, runtimeRef, metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(TileKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        frame = try container.decode(TileFrame.self, forKey: .frame)
        if let position = try container.decodeIfPresent(FracIndex.self, forKey: .zPosition) {
            zPosition = position
        } else {
            // Pre-v3 tile: migrate the legacy integer rank through the
            // order-preserving map. Self-contained per tile, so every
            // embedding (project canvas, workspace ambientTiles) migrates
            // identically with no container-level second pass.
            let legacy = try container.decode(Int.self, forKey: .zIndex)
            zPosition = FracIndex.fromLegacyRank(legacy)
        }
        // Pre-v2 canvases have no zoneId key: every tile decodes as ambient.
        zoneId = try container.decodeIfPresent(UUID.self, forKey: .zoneId)
        runtimeRef = try container.decodeIfPresent(RuntimeRef.self, forKey: .runtimeRef)
        metadata = try container.decode(TileMetadata.self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(frame, forKey: .frame)
        try container.encode(zPosition, forKey: .zPosition)
        try container.encodeIfPresent(zoneId, forKey: .zoneId)
        try container.encodeIfPresent(runtimeRef, forKey: .runtimeRef)
        try container.encode(metadata, forKey: .metadata)
    }
}

public enum TileKind: String, Codable, Equatable, Sendable, CaseIterable {
    case terminal
    case browser
    case browserInspector
    case note
    case file
    case fileTree
    case ticketQueue
    case conductorQueue
    case diffReview
    case runArtifacts
    case managedAgent

    /// Human label for chrome. `rawValue.capitalized` produced "Managedagent",
    /// "Filetree", "Browserinspector" — camelCase gets lowercased after the
    /// first letter.
    public var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .browser: return "Browser"
        case .browserInspector: return "Inspector"
        case .note: return "Note"
        case .file: return "Editor"
        case .fileTree: return "File Tree"
        case .ticketQueue: return "Tickets"
        case .conductorQueue: return "Queue"
        case .diffReview: return "Diff"
        case .runArtifacts: return "Artifacts"
        case .managedAgent: return "Agent"
        }
    }
}

public struct TileFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct RuntimeRef: Codable, Equatable, Sendable {
    public var kind: RuntimeRefKind
    public var id: UUID

    public init(kind: RuntimeRefKind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}

public enum RuntimeRefKind: String, Codable, Equatable, Sendable {
    case terminalSession
    case browserTile
    case note
    case file
}

/// The reading/editing presentation selected for a Markdown-bearing tile.
/// Stored with the tile so workspace switching and relaunch preserve intent.
public enum MarkdownDocumentMode: String, Codable, Equatable, Sendable {
    case preview
    case split
    case edit
}

/// Small, component-independent editor presentation state. The editor's text,
/// undo stack and recovery draft are document state and deliberately do not
/// belong in canvas metadata.
public struct FileEditorViewState: Codable, Equatable, Sendable {
    public var sidebarExpanded: Bool
    public var sidebarWidth: Double
    public var expandedPaths: [String]
    public var selectedPath: String?
    public var searchQuery: String
    public var cursorLine: Int
    public var cursorColumn: Int
    public var verticalScrollOffset: Double
    public var horizontalScrollOffset: Double

    public init(
        sidebarExpanded: Bool = false,
        sidebarWidth: Double = 220,
        expandedPaths: [String] = [],
        selectedPath: String? = nil,
        searchQuery: String = "",
        cursorLine: Int = 1,
        cursorColumn: Int = 1,
        verticalScrollOffset: Double = 0,
        horizontalScrollOffset: Double = 0
    ) {
        self.sidebarExpanded = sidebarExpanded
        self.sidebarWidth = sidebarWidth
        self.expandedPaths = expandedPaths
        self.selectedPath = selectedPath
        self.searchQuery = searchQuery
        self.cursorLine = cursorLine
        self.cursorColumn = cursorColumn
        self.verticalScrollOffset = verticalScrollOffset
        self.horizontalScrollOffset = horizontalScrollOffset
    }
}

public struct TileMetadata: Codable, Equatable, Sendable {
    public var launchProfileId: String?
    public var projectRelativeCwd: String?
    public var url: String?
    public var noteId: UUID?
    public var filePath: String?
    public var documentLocation: DocumentLocation?
    public var browserProfileId: UUID?
    public var linearTeamKey: String?
    public var linearTeamId: String?
    public var linearQuery: String?
    public var reviewId: UUID?
    public var diffSource: String?
    public var baseBranch: String?
    public var branch: String?
    /// Durable filesystem identity for Shell/File Tree (and any future
    /// filesystem-backed tile). Visual zone membership never rewrites these.
    public var filesystemProjectId: UUID?
    public var filesystemCheckoutRootPath: String?
    public var filesystemHomeRelativePath: String?
    public var filesystemWherePath: String?
    public var worktreeId: String?
    public var agentSoundOverrides: AgentSoundOverrides?
    /// Optional for backwards-compatible decoding of existing canvases.
    public var markdownDocumentMode: MarkdownDocumentMode?
    /// Optional so canvases written before the rich editor remain decodable.
    public var fileEditorViewState: FileEditorViewState?

    public init(
        launchProfileId: String? = nil,
        projectRelativeCwd: String? = nil,
        url: String? = nil,
        noteId: UUID? = nil,
        filePath: String? = nil,
        documentLocation: DocumentLocation? = nil,
        browserProfileId: UUID? = nil,
        linearTeamKey: String? = nil,
        linearTeamId: String? = nil,
        linearQuery: String? = nil,
        reviewId: UUID? = nil,
        diffSource: String? = nil,
        baseBranch: String? = nil,
        branch: String? = nil,
        filesystemProjectId: UUID? = nil,
        filesystemCheckoutRootPath: String? = nil,
        filesystemHomeRelativePath: String? = nil,
        filesystemWherePath: String? = nil,
        worktreeId: String? = nil,
        agentSoundOverrides: AgentSoundOverrides? = nil,
        markdownDocumentMode: MarkdownDocumentMode? = nil,
        fileEditorViewState: FileEditorViewState? = nil
    ) {
        self.launchProfileId = launchProfileId
        self.projectRelativeCwd = projectRelativeCwd
        self.url = url
        self.noteId = noteId
        self.filePath = filePath
        self.documentLocation = documentLocation
        self.browserProfileId = browserProfileId
        self.linearTeamKey = linearTeamKey
        self.linearTeamId = linearTeamId
        self.linearQuery = linearQuery
        self.reviewId = reviewId
        self.diffSource = diffSource
        self.baseBranch = baseBranch
        self.branch = branch
        self.filesystemProjectId = filesystemProjectId
        self.filesystemCheckoutRootPath = filesystemCheckoutRootPath
        self.filesystemHomeRelativePath = filesystemHomeRelativePath
        self.filesystemWherePath = filesystemWherePath
        self.worktreeId = worktreeId
        self.agentSoundOverrides = agentSoundOverrides
        self.markdownDocumentMode = markdownDocumentMode
        self.fileEditorViewState = fileEditorViewState
    }

    private enum CodingKeys: String, CodingKey {
        case launchProfileId
        case projectRelativeCwd
        case url
        case noteId
        case filePath
        case documentLocation
        case browserProfileId
        case linearTeamKey
        case linearTeamId
        case linearQuery
        case reviewId
        case diffSource
        case baseBranch
        case branch
        case filesystemProjectId
        case filesystemCheckoutRootPath
        case filesystemHomeRelativePath
        case filesystemWherePath
        case worktreeId
        case agentSoundOverrides
        case markdownDocumentMode
        case fileEditorViewState
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(launchProfileId, forKey: .launchProfileId)
        try container.encodeIfPresent(projectRelativeCwd, forKey: .projectRelativeCwd)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(noteId, forKey: .noteId)
        try container.encodeIfPresent(filePath, forKey: .filePath)
        try container.encodeIfPresent(documentLocation, forKey: .documentLocation)
        try container.encodeIfPresent(browserProfileId, forKey: .browserProfileId)
        try container.encodeIfPresent(linearTeamKey, forKey: .linearTeamKey)
        try container.encodeIfPresent(linearTeamId, forKey: .linearTeamId)
        try container.encodeIfPresent(linearQuery, forKey: .linearQuery)
        try container.encodeIfPresent(reviewId, forKey: .reviewId)
        try container.encodeIfPresent(diffSource, forKey: .diffSource)
        try container.encodeIfPresent(baseBranch, forKey: .baseBranch)
        try container.encodeIfPresent(branch, forKey: .branch)
        try container.encodeIfPresent(filesystemProjectId, forKey: .filesystemProjectId)
        try container.encodeIfPresent(filesystemCheckoutRootPath, forKey: .filesystemCheckoutRootPath)
        try container.encodeIfPresent(filesystemHomeRelativePath, forKey: .filesystemHomeRelativePath)
        try container.encodeIfPresent(filesystemWherePath, forKey: .filesystemWherePath)
        try container.encodeIfPresent(worktreeId, forKey: .worktreeId)
        try container.encodeIfPresent(agentSoundOverrides, forKey: .agentSoundOverrides)
        try container.encodeIfPresent(markdownDocumentMode, forKey: .markdownDocumentMode)
        try container.encodeIfPresent(fileEditorViewState, forKey: .fileEditorViewState)
    }
}

public struct TileGroup: Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var tileIds: [UUID]
    public var color: String
    public var collapsed: Bool

    public init(id: UUID, title: String, tileIds: [UUID], color: String, collapsed: Bool) {
        self.id = id
        self.title = title
        self.tileIds = tileIds
        self.color = color
        self.collapsed = collapsed
    }
}
