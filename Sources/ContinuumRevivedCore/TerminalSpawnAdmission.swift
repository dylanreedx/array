import Foundation

public struct TerminalSpawnAdmission: Equatable {
    public enum Refusal: Equatable {
        case rateLimited(trigger: String, retryAfter: TimeInterval)
        case liveRuntimeCapReached(maxLive: Int, liveCount: Int)

        public var message: String {
            switch self {
            case let .rateLimited(trigger, retryAfter):
                return "Terminal spawn refused: trigger '\(trigger)' is rate-limited; retry after \(String(format: "%.3f", retryAfter))s"
            case let .liveRuntimeCapReached(maxLive, liveCount):
                return "Terminal spawn refused: live terminal cap reached (\(liveCount)/\(maxLive))"
            }
        }
    }

    public static let defaultMaxLive = 32
    public static let debounceWindow: TimeInterval = 0.300
    public static let bundledDefaultsDomain = "dev.arrayapp.macos"
    public static let legacyDefaultsDomain = "continuum.revived"
    public static let defaultsKey = "continuum.terminalLiveBudget"

    public var maxLive: Int
    public var debounceWindow: TimeInterval
    private var lastAcceptedByTrigger: [String: Date]

    public init(maxLive: Int = Self.defaultMaxLive, debounceWindow: TimeInterval = Self.debounceWindow) {
        self.maxLive = max(1, maxLive)
        self.debounceWindow = max(0, debounceWindow)
        self.lastAcceptedByTrigger = [:]
    }

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

    public mutating func admit(trigger: String, liveCount: Int, now: Date = Date()) -> Refusal? {
        if let last = lastAcceptedByTrigger[trigger] {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < debounceWindow {
                return .rateLimited(trigger: trigger, retryAfter: debounceWindow - elapsed)
            }
        }
        if liveCount >= maxLive {
            return .liveRuntimeCapReached(maxLive: maxLive, liveCount: liveCount)
        }
        lastAcceptedByTrigger[trigger] = now
        return nil
    }
}
