import Foundation
import Markdown

/// The sole production adapter from swift-markdown's AST into AgentContent.
/// This first seam deliberately converts only a plain paragraph; subsequent
/// parser tickets add inline and block families without exposing `Markdown`.
public struct MarkdownAgentMarkupParser: AgentMarkupParsing {
    public init() {}

    public func parse(
        _ source: String,
        entryID: AgentNodeID,
        previous: [AgentBlock]
    ) -> AgentMarkupParse {
        guard !source.isEmpty else { return AgentMarkupParse(blocks: []) }

        let document = Document(parsing: source)
        guard document.childCount == 1,
              let paragraph = document.child(at: 0) as? Paragraph,
              paragraph.inlineChildren.allSatisfy({ $0 is Text })
        else {
            let blockID = previous.first(where: { block in
                guard block.kind == .unknown else { return false }
                if case .opaque = block.payload { return true }
                return false
            })?.id ?? blockID(entryID: entryID, stableKey: "markdown.unsupported")

            return AgentMarkupParse(
                blocks: [
                    AgentBlock(
                        id: blockID,
                        kind: .unknown,
                        payload: .opaque(.init(
                            debugLabel: "markdown.unsupported-structure",
                            value: .string(source)
                        ))
                    )
                ],
                diagnostics: [.init(severity: .warning, code: "markdown.unsupported-structure")]
            )
        }

        let blockID = previous.first(where: { block in
            guard block.kind == .paragraph else { return false }
            if case .paragraph = block.payload { return true }
            return false
        })?.id ?? blockID(entryID: entryID, stableKey: "markdown.paragraph")

        return AgentMarkupParse(blocks: [
            AgentBlock(
                id: blockID,
                kind: .paragraph,
                payload: .paragraph([.text(paragraph.plainText)])
            )
        ])
    }

    /// `AgentNodeID` permits provider IDs longer than its child-scope bound.
    /// Keep the ordinary readable child ID, but compact an unusually long scope
    /// to a deterministic parser-owned ID rather than dropping valid source.
    private func blockID(entryID: AgentNodeID, stableKey: String) -> AgentNodeID {
        if let child = entryID.childID(stableKey: stableKey) { return child }

        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x84222325cbf29ce4
        for byte in entryID.rawValue.utf8 {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second ^ UInt64(byte)) &* 0x9e3779b185ebca87
        }
        let digest = String(format: "%016llx%016llx", first, second)
        // Both inputs are fixed/bounded here, so construction cannot fail.
        return AgentNodeID(rawValue: "markdown-entry:\(digest)/\(stableKey)")!
    }
}
