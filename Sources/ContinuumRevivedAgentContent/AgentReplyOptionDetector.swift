import Foundation

/// Reads a settled assistant turn and, when it ended by asking the reader to
/// pick from a short list, returns those choices so the composer can offer them
/// as one click instead of a typed "2".
///
/// **What this is not.** It does not produce an `AgentRequestPayload`, mint a
/// `.question` block, or resolve anything. A provider request is a request
/// because a provider OPENED one and is holding it (`.requestOpened` /
/// `.userInputRequested`); prose that happens to contain a list is not that, and
/// dressing it up as one would fabricate a response contract the harness never
/// offered. What comes out of here is a composer shortcut: text the user still
/// sends themselves, exactly as if they had typed it.
///
/// **Why it reads structure and not characters.** The parser already turned the
/// reply's Markdown into a list block with item children. Detecting "1." with a
/// regex over rendered text would also fire on a numbered list of findings, a
/// changelog, or a code sample — and would miss `-`/`a)` phrasing entirely. The
/// rules below are deliberately narrow, because a wrong offer is worse than no
/// offer: a chip that answers a question nobody asked puts words in the user's
/// mouth.
public enum AgentReplyOptionDetector {
    /// At most this many chips. A longer list is a document, not a choice.
    public static let maximumOptions = 4
    /// A choice is a phrase. Anything longer is prose that happens to be in a
    /// list, and would be unreadable on a chip anyway.
    public static let maximumOptionLength = 72

    /// The options the last settled assistant turn is offering, or `[]`.
    public static func options(in document: AgentDocument) -> [String] {
        guard let entry = document.entries.last,
              entry.role == .assistant,
              // An OPEN entry is still being written: the item count and the
              // text both change under the reader, and a chip strip that
              // flickered through a stream would be worse than none. Offers
              // appear when the turn is finished.
              entry.lifecycle == .finished
        else { return [] }
        return options(inBlocks: entry.blocks)
    }

    /// Split out so a witness can drive block sequences directly.
    public static func options(inBlocks blocks: [AgentBlock]) -> [String] {
        // Trailing thematic breaks and empty paragraphs are decoration; the
        // choice list still has to be the last thing that carries content.
        let meaningful = blocks.filter { block in
            switch block.payload {
            case .thematicBreak: return false
            case .paragraph(let inlines): return !plainText(inlines).isEmpty
            default: return true
            }
        }
        guard meaningful.count >= 2,
              case .list = meaningful[meaningful.count - 1].payload,
              case let .paragraph(question) = meaningful[meaningful.count - 2].payload
        else { return [] }

        // The list must be an ANSWER to something. Without this, every reply
        // that ends in a summary list would sprout chips.
        guard asksAQuestion(plainText(question)) else { return [] }

        let items = meaningful[meaningful.count - 1].children.filter { $0.kind == .listItem }
        guard items.count >= 2, items.count <= maximumOptions else { return [] }

        var options: [String] = []
        for item in items {
            guard let label = label(forItem: item) else { return [] }
            guard !options.contains(label) else { return [] }
            options.append(label)
        }
        return options
    }

    /// The chip's text: the item's own leading phrase. An item written as
    /// "**Rewrite it** — keeps the API but drops the cache" chips to
    /// "Rewrite it", because the trailing clause is the explanation, not the
    /// answer. An item with no such split is used whole when it is short enough.
    private static func label(forItem item: AgentBlock) -> String? {
        let text = plainText(inItem: item)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // A choice is one line. A multi-paragraph item is a section.
        guard !text.contains("\n") else { return nil }
        let head = splitLeadingPhrase(text)
        let trimmed = head.trimmingCharacters(in: CharacterSet(charactersIn: " \t.,;:"))
        guard !trimmed.isEmpty, trimmed.count <= maximumOptionLength else { return nil }
        return trimmed
    }

    /// Cuts at the first em/en dash or colon separator, which is how a reply
    /// writes "option — why". A hyphen alone is NOT a separator: it appears
    /// inside ordinary words and file names.
    private static func splitLeadingPhrase(_ text: String) -> String {
        for separator in [" — ", " – ", ": ", " - "] {
            if let range = text.range(of: separator) {
                return String(text[text.startIndex..<range.lowerBound])
            }
        }
        return text
    }

    /// The paragraph above the list has to read as a question put to the reader.
    /// A question mark is the strong signal; the phrasings below are the ones
    /// that ask without one, and each must still be sentence-final so a passing
    /// mention ("I could go either way, so here is what changed") does not
    /// qualify.
    private static func asksAQuestion(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized.hasSuffix("?") { return true }
        let invitations = [
            "let me know which", "tell me which", "pick one", "your call",
            "which would you prefer", "say the word"
        ]
        return invitations.contains { normalized.hasSuffix($0) || normalized.hasSuffix($0 + ":") }
    }

    private static func plainText(inItem item: AgentBlock) -> String {
        var parts: [String] = []
        func walk(_ block: AgentBlock) {
            switch block.payload {
            case .paragraph(let inlines): parts.append(plainText(inlines))
            case .heading(_, let inlines): parts.append(plainText(inlines))
            default: break
            }
            block.children.forEach(walk)
        }
        walk(item)
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func plainText(_ inlines: [AgentInline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let value), .code(let value): return value
            case .emphasis(let children), .strong(let children): return plainText(children)
            case .link(_, _, let children): return plainText(children)
            case .softBreak: return " "
            case .hardBreak: return "\n"
            }
        }.joined()
    }
}
