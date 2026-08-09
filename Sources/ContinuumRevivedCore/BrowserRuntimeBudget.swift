import Foundation

public struct BrowserRuntimeBudget: Equatable {
    public var maxLive: Int
    private var recency: [UUID]

    public init(maxLive: Int = Self.defaultMaxLive) {
        self.maxLive = max(1, maxLive)
        self.recency = []
    }

    public static let defaultMaxLive = 6
    // Channel-scoped (AppChannel): dev builds read the DEV bundle's domain,
    // never prod preferences.
    public static var bundledDefaultsDomain: String { AppChannel.liveBundledDefaultsDomain }
    public static let legacyDefaultsDomain = "continuum.revived"
    public static let defaultsKey = "continuum.browserLiveBudget"

    public static func resolveMaxLive(
        standard: UserDefaults = .standard,
        bundled: UserDefaults? = UserDefaults(suiteName: bundledDefaultsDomain),
        legacy: UserDefaults? = UserDefaults(suiteName: legacyDefaultsDomain)
    ) -> Int {
        for defaults in [standard, bundled, legacy].compactMap({ $0 }) {
            if let value = defaults.object(forKey: defaultsKey) as? Int, value > 0 {
                return value
            }
            if let string = defaults.string(forKey: defaultsKey), let value = Int(string), value > 0 {
                return value
            }
        }
        return defaultMaxLive
    }

    public mutating func registerLive(tileId: UUID) {
        recency.removeAll { $0 == tileId }
        recency.append(tileId)
    }

    public mutating func unregister(tileId: UUID) {
        recency.removeAll { $0 == tileId }
    }

    public mutating func evictionCandidates(liveTileIds: [UUID], protectedTileIds: Set<UUID>) -> [UUID] {
        let liveSet = Set(liveTileIds)
        recency.removeAll { !liveSet.contains($0) }
        for tileId in liveTileIds where !recency.contains(tileId) {
            recency.append(tileId)
        }
        var overflow = liveTileIds.count - maxLive
        guard overflow > 0 else { return [] }
        var evict: [UUID] = []
        for tileId in recency where overflow > 0 && !protectedTileIds.contains(tileId) {
            evict.append(tileId)
            overflow -= 1
        }
        return evict
    }
}
