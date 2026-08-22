import Foundation

// Queue 91 spatial awareness — provider-neutral Home / Where / What contracts.
//
// HOST-LOCAL BY CONSTRUCTION. Home and Where carry absolute filesystem paths,
// so none of the types in this file conform to Codable. A future companion or
// spatial projection must be a separate scrubbed value, following
// AgentInventory/AgentActivityEvent rather than making this snapshot encodable.
// Provider session ids, transcript locators, resume cursors, runtime payloads,
// and pane handles do not belong in this contract.

/// Whether a filesystem location is the checkout root, inside it, or outside it.
/// Classification is component-aware and resolves existing symlink ancestors so
/// an in-Home link to an outside target remains visibly outside. This relation is
/// still display evidence, not filesystem authorization: access policy must make
/// its own race-safe decision at the operation boundary.
public enum AgentPathRelation: String, Equatable, Sendable {
    case root
    case inside
    case outside

    public static func classify(_ location: URL, relativeTo root: URL) -> AgentPathRelation {
        let locationComponents = symlinkAwareFileURL(location).pathComponents
        let rootComponents = symlinkAwareFileURL(root).pathComponents
        if locationComponents == rootComponents { return .root }
        guard locationComponents.count > rootComponents.count,
              locationComponents.prefix(rootComponents.count).elementsEqual(rootComponents) else {
            return .outside
        }
        return .inside
    }

    static func relativePath(_ location: URL, relativeTo root: URL) -> String? {
        let normalizedLocation = symlinkAwareFileURL(location)
        let normalizedRoot = symlinkAwareFileURL(root)
        guard classify(normalizedLocation, relativeTo: normalizedRoot) == .inside else {
            return nil
        }
        return normalizedLocation.pathComponents
            .dropFirst(normalizedRoot.pathComponents.count)
            .joined(separator: "/")
    }
}

/// Stable project/check-out identity: where the agent fundamentally belongs.
/// `projectRoot` names the registered logical project; `checkoutRoot` names the
/// concrete main checkout or isolated worktree this agent owns.
public struct AgentHome: Equatable, Sendable {
    public let projectId: UUID?
    public let projectRoot: URL?
    public let checkoutRoot: URL
    /// Logical Home relative to the checkout. nil means checkout root. Keeping
    /// it logical lets the same project subfolder map into an isolated worktree.
    public let homeRelativePath: String?

    public init(
        projectId: UUID?,
        projectRoot: URL?,
        checkoutRoot: URL,
        homeRelativePath: String? = nil
    ) {
        self.projectId = projectId
        self.projectRoot = projectRoot.map(normalizedDirectoryURL)
        self.checkoutRoot = normalizedDirectoryURL(checkoutRoot)
        self.homeRelativePath = homeRelativePath
    }

    public var homeRoot: URL {
        guard let homeRelativePath, !homeRelativePath.isEmpty else { return checkoutRoot }
        return normalizedDirectoryURL(
            checkoutRoot.appendingPathComponent(homeRelativePath, isDirectory: true)
        )
    }
}

/// The agent runtime's current working directory, interpreted against Home.
public struct AgentWorkingLocation: Equatable, Sendable {
    public let directory: URL
    public let relationToHome: AgentPathRelation
    /// Present only for a directory inside the checkout. Root is represented by
    /// `.root` plus nil rather than the synthetic path `.`.
    public let relativePath: String?

    public init(directory: URL, home: AgentHome) {
        let normalized = normalizedDirectoryURL(directory)
        self.directory = normalized
        self.relationToHome = AgentPathRelation.classify(normalized, relativeTo: home.homeRoot)
        self.relativePath = AgentPathRelation.relativePath(normalized, relativeTo: home.homeRoot)
    }
}

/// One observed current/recent activity fact. It describes work; it never owns
/// or mutates Home/Where. `AgentLocationSnapshot` relates its optional path to
/// Home so this provider evidence cannot carry a stale relation from elsewhere.
public struct AgentObservedActivity: Equatable, Sendable {
    public enum Operation: String, Equatable, Sendable {
        case reading
        case editing
        case running
        case searching
        case thinking
        case waiting
        case completed
        case interrupted
        case failed
        case messaging
        case inspecting
    }

    public enum EvidenceSource: String, Equatable, Sendable {
        case toolEvent
        case lifecycleEvent
        case hostAction
    }

    public let operation: Operation
    public let targetPath: URL?
    public let startedAt: Date
    public let updatedAt: Date
    public let evidenceSource: EvidenceSource

