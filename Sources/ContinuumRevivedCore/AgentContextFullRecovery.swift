import Foundation

/// Provider-neutral recognition and recovery choices for a turn that could
/// not fit in its context window. Translators collapse only explicit provider
/// codes or unmistakable context-limit messages to the canonical error text;
/// the original provider error is never retained by this model.
public enum AgentContextFullRecovery {
    public static let canonicalErrorMessage = "Context window full"

    public enum Action: String, Codable, Equatable, Sendable {
        case compactAndRetry
        case forkWithSummary
        case copyTranscript
    }

    /// These are the actions the shared recovery UI can offer. Availability
    /// for a specific agent is still checked against its live runner and
    /// transcript before an action is enabled.
    public static let actions: [Action] = [
        .compactAndRetry,
        .forkWithSummary,
        .copyTranscript,
    ]

    /// Recognizes context exhaustion from the bounded provider code/message
    /// fields available at the translation seam. Matching is deliberately
    /// conservative: output-token caps and generic provider failures do not
    /// qualify.
    public static func isContextFull(provider: String, candidates: [String?]) -> Bool {
        let providerName = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["claude", "anthropic", "codex", "openai", "pi"].contains(providerName) else {
            return false
        }

        return candidates.compactMap { $0 }.contains(where: isContextFullCandidate)
    }

    private static func isContextFullCandidate(_ candidate: String) -> Bool {
        guard candidate.count <= 4096 else { return false }
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return false }

        let identifier = value.filter { $0.isLetter || $0.isNumber }.map(String.init).joined()
        let knownCodes: Set<String> = [
            "contextfull",
            "contextwindowfull",
            "contextwindowexceeded",
            "contextwindowexhausted",
            "contextlengthexceeded",
            "modelcontextwindowexceeded",
            "modelcontextwindowfull",
            "prompttoolong",
            "promptistoolong",
            "errorprompttoolong",
            "inputtoolong",
            "requesttoolong",
            "maximumcontextlengthexceeded",
            "contextwindowoverflow",
        ]
        if knownCodes.contains(identifier) { return true }

        // Keep phrase matching tied to context/window/length language. This
        // avoids treating ordinary token-budget or output-length failures as
        // a recoverable context-full condition.
        let phrase = value
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
        let phrases = [
            "context full",
            "context is full",
            "context window full",
            "context window is full",
            "context window exceeded",
            "context window has been exceeded",
            "context window exhausted",
            "context window overflow",
            "context length exceeded",
            "maximum context length",
            "context limit exceeded",
            "prompt too long for context",
            "prompt is too long",
            "exceeds the context window",
            "prompt exceeds context",
            "prompt exceeds the model context",
            "input exceeds context",
            "request exceeds context",
        ]
        return phrases.contains { phrase.contains($0) }
    }
}
