import Foundation

/// Deterministic operation counts used to prove indexed behavior without a
/// wall-clock performance assertion.
public struct AgentDocumentReducerMetrics: Equatable, Sendable {
    public fileprivate(set) var indexedBlockLookups: UInt64 = 0
    public fileprivate(set) var blockPathSteps: UInt64 = 0
    public fileprivate(set) var reindexedNodes: UInt64 = 0
}

/// Pure, platform-neutral application of semantic document mutations.
public struct AgentDocumentReducer: Sendable {
    public private(set) var document: AgentDocument
    public private(set) var metrics = AgentDocumentReducerMetrics()

    private var entryIndexes: [AgentNodeID: Int] = [:]
    private var blockOwners: [AgentNodeID: AgentNodeID] = [:]
    private var blockLocations: [AgentNodeID: (entry: Int, path: [Int])] = [:]
    private var topBlockLocations: [AgentNodeID: (entry: Int, block: Int)] = [:]
    private var topRoots: [AgentNodeID: AgentNodeID] = [:]

    /// Supplies `AgentEntry.createdAt` when an entry is begun and
    /// `AgentEntry.finishedAt` when it is finished.
    ///
    /// Defaults to `{ nil }` so the reducer stays a pure function of its
    /// mutations: an unstamped reducer produces byte-identical documents on every
    /// run, which is what every existing witness compares. Production opts in by
    /// injecting a real clock from `AgentTranscriptProjection`.
    private let createdAtProvider: @Sendable () -> Date?

    public init(
        document: AgentDocument = AgentDocument(),
        createdAtProvider: @escaping @Sendable () -> Date? = { nil }
    ) {
        do { try document.validateIdentityInvariants() }
        catch { preconditionFailure("AgentDocumentReducer requires a valid document: \(error)") }
        self.document = document
        self.createdAtProvider = createdAtProvider
        rebuildIndexes()
    }

