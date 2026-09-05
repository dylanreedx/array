import Foundation

/// Extensible semantic renderer key. Built-ins are constants rather than enum
/// cases so a future provider/extension can introduce a kind without changing
/// every switch in the application.
public struct AgentBlockKind: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 96 else { return nil }
        let scalars = Array(rawValue.unicodeScalars)
        guard let first = scalars.first, Self.isLowercaseASCII(first) else { return nil }
        var previousWasSeparator = false
        for scalar in scalars.dropFirst() {
            let isSeparator = scalar == "." || scalar == "-" || scalar == "_"
            guard Self.isLowercaseASCII(scalar) || Self.isDigitASCII(scalar) || (isSeparator && !previousWasSeparator)
            else { return nil }
            previousWasSeparator = isSeparator
        }
        guard !previousWasSeparator else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let kind = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AgentBlockKind must be a bounded lowercase semantic key"
            )
        }
        self = kind
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isLowercaseASCII(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 97 && scalar.value <= 122
    }

    private static func isDigitASCII(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }

    public static let paragraph = Self(rawValue: "paragraph")!
    public static let heading = Self(rawValue: "heading")!
    public static let list = Self(rawValue: "list")!
    public static let listItem = Self(rawValue: "list-item")!
    public static let quote = Self(rawValue: "quote")!
    public static let thematicBreak = Self(rawValue: "thematic-break")!
    public static let table = Self(rawValue: "table")!
    public static let fencedCode = Self(rawValue: "fenced-code")!
    public static let toolCall = Self(rawValue: "tool-call")!
    public static let commandOutput = Self(rawValue: "command-output")!
    public static let plan = Self(rawValue: "plan")!
    public static let diff = Self(rawValue: "diff")!
    public static let approval = Self(rawValue: "approval")!
    public static let question = Self(rawValue: "question")!
    public static let image = Self(rawValue: "image")!
    public static let imageGallery = Self(rawValue: "image-gallery")!
    public static let fileReferences = Self(rawValue: "file-references")!
    public static let agentReference = Self(rawValue: "agent-reference")!
    public static let error = Self(rawValue: "error")!
    public static let notice = Self(rawValue: "notice")!
    public static let unknown = Self(rawValue: "unknown")!
    public static let compaction = Self(rawValue: "compaction")!
}

public struct AgentListPayload: Codable, Equatable, Sendable {
    public var ordered: Bool
    public var start: Int?

    public init(ordered: Bool, start: Int? = nil) {
        self.ordered = ordered
        self.start = start
    }
}

public struct AgentCodePayload: Codable, Equatable, Sendable {
    public var language: String?
    public var code: String
    public var isComplete: Bool

    public init(language: String? = nil, code: String, isComplete: Bool = true) {
        self.language = language
        self.code = code
        self.isComplete = isComplete
    }
}

public struct AgentToolCallPayload: Codable, Equatable, Sendable {
    public var name: String
    public var summary: String?
    public var arguments: AgentOpaqueValue?
    public var status: AgentItemStatus
    /// `.plans/45` S3 — presentation-only trailing detail (the "2.1s" beside
    /// the status glyph), set on the EPHEMERAL rendered copy from the
    /// host-local detail store. Deliberately excluded from CodingKeys: it is
    /// never document state and never crosses a sync boundary (I5).
    public var presentedTrailingDetailText: String?
    /// `.plans/45` S4 — when the presented `name` becomes the action sentence,
    /// the semantic tool name survives here for the icon, tooltip and AX
    /// label. Presentation-only, excluded from CodingKeys like the field above.
    public var presentedToolNameText: String?
    /// `.plans/45` S4 — the store's bounded output preview for the expanded
    /// pane, plus an honesty note ("Output truncated…" / "Redacted").
    /// Presentation-only, excluded from CodingKeys: tool output NEVER enters
    /// the semantic document (I5); this exists only on the ephemeral rendered
    /// copy the host composes from `AgentToolDetailStore`.
    public var presentedOutputText: String?
    public var presentedOutputNote: String?
    /// `.plans/45` — this row is a MEMBER of an expanded tool cluster: it draws
    /// indented behind a left rail so the group reads as a group. Presentation
    /// only, excluded from CodingKeys.
    public var presentedIsClusterMember: Bool = false

    private enum CodingKeys: String, CodingKey {
        case name, summary, arguments, status
    }

    public init(name: String, summary: String? = nil, arguments: AgentOpaqueValue? = nil, status: AgentItemStatus) {
        self.name = name
        self.summary = summary
        self.arguments = arguments
        self.status = status
    }
}

