import Foundation

// MARK: - standards.read (`docs/internals/project-standards-on-demand.md`)

/// The caller reads its own checkout's standards. No arguments: the index.
/// `standards`: those standards with every rule. `rules`: only those rules.
/// Ids are looked up in the scanned index and never touch the filesystem.
public struct StandardsReadRequest: Equatable, Sendable {
    public var standards: [String]
    public var rules: [String]

    public init(standards: [String] = [], rules: [String] = []) {
        self.standards = standards
        self.rules = rules
    }

    public static func validated(payload: [String: Any]) -> Result<StandardsReadRequest, WorkspaceAPIError> {
        if let unknown = payload.keys.first(where: { $0 != "standards" && $0 != "rules" }) {
            return .failure(WorkspaceAPIError(code: .invalidRequest, message: "Unknown field \(unknown). Pass standards, rules or nothing."))
        }
        func ids(_ key: String) -> [String]? {
            guard let value = payload[key] else { return [] }
            guard let list = value as? [Any], list.allSatisfy({ $0 is String }) else { return nil }
            return (list as! [String])
        }
        guard let standards = ids("standards"), let rules = ids("rules") else {
            return .failure(WorkspaceAPIError(code: .invalidRequest, message: "standards and rules must be arrays of ids."))
        }
        return .success(StandardsReadRequest(standards: standards, rules: rules))
    }

    public var isIndex: Bool { standards.isEmpty && rules.isEmpty }
}

public struct StandardsReadResult: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var path: String
        public var title: String
        public var appliesWhen: String
        public var version: String
        public var ruleIds: [String]
        /// Absent in the index; the requested rules otherwise.
        public var rules: [ProjectStandardRule]?
    }

    public var schema: String = WorkspaceAPISchema.v1
    /// Where the standards were read, relative to the caller's checkout.
    public var root: String = ProjectStandards.directory
    public var standards: [Entry]
    public var issues: [ProjectStandardsIssue]
    /// Requested ids that name no usable standard or rule, in request order.
    public var unresolved: [String]

    /// The pure answer to one request over one scanned index.
    public static func answer(_ request: StandardsReadRequest, index: ProjectStandardsIndex) -> StandardsReadResult {
        var unresolved: [String] = []
        func note(_ id: String) { if !unresolved.contains(id) { unresolved.append(id) } }
        var whole: Set<String> = []
        var picked: Set<String> = []
        for id in request.standards {
            if index.standards.contains(where: { $0.id == id }) { whole.insert(id) } else { note(id) }
        }
        for ruleId in request.rules {
            if index.standards.contains(where: { $0.rules.contains { $0.id == ruleId } }) { picked.insert(ruleId) } else { note(ruleId) }
        }
        let entries: [Entry] = index.standards.compactMap { standard in
            var entry = Entry(id: standard.id, path: standard.path, title: standard.title, appliesWhen: standard.appliesWhen,
                              version: standard.version, ruleIds: standard.rules.map(\.id), rules: nil)
            if request.isIndex { return entry }
            let rules = whole.contains(standard.id) ? standard.rules : standard.rules.filter { picked.contains($0.id) }
            guard !rules.isEmpty else { return nil }
            entry.rules = rules
            return entry
        }
        return StandardsReadResult(standards: entries, issues: index.issues, unresolved: unresolved)
    }

    public init(standards: [Entry], issues: [ProjectStandardsIssue], unresolved: [String]) {
        self.standards = standards
        self.issues = issues
        self.unresolved = unresolved
    }
}

/// What one answered `standards.read` hands the observation seam
/// (`WorkspaceAPIService.standardsRetrievalObserver`). Ids and versions only,
/// never rule text. Host-owned shadow record; not persisted by this part.
public struct StandardsRetrieval: Codable, Equatable, Sendable {
    public var agentId: AgentID
    public var at: Date
    /// true for an index read (no ids requested).
    public var index: Bool
    public var standardIds: [String]
    public var ruleIds: [String]
    /// standard id -> version, for every standard returned.
    public var versions: [String: String]
    public var unresolved: [String]
    public var issueCount: Int

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case agentId, at, index, standardIds, ruleIds, versions, unresolved, issueCount
    }

    public init(agentId: AgentID, at: Date, request: StandardsReadRequest, result: StandardsReadResult) {
        self.agentId = agentId
        self.at = at
        self.index = request.isIndex
        self.standardIds = result.standards.map(\.id)
        self.ruleIds = result.standards.flatMap { $0.rules?.map(\.id) ?? [] }
        self.versions = Dictionary(uniqueKeysWithValues: result.standards.map { ($0.id, $0.version) })
        self.unresolved = result.unresolved
        self.issueCount = result.issues.count
    }
}
