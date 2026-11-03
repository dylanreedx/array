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
        /// The shared agent's whole helper roster, replacing the last one
        /// (`SharedAgentTranscriptHelpers.swift`). Sent on change.
        case helpers([Helper])
        case toolDetail(block: AgentNodeID, detail: SharedAgentToolPresentation?)
        case imageManifest(SharedAgentTranscriptImages.Manifest)
        case imageChunk(SharedAgentTranscriptImages.Chunk)
        /// The host tile's chrome now (agent-chrome). Replaces the last one.
        case chrome(Chrome)
        /// A person's own character set, sent once per set before the chrome
        /// that names it.
        case characterTheme(CharacterTheme)
        /// An op this build does not know (a newer host): decoded and skipped.
        case unknown(String)

        private enum Keys: String, CodingKey { case op, head, after, blocks, entry, block, helpers, detail, manifest, chunk, chrome, theme }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let op = try c.decode(String.self, forKey: .op)
            switch op {
            case "entry":
                self = .entry(try c.decode(Head.self, forKey: .head), after: try c.decodeIfPresent(AgentNodeID.self, forKey: .after),
                              blocks: try c.decode([AgentNodeID].self, forKey: .blocks))
            case "block": self = .block(entry: try c.decode(AgentNodeID.self, forKey: .entry), try c.decode(AgentBlock.self, forKey: .block))
            case "remove": self = .remove(entry: try c.decode(AgentNodeID.self, forKey: .entry))
            case "helpers": self = .helpers(try c.decode([Helper].self, forKey: .helpers))
            case "toolDetail": self = .toolDetail(block: try c.decode(AgentNodeID.self, forKey: .block), detail: try c.decodeIfPresent(SharedAgentToolPresentation.self, forKey: .detail))
            case "imageManifest": self = .imageManifest(try c.decode(SharedAgentTranscriptImages.Manifest.self, forKey: .manifest))
            case "imageChunk": self = .imageChunk(try c.decode(SharedAgentTranscriptImages.Chunk.self, forKey: .chunk))
            // Chrome is presentation: one this build cannot read is skipped,
            // never a reason to drop the frame and resnapshot the transcript.
            case "chrome": self = (try? c.decode(Chrome.self, forKey: .chrome)).map(Op.chrome) ?? .unknown(op)
            case "characterTheme": self = (try? c.decode(CharacterTheme.self, forKey: .theme)).map(Op.characterTheme) ?? .unknown(op)
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
            case let .helpers(helpers):
                try c.encode("helpers", forKey: .op); try c.encode(helpers, forKey: .helpers)
            case let .toolDetail(block, detail):
                try c.encode("toolDetail", forKey: .op); try c.encode(block, forKey: .block)
                try c.encodeIfPresent(detail, forKey: .detail)
            case let .imageManifest(manifest):
                try c.encode("imageManifest", forKey: .op); try c.encode(manifest, forKey: .manifest)
            case let .imageChunk(chunk):
                try c.encode("imageChunk", forKey: .op); try c.encode(chunk, forKey: .chunk)
            case let .chrome(chrome):
                try c.encode("chrome", forKey: .op); try c.encode(chrome, forKey: .chrome)
            case let .characterTheme(theme):
                try c.encode("characterTheme", forKey: .op); try c.encode(theme, forKey: .theme)
            case let .unknown(op):
                try c.encode(op, forKey: .op)
            }
        }
    }

    public struct ToolDetail: Codable, Equatable, Sendable {
        public let block: AgentNodeID
        public let detail: SharedAgentToolPresentation
        public init(block: AgentNodeID, detail: SharedAgentToolPresentation) {
            self.block = block; self.detail = detail
        }
    }
    public struct Checkpoint: Codable, Equatable, Sendable {
        public let schema: Int
        public let entries: [AgentEntry]
        public let omittedEntries: Int
        /// The helper roster at this point. Nil from a host that sends none
        /// (a child stream, or a host before helpers).
        public let helpers: [Helper]?
        public let toolDetails: [ToolDetail]
        /// The chrome at the checkpoint, and the set it names when that is a
        /// person's own: a late joiner or a resnapshot has seen no earlier frame.
        public var chrome: Chrome?
        public var characterTheme: CharacterTheme?
        public init(entries: [AgentEntry], omittedEntries: Int, helpers: [Helper]? = nil, toolDetails: [ToolDetail] = [],
                    chrome: Chrome? = nil, characterTheme: CharacterTheme? = nil) {
            schema = SharedAgentTranscriptWire.schema; self.entries = entries
            self.omittedEntries = omittedEntries; self.helpers = helpers; self.toolDetails = toolDetails
            self.chrome = chrome; self.characterTheme = characterTheme
        }
        private enum Keys: String, CodingKey { case schema, entries, omittedEntries, helpers, toolDetails, chrome, characterTheme }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            schema = try c.decode(Int.self, forKey: .schema)
            entries = try c.decode([AgentEntry].self, forKey: .entries)
            omittedEntries = try c.decode(Int.self, forKey: .omittedEntries)
            helpers = try c.decodeIfPresent([Helper].self, forKey: .helpers)
            toolDetails = try c.decodeIfPresent([ToolDetail].self, forKey: .toolDetails) ?? []
            chrome = try? c.decodeIfPresent(Chrome.self, forKey: .chrome)
            characterTheme = try? c.decodeIfPresent(CharacterTheme.self, forKey: .characterTheme)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(schema, forKey: .schema); try c.encode(entries, forKey: .entries)
            try c.encode(omittedEntries, forKey: .omittedEntries)
            try c.encodeIfPresent(helpers, forKey: .helpers); try c.encode(toolDetails, forKey: .toolDetails)
            try c.encodeIfPresent(chrome, forKey: .chrome); try c.encodeIfPresent(characterTheme, forKey: .characterTheme)
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
    public static func window(_ entries: [AgentEntry], maxBytes: Int, budget: SharedAgentTranscriptBudget,
                              chrome: Chrome? = nil, characterTheme: CharacterTheme? = nil) -> Checkpoint {
        let carried = (chrome.flatMap { try? encode($0).count } ?? 0) + (characterTheme.flatMap { try? encode($0).count } ?? 0)
        var kept: [AgentEntry] = [], used = 64 + carried
        for entry in entries.reversed() {
            let fitted = budget.fit(entry)
            let size = (try? encode(fitted).count) ?? .max
            guard used + size <= maxBytes else { break }
            kept.append(fitted); used += size
        }
        return Checkpoint(entries: kept.reversed(), omittedEntries: entries.count - kept.count,
                          chrome: chrome, characterTheme: characterTheme)
    }

    public static func blockIDs(in entries: [AgentEntry]) -> Set<AgentNodeID> {
        var ids: Set<AgentNodeID> = []
        func visit(_ block: AgentBlock) { ids.insert(block.id); block.children.forEach(visit) }
        entries.forEach { $0.blocks.forEach(visit) }
        return ids
    }

    // MARK: - Guest

    /// The guest's copy of the host's document. It applies only what it was
    /// sent and reports what changed in the shape the renderer takes.
    public struct Mirror: Equatable, Sendable {
        public private(set) var document = AgentDocument()
        public private(set) var omittedEntries = 0
        /// The host's helper roster; nil until a host that sends one has.
        public private(set) var helpers: [Helper]?
        public private(set) var toolDetails: [AgentNodeID: SharedAgentToolPresentation] = [:]
        public private(set) var images = SharedAgentTranscriptImages.Receiver()
        /// The host tile's chrome, as last sent; nil before any (an older host).
        public private(set) var chrome: Chrome?
        /// The person's own sets this mirror was sent, by hash. Unvalidated: the
        /// app validates one before drawing it.
        public private(set) var characterThemes: [String: CharacterTheme] = [:]
        /// Sets kept at once: a host sends the one it shows, and a change of set
        /// sends the new one.
        public static let maximumCharacterThemes = 4
        public init() {}

        private mutating func keep(_ theme: CharacterTheme) {
            if characterThemes.count >= Self.maximumCharacterThemes, characterThemes[theme.hash] == nil {
                let named = chrome?.character?.theme.hash
                if let drop = characterThemes.keys.sorted().first(where: { $0 != named }) { characterThemes[drop] = nil }
            }
            characterThemes[theme.hash] = theme
        }

        public enum Failure: Error, Equatable { case schema, unknownEntry(AgentNodeID), missingBlock(AgentNodeID), unknownAnchor(AgentNodeID), invalidHelpers }
        public struct Touched: Equatable, Sendable {
            public var ids: Set<AgentNodeID> = []
            public var structural = false
            /// The chrome or a character set changed.
            public var chrome = false
            public init(ids: Set<AgentNodeID> = [], structural: Bool = false) { self.ids = ids; self.structural = structural }
        }

        public mutating func install(_ checkpoint: Checkpoint) throws -> Touched {
            guard checkpoint.schema <= SharedAgentTranscriptWire.schema else { throw Failure.schema }
            if let roster = checkpoint.helpers, !SharedAgentTranscriptWire.valid(helpers: roster) { throw Failure.invalidHelpers }
            let validIDs = SharedAgentTranscriptWire.blockIDs(in: checkpoint.entries)
            guard checkpoint.toolDetails.allSatisfy({ validIDs.contains($0.block) }),
                  Set(checkpoint.toolDetails.map(\.block)).count == checkpoint.toolDetails.count else { throw Failure.schema }
            toolDetails = Dictionary(uniqueKeysWithValues: checkpoint.toolDetails.map { ($0.block, $0.detail) })
            images = SharedAgentTranscriptImages.Receiver()
            omittedEntries = checkpoint.omittedEntries
            helpers = checkpoint.helpers
            chrome = checkpoint.chrome
            if let theme = checkpoint.characterTheme { keep(theme) }
            var entries = checkpoint.entries
            if checkpoint.omittedEntries > 0 { entries.insert(Self.omittedNotice(checkpoint.omittedEntries), at: 0) }
            document = AgentDocument(version: document.version &+ 1, entries: entries)
            var touched = Touched(ids: [], structural: true)
            touched.chrome = true
            return touched
        }

        /// All or nothing: a patch that fails leaves the mirror as it was.
        public mutating func apply(_ patch: Patch) throws -> Touched {
            guard patch.schema <= SharedAgentTranscriptWire.schema else { throw Failure.schema }
            var entries = document.entries
            var details = toolDetails
            var receivedImages = images
            var touched = Touched()
            var pendingOrder: [AgentNodeID: [AgentNodeID]] = [:]
            var stagedBlocks: [AgentNodeID: [AgentNodeID: AgentBlock]] = [:]
            var roster = helpers
            var pendingChrome: Chrome?
            var pendingThemes: [CharacterTheme] = []
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
                case let .helpers(list):
                    guard SharedAgentTranscriptWire.valid(helpers: list) else { throw Failure.invalidHelpers }
                    roster = list
                case let .toolDetail(block, detail):
                    details[block] = detail
                    touched.ids.insert(block)
                case let .imageManifest(manifest):
                    do { try receivedImages.register(manifest) } catch { throw Failure.schema }
                case let .imageChunk(chunk):
                    do { try receivedImages.receive(chunk) } catch { throw Failure.schema }
                    touched.structural = true
                case let .chrome(next):
                    touched.chrome = true
                    pendingChrome = next
                case let .characterTheme(theme):
                    touched.chrome = true
                    pendingThemes.append(theme)
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
            let validIDs = SharedAgentTranscriptWire.blockIDs(in: entries)
            guard touched.ids.filter({ details[$0] != nil }).allSatisfy(validIDs.contains) else { throw Failure.schema }
            toolDetails = details.filter { validIDs.contains($0.key) }
            images = receivedImages
            for theme in pendingThemes { keep(theme) }
            if let pendingChrome { chrome = pendingChrome }
            // A chrome-only patch leaves the document (and its version) alone,
            // so the transcript does not re-present for a status tick.
            if entries != document.entries || !touched.ids.isEmpty || touched.structural {
                document = AgentDocument(version: document.version &+ 1, entries: entries)
            }
            helpers = roster
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
        case .diff(var diff):
            diff.text = Self.cut(diff.text, to: limit / 2)
            copy.payload = .diff(diff)
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

/// The host's diff body renders only the first 30 hunk lines. Build the wire
/// preview from those visible lines, not the raw diff (which may also contain
/// undisplayed old paths and secret-bearing later hunks). The total travels in
/// the tool presentation, so the overflow label still tells the truth.
public struct SharedAgentTranscriptSafeBudget: SharedAgentTranscriptBudget {
    public init() {}
    /// The host shows at most eight file names. Keep hidden rows' counts and
    /// actions for the aggregate, but do not send their undisplayed names.
    public static func visibleFiles(_ files: [AgentDiffFileSummary]) -> [AgentDiffFileSummary] {
        files.enumerated().map { index, file in
            guard index >= 8 else { return file }
            var safe = file; safe.displayName = "Changed file"; return safe
        }
    }
    public func fit(_ block: AgentBlock, limit: Int) -> AgentBlock {
        var safe = block
        switch block.payload {
        case .toolCall, .diff: safe.children = []
        default: safe.children = block.children.map { fit($0, limit: limit) }
        }
        // The tool renderer never reads the opaque argument object; its
        // visible disclosure comes from the sanitized presentation op.
        if case var .toolCall(tool) = safe.payload {
            // The semantic node can outlive its visible row (a subagent chip
            // folds the spawning call away). Its actual visible name and body
            // travel only in the presentation op while the row is visible.
            tool.name = "Tool"; tool.summary = nil; tool.arguments = nil
            safe.payload = .toolCall(tool)
        }
        if case var .diff(diff) = safe.payload {
            diff.files = Self.visibleFiles(diff.files)
            guard !diff.text.isEmpty else {
                safe.payload = .diff(diff)
                return SharedAgentTranscriptTruncatingBudget().fit(safe, limit: limit)
            }
            let model = GitDiffParser.parse(diff.text)
            var lines: [String] = []
            var shown = 0
            for file in model.files {
                let path = file.newPath ?? file.oldPath ?? "(unknown)"
                lines.append("diff --git a/\(path) b/\(path)")
                switch file.change {
                case .added: lines.append("new file mode 100644")
                case .deleted: lines.append("deleted file mode 100644")
                case .renamed: lines.append("rename from \(path)"); lines.append("rename to \(path)")
                case .modified, .binary: break
                }
                lines.append("--- " + (file.change == .added ? "/dev/null" : "a/\(path)"))
                lines.append("+++ " + (file.change == .deleted ? "/dev/null" : "b/\(path)"))
                if file.isBinary { lines.append("Binary files differ"); continue }
                for hunk in file.hunks where shown < 30 {
                    lines.append(hunk.header)
                    for line in hunk.lines.prefix(30 - shown) {
                        switch line.kind {
                        case .addition: lines.append("+" + line.text)
                        case .deletion: lines.append("-" + line.text)
                        case .context: lines.append(" " + line.text)
                        case .metadata: lines.append(line.text)
                        }
                        shown += 1
                    }
                }
            }
            diff.text = lines.joined(separator: "\n")
            diff.canOpenReview = false
            safe.payload = .diff(diff)
        }
        return SharedAgentTranscriptTruncatingBudget().fit(safe, limit: limit)
    }
}
