import Foundation

public struct ReviewFlybackPrompt: Equatable, Sendable {
    public var text: String
    public var includedCommentIds: [UUID]
    public var excludedCommentIds: [UUID]

    public init(text: String, includedCommentIds: [UUID], excludedCommentIds: [UUID]) {
        self.text = text
        self.includedCommentIds = includedCommentIds
        self.excludedCommentIds = excludedCommentIds
    }
}

public enum ReviewFlybackPromptComposer {
    public static func compose(state: ReviewCommentState, diffSourceDescription: String, diff: GitDiffModel? = nil) -> ReviewFlybackPrompt {
        let comments = state.comments.map { comment in
            diff.map { comment.revalidated(against: $0) } ?? comment
        }
        let included = comments
            .filter { !$0.resolved && $0.status == .current }
            .sorted { lhs, rhs in
                if lhs.anchor.filePath != rhs.anchor.filePath { return lhs.anchor.filePath < rhs.anchor.filePath }
                let lhsLine = lhs.anchor.newLine ?? lhs.anchor.oldLine ?? 0
                let rhsLine = rhs.anchor.newLine ?? rhs.anchor.oldLine ?? 0
                if lhsLine != rhsLine { return lhsLine < rhsLine }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        let excluded = comments.filter { $0.resolved || $0.status == .outdated }.map(\.id)

        var lines: [String] = [
            "Please address these unresolved review comments.",
            "Review: \(state.reviewId.uuidString)",
            "Diff source: \(diffSourceDescription)",
            ""
        ]
        if included.isEmpty {
            lines.append("No current unresolved comments to address.")
        } else {
            for (index, comment) in included.enumerated() {
                let anchor = comment.anchor
                let coordinate: String
                switch (anchor.oldLine, anchor.newLine) {
                case let (old?, new?): coordinate = "old:\(old) new:\(new)"
                case let (old?, nil): coordinate = "old:\(old)"
                case let (nil, new?): coordinate = "new:\(new)"
                case (nil, nil): coordinate = "line:unknown"
                }
                lines.append("\(index + 1). \(anchor.filePath) (\(coordinate))")
                lines.append("   Hunk: \(anchor.hunkHeader)")
                lines.append("   Comment: \(comment.body.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        return ReviewFlybackPrompt(text: lines.joined(separator: "\n"), includedCommentIds: included.map(\.id), excludedCommentIds: excluded)
    }
}

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
