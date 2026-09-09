import Foundation

/// One offered choice: the short answer, and the reasoning the reply gave for it.
///
/// The detector used to return bare labels, throwing the trailing clause away.
/// That is the right shape for a typing shortcut and the wrong one for planning:
/// when the question is "which approach", the tradeoff after the dash IS the
/// content, and a surface that shows only "Incremental migration" has dropped
/// the half you decide on.
public struct AgentReplyOption: Equatable, Sendable {
    /// What a control says, and what gets written into the composer.
    public let label: String
    /// The rest of the item — the tradeoff, cost, or caveat. Nil when the reply
    /// offered a bare label with no reasoning.
    public let detail: String?

    public init(label: String, detail: String? = nil) {
        self.label = label
        self.detail = detail
    }
}

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
/// mouth. What "narrow" means has been RE-MEASURED (see `options(inBlocks:)`):
/// narrow about whether a list is a choice at all, not about where the question
/// sits relative to it.
public enum AgentReplyOptionDetector {
    /// At most this many options. A longer list is a document, not a choice.
    ///
    /// Was 4. Planning replies routinely lay out five or six approaches, and the
    /// cap silently rejected the whole set rather than trimming it — so the one
    /// reply that most needed the affordance was the one that never got it.
    public static let maximumOptions = 6
    /// A choice LABEL is a phrase. Anything longer is prose that happens to be in
    /// a list. The detail after it is not bound by this.
    public static let maximumOptionLength = 72

    /// The options the last settled assistant turn is offering, or `[]`.
    public static func options(in document: AgentDocument) -> [AgentReplyOption] {
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
    ///
    /// **Where the list may sit.** Originally the list had to be the LAST block
    /// and the question the one immediately above it. Measured against realistic
    /// planning replies, that shape is the minority: five of seven common ones
    /// were rejected, including the two most ordinary — asking and then adding a
    /// closing note, and laying the options out before asking. The rule now is
    /// adjacency in either direction, which keeps the binding between question
    /// and list tight while allowing what agents actually write.
    ///
    /// The two directions are NOT symmetric, deliberately. A question above a
    /// list introduces it. A question below one may be about something else
    /// entirely — "Done, here is what changed: … Want me to run the matrix?" —
    /// so it has to refer back to a set before its list counts as choices.
    public static func options(inBlocks blocks: [AgentBlock]) -> [AgentReplyOption] {
        // Thematic breaks and empty paragraphs are decoration, never content.
        let meaningful = blocks.filter { block in
            switch block.payload {
            case .thematicBreak: return false
            case .paragraph(let inlines): return !plainText(inlines).isEmpty
            default: return true
            }
        }
        guard let listIndex = meaningful.firstIndex(where: { block in
            if case .list = block.payload { return true }
            return false
        }) else { return [] }
        // Exactly one list. Two lists in one reply is a document — a summary and
        // a plan, say — and picking either as "the choices" would be a guess.
        guard meaningful.filter({ if case .list = $0.payload { return true }; return false })
            .count == 1 else { return [] }

        let before = listIndex > 0 ? paragraphText(meaningful[listIndex - 1]) : nil
        let after = listIndex + 1 < meaningful.count
            ? paragraphText(meaningful[listIndex + 1]) : nil
        let asked = (before.map(introducesAChoice) ?? false)
            || (after.map(refersBackToAChoice) ?? false)
        guard asked else { return [] }

        let items = meaningful[listIndex].children.filter { $0.kind == .listItem }
        guard items.count >= 2, items.count <= maximumOptions else { return [] }

        var options: [AgentReplyOption] = []
        for item in items {
            guard let option = option(forItem: item) else { return [] }
            guard !options.contains(where: { $0.label == option.label }) else { return [] }
            options.append(option)
        }
        return options
    }

    /// The chip's text: the item's own leading phrase. An item written as
    /// "**Rewrite it** — keeps the API but drops the cache" chips to
    /// "Rewrite it", because the trailing clause is the explanation, not the
    /// answer. An item with no such split is used whole when it is short enough.
    private static func option(forItem item: AgentBlock) -> AgentReplyOption? {
        let text = plainText(inItem: item)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // A choice is one line. A multi-paragraph item is a section.
        guard !text.contains("\n") else { return nil }
        let (head, tail) = splitLeadingPhrase(text)
        let label = head.trimmingCharacters(in: CharacterSet(charactersIn: " \t.,;:"))
        guard !label.isEmpty, label.count <= maximumOptionLength else { return nil }
        let detail = tail?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentReplyOption(
            label: label,
            detail: (detail?.isEmpty ?? true) ? nil : detail
        )
    }

    /// Cuts at the first em/en dash or colon separator, which is how a reply
    /// writes "option — why". A hyphen alone is NOT a separator: it appears
    /// inside ordinary words and file names.
    ///
    /// Returns both sides now. The tail is the reasoning, and dropping it is
    /// what made this a typing shortcut rather than a decision aid.
    private static func splitLeadingPhrase(_ text: String) -> (String, String?) {
        for separator in [" — ", " – ", ": ", " - "] {
            if let range = text.range(of: separator) {
                return (
                    String(text[text.startIndex..<range.lowerBound]),
                    String(text[range.upperBound...])
                )
            }
        }
        return (text, nil)
    }

    private static func paragraphText(_ block: AgentBlock) -> String? {
        guard case let .paragraph(inlines) = block.payload else { return nil }
        return plainText(inlines)
    }

    /// An explicit hand-off to the reader, with no question mark. Each must be
    /// sentence-final, so a passing mention does not qualify.
    private static let invitations = [
        "let me know which", "tell me which", "pick one", "your call",
        "which would you prefer", "say the word"
    ]

    /// Words that tie a question to a SET of things rather than to a new action.
    /// "Which", "either" and "option" point at a list; "want me to" points at
    /// something the agent would go do next.
    private static let choiceCues = [
        "which", "either", "option", "prefer", "pick", "choose", "your call",
        "one of these", "any of these"
    ]

    /// The paragraph ABOVE the list — it introduces what follows.
    ///
    /// The question mark may sit anywhere in the paragraph rather than at its
    /// end, because "Which do you want? I'd lean toward the first." is one of the
    /// most common ways an agent asks, and requiring a final `?` rejected it. A
    /// choice cue is required alongside, so a paragraph that merely happens to
    /// contain a question does not turn the next list into chips.
    private static func introducesAChoice(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if endsWithInvitation(normalized) { return true }
        return normalized.contains("?") && choiceCues.contains { normalized.contains($0) }
    }

    /// The paragraph BELOW the list — it has to refer BACK to it.
    ///
    /// Strictly narrower than the above-case, and the asymmetry is the whole
    /// point: "Done. Here is what changed: … Want me to run the matrix?" is a
    /// summary list followed by an unrelated question, and treating its items as
    /// choices would offer to answer a question nobody asked with text nobody
    /// wrote. Requiring a cue that points back at a set ("which", "your call")
    /// rejects it while accepting "I'd lean incremental. Your call?".
    private static func refersBackToAChoice(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if endsWithInvitation(normalized) { return true }
        guard normalized.contains("?") else { return false }
        let backReferences = ["which", "either", "option", "prefer", "your call", "one of these"]
        return backReferences.contains { normalized.contains($0) }
    }

    private static func endsWithInvitation(_ normalized: String) -> Bool {
        invitations.contains { normalized.hasSuffix($0) || normalized.hasSuffix($0 + ":") }
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
