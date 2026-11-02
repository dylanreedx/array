import Foundation
import ContinuumRevivedAgentContent

/// The body of `Collaboration.AgentTranscript` frames: the owner's own
/// `AgentDocument`, as a checkpoint plus entry/block patches. The relay never
/// reads this; the host's publisher writes it and the guest's mirror reads it,
/// so the guest draws the very document the host tile draws.
/// Contract: `~/array-scratch/mp-polish/transcript-lead/CONTRACT.md`.
public enum SharedAgentTranscriptWire {
    public static let schema = 1
    /// One outgoing top-level block, encoded, before the budget cuts it.
    public static let maxBlockBytes = 32 * 1024
    /// The guest's one synthetic node: the notice over a window that starts
    /// after the host's first entry.
    public static let omittedHistoryEntryID = AgentNodeID(rawValue: "shared-omitted-history")!

    /// An entry without its blocks: what `.entry` carries.
    public struct Head: Codable, Equatable, Sendable {
        public let id: AgentNodeID
        public var revision: UInt64
        public var role: AgentEntryRole
        public var provenance: AgentProvenance
        public var lifecycle: AgentEntryLifecycle
        public var createdAt: Date?
        public var finishedAt: Date?
        public var turnTiming: AgentTurnTiming?
        public init(_ entry: AgentEntry) {
            id = entry.id; revision = entry.revision; role = entry.role; provenance = entry.provenance
            lifecycle = entry.lifecycle; createdAt = entry.createdAt; finishedAt = entry.finishedAt; turnTiming = entry.turnTiming
        }
        func entry(blocks: [AgentBlock]) -> AgentEntry {
            AgentEntry(id: id, revision: revision, role: role, provenance: provenance, lifecycle: lifecycle,
                       blocks: blocks, createdAt: createdAt, finishedAt: finishedAt, turnTiming: turnTiming)
        }
    }

    public enum Op: Codable, Equatable, Sendable {
        /// Insert or update an entry's head and its top-level block order, after
        /// `after` (nil = first). Blocks it names arrive as `.block` in the same
        /// patch unless the guest already holds them.
        case entry(Head, after: AgentNodeID?, blocks: [AgentNodeID])
        /// One top-level block with its whole subtree.
        case block(entry: AgentNodeID, AgentBlock)
        case remove(entry: AgentNodeID)
        /// An op this build does not know (a newer host): decoded and skipped.
        case unknown(String)

