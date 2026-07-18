import Foundation

// Ticket: docs/38-tickets/86-relay-sync-transport.md (slice 2, milestone C)
//
// Where both apps learn the relay's address. Presence of a URL is what
// switches the app into relay mode; absence falls back to the parked
// CloudKit path. Environment wins over UserDefaults so scripted launches
// can override what `defaults write` persisted.
//
//   Mac:  defaults write com.continuum.revived continuum.relay.url http://127.0.0.1:8787
//         defaults write com.continuum.revived continuum.relay.operatorToken <secret>
//   Sim:  xcrun simctl spawn <dev> defaults write dev.dylanreedx.continuum continuum.relay.url http://127.0.0.1:8787
public struct RelayClientConfig: Sendable, Equatable {
    public static let urlDefaultsKey = "continuum.relay.url"
    public static let operatorTokenDefaultsKey = "continuum.relay.operatorToken"

    public var baseURL: URL
    /// The Mac's publish credential. Nil on iOS — the phone authenticates
    /// with its pairing session token instead.
    public var operatorToken: String?

    public init(baseURL: URL, operatorToken: String? = nil) {
        self.baseURL = baseURL
        self.operatorToken = operatorToken
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> RelayClientConfig? {
        let urlString = environment["CONTINUUM_RELAY_URL"] ?? defaults.string(forKey: urlDefaultsKey)
        guard let urlString = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !urlString.isEmpty,
              let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https" else {
            return nil
        }
        let token = environment["CONTINUUM_RELAY_OPERATOR_TOKEN"] ?? defaults.string(forKey: operatorTokenDefaultsKey)
        return RelayClientConfig(baseURL: url, operatorToken: token)
    }
}