public struct AgentCommandOutputPayload: Codable, Equatable, Sendable {
    public var text: String
    public var exitCode: Int?
    public var status: AgentItemStatus

    public init(text: String, exitCode: Int? = nil, status: AgentItemStatus) {
        self.text = text
        self.exitCode = exitCode
        self.status = status
    }
}

/// One explicit provider-owned plan step. The renderer may present this
/// hierarchy but must never manufacture steps from prose or local activity.
public struct AgentPlanStep: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String?
    public var status: AgentItemStatus
    public var children: [AgentPlanStep]

    public init(
        title: String,
        detail: String? = nil,
        status: AgentItemStatus,
        children: [AgentPlanStep] = []
    ) {
        self.title = title
        self.detail = detail
        self.status = status
        self.children = children
    }
}

public struct AgentPlanPayload: Codable, Equatable, Sendable {
    public var title: String?
    public var status: AgentItemStatus
    public var steps: [AgentPlanStep]

    public init(
        title: String? = nil,
        status: AgentItemStatus,
        steps: [AgentPlanStep] = []
    ) {
        self.title = title
        self.status = status
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey { case title, status, steps }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        status = try values.decode(AgentItemStatus.self, forKey: .status)
        steps = try values.decodeIfPresent([AgentPlanStep].self, forKey: .steps) ?? []
    }
}

/// What one file-change operation did to one file. Presentation vocabulary
/// only: it decides the words on a row ("Deleted", "Renamed"), never a
/// filesystem capability.
public enum AgentDiffFileAction: String, Codable, Equatable, Sendable {
    case add, edit, write, delete, rename, unknown
}

/// Safe, provider-supplied display metadata for one changed file. This is not a
/// filesystem path capability and the transcript renderer never resolves it.
///
/// TR-01: the two counts are INDEPENDENTLY optional. A claude `Write` knows how
/// many lines it wrote and cannot know how many it replaced without reading the
/// file it overwrote; collapsing that into one `lineCountsAreKnown` bit forced a
/// real, measured addition count to render as "counts unavailable". `nil` means
/// nobody measured it — zero is a legitimate measured value and must never be
/// inferred from an absent one.
public struct AgentDiffFileSummary: Codable, Equatable, Sendable {
    public var displayName: String
    public var addedLineCount: UInt?
    public var removedLineCount: UInt?
    /// The counts were derived from a BOUNDED provider preview (the detail
    /// store truncates a diff at 80 lines / 2 000 chars), so they are a floor,
    /// not a measurement. Rendered "≥ +42 −7"; promoting a floor to a count is
    /// the same false precision as reporting +0/−0 for an unmeasured file.
    public var countsAreLowerBound: Bool
    public var action: AgentDiffFileAction?

    /// Both counts measured. Kept as a computed property so no caller can set
    /// availability independently of the values it describes.
    public var lineCountsAreKnown: Bool { addedLineCount != nil && removedLineCount != nil }
    /// At least one count measured — the row has a number worth printing.
    public var hasAnyKnownCount: Bool { addedLineCount != nil || removedLineCount != nil }

    /// The counts as a sentence, for VoiceOver and for copied text. Lives here
    /// rather than on the view so the spoken form, the copied form and the
    /// drawn form cannot drift into claiming different precision.
    public var countsDescription: String {
        let bound = countsAreLowerBound ? "at least " : ""
        switch (addedLineCount, removedLineCount) {
        case let (added?, removed?):
            return "\(bound)\(added) additions, \(bound)\(removed) removals"
        case let (added?, nil):
            return "\(bound)\(added) additions, removals unknown"
        case let (nil, removed?):
            return "additions unknown, \(bound)\(removed) removals"
        case (nil, nil):
            switch action {
            case .delete: return "deleted, line counts unavailable"
            case .add: return "added, line counts unavailable"
            case .rename: return "renamed, line counts unavailable"
            default: return "line counts unavailable"
            }
        }
    }

    public init(
        displayName: String,
        addedLineCount: UInt? = nil,
        removedLineCount: UInt? = nil,
        countsAreLowerBound: Bool = false,
        action: AgentDiffFileAction? = nil
    ) {
        self.displayName = displayName
        self.addedLineCount = addedLineCount
        self.removedLineCount = removedLineCount
        self.countsAreLowerBound = countsAreLowerBound
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, addedLineCount, removedLineCount, lineCountsAreKnown
        case countsSchema, countsAreLowerBound, action
    }

