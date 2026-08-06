import Foundation

public enum LocationIndexMode: String, Codable, Hashable, Sendable {
    case location
    case reference
    case globalNavigation
}

public enum LocationIndexEntityKind: String, Codable, Hashable, Sendable, CaseIterable {
    case project
    case directory
    case file
    case agent
    case session
    case tile
    case zone
}

public struct LocationIndexID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "LocationIndexID must be non-empty")
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }
}

public struct LocationIndexWorkspaceMetadata: Codable, Equatable, Sendable {
    public var workspaceID: LocationIndexID?
    public var workspaceName: String?
    public var projectID: LocationIndexID?
    public var projectLabel: String?
    public var gitBranch: String?
    public var gitWorktreeLabel: String?
    public var isDirty: Bool
    public var isWorkspaceProject: Bool
    public var discoverySource: LocationIndexDiscoverySource

    public init(
        workspaceID: LocationIndexID? = nil,
        workspaceName: String? = nil,
        projectID: LocationIndexID? = nil,
        projectLabel: String? = nil,
        gitBranch: String? = nil,
        gitWorktreeLabel: String? = nil,
        isDirty: Bool = false,
        isWorkspaceProject: Bool = false,
        discoverySource: LocationIndexDiscoverySource = .registered
    ) {
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.projectID = projectID
        self.projectLabel = projectLabel
        self.gitBranch = gitBranch
        self.gitWorktreeLabel = gitWorktreeLabel
        self.isDirty = isDirty
        self.isWorkspaceProject = isWorkspaceProject
        self.discoverySource = discoverySource
    }
}

public enum LocationIndexDiscoverySource: String, Codable, Sendable {
    case registered
    case activeCanvas
    case boundedDiscovery
}

public struct LocationIndexActivityMetadata: Codable, Equatable, Sendable {
    public var lastUsedAt: Date?
    public var lastActivityAt: Date?
    public var activeAgentCount: Int
    public var isActive: Bool

    public init(
        lastUsedAt: Date? = nil,
        lastActivityAt: Date? = nil,
        activeAgentCount: Int = 0,
        isActive: Bool = false
    ) {
        self.lastUsedAt = lastUsedAt
        self.lastActivityAt = lastActivityAt
        self.activeAgentCount = activeAgentCount
        self.isActive = isActive
    }
}

public struct LocationIndexSpatialMetadata: Codable, Equatable, Sendable {
    public var anchorDistance: Double?
    public var nearbyContextRank: Int?
    public var nearbyProjectRank: Int?
    public var zoneID: LocationIndexID?

    public init(
        anchorDistance: Double? = nil,
        nearbyContextRank: Int? = nil,
        nearbyProjectRank: Int? = nil,
        zoneID: LocationIndexID? = nil
    ) {
        self.anchorDistance = anchorDistance
        self.nearbyContextRank = nearbyContextRank
        self.nearbyProjectRank = nearbyProjectRank
        self.zoneID = zoneID
    }
}

public struct LocationIndexEntry: Codable, Equatable, Sendable {
    public var id: LocationIndexID
    public var kind: LocationIndexEntityKind
    public var label: String
    public var aliases: [String]
    /// A non-secret, user-facing path or path fragment used for display and fuzzy matching.
    /// Absolute provider transcript paths and private routing locators do not belong here.
    public var displayPath: String?
    public var parentID: LocationIndexID?
    public var activity: LocationIndexActivityMetadata
    public var workspace: LocationIndexWorkspaceMetadata
    public var spatial: LocationIndexSpatialMetadata
    public var supportedModes: Set<LocationIndexMode>

    public init(
        id: LocationIndexID,
        kind: LocationIndexEntityKind,
        label: String,
        aliases: [String] = [],
        displayPath: String? = nil,
        parentID: LocationIndexID? = nil,
        activity: LocationIndexActivityMetadata = LocationIndexActivityMetadata(),
        workspace: LocationIndexWorkspaceMetadata = LocationIndexWorkspaceMetadata(),
        spatial: LocationIndexSpatialMetadata = LocationIndexSpatialMetadata(),
        supportedModes: Set<LocationIndexMode> = [.location, .reference, .globalNavigation]
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.aliases = aliases
        self.displayPath = displayPath
        self.parentID = parentID
        self.activity = activity
        self.workspace = workspace
        self.spatial = spatial
        self.supportedModes = supportedModes
    }
}

public struct LocationIndexPrivateRouting: Equatable, Sendable {
    public var providerSessionID: String?
    public var transcriptPath: String?
    public var absolutePath: String?

    public init(providerSessionID: String? = nil, transcriptPath: String? = nil, absolutePath: String? = nil) {
        self.providerSessionID = providerSessionID
        self.transcriptPath = transcriptPath
        self.absolutePath = absolutePath
    }
}

