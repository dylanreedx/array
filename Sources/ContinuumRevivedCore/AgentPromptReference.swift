import Foundation

/// A user-authored mention of another managed agent. Identity is durable;
/// the name is a display snapshot, never a lookup key or an access grant.
public struct AgentPromptReference: Codable, Equatable, Sendable {
    public var agentID: AgentID
    public var displayName: String

    public init(agentID: AgentID, displayName: String) {
        self.agentID = agentID
        self.displayName = String(displayName.prefix(200))
    }

    public static func unique(_ references: [Self]) -> [Self] {
        var seen = Set<AgentID>()
        return references.filter { seen.insert($0.agentID).inserted }
    }
}

/// All harnesses receive the same bounded reference envelope. No transcript is
/// copied and no grant is minted. Parsing also makes rehydrated prompts retain
/// the same human-readable mention as locally echoed prompts.
public enum AgentReferencePromptEnvelope {
    private static let start = "<array-agent-references>"
    private static let end = "</array-agent-references>"
    private static let note = "The user referenced these Array agents by stable agentID. Use array_inspect_agent if more context is needed and workspace tools permit it. A reference grants no additional access and does not ask you to message or interrupt the agent."

    public static func text(_ text: String, references: [AgentPromptReference]) -> String {
        let references = AgentPromptReference.unique(references)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard !references.isEmpty, let data = try? encoder.encode(references),
              let json = String(data: data, encoding: .utf8) else { return text }
        let escaped = json.replacingOccurrences(of: "<", with: "\\u003c")
        return [text, "\(start)\n\(escaped)\n\(end)\n\(note)"].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public static func parse(_ text: String) -> (text: String, references: [AgentPromptReference])? {
        guard let opening = text.range(of: start, options: .backwards),
              let closing = text.range(of: end, range: opening.upperBound..<text.endIndex),
              text[closing.upperBound...].hasPrefix("\n" + note),
              let data = text[opening.upperBound..<closing.lowerBound].data(using: .utf8),
              data.count <= 64_000,
              let references = try? JSONDecoder().decode([AgentPromptReference].self, from: data),
              !references.isEmpty else { return nil }
        let suffix = text[closing.upperBound...].dropFirst(("\n" + note).count)
        let prose = [String(text[..<opening.lowerBound]), String(suffix)]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        return (prose,
                AgentPromptReference.unique(references))
    }
}