    @discardableResult
    public mutating func apply(_ mutation: AgentDocumentMutation) throws -> AgentDocumentPatch {
        let before = document.version
        guard before < .max else { throw AgentDocumentMutationError.documentVersionOverflow(current: before) }

        var inserted: [AgentNodeID] = []
        var updated: [AgentNodeID] = []
        var removed: [AgentNodeID] = []
        var moved: [AgentNodeID] = []

        switch mutation {
        case let .beginEntry(id, role, provenance):
            guard entryIndexes[id] == nil && blockOwners[id] == nil else {
                throw AgentDocumentMutationError.duplicateBegin(entryID: id)
            }
            document.entries.append(AgentEntry(
                id: id, role: role, provenance: provenance, createdAt: createdAtProvider()))
            entryIndexes[id] = document.entries.count - 1
            inserted = [id]

        case let .appendMarkup(entryID, delta):
            let entryIndex = try requireEntry(entryID, .appendMarkup)
            guard case let .open(openBlockID) = document.entries[entryIndex].lifecycle else {
                throw AgentDocumentMutationError.entryFinished(entryID: entryID, operation: .appendMarkup)
            }
            guard !delta.isEmpty else { break }
            let entryRevision = try nextRevision(document.entries[entryIndex].revision, id: entryID)

            if let blockID = openBlockID,
               let location = topBlockLocations[blockID], location.entry == entryIndex {
                let old = document.entries[entryIndex].blocks[location.block]
                guard case let .paragraph(inlines) = old.payload else {
                    throw AgentDocumentMutationError.duplicateNodeID(id: blockID)
                }
                var replacement = old
                replacement.payload = .paragraph(appending(delta, to: inlines))
                replacement.revision = try nextRevision(old.revision, id: old.id)
                document.entries[entryIndex].blocks[location.block] = replacement
                document.entries[entryIndex].revision = entryRevision
                updated = [entryID, blockID]
            } else {
                let blockID = try markupID(entryID: entryID)
                let block = AgentBlock(
                    id: blockID,
                    kind: .paragraph,
                    payload: .paragraph(appending(delta, to: []))
                )
                let blockIndex = document.entries[entryIndex].blocks.count
                document.entries[entryIndex].blocks.append(block)
                document.entries[entryIndex].lifecycle = .open(markupBlockID: blockID)
                document.entries[entryIndex].revision = entryRevision
                index(block, owner: entryID, root: blockID, entry: entryIndex, path: [blockIndex])
                topBlockLocations[blockID] = (entryIndex, blockIndex)
                inserted = [blockID]
                updated = [entryID]
            }

        case let .replaceMarkup(entryID, incoming):
            let entryIndex = try requireEntry(entryID, .replaceMarkup)
            guard case .open = document.entries[entryIndex].lifecycle else {
                throw AgentDocumentMutationError.entryFinished(entryID: entryID, operation: .replaceMarkup)
            }
            try validateForest(incoming)

            let oldBlocks = document.entries[entryIndex].blocks
            let oldIDs = oldBlocks.flatMap(allIDs)
            let oldSet = Set(oldIDs)
            for block in incoming { try validateFreshIDs(block, allowed: oldSet) }

            let oldNodes = oldBlocks.reduce(into: [AgentNodeID: AgentBlock]()) { result, block in
                result.merge(indexed(block)) { current, _ in current }
            }
            let replacements = try incoming.map { try reconcile($0, oldNodes: oldNodes) }
            let newIDs = replacements.flatMap(allIDs)
            let newSet = Set(newIDs)
            let changed = replacements.flatMap { changedIDs($0, oldNodes: oldNodes) }.filter(oldSet.contains)
            let oldPaths = paths(oldBlocks), newPaths = paths(replacements)
            let oldLifecycle = document.entries[entryIndex].lifecycle
            let newLifecycle: AgentEntryLifecycle = .open(markupBlockID: nil)

            inserted = newIDs.filter { !oldSet.contains($0) }
            removed = oldIDs.filter { !newSet.contains($0) }
            moved = oldIDs.filter { newSet.contains($0) && oldPaths[$0] != newPaths[$0] }
            let entryChanged = oldBlocks.count != replacements.count || oldLifecycle != newLifecycle ||
                !inserted.isEmpty || !removed.isEmpty || !moved.isEmpty || !changed.isEmpty
            guard entryChanged else { break }

            let entryRevision = try nextRevision(document.entries[entryIndex].revision, id: entryID)
            for block in oldBlocks { unindex(block) }
            document.entries[entryIndex].blocks = replacements
            document.entries[entryIndex].lifecycle = newLifecycle
            document.entries[entryIndex].revision = entryRevision
            for (blockIndex, block) in replacements.enumerated() {
                index(block, owner: entryID, root: block.id, entry: entryIndex, path: [blockIndex])
                topBlockLocations[block.id] = (entryIndex, blockIndex)
            }
            updated = unique([entryID] + changed.filter { $0 != entryID })

        case let .upsertStructured(entryID, incoming):
            let entryIndex = try requireEntry(entryID, .upsertStructured)
            guard case .open = document.entries[entryIndex].lifecycle else {
                throw AgentDocumentMutationError.entryFinished(entryID: entryID, operation: .upsertStructured)
            }
            try validateTree(incoming)

            if let indexedLocation = blockLocations[incoming.id], indexedLocation.entry == entryIndex {
                metrics.indexedBlockLookups += 1
                let location = topBlockLocations[topRoots[incoming.id]!]!
                let oldRoot = document.entries[entryIndex].blocks[location.block]
                let targetPath = Array(indexedLocation.path.dropFirst())
                let old = block(at: targetPath, in: oldRoot)
                let allowed = Set(allIDs(old))
                try validateFreshIDs(incoming, allowed: allowed)
                let replacement = try reconcile(incoming, oldNodes: indexed(old))
                guard replacement != old else { break }

                let oldIDs = allIDs(old), newIDs = allIDs(replacement)
                let oldSet = Set(oldIDs), newSet = Set(newIDs)
                let changed = changedIDs(replacement, oldNodes: indexed(old)).filter(oldSet.contains)

                let oldLifecycle = document.entries[entryIndex].lifecycle
                let newLifecycle: AgentEntryLifecycle
                if case let .open(markupBlockID) = oldLifecycle, markupBlockID == incoming.id {
                    newLifecycle = .open(markupBlockID: nil)
                } else {
                    newLifecycle = oldLifecycle
                }
                let oldPaths = paths(old), newPaths = paths(replacement)
                inserted = newIDs.filter { !oldSet.contains($0) }
                removed = oldIDs.filter { !newSet.contains($0) }
                moved = oldIDs.filter { newSet.contains($0) && oldPaths[$0] != newPaths[$0] }
                let entryChanged = !inserted.isEmpty || !removed.isEmpty || !moved.isEmpty ||
                    !changed.isEmpty || newLifecycle != oldLifecycle
                let nextEntryRevision = entryChanged
                    ? try nextRevision(document.entries[entryIndex].revision, id: entryID)
                    : document.entries[entryIndex].revision

                let newRoot: AgentBlock
                let ancestorIDs: [AgentNodeID]
                if targetPath.isEmpty {
                    newRoot = replacement
                    ancestorIDs = []
                } else {
                    let ancestorResult = try replacingDescendant(in: oldRoot, path: targetPath, with: replacement)
                    newRoot = ancestorResult.block
                    ancestorIDs = ancestorResult.updated
                }

                unindex(old)
                document.entries[entryIndex].blocks[location.block] = newRoot
                document.entries[entryIndex].lifecycle = newLifecycle
                document.entries[entryIndex].revision = nextEntryRevision
                index(replacement, owner: entryID, root: newRoot.id, entry: entryIndex, path: indexedLocation.path)
                if targetPath.isEmpty { topBlockLocations[replacement.id] = location }

                updated = unique((entryChanged ? [entryID] : []) + ancestorIDs + changed.filter { $0 != entryID })
            } else {
                try validateFreshIDs(incoming, allowed: [])
                let block = normalizedNew(incoming)
                let entryRevision = try nextRevision(document.entries[entryIndex].revision, id: entryID)
                let blockIndex = document.entries[entryIndex].blocks.count
                document.entries[entryIndex].blocks.append(block)
                document.entries[entryIndex].lifecycle = .open(markupBlockID: nil)
                document.entries[entryIndex].revision = entryRevision
                index(block, owner: entryID, root: block.id, entry: entryIndex, path: [blockIndex])
                topBlockLocations[block.id] = (entryIndex, blockIndex)
                inserted = allIDs(block)
                updated = [entryID]
            }

        case let .completeBlock(id, status):
            guard let owner = blockOwners[id], let rootID = topRoots[id] else {
                throw AgentDocumentMutationError.unknownBlock(blockID: id, operation: .completeBlock)
            }
            let entryIndex = try requireEntry(owner, .completeBlock)
            guard case .open = document.entries[entryIndex].lifecycle else {
                throw AgentDocumentMutationError.entryFinished(entryID: owner, operation: .completeBlock)
            }
            guard let location = topBlockLocations[rootID], location.entry == entryIndex else {
                throw AgentDocumentMutationError.unknownBlock(blockID: id, operation: .completeBlock)
            }
            let old = document.entries[entryIndex].blocks[location.block]
            guard let target = blockLocations[id].map({ block(at: Array($0.path.dropFirst()), in: old) }),
                  self.status(of: target.payload) != nil else {
                throw AgentDocumentMutationError.statusUnavailable(blockID: id)
            }
            let result = try replacingStatus(in: old, targetID: id, status: status)
            guard let replacement = result.block else { break }
            let entryRevision = try nextRevision(document.entries[entryIndex].revision, id: owner)
            document.entries[entryIndex].blocks[location.block] = replacement
            document.entries[entryIndex].revision = entryRevision
            updated = [owner] + result.updated

        case let .finishEntry(id):
            let entryIndex = try requireEntry(id, .finishEntry)
            guard case .open = document.entries[entryIndex].lifecycle else {
                throw AgentDocumentMutationError.duplicateFinish(entryID: id)
            }
            let revision = try nextRevision(document.entries[entryIndex].revision, id: id)
            document.entries[entryIndex].lifecycle = .finished
            document.entries[entryIndex].revision = revision
            // The turn's real end. Stamped HERE and not on every mutation: the
            // per-token path must stay free of clock reads, and this is the one
            // moment that is actually the end of anything.
            document.entries[entryIndex].finishedAt = createdAtProvider()
            updated = [id]

        case let .removeEntry(id):
            let entryIndex = try requireEntry(id, .removeEntry)
            let entry = document.entries.remove(at: entryIndex)
            removed = [entry.id] + entry.blocks.flatMap(allIDs)
            entryIndexes.removeValue(forKey: id)
            for block in entry.blocks { unindex(block) }
            for index in entryIndex..<document.entries.count { entryIndexes[document.entries[index].id] = index }
            let shiftedEntries = document.entries.dropFirst(entryIndex)
            moved = shiftedEntries.flatMap { [$0.id] + $0.blocks.flatMap(allIDs) }
            // Entry positions changed; update indexed locations for every shifted subtree.
            for block in shiftedEntries.flatMap(\.blocks) {
                if let owner = blockOwners[block.id], let ownerIndex = entryIndexes[owner],
                   let blockIndex = document.entries[ownerIndex].blocks.firstIndex(where: { $0.id == block.id }) {
                    topBlockLocations[block.id] = (ownerIndex, blockIndex)
                    updateIndexedEntry(for: block, to: ownerIndex)
                }
            }
        }

        document.version += 1
        return try AgentDocumentPatch(fromVersion: before, toVersion: document.version,
                                      inserted: inserted, updated: updated, removed: removed, moved: moved)
    }

