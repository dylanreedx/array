import Foundation

public enum NewTileCwdPolicy: String, CaseIterable, Sendable {
    case inheritFocus
    case projectRoot
    case lastUsed
}

public enum NewTileCwdConfig {
    public static let userDefaultsKey = "continuum.terminal.newTileCwd"
    public static let defaultPolicy: NewTileCwdPolicy = .inheritFocus

    public static func policy(defaults: UserDefaults = .standard) -> NewTileCwdPolicy {
        guard let raw = defaults.string(forKey: userDefaultsKey) else {
            return defaultPolicy
        }
        return NewTileCwdPolicy(rawValue: raw) ?? defaultPolicy
    }
}

public func resolveNewTileCwd(
    policy: NewTileCwdPolicy,
    focused: String?,
    lastUsed: String?,
    projectRoot: String
) -> String {
    switch policy {
    case .inheritFocus:
        return focused ?? projectRoot
    case .projectRoot:
        return projectRoot
    case .lastUsed:
        return lastUsed ?? projectRoot
    }
}
