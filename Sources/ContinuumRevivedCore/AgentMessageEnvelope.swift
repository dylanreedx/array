import ContinuumRevivedAgentContent
import Foundation

/// A turn one agent wrote for another, recognised on its way into the
/// transcript.
///
/// Array delivers an agent's words — `agent.message`, and a delegated child's
/// first task — through the same send path as a user's prompt, so without this
/// the receiving tile drew them as if the user had typed them. Array now wraps
/// them before delivery:
///
///     <array-agent-message from="<sender agent id>" name="<sender name>">
///     …the sender's text, verbatim…
///     </array-agent-message>
///
/// The receiving MODEL sees who wrote it, the way the Claude app tells its
/// sessions apart with `<cross-session-message>`, and every provider's session
/// file then carries the sender too, so a restore recovers it with no side
/// store (`.plans/79-session-handoff/BUILD.md`, decision 3).
///
/// `classify` is the one parser. `AgentTranscriptProjection.appendUserPrompt`
/// calls it, which is the seam the live send and every provider's rehydration
/// share, so a relaunched transcript draws the same card the live one did. It
/// also reads what the Claude app writes between its own sessions.
public enum AgentMessageEnvelope {
    public static let tag = "array-agent-message"
    static let crossSessionTag = "cross-session-message"
    static let sideSessionsTag = "side-sessions-event"
    /// The Claude app's note seeding a session it started from another one.
    static let backgroundHeading = "Background (from the session that started this one):"
    /// What a background note's card names as its sender.
    public static let backgroundSenderName = "The session that started this one"
    /// A `<cross-session-message>` that names nobody.
    static let unnamedSessionName = "Another Claude session"

    /// What user text turned out to be.
    public enum Inbound: Equatable, Sendable {
        /// Something the user wrote, or anything this parser does not
        /// recognise exactly. The text is drawn as it is.
        case prompt
        /// Another agent's words.
        case agentMessage(AgentMessagePayload)
        /// A host's note to the model about its other sessions (the Claude
        /// app's `<side-sessions-event>`): neither the user nor an agent wrote
        /// it, so it is a quiet notice carrying its first sentence.
        case hostNote(String)
    }

    /// The text the receiving agent's model is given. The name is reduced to
    /// one bounded line and both attributes are escaped; the body is verbatim,
    /// because the model must read exactly what the sender wrote.
    public static func wrap(_ text: String, senderID: UUID, senderName: String) -> String {
        let name = singleLineName(senderName) ?? "Agent"
        return "<\(tag) from=\"\(escape(senderID.uuidString.lowercased()))\" name=\"\(escape(name))\">\n"
            + text + "\n</\(tag)>"
    }

    /// The words a person would recognise: the body of a wrapped message, or
    /// the text itself. For naming a tile from its first prompt.
    public static func unwrappedText(_ text: String) -> String {
        if case let .agentMessage(message) = classify(text) { return message.text }
        return text
    }

    /// Text a person typed, made safe to send. Only Array's own wrap may
    /// read back as another agent's words (`.plans/79`): a typed prompt that
    /// is word for word an envelope — Array's, or one of the Claude app's —
    /// gets a zero-width space just inside its opening tag (before the
    /// background note's heading), so it draws and restores as the user's
    /// prompt, and the model is not handed a tag that names a sender who
    /// never wrote it. The text looks the same; anything else is untouched.
    public static func neutralizedUserText(_ text: String) -> String {
        guard classify(text) != .prompt,
              let first = text.firstIndex(where: { !$0.isWhitespace && !$0.isNewline }) else { return text }
        var out = text
        out.insert("\u{200B}", at: text[first] == "<" ? text.index(after: first) : first)
        return out
    }

