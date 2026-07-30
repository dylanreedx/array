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
    public static let fencedCode = Self(rawValue: "fenced-code")!
    public static let toolCall = Self(rawValue: "tool-call")!
    public static let commandOutput = Self(rawValue: "command-output")!
    public static let plan = Self(rawValue: "plan")!
    public static let diff = Self(rawValue: "diff")!
    public static let approval = Self(rawValue: "approval")!
    public static let question = Self(rawValue: "question")!
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

public struct AgentPlanPayload: Codable, Equatable, Sendable {
    public var title: String?
    public var status: AgentItemStatus

    public init(title: String? = nil, status: AgentItemStatus) {
        self.title = title
        self.status = status
    }
}

public struct AgentDiffPayload: Codable, Equatable, Sendable {
    public var text: String
    public var language: String?

    public init(text: String, language: String? = nil) {
        self.text = text
        self.language = language
    }
}

public struct AgentRequestPayload: Codable, Equatable, Sendable {
    public var prompt: [AgentInline]
    public var status: AgentItemStatus
    public var choices: [String]

    public init(prompt: [AgentInline], status: AgentItemStatus, choices: [String] = []) {
        self.prompt = prompt
        self.status = status
        self.choices = choices
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

/// Typed built-in content. Container block structure lives in `children`, so
/// list items and quotes do not encode nested blocks into strings.
public enum AgentBlockPayload: Codable, Equatable, Sendable {
    case paragraph([AgentInline])
    case heading(level: UInt8, content: [AgentInline])
    case list(AgentListPayload)
    case listItem
    case quote
    case thematicBreak
    case fencedCode(AgentCodePayload)
    case toolCall(AgentToolCallPayload)
    case commandOutput(AgentCommandOutputPayload)
    case plan(AgentPlanPayload)
    case diff(AgentDiffPayload)
    case approval(AgentRequestPayload)
    case question(AgentRequestPayload)
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
