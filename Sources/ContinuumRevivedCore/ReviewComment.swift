import Foundation

public struct ReviewCommentState: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var reviewId: UUID
    public var comments: [ReviewComment]

    public init(
        schemaVersion: Int = ReviewCommentState.currentSchemaVersion,
        reviewId: UUID,
        comments: [ReviewComment]
    ) {
        self.schemaVersion = schemaVersion
        self.reviewId = reviewId
        self.comments = comments
    }

    public func addingComment(id: UUID = UUID(), anchor: ReviewCommentAnchor, body: String, createdAt: Date = Date()) -> ReviewCommentState {
        var copy = self
        copy.comments.append(ReviewComment(id: id, anchor: anchor, body: body, createdAt: createdAt, resolved: false, status: .current))
        return copy
    }

    public func editingComment(id: UUID, body: String) -> ReviewCommentState {
        var copy = self
        guard let index = copy.comments.firstIndex(where: { $0.id == id }) else { return copy }
        copy.comments[index].body = body
        return copy
    }

    public func settingResolved(id: UUID, resolved: Bool) -> ReviewCommentState {
        var copy = self
        guard let index = copy.comments.firstIndex(where: { $0.id == id }) else { return copy }
        copy.comments[index].resolved = resolved
        return copy
    }

    public func revalidated(against diff: GitDiffModel) -> ReviewCommentState {
        var copy = self
        copy.comments = comments.map { $0.revalidated(against: diff) }
        return copy
    }
}

public struct ReviewComment: Equatable, Codable, Sendable {
    public enum Status: String, Codable, Sendable { case current, outdated }

    public var id: UUID
    public var anchor: ReviewCommentAnchor
    public var body: String
    public var createdAt: Date
    public var resolved: Bool
    public var status: Status

    public init(
        id: UUID = UUID(),
        anchor: ReviewCommentAnchor,
        body: String,
        createdAt: Date,
        resolved: Bool = false,
        status: Status = .current
    ) {
        self.id = id
        self.anchor = anchor
        self.body = body
        self.createdAt = createdAt
        self.resolved = resolved
        self.status = status
    }

    public func revalidated(against diff: GitDiffModel) -> ReviewComment {
        var copy = self
        copy.status = anchor.isPresent(in: diff) ? .current : .outdated
        return copy
    }
}

public struct ReviewCommentAnchor: Equatable, Hashable, Codable, Sendable {
    public var filePath: String
    public var oldLine: Int?
    public var newLine: Int?
    public var hunkHeader: String

    public init(filePath: String, oldLine: Int?, newLine: Int?, hunkHeader: String) {
        self.filePath = filePath
        self.oldLine = oldLine
        self.newLine = newLine
        self.hunkHeader = hunkHeader
    }

    public static func make(file: GitDiffFile, hunk: GitDiffHunk, line: GitDiffLine) -> ReviewCommentAnchor? {
        guard line.oldLine != nil || line.newLine != nil else { return nil }
        guard let path = file.newPath ?? file.oldPath else { return nil }
        return ReviewCommentAnchor(filePath: path, oldLine: line.oldLine, newLine: line.newLine, hunkHeader: hunk.header)
    }

    public func isPresent(in diff: GitDiffModel) -> Bool {
        diff.files.contains { file in
            (file.newPath == filePath || file.oldPath == filePath) && file.hunks.contains { hunk in
                hunk.lines.contains { line in
                    line.oldLine == oldLine && line.newLine == newLine
                }
            }
        }
    }
}
