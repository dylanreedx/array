import Foundation

/// Immutable attribution. The host supplies author identity rather than accepting
/// a display name from untrusted comment text.
public struct BoardComment: Codable, Equatable, Sendable, Identifiable {
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id, authorID, authorName, createdAt, authorColour, authorCharacter, body
    }
    public let id: UUID
    public let authorID: String
    public let authorName: String
    public let createdAt: Date
    public var authorColour: String?
    public var authorCharacter: String?
    public var body: String

    public init(id: UUID = UUID(), authorID: String, authorName: String, createdAt: Date, body: String) {
        self.id = id; self.authorID = authorID; self.authorName = authorName
        self.createdAt = createdAt; self.body = body
    }
}
