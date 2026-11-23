import Foundation

/// The one setting behind automatic context compaction, shared by the three
/// provider-native compaction commands.
///
/// Meaning: compact an agent's conversation when it reaches `compactAtTokens`,
/// or earlier when it fills 90% of the model's window (a small window cannot
/// hold a 300k conversation, and compaction needs room to run). "Never" turns
/// automatic compaction off; the Compact command still works by hand.
///
/// A turn at 450k tokens costs about six times a turn at 50-100k, so a large
/// window must not let a conversation grow unbounded. 300k is the default.
public enum AgentContextAutoCompactionPolicy {
    /// The only key Settings writes. A stored word: `off` or a token count.
    public static let compactAtKey = "continuum.agentContext.compactAtTokens"
    public static let offOption = "off"
    public static let defaultTokens = 300_000
    public static let tokenOptions = [100_000, 150_000, 200_000, 300_000, 500_000]
    public static let options: [String] = [offOption] + tokenOptions.map(String.init)
    public static let defaultOption = String(defaultTokens)
    /// Fixed guard, not a setting: compact before the window is this full.
    public static let windowFraction = 0.90

    /// Retired keys (the old on/off switch and the percent field). Still READ,
    /// once, to carry a person's choice into `compactAtKey`; never written.
    public static let enabledKey = "continuum.agentContext.autoCompact"
    public static let percentKey = "continuum.agentContext.autoCompactPercent"
    /// The window the old percentage is converted against: Claude's standard one.
    static let legacyReferenceWindow = 200_000

    public static func title(for option: String) -> String {
        guard let tokens = Int(option) else { return "Never" }
        return "At \(tokens / 1_000)k tokens"
    }

    /// Carries a saved pre-0.7.61 choice into the one setting, once. No new
    /// value yet and an old one present: Off stays Off; a percent below the old
    /// 90% default becomes that share of a 200k window, snapped to the nearest
    /// offered size; the old default (or anything above it) keeps today's 300k.
    /// Idempotent; the old keys stay where they are.
    public static func migrateLegacy(defaults: UserDefaults) {
        guard defaults.object(forKey: compactAtKey) == nil else { return }
        if defaults.object(forKey: enabledKey) != nil, !defaults.bool(forKey: enabledKey) {
            defaults.set(offOption, forKey: compactAtKey)
            return
        }
        guard defaults.object(forKey: percentKey) != nil else { return }
        let percent = defaults.double(forKey: percentKey)
        guard percent.isFinite, percent >= 50, percent < 90 else { return }
        let wanted = percent / 100 * Double(legacyReferenceWindow)
        let nearest = tokenOptions.min { abs(Double($0) - wanted) < abs(Double($1) - wanted) } ?? defaultTokens
        defaults.set(String(nearest), forKey: compactAtKey)
    }

    /// Tokens at which to compact, or nil when automatic compaction is off.
    public static func compactAtTokens(defaults: UserDefaults = .standard) -> Int? {
        migrateLegacy(defaults: defaults)
        guard let word = defaults.string(forKey: compactAtKey) else { return defaultTokens }
        if word == offOption { return nil }
        guard let tokens = Int(word), tokens > 0 else { return defaultTokens }
        return tokens
    }

    public static func shouldCompact(used: Int, max window: Int, limit: Int) -> Bool {
        guard window > 0 else { return false }
        return used >= limit || Double(used) / Double(window) >= windowFraction
    }
}
