import Foundation

/// Host-local identity and directory scope for a document tile.
///
/// `path` is the canonical concrete file identity used for workspace-wide
/// deduplication. A checkout scope is trusted only after component-based,
/// symlink-aware containment has been established by `DocumentLocationResolver`.
public struct DocumentLocation: Codable, Equatable, Sendable {
    public enum Scope: Codable, Equatable, Sendable {
        case checkout(projectId: UUID?, rootPath: String, relativePath: String)
        case standalone
    }

    public var path: String
    public var scope: Scope

    public init(path: String, scope: Scope) {
        self.path = path
        self.scope = scope
    }

    public var projectId: UUID? {
        guard case let .checkout(projectId, _, _) = scope else { return nil }
        return projectId
    }

    public var checkoutRootPath: String? {
        guard case let .checkout(_, rootPath, _) = scope else { return nil }
        return rootPath
    }

    public var relativePath: String? {
        guard case let .checkout(_, _, relativePath) = scope else { return nil }
        return relativePath
    }

    /// Directory contributed to spatial agent context. A root-level file emits
    /// `.` rather than an empty path.
    public var relativeDirectory: String? {
        guard let relativePath else { return nil }
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? "." : parent
    }
}

public struct DocumentLocationRoot: Equatable, Sendable {
    public var rootURL: URL
    public var projectId: UUID?

    public init(rootURL: URL, projectId: UUID?) {
        self.rootURL = rootURL
        self.projectId = projectId
    }
}

public enum DocumentLocationResolver {
    /// Resolves a concrete file against the most-specific known checkout. Pass an
    /// explicit root for an agent-authored link; it wins even if another registered
    /// root also contains the path.
    public static func resolve(
        fileURL: URL,
        explicitRoot: DocumentLocationRoot? = nil,
        knownRoots: [DocumentLocationRoot] = []
    ) -> DocumentLocation {
        let file = canonical(fileURL, isDirectory: false)
        if let explicitRoot, let scoped = scopedLocation(file: file, root: explicitRoot) {
            return scoped
        }
        let candidates = knownRoots.compactMap { root -> (DocumentLocation, Int)? in
            guard let location = scopedLocation(file: file, root: root) else { return nil }
            return (location, canonical(root.rootURL, isDirectory: true).pathComponents.count)
        }
        if let best = candidates.max(by: { $0.1 < $1.1 })?.0 { return best }
        return DocumentLocation(path: file.path, scope: .standalone)
    }

    public static func contains(_ fileURL: URL, in rootURL: URL) -> Bool {
        let file = canonical(fileURL, isDirectory: false)
        let root = canonical(rootURL, isDirectory: true)
        let rootComponents = root.pathComponents
        let fileComponents = file.pathComponents
        guard fileComponents.count > rootComponents.count else { return false }
        return Array(fileComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func scopedLocation(file: URL, root: DocumentLocationRoot) -> DocumentLocation? {
        let canonicalRoot = canonical(root.rootURL, isDirectory: true)
        guard contains(file, in: canonicalRoot) else { return nil }
        let relative = file.pathComponents.dropFirst(canonicalRoot.pathComponents.count).joined(separator: "/")
        guard !relative.isEmpty else { return nil }
        return DocumentLocation(
            path: file.path,
            scope: .checkout(projectId: root.projectId, rootPath: canonicalRoot.path, relativePath: relative)
        )
    }

    private static func canonical(_ url: URL, isDirectory: Bool) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: isDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }
}

/// A durable workspace-local relationship between one stable agent and one
/// concrete document tile. Equality includes timestamps; workspace helpers own
/// pair-based deduplication.
public struct DocumentAgentLink: Codable, Equatable, Sendable {
    public var agentId: AgentID
    public var documentTileId: UUID
    public var createdAt: Date
    public var updatedAt: Date

    public init(agentId: AgentID, documentTileId: UUID, createdAt: Date, updatedAt: Date) {
        self.agentId = agentId
        self.documentTileId = documentTileId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