    /// Bumped when a writer states each count's availability by PRESENCE. A v2
    /// payload cannot be read under the v1 rule: v1 encodes
    /// `lineCountsAreKnown: false` for a partially-known row (so an old build
    /// degrades to "counts unavailable" rather than reading a placeholder zero
    /// as a measurement), and that same `false` would otherwise make this
    /// decoder throw away the one count it does have.
    private static let currentCountsSchema = 2

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try values.decode(String.self, forKey: .displayName)
        let added = try values.decodeIfPresent(UInt.self, forKey: .addedLineCount)
        let removed = try values.decodeIfPresent(UInt.self, forKey: .removedLineCount)
        let schema = try values.decodeIfPresent(Int.self, forKey: .countsSchema) ?? 1
        if schema >= 2 {
            addedLineCount = added
            removedLineCount = removed
        } else {
            // Old payloads always encoded the numeric defaults and had no
            // availability bit. Preserve useful non-zero history, but treat
            // legacy +0/−0 as unknown rather than continuing to assert false
            // precision. A payload that explicitly said "not known" keeps
            // saying it: its numbers were placeholders, not measurements.
            let known = try values.decodeIfPresent(Bool.self, forKey: .lineCountsAreKnown)
                ?? ((added ?? 0) > 0 || (removed ?? 0) > 0)
            addedLineCount = known ? added : nil
            removedLineCount = known ? removed : nil
        }
        countsAreLowerBound = try values.decodeIfPresent(Bool.self, forKey: .countsAreLowerBound) ?? false
        action = try values.decodeIfPresent(AgentDiffFileAction.self, forKey: .action)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(addedLineCount, forKey: .addedLineCount)
        try container.encodeIfPresent(removedLineCount, forKey: .removedLineCount)
        try container.encode(Self.currentCountsSchema, forKey: .countsSchema)
        try container.encode(lineCountsAreKnown, forKey: .lineCountsAreKnown)
        if countsAreLowerBound { try container.encode(true, forKey: .countsAreLowerBound) }
        try container.encodeIfPresent(action, forKey: .action)
    }
}

public struct AgentDiffPayload: Codable, Equatable, Sendable {
    /// Compatibility/source text. A semantic renderer must not parse or display
    /// this as a file summary; use the explicitly safe fields below.
    public var text: String
    public var language: String?
    public var summary: String?
    public var files: [AgentDiffFileSummary]
    public var canOpenReview: Bool
    /// TR-01 — the operation is still running, so an empty `files` means "not
    /// yet", not "nothing". Presentation-only and excluded from CodingKeys for
    /// the same reason as `AgentToolCallPayload.presented*`: it is composed on
    /// the ephemeral rendered copy from the host-local detail store and is
    /// never document state (I5).
    public var presentedFilesArePending: Bool = false

    public init(
        text: String,
        language: String? = nil,
        summary: String? = nil,
        files: [AgentDiffFileSummary] = [],
        canOpenReview: Bool = false
    ) {
        self.text = text
        self.language = language
        self.summary = summary
        self.files = files
        self.canOpenReview = canOpenReview
    }

    private enum CodingKeys: String, CodingKey {
        case text, language, summary, files, canOpenReview
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
        language = try values.decodeIfPresent(String.self, forKey: .language)
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        files = try values.decodeIfPresent([AgentDiffFileSummary].self, forKey: .files) ?? []
        canOpenReview = try values.decodeIfPresent(Bool.self, forKey: .canOpenReview) ?? false
    }
}

public struct AgentRequestPayload: Codable, Equatable, Sendable {
    /// Opaque provider request identity. Without it a request remains readable
    /// history but cannot acquire response controls.
    public var requestID: String?
    public var prompt: [AgentInline]
    public var status: AgentItemStatus
    public var choices: [String]

    public init(
        requestID: String? = nil,
        prompt: [AgentInline],
        status: AgentItemStatus,
        choices: [String] = []
    ) {
        self.requestID = requestID
        self.prompt = prompt
        self.status = status
        self.choices = choices
    }

    private enum CodingKeys: String, CodingKey { case requestID, prompt, status, choices }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try values.decodeIfPresent(String.self, forKey: .requestID)
        prompt = try values.decode([AgentInline].self, forKey: .prompt)
        status = try values.decode(AgentItemStatus.self, forKey: .status)
        choices = try values.decodeIfPresent([String].self, forKey: .choices) ?? []
    }
}

public struct AgentErrorPayload: Codable, Equatable, Sendable {
    public var message: String
    public var code: String?
    public var isRecoverable: Bool