    private func requireEntry(_ id: AgentNodeID, _ operation: AgentDocumentMutationOperation) throws -> Int {
        guard let index = entryIndexes[id] else { throw AgentDocumentMutationError.unknownEntry(entryID: id, operation: operation) }
        return index
    }

    private func markupID(entryID: AgentNodeID) throws -> AgentNodeID {
        var suffix = 0
        while true {
            let suffixText = "markup:\(document.version)\(suffix == 0 ? "" : "-\(suffix)")"
            let scoped = "\(entryID.rawValue)/\(suffixText)"
            // Provider IDs may consume the full AgentNodeID bound. The fallback
            // remains deterministic from the snapshot without rejecting an
            // otherwise valid entry solely because a derived ID needs space.
            let raw = scoped.utf8.count <= 512 ? scoped : suffixText
            guard let candidate = AgentNodeID(rawValue: raw) else {
                throw AgentDocumentMutationError.duplicateNodeID(id: entryID)
            }
            if entryIndexes[candidate] == nil && blockOwners[candidate] == nil { return candidate }
            suffix += 1
        }
    }

    private mutating func rebuildIndexes() {
        entryIndexes.removeAll(keepingCapacity: true)
        blockOwners.removeAll(keepingCapacity: true)
        blockLocations.removeAll(keepingCapacity: true)
        topBlockLocations.removeAll(keepingCapacity: true)
        topRoots.removeAll(keepingCapacity: true)
        for (entryIndex, entry) in document.entries.enumerated() {
            entryIndexes[entry.id] = entryIndex
            for (blockIndex, block) in entry.blocks.enumerated() {
                topBlockLocations[block.id] = (entryIndex, blockIndex)
                index(block, owner: entry.id, root: block.id, entry: entryIndex, path: [blockIndex])
            }
        }
    }

