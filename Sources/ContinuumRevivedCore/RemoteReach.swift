import Foundation

public struct SSHTarget: Equatable, Sendable, Codable {
    public var alias: String
    public var hostname: String
    public var username: String?
    public var port: Int?

    public init(alias: String, hostname: String, username: String? = nil, port: Int? = nil) {
        self.alias = alias
        self.hostname = hostname
        self.username = username
        self.port = port
    }
}

public enum RemoteReach: Equatable, Sendable, Codable {
    case localhost
    case sshForward(SSHTarget)
    case tailscale(SSHTarget)
    case tunnel(relayHost: String)
}

public struct RemoteEnvironment: Equatable, Sendable, Codable {
    public var id: UUID
    public var label: String
    public var reach: RemoteReach
    public var lastConnectedAt: Date?

    public init(id: UUID = UUID(), label: String, reach: RemoteReach, lastConnectedAt: Date? = nil) {
        self.id = id
        self.label = label
        self.reach = reach
        self.lastConnectedAt = lastConnectedAt
    }
}

public enum RemoteReachConfig {
    public static let serverAliveIntervalKey = "continuum.remote.ssh.serverAliveInterval"
    public static let serverAliveCountMaxKey = "continuum.remote.ssh.serverAliveCountMax"
    public static let connectTimeoutKey = "continuum.remote.ssh.connectTimeout"
    public static let configFileKey = "continuum.remote.ssh.configFile"

    public static let defaultServerAliveInterval = 15
    public static let defaultServerAliveCountMax = 3
    public static let defaultConnectTimeout = 10

    public static func serverAliveInterval(defaults: UserDefaults = .standard) -> Int {
        intValue(forKey: serverAliveIntervalKey, defaultValue: defaultServerAliveInterval, defaults: defaults)
    }

    public static func serverAliveCountMax(defaults: UserDefaults = .standard) -> Int {
        intValue(forKey: serverAliveCountMaxKey, defaultValue: defaultServerAliveCountMax, defaults: defaults)
    }

    public static func connectTimeout(defaults: UserDefaults = .standard) -> Int {
        intValue(forKey: connectTimeoutKey, defaultValue: defaultConnectTimeout, defaults: defaults)
    }

    public static func configFile(defaults: UserDefaults = .standard) -> String? {
        guard let value = defaults.string(forKey: configFileKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func intValue(forKey key: String, defaultValue: Int, defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return max(1, defaults.integer(forKey: key))
    }
}
