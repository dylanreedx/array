import Foundation

/// The result of reconciling one provisional parse against the previous parse.
/// IDs are semantic identities; source offsets and array positions are never
/// used as identity inputs.
public struct AgentNodeIdentityReconciliation: Equatable, Sendable {
    public let blocks: [AgentBlock]
    public let patch: AgentNodeIdentityPatch

    public init(blocks: [AgentBlock], patch: AgentNodeIdentityPatch) {
        self.blocks = blocks
        self.patch = patch
    }
}

/// The minimal structural and visible-content changes made by reconciliation.
public struct AgentNodeIdentityPatch: Equatable, Sendable {
    public let inserted: [AgentNodeID]
    public let updated: [AgentNodeID]
    public let removed: [AgentNodeID]
    public let moved: [AgentNodeID]

    public init(inserted: [AgentNodeID] = [], updated: [AgentNodeID] = [],
                removed: [AgentNodeID] = [], moved: [AgentNodeID] = []) {
        self.inserted = Self.sortedUnique(inserted)
        self.updated = Self.sortedUnique(updated)
        self.removed = Self.sortedUnique(removed)
        self.moved = Self.sortedUnique(moved)
    }

    private static func sortedUnique(_ ids: [AgentNodeID]) -> [AgentNodeID] {
        Array(Set(ids)).sorted { $0.rawValue < $1.rawValue }
    }

    public var isEmpty: Bool { inserted.isEmpty && updated.isEmpty && removed.isEmpty && moved.isEmpty }
}

/// Reuses identities from a previous semantic tree while allowing the open
/// streaming tail to change kind/payload. Exact matches are occurrence-aware:
/// the first available old occurrence is paired with the first new occurrence.
/// Only the two open tails may use a compatible (non-exact) match, preventing
/// an insertion from borrowing an unrelated completed node.
public enum AgentNodeIdentityReconciler {
    public enum Error: Swift.Error, Equatable, Sendable {
        case revisionOverflow(id: AgentNodeID, current: UInt64)
        case identityAllocationOverflow(seed: String)
    }

    public static func reconcile(previous: [AgentBlock], parsed: [AgentBlock]) throws -> AgentNodeIdentityReconciliation {
        var context = Context()
        context.occupied = allIDs(previous)
        let blocks = try reconcileSiblings(parsed, previous: previous, context: &context)
        let oldIDs = allIDs(previous)
        let newIDs = allIDs(blocks)
        context.removed.append(contentsOf: oldIDs.filter { !newIDs.contains($0) })
        context.moved.append(contentsOf: oldIDs.filter {
            guard newIDs.contains($0) else { return false }
            return path(of: $0, in: previous) != path(of: $0, in: blocks)
        })
        return AgentNodeIdentityReconciliation(
            blocks: blocks,
            patch: AgentNodeIdentityPatch(inserted: context.inserted, updated: context.updated,
                                           removed: context.removed, moved: context.moved)
        )
    }

    private struct Context {
        var inserted: [AgentNodeID] = []
        var updated: [AgentNodeID] = []
        var removed: [AgentNodeID] = []
        var moved: [AgentNodeID] = []
        var occupied: Set<AgentNodeID> = []
        var collisionOrdinals: [String: UInt64] = [:]
    }

