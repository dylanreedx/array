import Foundation

/// A board mention carries durable document identity, never tile identity or access.
public struct BoardPromptReference: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var boardID: UUID
    public var displayName: String

    public init(projectID: UUID, boardID: UUID, displayName: String) {
        self.projectID = projectID
        self.boardID = boardID
        self.displayName = String(displayName.prefix(200))
    }

    public static func unique(_ references: [Self]) -> [Self] {
        var seen = Set<String>()
        return references.filter { seen.insert($0.projectID.uuidString + $0.boardID.uuidString).inserted }
    }
}

/// The agent reads current contents through the existing granted workspace API.
public enum BoardReferencePromptEnvelope {
    private static let start = "<array-board-references>"
    private static let end = "</array-board-references>"
    private static let note = "The user referenced these Array boards by stable boardID. Use array_board_query with boardId to read current contents when workspace tools permit it. A reference grants no additional access and does not assign tasks."

    public static func text(_ text: String, references: [BoardPromptReference]) -> String {
        let references = BoardPromptReference.unique(references)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard !references.isEmpty, let data = try? encoder.encode(references),
              let json = String(data: data, encoding: .utf8) else { return text }
        let escaped = json.replacingOccurrences(of: "<", with: "\\u003c")
        return [text, "\(start)\n\(escaped)\n\(end)\n\(note)"].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public static func parse(_ text: String) -> (text: String, references: [BoardPromptReference])? {
        guard let opening = text.range(of: start, options: .backwards),
              let closing = text.range(of: end, range: opening.upperBound..<text.endIndex),
              text[closing.upperBound...].hasPrefix("\n" + note),
              let data = text[opening.upperBound..<closing.lowerBound].data(using: .utf8), data.count <= 64_000,
              let references = try? JSONDecoder().decode([BoardPromptReference].self, from: data), !references.isEmpty else { return nil }
        let suffix = text[closing.upperBound...].dropFirst(("\n" + note).count)
        let prose = [String(text[..<opening.lowerBound]), String(suffix)]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return (prose, BoardPromptReference.unique(references))
    }
}
