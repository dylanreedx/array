import Foundation

/// Local retry provenance. The original task stays separate from the augmented
/// prompt so retry chains never recursively copy earlier handoffs into context.
public struct AgentDelegationContext: Codable, Equatable, Sendable {
    public var brief: String
    public var baseHead: String?
    public var retryOf: AgentID?
    public var createdWorktree: Bool
    public var checkoutNotice: String?
    /// The lead's stated contract, kept beside the brief. Absent for a helper
    /// delegated without one.
    public var contract: AgentDelegationContract?

    public init(brief: String, baseHead: String?, retryOf: AgentID?, createdWorktree: Bool, checkoutNotice: String?, contract: AgentDelegationContract? = nil) {
        self.brief = brief
        self.baseHead = baseHead
        self.retryOf = retryOf
        self.createdWorktree = createdWorktree
        self.checkoutNotice = checkoutNotice
        self.contract = contract
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

/// What a lead states a helper owns and owes (`.plans/116` part 4). Model-authored
/// claims: Array stores them, tells the helper once and compares ownership with
/// live siblings as advice. Nothing here is enforced.
public struct AgentDelegationContract: Codable, Equatable, Sendable {
    /// Repository-relative files or directories the helper owns.
    public var owns: [String]
    /// Repository-relative paths the helper must not touch.
    public var mustNotTouch: [String]
    /// Checks the helper owes, by flag or invocation.
    public var checks: [String]
    /// Owner decisions that bind the helper.
    public var decisions: [String]
    /// A hot-path cost limit, when one applies.
    public var costLimit: String?
    /// What the helper reports back.
    public var report: String?

    public init(owns: [String] = [], mustNotTouch: [String] = [], checks: [String] = [], decisions: [String] = [], costLimit: String? = nil, report: String? = nil) {
        self.owns = owns
        self.mustNotTouch = mustNotTouch
        self.checks = checks
        self.decisions = decisions
        self.costLimit = costLimit
        self.report = report
    }

    private enum CodingKeys: String, CodingKey { case owns, mustNotTouch, checks, decisions, costLimit, report }

    /// Any subset of the fields; an absent list is empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owns = try c.decodeIfPresent([String].self, forKey: .owns) ?? []
        mustNotTouch = try c.decodeIfPresent([String].self, forKey: .mustNotTouch) ?? []
        checks = try c.decodeIfPresent([String].self, forKey: .checks) ?? []
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        costLimit = try c.decodeIfPresent(String.self, forKey: .costLimit)
        report = try c.decodeIfPresent(String.self, forKey: .report)
    }

    /// Files every new check has to edit, so two parts touching them is expected
    /// (`.plans/116` README c7): the check dispatch, the matrix and its inventory.
    public static let sharedRegistries: Set<String> = [
        "Sources/ContinuumRevived/App/ContinuumApp.swift",
        "scripts/run-matrix.sh",
        "docs/38-tickets/90-agent-ux/matrix-inventory.txt",
    ]

    public struct InvalidPath: LocalizedError { public let errorDescription: String? }

    /// The same contract with exact repository-relative paths ("./a/" -> "a").
    /// Throws for an absolute path or a `..` step: neither can be compared with
    /// a sibling's claim.
    public func normalized() throws -> AgentDelegationContract {
        var copy = self
        for keyPath in [\AgentDelegationContract.owns, \.mustNotTouch] {
            var paths: [String] = []
            for raw in self[keyPath: keyPath] {
                var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                while path.hasPrefix("./") { path.removeFirst(2) }
                while path.hasSuffix("/") { path.removeLast() }
                if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("~") || path.split(separator: "/").contains("..") {
                    throw InvalidPath(errorDescription: "contract paths must be repository-relative without '..'; got '\(raw)'.")
                }
                paths.append(path)
            }
            copy[keyPath: keyPath] = paths
        }
        return copy
    }

    /// Owned paths this contract shares with `other`'s: the more specific path
    /// of each overlapping pair, leaving out the shared registries.
    public func ownershipOverlap(with other: AgentDelegationContract) -> [String] {
        var shared: [String] = []
        for mine in owns {
            for theirs in other.owns {
                let path: String
                if mine == theirs || mine.hasPrefix(theirs + "/") { path = mine }
                else if theirs.hasPrefix(mine + "/") { path = theirs }
                else { continue }
                if !Self.sharedRegistries.contains(path), !shared.contains(path) { shared.append(path) }
            }
        }
        return shared
    }

    /// The one block the helper is told, in a fixed order; empty fields are left out.
    public var promptText: String {
        let lines = [
            ("Owns", owns.joined(separator: ", ")),
            ("Must not touch", mustNotTouch.joined(separator: ", ")),
            ("Checks owed", checks.joined(separator: "; ")),
            ("Decisions", decisions.joined(separator: "; ")),
            ("Cost limit", costLimit ?? ""),
            ("Report", report ?? ""),
        ].filter { !$0.1.isEmpty }.map { "- \($0.0): \($0.1)" }
        return (["Contract from your lead (recorded by Array):"] + lines).joined(separator: "\n")
    }
}