    private mutating func index(
        _ block: AgentBlock,
        owner: AgentNodeID,
        root: AgentNodeID,
        entry: Int,
        path: [Int]
    ) {
        metrics.reindexedNodes += 1
        blockOwners[block.id] = owner
        blockLocations[block.id] = (entry, path)
        topRoots[block.id] = root
        for (childIndex, child) in block.children.enumerated() {
            index(child, owner: owner, root: root, entry: entry, path: path + [childIndex])
        }
    }

    private mutating func unindex(_ block: AgentBlock) {
        metrics.reindexedNodes += 1
        blockOwners.removeValue(forKey: block.id)
        blockLocations.removeValue(forKey: block.id)
        topRoots.removeValue(forKey: block.id)
        if topBlockLocations[block.id] != nil { topBlockLocations.removeValue(forKey: block.id) }
        for child in block.children { unindex(child) }
    }

    private mutating func updateIndexedEntry(for block: AgentBlock, to entry: Int) {
        if let location = blockLocations[block.id] { blockLocations[block.id] = (entry, location.path) }
        for child in block.children { updateIndexedEntry(for: child, to: entry) }
    }

    private mutating func block(at path: [Int], in root: AgentBlock) -> AgentBlock {
        var result = root
        for index in path {
            metrics.blockPathSteps += 1
            result = result.children[index]
        }
        return result
    }