    private static func reconcileSiblings(_ parsed: [AgentBlock], previous: [AgentBlock], context: inout Context) throws -> [AgentBlock] {
        var matches: [Int: Int] = [:]
        var used = Set<Int>()

        // Forward occurrence matching is intentional. It preserves the
        // completed prefix when an equal repeated sibling is appended. For a
        // semantically unique insertion, exact matches reserve the old nodes
        // before the unmatched insertion is allocated fresh. An insertion
        // indistinguishable from repeated siblings has no observable witness;
        // this policy does not pretend to identify which occurrence moved.
        for index in parsed.indices {
            if let old = previous.indices.first(where: {
                !used.contains($0) && semanticallyEqual(parsed[index], previous[$0])
            }) {
                matches[index] = old
                used.insert(old)
            }
        }

        // Preserve a parser-owned tail seed when the reparse expands that
        // node into a longer sibling list. This is an explicit identity match,
        // not compatible-tail fallback; the latter remains restricted to the
        // actual parsed tail below.
        if let previousTail = previous.indices.last,
           let parsedIndex = parsed.indices.first(where: { parsed[$0].id == previous[previousTail].id }),
           matches[parsedIndex] == nil, !used.contains(previousTail) {
            matches[parsedIndex] = previousTail
            used.insert(previousTail)
        }

        // A provisional open tail may change Markdown shape as delimiters arrive
        // (paragraph → heading/list/fence, or incomplete → complete fence). No
        // completed sibling is eligible for this fallback.
        if let parsedTail = parsed.indices.last, let previousTail = previous.indices.last {
            // When reparsing expands a lone provisional node into several
            // siblings, there is no evidence that the old tail is the final
            // parsed node. Require an exact anchor in that case; a same-sized
            // reparse may still reconcile its sole edited tail.
            let hasTailAnchor = previous.count == parsed.count || !matches.isEmpty
            if hasTailAnchor, matches[parsedTail] == nil, !used.contains(previousTail) {
                if compatibleOpenTail(parsed[parsedTail], previous[previousTail]) {
                    matches[parsedTail] = previousTail
                    used.insert(previousTail)
                } else if parsed[parsedTail].kind != previous[previousTail].kind {
                    // An incomplete delimiter can be replaced by a different
                    // structural node. Its provisional tail is removed, so a
                    // stable parser occurrence key is not needlessly treated as
                    // a collision in the same reconciliation.
                    for id in allIDs([previous[previousTail]]) { context.occupied.remove(id) }
                }
            }
        }

        return try parsed.indices.map { index in
            let incoming = parsed[index]
            guard let oldIndex = matches[index] else {
                return try insertFresh(incoming, context: &context)
            }
            let old = previous[oldIndex]
            let children = try reconcileSiblings(incoming.children, previous: old.children, context: &context)
            let visibleChanged = incoming.kind != old.kind || incoming.payload != old.payload || children != old.children
            let revision: UInt64
            if visibleChanged {
                guard old.revision < .max else {
                    throw Error.revisionOverflow(id: old.id, current: old.revision)
                }
                revision = old.revision + 1
            } else {
                revision = old.revision
            }
            let result = AgentBlock(id: old.id, revision: revision, kind: incoming.kind,
                                    sourceRange: incoming.sourceRange, payload: incoming.payload,
                                    children: children)
            if visibleChanged { context.updated.append(old.id) }
            return result
        }
    }

    private static func insertFresh(_ block: AgentBlock, context: inout Context) throws -> AgentBlock {
        var id = block.id
        if context.occupied.contains(id) {
            // The incoming provisional ID is the stable seed. A deterministic
            // digest plus an allocator ordinal avoids mutable positions and is
            // always short enough for AgentNodeID, even for a 512-byte seed.
            let seed = stableDigest(id.rawValue)
            var ordinal = context.collisionOrdinals[id.rawValue, default: 0]
            while true {
                let candidateRaw = "reconciled-insert:\(seed):\(ordinal)"
                guard let candidate = AgentNodeID(rawValue: candidateRaw) else {
                    throw Error.identityAllocationOverflow(seed: id.rawValue)
                }
                if !context.occupied.contains(candidate) {
                    id = candidate
                    if ordinal < .max { ordinal += 1 }
                    context.collisionOrdinals[block.id.rawValue] = ordinal
                    break
                }
                guard ordinal < .max else {
                    throw Error.identityAllocationOverflow(seed: id.rawValue)
                }
                ordinal += 1
            }
        }
        context.occupied.insert(id)
        context.inserted.append(id)
        let children = try block.children.map { try insertFresh($0, context: &context) }
        return AgentBlock(id: id, revision: block.revision, kind: block.kind,
                          sourceRange: block.sourceRange, payload: block.payload, children: children)
    }

    private static func compatibleOpenTail(_ lhs: AgentBlock, _ rhs: AgentBlock) -> Bool {
        let markdownKinds: Set<AgentBlockKind> = [.paragraph, .heading, .list, .listItem, .quote, .thematicBreak, .fencedCode]
        guard markdownKinds.contains(lhs.kind) && markdownKinds.contains(rhs.kind) else { return false }
        // A partial fence is parsed as a paragraph until its opening delimiter
        // is complete. It is a new structural node, not an edited paragraph;
        // preserving that provisional ID would make scalar chunkings diverge.
        return !((lhs.kind == .fencedCode) != (rhs.kind == .fencedCode))
    }

    private static func semanticallyEqual(_ lhs: AgentBlock, _ rhs: AgentBlock) -> Bool {
        lhs.kind == rhs.kind && lhs.payload == rhs.payload && lhs.children.count == rhs.children.count &&
            zip(lhs.children, rhs.children).allSatisfy { semanticallyEqual($0.0, $0.1) }
    }

    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 { hash ^= UInt64(byte); hash &*= 1099511628211 }
        return String(hash, radix: 16)
    }

    private static func allIDs(_ blocks: [AgentBlock]) -> Set<AgentNodeID> {
        Set(blocks.flatMap { [$0.id] + Array(allIDs($0.children)) })
    }

    private static func path(of id: AgentNodeID, in blocks: [AgentBlock]) -> [Int]? {
        for (index, block) in blocks.enumerated() {
            if block.id == id { return [index] }
            if let child = path(of: id, in: block.children) { return [index] + child }
        }
        return nil
    }
}