public struct LocationIndexRecord: Equatable, Sendable {
    public var entry: LocationIndexEntry
    public var privateRouting: LocationIndexPrivateRouting

    public init(entry: LocationIndexEntry, privateRouting: LocationIndexPrivateRouting = LocationIndexPrivateRouting()) {
        self.entry = entry
        self.privateRouting = privateRouting
    }
}

public struct LocationIndexSearchContext: Sendable {
    public var mode: LocationIndexMode
    public var anchorID: LocationIndexID?
    public var now: Date

    public init(mode: LocationIndexMode, anchorID: LocationIndexID? = nil, now: Date = Date()) {
        self.mode = mode
        self.anchorID = anchorID
        self.now = now
    }
}

public struct LocationIndexResult: Equatable, Sendable {
    public var entry: LocationIndexEntry
    public var disambiguatedLabel: String
    public var matchedAlias: String?
    public var rankBucket: LocationIndexRankBucket
    public var fuzzyScore: Int

    public init(
        entry: LocationIndexEntry,
        disambiguatedLabel: String,
        matchedAlias: String?,
        rankBucket: LocationIndexRankBucket,
        fuzzyScore: Int
    ) {
        self.entry = entry
        self.disambiguatedLabel = disambiguatedLabel
        self.matchedAlias = matchedAlias
        self.rankBucket = rankBucket
        self.fuzzyScore = fuzzyScore
    }
}

public enum LocationIndexRankBucket: Int, Codable, Sendable, Comparable {
    case anchor = 0
    case nearbyContext = 1
    case nearbyProject = 2
    case recent = 3
    case activeAgents = 4
    case workspaceProject = 5
    case boundedDiscovery = 6
    case other = 7

    public static func < (lhs: LocationIndexRankBucket, rhs: LocationIndexRankBucket) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct LocationSessionIndex: Sendable {
    public var records: [LocationIndexRecord]

    public init(records: [LocationIndexRecord] = []) {
        self.records = records
    }

    public func entriesForCodableOutput() -> [LocationIndexEntry] {
        records.map(\.entry)
    }

    public func search(_ query: String, context: LocationIndexSearchContext) -> [LocationIndexResult] {
        let normalizedQuery = LocationIndexMatcher.normalize(query)
        let candidates = records.compactMap { record -> LocationIndexResult? in
            let entry = record.entry
            guard entry.supportedModes.contains(context.mode) else { return nil }
            let match = LocationIndexMatcher.bestMatch(query: normalizedQuery, entry: entry)
            guard normalizedQuery.isEmpty || match.score > 0 else { return nil }
            return LocationIndexResult(
                entry: entry,
                disambiguatedLabel: "",
                matchedAlias: match.alias,
                rankBucket: rankBucket(for: entry, context: context),
                fuzzyScore: match.score
            )
        }
        let labelCounts = Dictionary(grouping: candidates, by: { LocationIndexMatcher.normalize($0.entry.label) })
            .mapValues(\.count)
        return candidates.map { result in
            var copy = result
            copy.disambiguatedLabel = disambiguatedLabel(for: result.entry, collides: (labelCounts[LocationIndexMatcher.normalize(result.entry.label)] ?? 0) > 1)
            return copy
        }.sorted { lhs, rhs in
            if lhs.rankBucket != rhs.rankBucket { return lhs.rankBucket < rhs.rankBucket }
            let lhsSpatialRank = spatialRank(for: lhs.entry, bucket: lhs.rankBucket)
            let rhsSpatialRank = spatialRank(for: rhs.entry, bucket: rhs.rankBucket)
            if lhsSpatialRank != rhsSpatialRank { return lhsSpatialRank < rhsSpatialRank }
            let lhsAnchorDistance = anchorDistance(for: lhs.entry, bucket: lhs.rankBucket)
            let rhsAnchorDistance = anchorDistance(for: rhs.entry, bucket: rhs.rankBucket)
            if lhsAnchorDistance != rhsAnchorDistance { return lhsAnchorDistance < rhsAnchorDistance }
            if lhs.fuzzyScore != rhs.fuzzyScore { return lhs.fuzzyScore > rhs.fuzzyScore }
            let lDate = lhs.entry.activity.lastActivityAt ?? lhs.entry.activity.lastUsedAt ?? .distantPast
            let rDate = rhs.entry.activity.lastActivityAt ?? rhs.entry.activity.lastUsedAt ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            if lhs.entry.activity.activeAgentCount != rhs.entry.activity.activeAgentCount {
                return lhs.entry.activity.activeAgentCount > rhs.entry.activity.activeAgentCount
            }
            let lhsLabel = LocationIndexMatcher.normalize(lhs.entry.label)
            let rhsLabel = LocationIndexMatcher.normalize(rhs.entry.label)
            if lhsLabel != rhsLabel { return lhsLabel < rhsLabel }
            return lhs.entry.id.rawValue < rhs.entry.id.rawValue
        }
    }

    private func rankBucket(for entry: LocationIndexEntry, context: LocationIndexSearchContext) -> LocationIndexRankBucket {
        if entry.id == context.anchorID { return .anchor }
        if entry.spatial.nearbyContextRank != nil { return .nearbyContext }
        if entry.spatial.nearbyProjectRank != nil { return .nearbyProject }
        if entry.activity.lastUsedAt != nil || entry.activity.lastActivityAt != nil { return .recent }
        if entry.kind == .agent && (entry.activity.isActive || entry.activity.activeAgentCount > 0) { return .activeAgents }
        if entry.workspace.isWorkspaceProject { return .workspaceProject }
        if entry.workspace.discoverySource == .boundedDiscovery { return .boundedDiscovery }
        return .other
    }

    private func spatialRank(for entry: LocationIndexEntry, bucket: LocationIndexRankBucket) -> Int {
        switch bucket {
        case .nearbyContext:
            return entry.spatial.nearbyContextRank ?? Int.max
        case .nearbyProject:
            return entry.spatial.nearbyProjectRank ?? Int.max
        default:
            return 0
        }
    }

    private func anchorDistance(for entry: LocationIndexEntry, bucket: LocationIndexRankBucket) -> Double {
        switch bucket {
        case .nearbyContext, .nearbyProject:
            return entry.spatial.anchorDistance ?? .greatestFiniteMagnitude
        default:
            return 0
        }
    }

    private func disambiguatedLabel(for entry: LocationIndexEntry, collides: Bool) -> String {
        guard collides else { return entry.label }
        if let project = entry.workspace.projectLabel, project != entry.label {
            return "\(entry.label) — \(project)"
        }
        if let path = entry.displayPath, !path.isEmpty {
            return "\(entry.label) — \(path)"
        }
        if let workspace = entry.workspace.workspaceName, !workspace.isEmpty {
            return "\(entry.label) — \(workspace)"
        }
        return "\(entry.label) — \(entry.id.rawValue)"
    }
}

public enum LocationIndexMatcher {
    public static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    public static func bestMatch(query: String, entry: LocationIndexEntry) -> (score: Int, alias: String?) {
        if query.isEmpty { return (1, nil) }
        var fields: [(String, String?)] = [(entry.label, nil)]
        fields.append(contentsOf: entry.aliases.map { ($0, $0) })
        if let displayPath = entry.displayPath { fields.append((displayPath, displayPath)) }
        return fields.map { field, alias in
            (score: fuzzyScore(query: query, candidate: normalize(field)), alias: alias)
        }.max { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return (lhs.alias ?? "") > (rhs.alias ?? "")
        } ?? (0, nil)
    }

