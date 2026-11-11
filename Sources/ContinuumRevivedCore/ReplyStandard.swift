import Foundation

/// Array's rules for every reply an agent writes to the user (RFC 6, rules 6.1
/// to 6.11, compressed). The one place this text lives. It is Array-layer text:
/// content, order, terms and length only, never tone or formatting (those are
/// the user's personal layer). Array never writes it into user or project files.
/// Settings ▸ Agents ▸ Reply rules; default off until the paired replay shows it
/// helps.
public enum ReplyStandard {
    public static let enabledKey = "agents.replyRules.enabled"
    public static let label = "Replying to the user"
    public static let text = "Answer first, then what it means and why, then detail. Do and say only what was asked; offer any extra in one line. Explain each term, label or code plainly the first time unless the user used it. Reports go: goal and stage reached, what changed, the one limit, next step. Fit length to the question; put unasked detail in a file and give its path. Say \"done\" or \"verified\" only for what you checked."

    /// Exactly what reaches the agent: the label line, then the rules.
    public static let block = label + ":\n" + text
    /// Counts toward Array's always-loaded text. Reported, never capped.
    public static let wordCount = block.split(whereSeparator: { $0.isWhitespace }).count

    public static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool == true
    }
}
