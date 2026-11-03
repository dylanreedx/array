import Foundation

/// Immutable attribution. The host supplies author identity rather than accepting
/// a display name from untrusted comment text.
public struct BoardComment: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let authorID: String
    public let authorName: String
    public let createdAt: Date
    public var body: String

    public init(id: UUID = UUID(), authorID: String, authorName: String, createdAt: Date, body: String) {
        self.id = id; self.authorID = authorID; self.authorName = authorName
        self.createdAt = createdAt; self.body = body
    }
}