    public static func fuzzyScore(query: String, candidate: String) -> Int {
        guard !query.isEmpty else { return 1 }
        guard !candidate.isEmpty else { return 0 }
        if candidate == query { return 10_000 - candidate.count }
        if candidate.hasPrefix(query) { return 8_000 - candidate.count }
        if candidate.contains(query) { return 6_000 - candidate.count }
        let queryScalars = Array(query.unicodeScalars)
        let candidateScalars = Array(candidate.unicodeScalars)
        var qi = 0
        var gaps = 0
        var lastMatch = -1
        for (index, scalar) in candidateScalars.enumerated() where qi < queryScalars.count {
            if scalar == queryScalars[qi] {
                if lastMatch >= 0 { gaps += index - lastMatch - 1 }
                lastMatch = index
                qi += 1
            }
        }
        guard qi == queryScalars.count else { return 0 }
        return max(1, 3_000 - gaps - candidateScalars.count)
    }
}

public struct LocationDiscoveryRoot: Sendable {
    public var url: URL
    public var maxDepth: Int
    public var maxEntries: Int

    public init(url: URL, maxDepth: Int = 2, maxEntries: Int = 200) {
        self.url = url
        self.maxDepth = max(0, maxDepth)
        self.maxEntries = max(0, maxEntries)
    }
}

public struct LocationDiscoveryOptions: Sendable {
    public var roots: [LocationDiscoveryRoot]
    public var homeDirectory: URL

    public init(
        roots: [LocationDiscoveryRoot],
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) {
        self.roots = roots
        self.homeDirectory = homeDirectory
    }
}

public enum LocationDiscoveryError: Error, Equatable {
    case recursiveHomeScanRejected(URL)
    case unsafeBroadRootRejected(URL)
}

public struct LocationDiscoveryStats: Equatable, Sendable {
    public var visitedDirectories: Int = 0
    public var emittedEntries: Int = 0
    public var cancelled: Bool = false
}

public struct LocationDiscoveryResult: Sendable {
    public var records: [LocationIndexRecord]
    public var stats: LocationDiscoveryStats