    public init(
        operation: Operation,
        targetPath: URL?,
        startedAt: Date,
        updatedAt: Date,
        evidenceSource: EvidenceSource
    ) {
        self.operation = operation
        self.targetPath = targetPath.map(normalizedFileURL)
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.evidenceSource = evidenceSource
    }
}

/// The single host-local snapshot UI, harness tools, and provider adapters will
/// consume. This first slice derives legacy agents without changing persistence:
/// existing `AgentRecord.cwd` remains both checkout root and Where until a later
/// migration introduces independently persisted location facts.
public struct AgentLocationSnapshot: Equatable, Sendable {
    public let home: AgentHome
    public let workingLocation: AgentWorkingLocation
    /// What the agent is doing now, subject to the projector's stale window.
    public let what: AgentObservedActivity?
    public let whatRelationToHome: AgentPathRelation?
    /// Exact host-local instant when current What should be re-projected as
    /// stale. nil for hand-built/legacy snapshots and whenever current What is
    /// already absent.
    public let whatExpiresAt: Date?
    /// Last meaningful tool activity, retained separately when current What has
    /// advanced to thinking/waiting/completed or expired.
    public let lastUsefulWhat: AgentObservedActivity?
    public let lastUsefulWhatRelationToHome: AgentPathRelation?

    public init(
        home: AgentHome,
        whereDirectory: URL,
        what: AgentObservedActivity? = nil,
        whatExpiresAt: Date? = nil,
        lastUsefulWhat: AgentObservedActivity? = nil
    ) {
        self.home = home
        self.workingLocation = AgentWorkingLocation(directory: whereDirectory, home: home)
        self.what = what
        self.whatRelationToHome = what?.targetPath.map {
            AgentPathRelation.classify($0, relativeTo: home.homeRoot)
        }
        self.whatExpiresAt = what == nil ? nil : whatExpiresAt
        self.lastUsefulWhat = lastUsefulWhat
        self.lastUsefulWhatRelationToHome = lastUsefulWhat?.targetPath.map {
            AgentPathRelation.classify($0, relativeTo: home.homeRoot)
        }
    }

    /// Projection for both v2 records and legacy records. v1 decoding migrates
    /// `cwd` into checkout, Home and Where, so callers always consume the four
    /// distinct roles without branching on schema version.
    public static func legacy(
        record: AgentRecord,
        projectRoot: URL? = nil,
        what: AgentObservedActivity? = nil
    ) -> AgentLocationSnapshot {
        let checkout = URL(fileURLWithPath: record.checkoutRoot, isDirectory: true)
        let whereDirectory = URL(fileURLWithPath: record.lastObservedWhere, isDirectory: true)
        let persistedProjectRoot = record.projectRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let home = AgentHome(
            projectId: record.projectId,
            projectRoot: persistedProjectRoot ?? projectRoot,
            checkoutRoot: checkout,
            homeRelativePath: record.homeRelativePath)
        return AgentLocationSnapshot(home: home, whereDirectory: whereDirectory, what: what)
    }
}

private func normalizedDirectoryURL(_ url: URL) -> URL {
    normalizedFileURL(URL(fileURLWithPath: url.path, isDirectory: true))
}

private func normalizedFileURL(_ url: URL) -> URL {
    guard url.isFileURL else { return url.standardized }
    let expanded = (url.path as NSString).expandingTildeInPath
    let standardized = (expanded as NSString).standardizingPath
    return URL(fileURLWithPath: standardized, isDirectory: url.hasDirectoryPath).standardizedFileURL
}

/// Resolves the deepest existing ancestor, then restores any not-yet-created
/// suffix. Resolving only the complete URL would miss an edit target whose leaf
/// does not exist yet but whose parent traverses a symlink outside Home.
private func symlinkAwareFileURL(_ url: URL) -> URL {
    guard url.isFileURL else { return url.standardized }
    let normalized = normalizedFileURL(url)
    var existingAncestor = normalized
    var missingSuffix: [String] = []
    let fileManager = FileManager.default

    while existingAncestor.path != "/",
          !fileManager.fileExists(atPath: existingAncestor.path) {
        missingSuffix.insert(existingAncestor.lastPathComponent, at: 0)
        existingAncestor.deleteLastPathComponent()
    }

    var resolved = existingAncestor.resolvingSymlinksInPath()
    for component in missingSuffix {
        resolved.appendPathComponent(component, isDirectory: false)
    }
    return normalizedFileURL(resolved)
}