    private func replacingDescendant(
        in block: AgentBlock,
        path: [Int],
        with replacement: AgentBlock
    ) throws -> (block: AgentBlock, updated: [AgentNodeID]) {
        guard let childIndex = path.first else { return (replacement, []) }
        let childResult = try replacingDescendant(
            in: block.children[childIndex],
            path: Array(path.dropFirst()),
            with: replacement
        )
        var result = block
        result.children[childIndex] = childResult.block
        guard !visibleEqual(result, block) else { return (result, childResult.updated) }
        result.revision = try nextRevision(block.revision, id: block.id)
        return (result, [block.id] + childResult.updated)
    }

    private func validateTree(_ block: AgentBlock) throws {
        try validateForest([block])
    }

    private func validateForest(_ blocks: [AgentBlock]) throws {
        var seen: Set<AgentNodeID> = []
        func visit(_ node: AgentBlock) throws {
            guard seen.insert(node.id).inserted else { throw AgentDocumentMutationError.duplicateNodeID(id: node.id) }
            guard payloadMatchesKind(node) else { throw AgentDocumentMutationError.duplicateNodeID(id: node.id) }
            for child in node.children { try visit(child) }
        }
        for block in blocks { try visit(block) }
    }

    private func validateFreshIDs(_ block: AgentBlock, allowed: Set<AgentNodeID>) throws {
        for id in allIDs(block) where !allowed.contains(id) && (entryIndexes[id] != nil || blockOwners[id] != nil) {
            throw AgentDocumentMutationError.duplicateNodeID(id: id)
        }
    }

    private func payloadMatchesKind(_ block: AgentBlock) -> Bool {
        switch block.payload {
        case .paragraph: return block.kind == .paragraph
        case .heading: return block.kind == .heading
        case .list: return block.kind == .list
        case .listItem: return block.kind == .listItem
        case .quote: return block.kind == .quote
        case .thematicBreak: return block.kind == .thematicBreak
        case .table: return block.kind == .table
        case .fencedCode: return block.kind == .fencedCode
        case .toolCall: return block.kind == .toolCall
        case .commandOutput: return block.kind == .commandOutput
        case .plan: return block.kind == .plan
        case .diff: return block.kind == .diff
        case .approval: return block.kind == .approval
        case .question: return block.kind == .question
        case .image: return block.kind == .image
        case .imageGallery: return block.kind == .imageGallery
        case .fileReferences: return block.kind == .fileReferences
        case .agentReference: return block.kind == .agentReference
        case .error: return block.kind == .error
        case .notice: return block.kind == .notice
        case .compaction: return block.kind == .compaction
        case .opaque: return block.kind == .unknown || !builtInKinds.contains(block.kind)
        }
    }

    private var builtInKinds: Set<AgentBlockKind> {
        [.paragraph, .heading, .list, .listItem, .quote, .thematicBreak, .table, .fencedCode, .toolCall,
         .commandOutput, .plan, .diff, .approval, .question, .image, .imageGallery, .fileReferences, .agentReference, .error, .notice, .compaction, .unknown]
    }

    private func normalizedNew(_ block: AgentBlock) -> AgentBlock {
        var result = block
        result.revision = 0
        result.children = block.children.map(normalizedNew)
        return result
    }

