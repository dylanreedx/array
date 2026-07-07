import Foundation

public enum AgentUserInputStatus: String, Codable, Equatable, Sendable {
    case pending
    case resolved
}

public struct AgentUserInputRequest: Codable, Equatable, Sendable {
    public var requestId: String
    public var tileId: UUID
    public var question: String
    public var status: AgentUserInputStatus
    public var answer: String?
    public var createdAt: Date

    public init(
        requestId: String,
        tileId: UUID,
        question: String,
        status: AgentUserInputStatus = .pending,
        answer: String? = nil,
        createdAt: Date = Date()
    ) {
        self.requestId = requestId
        self.tileId = tileId
        self.question = Self.sanitizedQuestion(question)
        self.status = status
        self.answer = answer
        self.createdAt = createdAt
    }

    public static func sanitizedQuestion(_ question: String) -> String {
        let collapsed = question
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(160))
    }
}
