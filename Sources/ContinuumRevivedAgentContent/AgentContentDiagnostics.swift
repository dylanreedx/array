import Foundation

/// A deliberately boring, body-free view of an AgentDocument. This is safe to
/// attach to metrics and sync diagnostics: it contains shape and lifecycle
/// metadata, never transcript prose, paths, prompts, arguments, or secrets.
public struct AgentDocumentDiagnostics: Codable, Equatable, Sendable {

    public enum IssueCode: String, Codable, Equatable, Sendable {
        case duplicateID
        case invalidRange
        case missingParent
        case nonMonotonicRevision
        case revisionChangedWithoutContentChange
    }

    public struct Issue: Codable, Equatable, Sendable {
        public let code: IssueCode
        public let id: AgentNodeID?
        public let path: String
        public let detail: String

        public init(code: IssueCode, id: AgentNodeID? = nil, path: String, detail: String) {
            self.code = code
            self.id = id
            self.path = path
            self.detail = detail
        }
    }

    public struct Node: Codable, Equatable, Sendable {
        public let id: AgentNodeID
        public let parentID: AgentNodeID?
        public let path: String
        public let kind: String?
        public let revision: UInt64
        public let childCount: Int
        /// Length of the associated source range, not the source text itself.
        public let sourceLength: UInt64?
        public let status: AgentItemStatus?

        public init(id: AgentNodeID, parentID: AgentNodeID?, path: String, kind: String?, revision: UInt64,
                    childCount: Int, sourceLength: UInt64?, status: AgentItemStatus?) {
            self.id = id
            self.parentID = parentID
            self.path = path
            self.kind = kind
            self.revision = revision
            self.childCount = childCount
            self.sourceLength = sourceLength
            self.status = status
        }
    }

    public let version: UInt64
    public let entryCount: Int
    public let entryIDs: [AgentNodeID]
    public let blockCountsByKind: [String: Int]
    public let openEntryIDs: [AgentNodeID]
    public let nodes: [Node]
    public let patchCount: Int
    public let patchCountsBySection: [String: Int]
    public let validationIssues: [Issue]
    public init(document: AgentDocument, patches: [AgentDocumentPatch] = [], previous: AgentDocument? = nil) {
        let patchSectionCounts = [
            "inserted": patches.reduce(0) { $0 + $1.inserted.count },
            "updated": patches.reduce(0) { $0 + $1.updated.count },
            "removed": patches.reduce(0) { $0 + $1.removed.count },
            "moved": patches.reduce(0) { $0 + $1.moved.count }
        ]

        var counts: [String: Int] = [:]
        var open: [AgentNodeID] = []
        var summaries: [Node] = []
        var issues: [Issue] = []
        var seen: [AgentNodeID: String] = [:]

        func inspect(_ block: AgentBlock, parentID: AgentNodeID, path: String) {
            if let firstPath = seen[block.id] {
                issues.append(Issue(code: .duplicateID, id: block.id, path: path,
                                    detail: "already declared at \(firstPath)"))
            } else { seen[block.id] = path }
            counts[block.kind.rawValue, default: 0] += 1
            let sourceLength: UInt64?
            if let range = block.sourceRange {
                if range.upperBound >= range.lowerBound {
                    sourceLength = range.upperBound - range.lowerBound
                } else {
                    sourceLength = nil
                    issues.append(Issue(code: .invalidRange, id: block.id,
                                        path: "\(path).sourceRange",
                                        detail: "upperBound \(range.upperBound) precedes lowerBound \(range.lowerBound)"))
                }
            } else {
                sourceLength = nil
            }
            var status: AgentItemStatus?
            switch block.payload {
            case .toolCall(let value): status = value.status
            case .commandOutput(let value): status = value.status
            case .plan(let value): status = value.status
            case .approval(let value), .question(let value): status = value.status
            case .notice(let value): status = value.status
            default: break
            }
            summaries.append(Node(id: block.id, parentID: parentID, path: path,
                                  kind: block.kind.rawValue, revision: block.revision,
                                  childCount: block.children.count, sourceLength: sourceLength, status: status))
            for (index, child) in block.children.enumerated() {
                inspect(child, parentID: block.id, path: "\(path).children[\(index)]")
            }
        }

        for (entryIndex, entry) in document.entries.enumerated() {
            let path = "entries[\(entryIndex)]"
            if let firstPath = seen[entry.id] {
                issues.append(Issue(code: .duplicateID, id: entry.id, path: path,
                                    detail: "already declared at \(firstPath)"))
            } else { seen[entry.id] = path }
            if case .open = entry.lifecycle { open.append(entry.id) }
            summaries.append(Node(id: entry.id, parentID: nil, path: path, kind: nil,
                                  revision: entry.revision, childCount: entry.blocks.count,
                                  sourceLength: nil, status: nil))
            var entryBlockIDs = Set<AgentNodeID>()
            for (blockIndex, block) in entry.blocks.enumerated() {
                entryBlockIDs.insert(block.id)
                inspect(block, parentID: entry.id, path: "\(path).blocks[\(blockIndex)]")
            }
            if case let .open(markupBlockID?) = entry.lifecycle,
               !entryBlockIDs.contains(markupBlockID) {
                issues.append(Issue(code: .missingParent, id: markupBlockID,
                                    path: "\(path).lifecycle.markupBlockID",
                                    detail: "markup block \(markupBlockID.rawValue) is absent from this entry"))
            }
        }
        self.version = document.version
        self.entryCount = document.entries.count
        self.entryIDs = document.entries.map(\.id)
        self.blockCountsByKind = counts
        self.openEntryIDs = open
        self.nodes = summaries
        self.patchCount = patches.count
        self.patchCountsBySection = patchSectionCounts
        self.validationIssues = issues + diagnosticsValidateParentLinks(summaries)
            + (previous.map { Self.validateRevisionOrder(previous: $0, current: document) } ?? [])
    }

    /// Compares two snapshots without exposing their payloads in the result.
    public static func validateRevisionOrder(previous: AgentDocument, current: AgentDocument) -> [Issue] {
        let old = AgentDocumentDiagnostics(document: previous).nodes.reduce(into: [:]) { $0[$1.id] = $1 }
        return AgentDocumentDiagnostics(document: current).nodes.compactMap { node in
            guard let prior = old[node.id], node.revision < prior.revision else { return nil }
            return Issue(code: .nonMonotonicRevision, id: node.id, path: node.path,
                         detail: "revision \(node.revision) precedes \(prior.revision)")
        }
    }

}

private func diagnosticsValidateParentLinks(_ nodes: [AgentDocumentDiagnostics.Node]) -> [AgentDocumentDiagnostics.Issue] {
    let IDs = Set(nodes.map(\.id))
    return nodes.compactMap { node in
        guard let parent = node.parentID, !IDs.contains(parent) else { return nil }
        return AgentDocumentDiagnostics.Issue(code: .missingParent, id: node.id, path: node.path,
                                              detail: "parent \(parent.rawValue) is absent")
    }
}

/// Short name for callers that treat diagnostics as a content-module service.
public typealias AgentContentDiagnostics = AgentDocumentDiagnostics