    private func reconcile(_ block: AgentBlock, oldNodes: [AgentNodeID: AgentBlock]) throws -> AgentBlock {
        guard let old = oldNodes[block.id] else {
            var inserted = block
            inserted.revision = 0
            inserted.children = try block.children.map { try reconcile($0, oldNodes: oldNodes) }
            return inserted
        }
        guard old.kind == block.kind else { throw AgentDocumentMutationError.duplicateNodeID(id: block.id) }
        if let from = status(of: old.payload), let to = status(of: block.payload), from != to, !allows(from, to) {
            throw AgentDocumentMutationError.invalidStatusTransition(blockID: block.id, from: from, to: to)
        }
        var result = block
        result.children = try block.children.map { try reconcile($0, oldNodes: oldNodes) }
        result.revision = visibleEqual(result, old) ? old.revision : try nextRevision(old.revision, id: old.id)
        return result
    }

    private func replacingStatus(in block: AgentBlock, targetID: AgentNodeID, status: AgentItemStatus) throws -> (block: AgentBlock?, updated: [AgentNodeID]) {
        if block.id == targetID {
            guard let current = self.status(of: block.payload), current == status || allows(current, status) else {
                throw AgentDocumentMutationError.invalidStatusTransition(blockID: targetID, from: self.status(of: block.payload) ?? .completed, to: status)
            }
            guard current != status else { return (nil, []) }
            var result = block
            result.payload = payload(block.payload, replacingStatusWith: status)
            result.revision = try nextRevision(block.revision, id: block.id)
            return (result, [block.id])
        }
        for index in block.children.indices where contains(block.children[index], targetID) {
            let childResult = try replacingStatus(in: block.children[index], targetID: targetID, status: status)
            guard let child = childResult.block else { return (nil, []) }
            var result = block
            result.children[index] = child
            result.revision = try nextRevision(block.revision, id: block.id)
            return (result, [block.id] + childResult.updated)
        }
        throw AgentDocumentMutationError.unknownBlock(blockID: targetID, operation: .completeBlock)
    }

    private func status(of payload: AgentBlockPayload) -> AgentItemStatus? {
        switch payload {
        case .toolCall(let value): return value.status
        case .commandOutput(let value): return value.status
        case .plan(let value): return value.status
        case .approval(let value), .question(let value): return value.status
        case .notice(let value): return value.status
        default: return nil
        }
    }

    private func payload(_ payload: AgentBlockPayload, replacingStatusWith status: AgentItemStatus) -> AgentBlockPayload {
        switch payload {
        case .toolCall(var value): value.status = status; return .toolCall(value)
        case .commandOutput(var value): value.status = status; return .commandOutput(value)
        case .plan(var value): value.status = status; return .plan(value)
        case .approval(var value): value.status = status; return .approval(value)
        case .question(var value): value.status = status; return .question(value)
        case .notice(var value): value.status = status; return .notice(value)
        default: return payload
        }
    }

    private func allows(_ from: AgentItemStatus, _ to: AgentItemStatus) -> Bool {
        switch from {
        case .pending: return to != .pending
        case .inProgress: return [.completed, .failed, .cancelled, .interrupted].contains(to)
        case .completed, .failed, .cancelled, .interrupted: return false
        }
    }

    private func nextRevision(_ revision: UInt64, id: AgentNodeID) throws -> UInt64 {
        guard revision < .max else { throw AgentDocumentMutationError.nodeRevisionOverflow(id: id, current: revision) }
        return revision + 1
    }

    private func contains(_ block: AgentBlock, _ id: AgentNodeID) -> Bool {
        block.id == id || block.children.contains { contains($0, id) }
    }

    private func allIDs(_ block: AgentBlock) -> [AgentNodeID] { [block.id] + block.children.flatMap(allIDs) }

    private func indexed(_ block: AgentBlock) -> [AgentNodeID: AgentBlock] {
        var result: [AgentNodeID: AgentBlock] = [:]
        func visit(_ node: AgentBlock) { result[node.id] = node; node.children.forEach(visit) }
        visit(block)
        return result
    }

