import Foundation

/// Local retry provenance. The original task stays separate from the augmented
/// prompt so retry chains never recursively copy earlier handoffs into context.
public struct AgentDelegationContext: Codable, Equatable, Sendable {
    public var brief: String
    public var baseHead: String?
    public var retryOf: AgentID?
    public var createdWorktree: Bool
    public var checkoutNotice: String?

    public init(brief: String, baseHead: String?, retryOf: AgentID?, createdWorktree: Bool, checkoutNotice: String?) {
        self.brief = brief
        self.baseHead = baseHead
        self.retryOf = retryOf
        self.createdWorktree = createdWorktree
        self.checkoutNotice = checkoutNotice
    }

    /// At most 300 whitespace-delimited words / 4,800 characters of additional
    /// context. Reserve space per section: a long brief cannot crowd out Next.
    public static func handoff(from old: AgentRecord, changedFiles: [String]?) -> String {
        func clip(_ text: String, _ words: Int, _ characters: Int = 900) -> String {
            let tokens = text.split(whereSeparator: \.isWhitespace)
            let clipped = String(tokens.prefix(words).joined(separator: " ").prefix(characters))
            return clipped + (tokens.count > words || text.count > characters ? " …" : "")
        }
        let report = old.lastReport?.report
        let files = changedFiles.map { names in
            names.isEmpty ? "none" : names.prefix(12).map { String(reflecting: $0) }.joined(separator: ", ")
                + (names.count > 12 ? " (more omitted)" : "")
        } ?? "unavailable"
        let sections = [
            "Retry context (bounded). Full brief, transcript and report: inspect old helper \(old.id.rawValue.uuidString).",
            "Prior checkout: \(clip(old.checkoutRoot, 8, 512)). Work is retained there; a new checkout does not copy uncommitted changes.",
            "Earlier brief: \(clip(old.delegationContext?.brief ?? "unavailable for this legacy helper; inspect its transcript", 55))",
            "Changed files (checkout-wide git names): \(clip(files, 30, 700))",
            "Summary: \(clip(report?.summary ?? "no report filed", 40, 600))",
            "Failed checks: \(clip(report?.checks.filter { $0.result == .fail }.map(\.what).joined(separator: "; ") ?? "none reported", 30, 500))",
            "Findings: \(clip(report?.findings.map { "\($0.level.rawValue): \($0.text)" }.joined(separator: "; ") ?? "none reported", 35, 600))",
            "Next: \(clip(report?.next ?? "none reported", 20, 250))"
        ]
        return clip(sections.joined(separator: "\n"), 298, 4798)
    }
}
