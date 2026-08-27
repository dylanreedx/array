import ContinuumRevivedCore
import ContinuumRevivedRelayProtocol
import Foundation

enum HostedPairingPolicy {
    static let productionHTTPOrigin = URL(string: "https://relay.arrayapp.dev")!

    /// Resolves the relay advertised in a QR invitation without allowing the
    /// one-time pairing credential to be posted to an arbitrary origin.
    static func relayHTTPOrigin(advertisedURL: URL?, allowLoopback: Bool) -> URL? {
        guard let advertisedURL else { return productionHTTPOrigin }
        guard var components = URLComponents(url: advertisedURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "wss": components.scheme = "https"
        case "ws": components.scheme = "http"
        case "https", "http": break
        default: return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let origin = components.url else { return nil }

        if origin.scheme == "https", origin.host?.lowercased() == "relay.arrayapp.dev", origin.port == nil {
            return productionHTTPOrigin
        }
        let loopbackHosts = Set(["localhost", "127.0.0.1", "::1"])
        if allowLoopback,
           let host = origin.host?.lowercased(), loopbackHosts.contains(host),
           origin.scheme == "http" || origin.scheme == "https" {
            return origin
        }
        return nil
    }

    /// Capabilities are fixed by the server. Refuse a credential if the relay
    /// adds or removes authority instead of silently projecting it to a broader
    /// local Scope.
    static func companionScope(capabilities: Set<RelayCapability>, credential: String) -> Scope? {
        guard !credential.isEmpty, capabilities == RelayWire.companionCapabilities else { return nil }
        return .companionControl
    }

    /// Production no longer has a provisioned CloudKit desktop peer. A saved
    /// session without a relay endpoint is therefore a legacy pairing that
    /// must be replaced, not a connection that can eventually become live.
    static func requiresHostedRepair(isPaired: Bool, relayURL: URL?) -> Bool {
        isPaired && relayURL == nil
    }
}