        private enum Keys: String, CodingKey { case op, head, after, blocks, entry, block }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let op = try c.decode(String.self, forKey: .op)
            switch op {
            case "entry":
                self = .entry(try c.decode(Head.self, forKey: .head), after: try c.decodeIfPresent(AgentNodeID.self, forKey: .after),
                              blocks: try c.decode([AgentNodeID].self, forKey: .blocks))
            case "block": self = .block(entry: try c.decode(AgentNodeID.self, forKey: .entry), try c.decode(AgentBlock.self, forKey: .block))
            case "remove": self = .remove(entry: try c.decode(AgentNodeID.self, forKey: .entry))
            default: self = .unknown(op)
            }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case let .entry(head, after, blocks):
                try c.encode("entry", forKey: .op); try c.encode(head, forKey: .head)
                try c.encodeIfPresent(after, forKey: .after); try c.encode(blocks, forKey: .blocks)
            case let .block(entry, block):
                try c.encode("block", forKey: .op); try c.encode(entry, forKey: .entry); try c.encode(block, forKey: .block)
            case let .remove(entry):
                try c.encode("remove", forKey: .op); try c.encode(entry, forKey: .entry)
            case let .unknown(op):
                try c.encode(op, forKey: .op)
            }
        }
    }

    public struct Checkpoint: Codable, Equatable, Sendable {
        public let schema: Int
        public let entries: [AgentEntry]
        /// Host entries before the window, which stay on the host's Mac.
        public let omittedEntries: Int
        public init(entries: [AgentEntry], omittedEntries: Int) {
            schema = SharedAgentTranscriptWire.schema; self.entries = entries; self.omittedEntries = omittedEntries
        }
    }
    public struct Patch: Codable, Equatable, Sendable {
        public let schema: Int
        public let ops: [Op]
        public init(ops: [Op]) { schema = SharedAgentTranscriptWire.schema; self.ops = ops }
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        // Dates as Foundation's own seconds, not ISO-8601: whole-second
        // strings would round every timestamp and break host/guest equality.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    // MARK: - Host

    /// Changes from what was published to the current document, by id and
    /// revision. Nil when surviving entries changed relative order: the
    /// publisher sends a checkpoint instead of encoding a move.
    public static func patch(from published: [AgentEntry], to current: [AgentEntry]) -> [Op]? {
        let old = Dictionary(published.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(current.map(\.id))
        let survivingOld = published.map(\.id).filter(currentIDs.contains)
        let survivingNew = current.map(\.id).filter { old[$0] != nil }
        guard survivingOld == survivingNew else { return nil }
        var ops: [Op] = published.filter { !currentIDs.contains($0.id) }.map { .remove(entry: $0.id) }
        var previous: AgentNodeID?
        for entry in current {
            defer { previous = entry.id }
            let prior = old[entry.id]
            // Revisions move on every visible change (`validateIdentityInvariants`),
            // so a streaming tick compares integers, not the whole transcript.
            if let prior, Head(prior) == Head(entry), prior.blocks.map(\.id) == entry.blocks.map(\.id),
               zip(prior.blocks, entry.blocks).allSatisfy({ $0.revision == $1.revision }) { continue }
            let priorRevisions = Dictionary((prior?.blocks ?? []).map { ($0.id, $0.revision) }, uniquingKeysWith: { first, _ in first })
            ops.append(.entry(Head(entry), after: previous, blocks: entry.blocks.map(\.id)))
            for block in entry.blocks where priorRevisions[block.id] != block.revision {
                ops.append(.block(entry: entry.id, block))
            }
        }
        return ops
    }

    /// The newest entries whose encoding fits `maxBytes`, oldest first.
    public static func window(_ entries: [AgentEntry], maxBytes: Int, budget: SharedAgentTranscriptBudget) -> Checkpoint {
        var kept: [AgentEntry] = [], used = 64
        for entry in entries.reversed() {
            let fitted = budget.fit(entry)
            let size = (try? encode(fitted).count) ?? .max
            guard used + size <= maxBytes else { break }
            kept.append(fitted); used += size
        }
        return Checkpoint(entries: kept.reversed(), omittedEntries: entries.count - kept.count)
    }

    // MARK: - Guest

    /// The guest's copy of the host's document. It applies only what it was
    /// sent and reports what changed in the shape the renderer takes.
    public struct Mirror: Equatable, Sendable {
        public private(set) var document = AgentDocument()
        public private(set) var omittedEntries = 0
        public init() {}

        public enum Failure: Error, Equatable { case schema, unknownEntry(AgentNodeID), missingBlock(AgentNodeID), unknownAnchor(AgentNodeID) }
        public struct Touched: Equatable, Sendable {
            public var ids: Set<AgentNodeID> = []
            public var structural = false
            public init(ids: Set<AgentNodeID> = [], structural: Bool = false) { self.ids = ids; self.structural = structural }
        }

        public mutating func install(_ checkpoint: Checkpoint) throws -> Touched {
            guard checkpoint.schema <= SharedAgentTranscriptWire.schema else { throw Failure.schema }
            omittedEntries = checkpoint.omittedEntries
            var entries = checkpoint.entries
            if checkpoint.omittedEntries > 0 { entries.insert(Self.omittedNotice(checkpoint.omittedEntries), at: 0) }
            document = AgentDocument(version: document.version &+ 1, entries: entries)
            return Touched(ids: [], structural: true)
        }

        /// All or nothing: a patch that fails leaves the mirror as it was.
        public mutating func apply(_ patch: Patch) throws -> Touched {
            guard patch.schema <= SharedAgentTranscriptWire.schema else { throw Failure.schema }
            var entries = document.entries
            var touched = Touched()
            var pendingOrder: [AgentNodeID: [AgentNodeID]] = [:]
            var stagedBlocks: [AgentNodeID: [AgentNodeID: AgentBlock]] = [:]
            func index(_ id: AgentNodeID) -> Int? { entries.firstIndex { $0.id == id } }
            for op in patch.ops {
                switch op {
                case let .remove(id):
                    guard let at = index(id) else { continue }
                    entries.remove(at: at); touched.structural = true; touched.ids.insert(id)
                case let .entry(head, after, order):
                    let anchor: Int
                    if let after {
                        guard let found = index(after) else { throw Failure.unknownAnchor(after) }
                        anchor = found + 1
                    } else {
                        anchor = entries.first?.id == SharedAgentTranscriptWire.omittedHistoryEntryID ? 1 : 0
                    }
                    if let at = index(head.id) {
                        let existing = entries[at]
                        entries[at] = head.entry(blocks: existing.blocks)
                        if existing.blocks.map(\.id) != order { touched.structural = true }
                        if at != anchor { throw Failure.unknownAnchor(head.id) }
                    } else {
                        entries.insert(head.entry(blocks: []), at: min(anchor, entries.count))
                        touched.structural = true
                    }
                    pendingOrder[head.id] = order
                    touched.ids.insert(head.id)
                case let .block(entryID, block):
                    guard index(entryID) != nil else { throw Failure.unknownEntry(entryID) }
                    stagedBlocks[entryID, default: [:]][block.id] = block
                    touched.ids.insert(block.id)
                case .unknown:
                    continue
                }
            }
            for (entryID, order) in pendingOrder {
                guard let at = index(entryID) else { continue }
                let held = Dictionary(entries[at].blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let staged = stagedBlocks.removeValue(forKey: entryID) ?? [:]
                entries[at].blocks = try order.map { id in
                    guard let block = staged[id] ?? held[id] else { throw Failure.missingBlock(id) }
                    return block
                }
            }
            for (entryID, staged) in stagedBlocks {
                guard let at = index(entryID) else { throw Failure.unknownEntry(entryID) }
                for (id, block) in staged {
                    guard let slot = entries[at].blocks.firstIndex(where: { $0.id == id }) else { throw Failure.missingBlock(id) }
                    entries[at].blocks[slot] = block
                }
            }
            document = AgentDocument(version: document.version &+ 1, entries: entries)
            return touched
        }

        static func omittedNotice(_ count: Int) -> AgentEntry {
            let text = count == 1 ? "1 earlier message stays on the owner's Mac" : "\(count) earlier messages stay on the owner's Mac"
            let block = AgentBlock(id: AgentNodeID(rawValue: "shared-omitted-history-notice")!, kind: .notice,
                                   payload: .notice(AgentNoticePayload(message: [.text(text)])))
            return AgentEntry(id: SharedAgentTranscriptWire.omittedHistoryEntryID, role: .system, provenance: .localNotice(reason: "shared-omitted-history"),
                              lifecycle: .finished, blocks: [block])
        }
    }
}

/// transcript-tools' hook: what one outgoing block may cost. The publisher
/// passes every top-level block through `fit` before encoding it. A fitted
/// block keeps its id and revision so the guest's renderer reuses it the same
/// way the host's does.
public protocol SharedAgentTranscriptBudget: Sendable {
    func fit(_ block: AgentBlock, limit: Int) -> AgentBlock
}

public extension SharedAgentTranscriptBudget {
    func fit(_ entry: AgentEntry) -> AgentEntry {
        var copy = entry
        copy.blocks = entry.blocks.map { fit($0, limit: SharedAgentTranscriptWire.maxBlockBytes) }
        return copy
    }
}

/// The default: cut long code and command output, and replace any other
/// block still over the limit with a notice.
public struct SharedAgentTranscriptTruncatingBudget: SharedAgentTranscriptBudget {
    public init() {}
    public func fit(_ block: AgentBlock, limit: Int) -> AgentBlock {
        guard let size = try? SharedAgentTranscriptWire.encode(block).count, size > limit else { return block }
        var copy = block
        switch block.payload {
        case .fencedCode(var code):
            code.code = Self.cut(code.code, to: limit / 2)
            copy.payload = .fencedCode(code)
        case .commandOutput(var output):
            output.text = Self.cut(output.text, to: limit / 2)
            copy.payload = .commandOutput(output)
        default:
            break
        }
        if copy != block, let cut = try? SharedAgentTranscriptWire.encode(copy).count, cut <= limit { return copy }
        return AgentBlock(id: block.id, revision: block.revision, kind: .notice,
                          payload: .notice(AgentNoticePayload(message: [.text("Too large to share · stays on the owner's Mac")])))
    }
    static func cut(_ text: String, to bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var out = "", used = 0
        for character in text {
            let size = String(character).utf8.count
            guard used + size <= bytes else { break }
            out.append(character); used += size
        }
        return out + "\n…"
    }
}
