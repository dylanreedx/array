import Foundation

/// WHICH account a CLI is spending: the login's email, organisation and plan.
///
/// The night this was asked for, overnight agents ran on a login nobody meant
/// them to use, and the row said `5h 84%` without saying whose five hours they
/// were. So the identity is read alongside every limit and shown next to it.
///
/// It is never a credential. Each field comes from the CLI's own report on its
/// own login — `claude auth status --json`, codex app-server `account/read` —
/// and Array keeps only what those print. No token is read, copied or stored.
public struct AgentAccountIdentity: Equatable, Sendable, Codable {
    public var harness: AgentHarness
    public var email: String?
    public var organizationName: String?
    /// Stable across renames, so a change of login outside Array is noticed
    /// even when the email stays the same (a personal and a team seat can share
    /// one address).
    public var organizationId: String?
    /// The provider's raw plan word (`max`, `team`, `prolite`). Kept raw;
    /// `planDisplayName` is the only place it is worded for people.
    public var plan: String?
    public var observedAt: Date

    public init(
        harness: AgentHarness,
        email: String? = nil,
        organizationName: String? = nil,
        organizationId: String? = nil,
        plan: String? = nil,
        observedAt: Date
    ) {
        self.harness = harness
        self.email = email
        self.organizationName = organizationName
        self.organizationId = organizationId
        self.plan = plan
        self.observedAt = observedAt
    }

    /// `Max`, `Team`, `Pro Lite`. Unknown words are capitalised, not dropped:
    /// a plan this build has never heard of is still the account's plan.
    public var planDisplayName: String? {
        guard let plan, !plan.isEmpty else { return nil }
        switch plan.lowercased() {
        case "max", "claude_max": return "Max"
        case "pro", "claude_pro": return "Pro"
        case "team", "claude_team": return "Team"
        case "enterprise", "claude_enterprise": return "Enterprise"
        case "prolite": return "Pro Lite"
        case "plus": return "Plus"
        case "business": return "Business"
        case "free": return "Free"
        default:
            return plan.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// `claude auth status --json`. Nil when the dir is signed out: a
    /// signed-out login has no identity to show, and an empty one would read
    /// as a real account with no name.
    public static func claude(authStatusJSON data: Data, observedAt: Date) -> AgentAccountIdentity? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["loggedIn"] as? Bool) == true else { return nil }
        return AgentAccountIdentity(
            harness: .claudeCode,
            email: nonEmpty(object["email"]),
            organizationName: nonEmpty(object["orgName"]),
            organizationId: nonEmpty(object["orgId"]),
            plan: nonEmpty(object["subscriptionType"]),
            observedAt: observedAt)
    }

    /// codex app-server `account/read` result. `account` is null when codex is
    /// signed out, and an API-key login (`type: apiKey`) has no plan or email.
    public static func codex(accountReadResult result: [String: Any], observedAt: Date) -> AgentAccountIdentity? {
        guard let account = result["account"] as? [String: Any] else { return nil }
        return AgentAccountIdentity(
            harness: .codex,
            email: nonEmpty(account["email"]),
            organizationName: nil,
            organizationId: nonEmpty((result["workspaceRouting"] as? [String: Any])?["chatgptAccountId"]),
            plan: nonEmpty(account["planType"]),
            observedAt: observedAt)
    }

    private static func nonEmpty(_ raw: Any?) -> String? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        return value
    }
}