    public init(records: [LocationIndexRecord], stats: LocationDiscoveryStats) {
        self.records = records
        self.stats = stats
    }
}

public enum LocationIndexDiscovery {
    public static func discoverDirectories(
        options: LocationDiscoveryOptions,
        isCancelled: () -> Bool = { false }
    ) throws -> LocationDiscoveryResult {
        var records: [LocationIndexRecord] = []
        var stats = LocationDiscoveryStats()
        let fileManager = FileManager.default
        let home = options.homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        for root in options.roots.sorted(by: { $0.url.path < $1.url.path }) {
            let rootURL = root.url.standardizedFileURL.resolvingSymlinksInPath()
            guard root.maxEntries > 0 else { continue }
            if root.maxDepth > 0 && isUnsafeBroadDiscoveryRoot(rootURL) {
                throw LocationDiscoveryError.unsafeBroadRootRejected(root.url)
            }
            if rootURL.path == home && root.maxDepth > 0 {
                throw LocationDiscoveryError.recursiveHomeScanRejected(root.url)
            }
            let rootDisplayLabel = safeDiscoveryRootLabel(for: rootURL)
            var queue: [(url: URL, depth: Int)] = [(rootURL, 0)]
            while !queue.isEmpty && records.count < root.maxEntries {
                if isCancelled() {
                    stats.cancelled = true
                    return LocationDiscoveryResult(records: records, stats: stats)
                }
                let current = queue.removeFirst()
                stats.visitedDirectories += 1
                if current.depth > 0 {
                    let label = current.url.lastPathComponent.isEmpty ? current.url.path : current.url.lastPathComponent
                    let displayPath = rootRelativeDisplayPath(for: current.url, rootURL: rootURL, rootDisplayLabel: rootDisplayLabel)
                    let entry = LocationIndexEntry(
                        id: LocationIndexID(rawValue: "directory:discovered:\(stablePathHash(current.url.path))"),
                        kind: .directory,
                        label: label,
                        displayPath: displayPath,
                        workspace: LocationIndexWorkspaceMetadata(discoverySource: .boundedDiscovery),
                        supportedModes: [.location, .reference, .globalNavigation]
                    )
                    records.append(LocationIndexRecord(entry: entry, privateRouting: LocationIndexPrivateRouting(absolutePath: current.url.path)))
                    stats.emittedEntries += 1
                }
                guard current.depth < root.maxDepth else { continue }
                let children = (try? fileManager.contentsOfDirectory(
                    at: current.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                let directories = children.filter { url in
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                queue.append(contentsOf: directories.map { ($0, current.depth + 1) })
            }
        }
        return LocationDiscoveryResult(records: records, stats: stats)
    }

    private static func isUnsafeBroadDiscoveryRoot(_ url: URL) -> Bool {
        let path = url.path
        return path == "/" || path == "/Users"
    }

    private static func safeDiscoveryRootLabel(for url: URL) -> String {
        let label = url.lastPathComponent
        if !label.isEmpty { return label }
        return "discovery-root-" + stablePathHash(url.path)
    }

    private static func rootRelativeDisplayPath(for url: URL, rootURL: URL, rootDisplayLabel: String) -> String {
        let rootPath = rootURL.path
        let path = url.path
        let relativePath: String
        if path.hasPrefix(rootPath + "/") {
            relativePath = String(path.dropFirst(rootPath.count + 1))
        } else {
            relativePath = url.lastPathComponent
        }
        return relativePath.isEmpty ? rootDisplayLabel : "\(rootDisplayLabel)/\(relativePath)"
    }

    private static func stablePathHash(_ path: String) -> String {
        // Deterministic FNV-1a 64-bit; sufficient for local stable discovery IDs without importing CryptoKit.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

public struct LocationIndexPreviewRequest: Equatable, Sendable {
    public var id: LocationIndexID
    public var mode: LocationIndexMode

    public init(id: LocationIndexID, mode: LocationIndexMode) {
        self.id = id
        self.mode = mode
    }
}

public struct LocationIndexPreview: Equatable, Sendable {
    public var title: String
    public var lines: [String]
    public var freshness: String?

    public init(title: String, lines: [String] = [], freshness: String? = nil) {
        self.title = title
        self.lines = lines
        self.freshness = freshness
    }
}

public protocol LocationIndexPreviewProvider: Sendable {
    func loadPreview(for request: LocationIndexPreviewRequest) async throws -> LocationIndexPreview
}

public enum LocationIndexPreviewLoader {
    public static func startPreview(
        for request: LocationIndexPreviewRequest,
        provider: LocationIndexPreviewProvider
    ) -> Task<LocationIndexPreview, Error> {
        Task(priority: .utility) {
            try Task.checkCancellation()
            return try await provider.loadPreview(for: request)
        }
    }
}