    public init(message: String, code: String? = nil, isRecoverable: Bool = false) {
        self.message = message
        self.code = code
        self.isRecoverable = isRecoverable
    }
}

public struct AgentNoticePayload: Codable, Equatable, Sendable {
    public var message: [AgentInline]
    public var status: AgentItemStatus?

    public init(message: [AgentInline], status: AgentItemStatus? = nil) {
        self.message = message
        self.status = status
    }
}

/// B6.2/B6.3 — a compaction boundary reached the transcript, from either
/// harness. Rendered collapsed and attributed to the harness, never to the
/// user or assistant. Fields are exactly what each provider's own frame
/// carries — never a fabricated field the real frame does not send. claude's
/// `compact_boundary` gives all three (`pre_tokens` only absent on a resumed
/// session); pi's persisted `compaction` session entry gives only
/// `tokensBefore` — no post-compaction size (the runtime estimates one in
/// memory but never persists it) and no manual/automatic distinction (its
/// `fromHook` flag means "an extension supplied the summary", not "triggered
/// automatically") — so `postTokens` and `automaticCompaction` are optional
/// here rather than guessed.
public struct AgentCompactionPayload: Codable, Equatable, Sendable {
    public var preTokens: Int?
    public var postTokens: Int?
    public var automaticCompaction: Bool?
    public var provider: String?
    public var operationID: UUID?
    public var boundaryID: String?
    public var phase: String?
    public var trigger: String?
    public var preTokensEstimated: Bool?
    public var postTokensEstimated: Bool?
    public var willRetryInterruptedTurn: Bool?
    public var observedAt: Date?
    public var errorMessage: String?

    public init(
        preTokens: Int?,
        postTokens: Int?,
        automaticCompaction: Bool?,
        provider: String? = nil,
        operationID: UUID? = nil,
        boundaryID: String? = nil,
        phase: String? = nil,
        trigger: String? = nil,
        preTokensEstimated: Bool? = nil,
        postTokensEstimated: Bool? = nil,
        willRetryInterruptedTurn: Bool? = nil,
        observedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.preTokens = preTokens
        self.postTokens = postTokens
        self.automaticCompaction = automaticCompaction
        self.provider = provider
        self.operationID = operationID
        self.boundaryID = boundaryID
        self.phase = phase
        self.trigger = trigger
        self.preTokensEstimated = preTokensEstimated
        self.postTokensEstimated = postTokensEstimated
        self.willRetryInterruptedTurn = willRetryInterruptedTurn
        self.observedAt = observedAt
        self.errorMessage = errorMessage
    }
}

extension AgentCompactionPayload {
    /// Wire format for `AgentRuntimeEvent.itemStarted`'s `title` — the only
    /// per-item channel a provider translator has into `AgentTranscriptProjection`
    /// (I5 forbids widening the event itself with dedicated fields). Never
    /// displayed raw; `AgentTranscriptProjection` decodes it back into this
    /// typed payload immediately.
    public static func encodeTitle(
        preTokens: Int?,
        postTokens: Int?,
        automaticCompaction: Bool?,
        provider: String? = nil,
        boundaryID: String? = nil,
        phase: String? = nil,
        trigger: String? = nil,
        postTokensEstimated: Bool? = nil
    ) -> String {
        "compaction:pre=\(preTokens.map(String.init) ?? "");post=\(postTokens.map(String.init) ?? "");auto=\(automaticCompaction.map(String.init) ?? "");provider=\(provider ?? "");boundary=\(boundaryID ?? "");phase=\(phase ?? "");trigger=\(trigger ?? "");postEstimated=\(postTokensEstimated.map(String.init) ?? "")"
    }

    public init?(decodingTitle title: String?) {
        guard let title, title.hasPrefix("compaction:") else { return nil }
        var pre: Int?
        var post: Int?
        var auto: Bool?
        var provider: String?
        var boundaryID: String?
        var phase: String?
        var trigger: String?
        var postEstimated: Bool?
        for pair in title.dropFirst("compaction:".count).split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "pre": pre = Int(parts[1])
            case "post": post = Int(parts[1])
            case "auto": auto = Bool(String(parts[1]))
            case "provider": provider = parts[1].isEmpty ? nil : String(parts[1])
            case "boundary": boundaryID = parts[1].isEmpty ? nil : String(parts[1])
            case "phase": phase = parts[1].isEmpty ? nil : String(parts[1])
            case "trigger": trigger = parts[1].isEmpty ? nil : String(parts[1])
            case "postEstimated": postEstimated = Bool(String(parts[1]))
            default: break
            }
        }
        self.init(
            preTokens: pre,
            postTokens: post,
            automaticCompaction: auto,
            provider: provider,
            boundaryID: boundaryID,
            phase: phase ?? "succeeded",
            trigger: trigger,
            postTokensEstimated: postEstimated)
    }
}

