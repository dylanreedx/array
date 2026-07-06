import Foundation

public struct PersistedPushCategoryPreferences: PushCategoryPreferences, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func key(for category: PushCategory) -> String {
        "continuum.notify.\(category.rawValue)"
    }

    public func isEnabled(_ category: PushCategory) -> Bool {
        let key = Self.key(for: category)
        guard defaults.object(forKey: key) != nil else { return category.defaultEnabled }
        return defaults.bool(forKey: key)
    }
}
