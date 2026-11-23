import Foundation

/// What Array does when an agent's context gets long.
public enum AgentContextCompactionMode: String, CaseIterable, Sendable {
    /// A quick button beside the composer; nothing happens until it is pressed.
    case ask
    /// Compact between turns, once the size below is reached.
    case automatic
    case never

    public var title: String {
        switch self {
        case .ask: return "Ask me"
        case .automatic: return "Automatically"
        case .never: return "Never"
        }
    }
}

/// The settings behind context compaction, shared by the three provider-native
/// compaction commands.
///
/// Two rows: a mode ("When an agent's context gets long") and a size ("Context
/// is long at"). The context counts as long at that many tokens, or when it
/// fills 90% of the model's window if that comes first (a small window cannot
/// hold a 300k conversation, and compaction needs room to run). A turn at 450k
/// tokens costs about six times a turn at 50-100k, so 300k is the default.
///
/// Who is asked: agents the user drives (leads and standalone agents) follow
/// the mode. A delegated helper has nobody watching its composer, so "Ask me"
/// means Automatically for it, between turns only. "Never" holds for everyone.
public enum AgentContextAutoCompactionPolicy {
    public static let modeKey = "continuum.agentContext.compactMode"
    public static let defaultMode = AgentContextCompactionMode.ask
    public static let compactAtKey = "continuum.agentContext.compactAtTokens"
    public static let defaultTokens = 300_000
    public static let tokenOptions = [100_000, 150_000, 200_000, 300_000, 500_000]
    public static let options: [String] = tokenOptions.map(String.init)
    public static let defaultOption = String(defaultTokens)
    /// Fixed guard, not a setting: the context is long before the window is this full.
    public static let windowFraction = 0.90

    /// Retired keys: the old on/off switch and the percent field. Read once to
    /// carry a person's choice over, never written.
    public static let enabledKey = "continuum.agentContext.autoCompact"
    public static let percentKey = "continuum.agentContext.autoCompactPercent"
    static let migratedKey = "continuum.agentContext.compactionMigrated"
    /// The window the old percentage is converted against: Claude's standard one.
    static let legacyReferenceWindow = 200_000

    /// The size beside the slider: "300k tokens".
    public static func sizeLabel(for option: String) -> String {
        guard let tokens = Int(option) else { return option }
        return "\(tokens / 1_000)k tokens"
    }

    public static func title(for option: String) -> String {
        guard let tokens = Int(option) else { return option }
        return "At \(tokens / 1_000)k tokens"
    }

    /// Carries saved choices into the two rows, once (a Reset to Default must
    /// not bring an old value back):
    /// - old Off, or an interim size of "off", becomes mode Never;
    /// - an old percent below the old 90% default becomes that share of a 200k
    ///   window, snapped to the nearest size;
    /// - everything else keeps the defaults (Ask me, 300k).
    public static func migrateLegacy(defaults: UserDefaults) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defer { defaults.set(true, forKey: migratedKey) }
        if defaults.string(forKey: compactAtKey) == "off" {
            defaults.removeObject(forKey: compactAtKey)
            if defaults.object(forKey: modeKey) == nil { defaults.set(AgentContextCompactionMode.never.rawValue, forKey: modeKey) }
        }
        if defaults.object(forKey: modeKey) == nil,
           defaults.object(forKey: enabledKey) != nil, !defaults.bool(forKey: enabledKey) {
            defaults.set(AgentContextCompactionMode.never.rawValue, forKey: modeKey)
        }
        if defaults.object(forKey: compactAtKey) == nil, defaults.object(forKey: percentKey) != nil {
            let percent = defaults.double(forKey: percentKey)
            if percent.isFinite, percent >= 50, percent < 90 {
                let wanted = percent / 100 * Double(legacyReferenceWindow)
                let nearest = tokenOptions.min { abs(Double($0) - wanted) < abs(Double($1) - wanted) } ?? defaultTokens
                defaults.set(String(nearest), forKey: compactAtKey)
            }
        }
    }

    /// The mode as saved.
    public static func mode(defaults: UserDefaults = .standard) -> AgentContextCompactionMode {
        migrateLegacy(defaults: defaults)
        return defaults.string(forKey: modeKey).flatMap(AgentContextCompactionMode.init(rawValue:)) ?? defaultMode
    }

    /// The mode that applies to one agent: a helper cannot be asked.
    public static func effectiveMode(isHelper: Bool, defaults: UserDefaults = .standard) -> AgentContextCompactionMode {
        let saved = mode(defaults: defaults)
        return saved == .ask && isHelper ? .automatic : saved
    }

    /// Tokens at which the context counts as long.
    public static func limitTokens(defaults: UserDefaults = .standard) -> Int {
        migrateLegacy(defaults: defaults)
        guard let word = defaults.string(forKey: compactAtKey), let tokens = Int(word), tokens > 0 else { return defaultTokens }
        return tokens
    }

    public static func shouldCompact(used: Int, max window: Int, limit: Int) -> Bool {
        guard window > 0 else { return false }
        return used >= limit || Double(used) / Double(window) >= windowFraction
    }
}
