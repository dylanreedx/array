import Foundation

public enum ProviderTrustState: Equatable, Sendable {
    case trusted
    case untrusted
    case unavailable(reason: String)
}

/// Immutable, host-local scope captured when a composer binds to one managed
/// agent. Providers must resolve files and capabilities from this context, never
/// from Array's globally active project or the process working directory.
public struct AgentCompletionContext: Equatable, Sendable {
    public let agentID: AgentID
    public let backend: AgentBackend
    public let checkoutRoot: URL
    public let gitRoot: URL?
    public let arrayProjectRoot: URL
    public let trustState: ProviderTrustState

    public init(
        agentID: AgentID,
        backend: AgentBackend,
        checkoutRoot: URL,
        gitRoot: URL? = nil,
        arrayProjectRoot: URL,
        trustState: ProviderTrustState
    ) {
        precondition(checkoutRoot.isFileURL, "AgentCompletionContext requires a local checkout root")
        precondition(gitRoot?.isFileURL != false, "AgentCompletionContext requires a local git root")
        precondition(arrayProjectRoot.isFileURL, "AgentCompletionContext requires a local Array project root")
        self.agentID = agentID
        self.backend = backend
        self.checkoutRoot = checkoutRoot
        self.gitRoot = gitRoot
        self.arrayProjectRoot = arrayProjectRoot
        self.trustState = trustState
    }
}

/// A host-local completion query. `replacementRange` uses UTF-16 offsets so an
/// AppKit/UIKit editor can apply it directly without converting String indices.
/// Query text and replacement ranges are deliberately not Codable and must never
/// be included in the desktop-to-phone metadata projection.
public struct AgentCompletionQuery: Equatable, Sendable {
    public let trigger: Character
    public let text: String
    public let replacementRange: NSRange
    public let context: AgentCompletionContext?
    /// Host-local browser scope for `@` completion. This is presentation state,
    /// not prompt text, and is intentionally absent from every persisted draft.
    public let navigationPath: String?

    public init(
        trigger: Character,
        text: String,
        replacementRange: NSRange,
        context: AgentCompletionContext? = nil,
        navigationPath: String? = nil
    ) {
        self.trigger = trigger
        self.text = text
        self.replacementRange = replacementRange
        self.context = context
        self.navigationPath = navigationPath
    }
}

public enum AgentCompletionQueryDetector {
    public static let supportedTriggers: Set<Character> = ["/", "@", "$"]

    /// Finds the trigger token containing the caret. Unquoted whitespace ends a
    /// token; quoted or backslash-escaped whitespace remains part of it. The
    /// returned query contains only text before the caret while replacement spans
    /// the complete token, which makes completion work when the caret is moved
    /// into the middle of an existing query.
    public static func activeQuery(
        in text: String,
        selection: NSRange,
        triggers: Set<Character> = supportedTriggers
    ) -> AgentCompletionQuery? {
        let source = text as NSString
        guard selection.length == 0,
              selection.location >= 0,
              selection.location <= source.length else { return nil }

        var cursor = 0
        while cursor < source.length {
            while cursor < source.length, isWhitespace(source.character(at: cursor)) {
                cursor += 1
            }
            guard cursor < source.length else { break }

            let tokenStart = cursor
            var quote: unichar?
            var escaped = false
            while cursor < source.length {
                let character = source.character(at: cursor)
                if escaped {
                    escaped = false
                    cursor += 1
                    continue
                }
                if character == 0x5C { // backslash
                    escaped = true
                    cursor += 1
                    continue
                }
                if character == 0x22 || character == 0x27 { // double/single quote
                    if quote == character { quote = nil }
                    else if quote == nil { quote = character }
                    cursor += 1
                    continue
                }
                if quote == nil, isWhitespace(character) { break }
                cursor += 1
            }
            let tokenEnd = cursor

            if selection.location > tokenStart,
               selection.location <= tokenEnd,
               tokenEnd > tokenStart {
                let triggerString = source.substring(with: NSRange(location: tokenStart, length: 1))
                guard let trigger = triggerString.first, triggers.contains(trigger) else { return nil }
                let queryRange = NSRange(
                    location: tokenStart + 1,
                    length: max(0, selection.location - tokenStart - 1)
                )
                return AgentCompletionQuery(
                    trigger: trigger,
                    text: decodedQuery(source.substring(with: queryRange)),
                    replacementRange: NSRange(location: tokenStart, length: tokenEnd - tokenStart)
                )
            }
        }
        return nil
    }

    private static func decodedQuery(_ raw: String) -> String {
        var result = ""
        var escaped = false
        var quote: Character?
        for character in raw {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                else { result.append(character) }
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