    public static func classify(_ text: String) -> Inbound {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let element = element(trimmed, tag: tag) {
            // Exactly what `wrap` writes, or it is not Array's: a malformed
            // envelope falls back to the prompt with nothing lost.
            guard let from = element.attributes["from"], let senderID = UUID(uuidString: from),
                  let name = element.attributes["name"].flatMap(singleLineName) else { return .prompt }
            var body = Substring(element.body)
            if body.hasPrefix("\n") { body.removeFirst() }
            if body.hasSuffix("\n") { body.removeLast() }
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .prompt }
            return .agentMessage(AgentMessagePayload(
                origin: .array, senderAgentID: senderID, senderName: name, text: String(body)))
        }
        if let element = element(trimmed, tag: crossSessionTag) {
            let body = element.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return .prompt }
            // The Claude app names the sender `name`; Claude Code's peer
            // channel writes `from-name` and `from-mode`.
            let isPeer = element.attributes["from-name"] != nil || element.attributes["from-mode"] != nil
            let name = (element.attributes["name"] ?? element.attributes["from-name"]).flatMap(singleLineName)
            return .agentMessage(AgentMessagePayload(
                origin: isPeer ? .peer : .crossSession,
                senderName: name ?? unnamedSessionName, text: body))
        }
        if let element = element(trimmed, tag: sideSessionsTag), element.attributes.isEmpty,
           let note = firstSentence(element.body) {
            return .hostNote(note)
        }
        if trimmed.hasPrefix(backgroundHeading) {
            let body = trimmed.dropFirst(backgroundHeading.count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return .prompt }
            return .agentMessage(AgentMessagePayload(
                origin: .background, senderName: backgroundSenderName, text: body))
        }
        return .prompt
    }

    /// The one `<cross-session-message …>…</cross-session-message>` inside a
    /// longer line. Claude Code logs a peer message with a sentence before it
    /// and a reminder after it, both addressed to the model.
    public static func crossSessionElement(in text: String) -> String? {
        guard let open = text.range(of: "<\(crossSessionTag)"),
              let close = text.range(of: "</\(crossSessionTag)>", options: .backwards),
              open.lowerBound < close.lowerBound else { return nil }
        let candidate = String(text[open.lowerBound..<close.upperBound])
        return element(candidate, tag: crossSessionTag) == nil ? nil : candidate
    }

    // MARK: - Element and attribute syntax

    private struct Element {
        var attributes: [String: String]
        var body: String
    }

    /// `text` is exactly one `<tag a="…" …>body</tag>` element: the open tag
    /// first, the matching close tag last. The body may contain anything,
    /// including the close tag itself, because the LAST one closes.
    private static func element(_ text: String, tag: String) -> Element? {
        let openPrefix = "<\(tag)"
        let close = "</\(tag)>"
        guard text.hasPrefix(openPrefix), text.hasSuffix(close) else { return nil }
        var cursor = text.index(text.startIndex, offsetBy: openPrefix.count)
        var attributes: [String: String] = [:]
        while true {
            let whitespaceStart = cursor
            while cursor < text.endIndex, text[cursor] == " " || text[cursor] == "\t" { cursor = text.index(after: cursor) }
            guard cursor < text.endIndex else { return nil }
            if text[cursor] == ">" { cursor = text.index(after: cursor); break }
            guard cursor > whitespaceStart else { return nil }
            let nameStart = cursor
            while cursor < text.endIndex, text[cursor].isLetter || text[cursor].isNumber
                    || text[cursor] == "-" || text[cursor] == "_" {
                cursor = text.index(after: cursor)
            }
            guard cursor > nameStart, cursor < text.endIndex, text[cursor] == "=" else { return nil }
            let name = String(text[nameStart..<cursor])
            cursor = text.index(after: cursor)
            guard cursor < text.endIndex, text[cursor] == "\"" else { return nil }
            cursor = text.index(after: cursor)
            guard let quote = text[cursor...].firstIndex(of: "\"") else { return nil }
            guard attributes[name] == nil else { return nil }
            attributes[name] = unescape(String(text[cursor..<quote]))
            cursor = text.index(after: quote)
        }
        let bodyEnd = text.index(text.endIndex, offsetBy: -close.count)
        guard cursor <= bodyEnd else { return nil }
        return Element(attributes: attributes, body: String(text[cursor..<bodyEnd]))
    }

    static func escape(_ value: String) -> String {
        var out = ""
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "\"": out += "&quot;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\n": out += "&#10;"
            case "\r": out += "&#13;"
            case "\t": out += "&#9;"
            default: out.append(character)
            }
        }
        return out
    }

    static func unescape(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&#13;", with: "\r")
            .replacingOccurrences(of: "&#9;", with: "\t")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// A sender name is a label: one line, whitespace collapsed, at most 80
    /// characters. Nil when nothing is left.
    static func singleLineName(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 80 ? String(collapsed.prefix(79)) + "…" : collapsed
    }

    /// "None of the sessions you started is working now; their notes are
    /// above. …" → "None of the sessions you started is working now." The rest
    /// of a side-sessions note tells the model how to read its sessions' notes,
    /// which is nothing the user needs to see.
    private static func firstSentence(_ body: String) -> String? {
        guard let line = body.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        var sentence = line
        for separator in ["; ", ". "] {
            if let range = sentence.range(of: separator) { sentence = String(sentence[..<range.lowerBound]) }
        }
        sentence = sentence.trimmingCharacters(in: .whitespaces)
        guard !sentence.isEmpty else { return nil }
        if let last = sentence.last, !".!?".contains(last) { sentence += "." }
        return sentence.count > 200 ? String(sentence.prefix(199)) + "…" : sentence
    }
}

extension AgentComposerIntent {
    /// The same intent with what the person typed passed through
    /// `AgentMessageEnvelope.neutralizedUserText`. The composer and the
    /// supervisor's action sink both apply it, so the echo, the send and the
    /// session file all carry the same, user-owned text.
    public var neutralizingTypedEnvelopes: AgentComposerIntent {
        func typed(_ prompt: AgentPrompt) -> AgentPrompt {
            var prompt = prompt
            prompt.text = AgentMessageEnvelope.neutralizedUserText(prompt.text)
            return prompt
        }
        switch self {
        case .send(let text): return .send(AgentMessageEnvelope.neutralizedUserText(text))
        case .sendPrompt(let prompt): return .sendPrompt(typed(prompt))
        case .steer(let prompt): return .steer(typed(prompt))
        case .queue(let prompt): return .queue(typed(prompt))
        case .forceSend(let prompt): return .forceSend(typed(prompt))
        case .stop, .command, .providerCommand, .compact: return self
        }
    }
}
