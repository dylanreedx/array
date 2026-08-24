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

/// Safe, provider-supplied display metadata for one changed file. This is not a
/// filesystem path capability and the transcript renderer never resolves it.
public struct AgentDiffFileSummary: Codable, Equatable, Sendable {
    public var displayName: String
    public var addedLineCount: UInt
    public var removedLineCount: UInt

    public init(displayName: String, addedLineCount: UInt = 0, removedLineCount: UInt = 0) {
        self.displayName = displayName
        self.addedLineCount = addedLineCount
        self.removedLineCount = removedLineCount
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
