import Foundation

/// Experimental helper-only discovery policy. Native memory exclusion is NOT
/// established. No synchronous CLI probes or edits to user/project files.
public enum HelperContextDiet {
    public static let enabledKey = "agents.helpers.contextDiet"
    public static func requested(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? false
    }
    public static func arguments(for record: AgentRecord) -> [String] {
        guard record.parentAgentID != nil,
              record.delegationContext?.contextDietRequested == true,
              record.harness == .pi else { return [] }
        return ["--no-skills"]
    }
    /// A delegated Claude helper starts without the personal memory index (about
    /// 8.6k tokens re-read every turn). The CLI's own switch, set per launch and
    /// identical on resume and after compaction, so the prefix never changes
    /// mid-session; it touches no login or credential. Leads keep their memory.
    public static func disablesClaudeAutoMemory(_ record: AgentRecord) -> Bool {
        record.harness == .claudeCode && record.parentAgentID != nil && record.delegationContext != nil
    }
    public static func status(for record: AgentRecord) -> HelperContextDietStatus? {
        guard record.parentAgentID != nil else { return nil }
        let requested = record.delegationContext?.contextDietRequested == true
        return HelperContextDietStatus(requested: requested,
            automaticSkillDiscovery: !requested ? "unchanged" : (record.harness == .pi ? "disabled_by_launch_flag" : "unsupported"),
            personalMemoryExclusion: disablesClaudeAutoMemory(record) ? "disabled_by_launch_env" : "unknown",
            note: record.harness == .pi
                ? "Pi automatic skill discovery only. Explicit skills, project rules and host rules remain. Personal-memory exclusion is unproven."
                : "No diet override applied: OAuth-safe discovery exclusion with resume and compaction compatibility has not been established for this harness.")
    }
}

/// Launch policy scope, not a provider-payload observation or model obedience.
public struct HelperContextDietStatus: Codable, Equatable, Sendable {
    public var requested: Bool
    public var automaticSkillDiscovery: String
    public var personalMemoryExclusion: String
    public var note: String
}