    private func visibleEqual(_ lhs: AgentBlock, _ rhs: AgentBlock) -> Bool {
        lhs.kind == rhs.kind && lhs.payload == rhs.payload && lhs.children.count == rhs.children.count &&
        zip(lhs.children, rhs.children).allSatisfy(visibleEqual)
    }

    private func changedIDs(_ block: AgentBlock, oldNodes: [AgentNodeID: AgentBlock]) -> [AgentNodeID] {
        var result: [AgentNodeID] = []
        if let old = oldNodes[block.id], !visibleEqual(block, old) { result.append(block.id) }
        for child in block.children { result += changedIDs(child, oldNodes: oldNodes) }
        return result
    }

    private func paths(_ block: AgentBlock) -> [AgentNodeID: String] {
        paths([block])
    }

    private func paths(_ blocks: [AgentBlock]) -> [AgentNodeID: String] {
        var result: [AgentNodeID: String] = [:]
        func visit(_ node: AgentBlock, _ path: String) {
            result[node.id] = path
            for (index, child) in node.children.enumerated() { visit(child, "\(path).\(index)") }
        }
        for (index, block) in blocks.enumerated() { visit(block, "\(index)") }
        return result
    }

    private func unique(_ ids: [AgentNodeID]) -> [AgentNodeID] {
        var seen: Set<AgentNodeID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    /// Streaming appends extend the trailing text run until it reaches this size,
    /// then open a new run.
    ///
    /// A document snapshot is always live elsewhere while a turn streams (the
    /// rendered snapshot the list holds), so the accumulated string is never
    /// uniquely referenced and `+` must copy it. Concatenating into one
    /// ever-growing run therefore copied the whole answer-so-far on every
    /// streamed chunk, making a single long response cost O(length²) to
    /// assemble — the reason a long turn degraded while total session length did
    /// not matter. Capping the run bounds each append to a constant instead.
    ///
    /// The cap is well above ordinary content, so a normal block is still one
    /// inline and finished transcripts keep their canonical single-run shape;
    /// only genuinely long streamed answers split, and every reader already
    /// treats `.paragraph` as a run sequence (emphasis, code and links produce
    /// several runs today).
    public static let maximumStreamingRunUTF8Length = 4096

    private func appending(_ delta: String, to inlines: [AgentInline]) -> [AgentInline] {
        var result = inlines
        let cap = Self.maximumStreamingRunUTF8Length

        // Keep the overwhelmingly common small-delta path direct. Checking both
        // operands matters: merely checking that the existing run is below the
        // cap lets one large provider delta create an arbitrarily oversized run.
        if case let .text(text) = result.last {
            let existingBytes = text.utf8.count
            let deltaBytes = delta.utf8.count
            if existingBytes <= cap, deltaBytes <= cap - existingBytes {
                result[result.count - 1] = .text(text + delta)
                return result
            }
        }

        if delta.isEmpty {
            result.append(.text(""))
            return result
        }

        // Provider chunks are not size-bounded. Fill any remaining capacity and
        // split a large delta at Unicode-scalar boundaries so every run remains
        // valid UTF-8 while the concatenated source stays exact.
        var buffer = ""
        var bufferBytes = 0
        var ownsTrailingTextRun = false
        if case let .text(text) = result.last, text.utf8.count < cap {
            buffer = text
            bufferBytes = text.utf8.count
            ownsTrailingTextRun = true
            result.removeLast()
        }

        for scalar in delta.unicodeScalars {
            let scalarText = String(scalar)
            let scalarBytes = scalarText.utf8.count
            if bufferBytes + scalarBytes > cap {
                result.append(.text(buffer))
                buffer = ""
                bufferBytes = 0
                ownsTrailingTextRun = false
            }
            buffer.append(contentsOf: scalarText)
            bufferBytes += scalarBytes
        }
        if !buffer.isEmpty || ownsTrailingTextRun || (delta.isEmpty && result.isEmpty) {
            result.append(.text(buffer))
        }
        return result
    }
}
