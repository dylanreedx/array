import Foundation

/// The four filesystem concepts Array presents separately. A logical Home is
/// stored relative to the registered project so it can be mapped into either
/// the main checkout or an agent-specific worktree without ever pointing back
/// into the main checkout.
public struct FilesystemScope: Codable, Equatable, Sendable {
    public var projectId: UUID
    public var projectRoot: String
    public var checkoutRoot: String
    public var homeRelativePath: String?
    public var wherePath: String

    public init(
        projectId: UUID,
        projectRoot: String,
        checkoutRoot: String,
        homeRelativePath: String? = nil,
        wherePath: String
    ) {
        self.projectId = projectId
        self.projectRoot = projectRoot
        self.checkoutRoot = checkoutRoot
        self.homeRelativePath = homeRelativePath
        self.wherePath = wherePath
    }

    public var homePath: String {
        Self.mapHome(homeRelativePath, intoCheckoutRoot: checkoutRoot)
    }

    public var isWhereOutsideHome: Bool {
        !Self.contains(path: wherePath, within: homePath)
    }

    public static func mapHome(_ relativePath: String?, intoCheckoutRoot checkoutRoot: String) -> String {
        guard let relativePath, !relativePath.isEmpty else {
            return URL(fileURLWithPath: checkoutRoot).standardizedFileURL.path
        }
        return URL(fileURLWithPath: checkoutRoot)
            .appendingPathComponent(relativePath, isDirectory: true)
            .standardizedFileURL.path
    }

    public static func contains(path: String, within root: String) -> Bool {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let boundary = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
        return candidate.count >= boundary.count && candidate.prefix(boundary.count).elementsEqual(boundary)
    }
}

public enum ProjectHomeValidationError: Error, Equatable, LocalizedError, Sendable {
    case projectRootMissing(String)
    case homeMissing(String)
    case homeIsNotDirectory(String)
    case homeEscapesProject(String)

    public var errorDescription: String? {
        switch self {
        case .projectRootMissing(let path): return "The project folder no longer exists: \(path)"
        case .homeMissing(let path): return "The selected Home no longer exists: \(path)"
        case .homeIsNotDirectory(let path): return "Home must be a folder: \(path)"
        case .homeEscapesProject(let path): return "Home must stay inside the selected project: \(path)"
        }
    }
}

public enum ProjectHomeValidator {
    /// Validates a concrete folder selected beneath `projectRoot` and returns
    /// its normalized project-relative representation. Symlinks are resolved
    /// before containment is checked, so a symlink cannot escape the project.
    public static func relativeHome(
        projectRoot: URL,
        selectedHome: URL,
        fileManager: FileManager = .default
    ) throws -> String? {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let selected = selectedHome.standardizedFileURL.resolvingSymlinksInPath()

        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &rootIsDirectory), rootIsDirectory.boolValue else {
            throw ProjectHomeValidationError.projectRootMissing(root.path)
        }

        var selectedIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: selected.path, isDirectory: &selectedIsDirectory) else {
            throw ProjectHomeValidationError.homeMissing(selected.path)
        }
        guard selectedIsDirectory.boolValue else {
            throw ProjectHomeValidationError.homeIsNotDirectory(selected.path)
        }

        let rootComponents = root.pathComponents
        let selectedComponents = selected.pathComponents
        guard selectedComponents.count >= rootComponents.count,
              selectedComponents.prefix(rootComponents.count).elementsEqual(rootComponents) else {
            throw ProjectHomeValidationError.homeEscapesProject(selected.path)
        }

        let relativeComponents = selectedComponents.dropFirst(rootComponents.count)
        return relativeComponents.isEmpty ? nil : relativeComponents.joined(separator: "/")
    }
}

public enum CreationScopeSource: String, Codable, Equatable, Sendable {
    case explicit
    case zone
    case focusedAgent
    case recentExplicit
}

/// Project + logical Home resolved once at invocation and passed unchanged to
/// placement, runtime creation, metadata, and persistence.
public struct CreationScope: Codable, Equatable, Sendable {
    public var projectId: UUID
    public var projectRoot: String
    public var homeRelativePath: String?
    public var source: CreationScopeSource
    public var zoneId: UUID?

    public init(
        projectId: UUID,
        projectRoot: String,
        homeRelativePath: String? = nil,
        source: CreationScopeSource,
        zoneId: UUID? = nil
    ) {
        self.projectId = projectId
        self.projectRoot = projectRoot
        self.homeRelativePath = homeRelativePath
        self.source = source
        self.zoneId = zoneId
    }

    public func homePath(inCheckoutRoot checkoutRoot: String) -> String {
        FilesystemScope.mapHome(homeRelativePath, intoCheckoutRoot: checkoutRoot)
    }
}

public enum CreationScopeResolver {
    /// Locked precedence. Focus alone never mutates `recentExplicit`; callers
    /// persist that value only after an explicit picker confirmation or a
    /// confirmed committed-zone scope.
    public static func resolve(
        explicit: CreationScope?,
        zone: CreationScope?,
        focusedAgent: CreationScope?,
        recentExplicit: CreationScope?
    ) -> CreationScope? {
        if var explicit { explicit.source = .explicit; return explicit }
        if var zone { zone.source = .zone; return zone }
        if var focusedAgent { focusedAgent.source = .focusedAgent; return focusedAgent }
        if var recentExplicit { recentExplicit.source = .recentExplicit; return recentExplicit }
        return nil
    }
}