/// A durable, portable reference to an agent that participated in this
/// conversation. Runtime status and controls are deliberately resolved by the
/// host from `agentID`; keeping them out of the document prevents every status
/// tick from rewriting transcript history.
public struct AgentReferencePayload: Codable, Equatable, Sendable {
    public enum Relationship: String, Codable, Equatable, Sendable {
        case child
    }

    public var agentID: UUID
    public var parentAgentID: UUID
    public var relationship: Relationship
    public var displayNameAtSpawn: String
    public var spawnedAt: Date
    public var sourceItemID: String?
    public var provider: String

    public init(
        agentID: UUID,
        parentAgentID: UUID,
        relationship: Relationship = .child,
        displayNameAtSpawn: String,
        spawnedAt: Date,
        sourceItemID: String? = nil,
        provider: String
    ) {
        self.agentID = agentID
        self.parentAgentID = parentAgentID
        self.relationship = relationship
        self.displayNameAtSpawn = displayNameAtSpawn
        self.spawnedAt = spawnedAt
        self.sourceItemID = sourceItemID
        self.provider = provider
    }
}

/// A GFM table, kept as cells rather than as its pipe source.
///
/// `.plans/45` T8. The parser previously mapped every `Table` to `.fencedCode`
/// and stored the raw Markdown, which destroyed the column structure at parse
/// time — the renderer could only ever dump pipes as monospace. Alignment is
/// per column and comes from the delimiter row.
public struct AgentTablePayload: Codable, Equatable, Sendable {
    public enum Alignment: String, Codable, Equatable, Sendable {
        case leading, center, trailing
    }

    /// Header cells. Empty means the table had no header row.
    public var header: [[AgentInline]]
    public var rows: [[[AgentInline]]]
    /// One entry per column. Shorter than the widest row means "leading".
    public var alignments: [Alignment]
    /// The original Markdown, retained so copy still yields a real table and so
    /// nothing is lost when a row is wider than the renderer chooses to draw.
    public var source: String

    public init(
        header: [[AgentInline]] = [],
        rows: [[[AgentInline]]] = [],
        alignments: [Alignment] = [],
        source: String = ""
    ) {
        self.header = header
        self.rows = rows
        self.alignments = alignments
        self.source = source
    }

    /// Widest row, header included — the column count a renderer must lay out.
    public var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    public func alignment(forColumn index: Int) -> Alignment {
        index < alignments.count ? alignments[index] : .leading
    }
}

/// Typed built-in content. Container block structure lives in `children`, so
/// list items and quotes do not encode nested blocks into strings.
public enum AgentBlockPayload: Codable, Equatable, Sendable {
    case paragraph([AgentInline])
    case heading(level: UInt8, content: [AgentInline])
    case list(AgentListPayload)
    case listItem
    case quote
    case thematicBreak
    case table(AgentTablePayload)
    case fencedCode(AgentCodePayload)
    case toolCall(AgentToolCallPayload)
    case commandOutput(AgentCommandOutputPayload)
    case plan(AgentPlanPayload)
    case diff(AgentDiffPayload)
    case approval(AgentRequestPayload)
    case question(AgentRequestPayload)
    case image(AgentImagePayload)
    case imageGallery(AgentImageGalleryPayload)
    case fileReferences(AgentFileReferencePayload)
    case agentReference(AgentReferencePayload)
    case error(AgentErrorPayload)
    case notice(AgentNoticePayload)
    case compaction(AgentCompactionPayload)
    case opaque(AgentOpaquePayload)
}

public struct AgentBlock: Identifiable, Codable, Equatable, Sendable {
    public let id: AgentNodeID
    public var revision: UInt64
    public var kind: AgentBlockKind
    public var sourceRange: AgentSourceRange?
    public var payload: AgentBlockPayload
    public var children: [AgentBlock]

    public init(
        id: AgentNodeID,
        revision: UInt64 = 0,
        kind: AgentBlockKind,
        sourceRange: AgentSourceRange? = nil,
        payload: AgentBlockPayload,
        children: [AgentBlock] = []
    ) {
        self.id = id
        self.revision = revision
        self.kind = kind
        self.sourceRange = sourceRange
        self.payload = payload
        self.children = children
    }
}
