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

public struct ReviewCommentAnchor: Equatable, Codable, Sendable {
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
