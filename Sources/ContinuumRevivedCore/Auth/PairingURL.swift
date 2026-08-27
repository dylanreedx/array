import Foundation

public enum PairingAlphabet: Sendable {
    public static let symbols = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    private static let symbolSet = Set(symbols)

    public static func credential(length: Int = 12) throws -> String {
        var output: [Character] = []
        output.reserveCapacity(length)
        let limit = (256 / symbols.count) * symbols.count

        while output.count < length {
            let byte = try AuthRandom.bytes(count: 1)[0]
            guard Int(byte) < limit else { continue }
            output.append(symbols[Int(byte) % symbols.count])
        }
        return String(output)
    }

    public static func containsOnlySymbols(_ credential: String) -> Bool {
        credential.allSatisfy { symbolSet.contains($0) }
    }
}

public enum PairingURL: Sendable {
    public static let scheme = "array"
    public static let legacyScheme = "continuum"
    public static let host = "pair"
    public static let hostedOrigin = URL(string: "https://arrayapp.dev")!

    public struct Payload: Equatable, Sendable {
        public var token: String
        public var endpoint: URL?
        public var scopes: Scope?
        public var instanceId: UUID?
        /// Ticket 86 (D4-R1): the relay the phone should sync against,
        /// advertised in a form reachable from the phone. Pairing is the
        /// configuration handoff — the phone never types a URL.
        public var relay: URL?

        public init(token: String, endpoint: URL?, scopes: Scope?, instanceId: UUID?, relay: URL? = nil) {
            self.token = token
            self.endpoint = endpoint
            self.scopes = scopes
            self.instanceId = instanceId
            self.relay = relay
        }
    }

    public static func issue(credential: String, scopes: Scope, instanceId: UUID? = nil, endpoint: URL? = nil, relay: URL? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var fragmentItems: [URLQueryItem] = []
        if let endpoint {
            fragmentItems.append(URLQueryItem(name: "endpoint", value: endpoint.absoluteString))
        }
        fragmentItems.append(contentsOf: [
            URLQueryItem(name: "token", value: credential),
            URLQueryItem(name: "scopes", value: "\(scopes.rawValue)")
        ])
        if let instanceId {
            fragmentItems.append(URLQueryItem(name: "instance", value: instanceId.uuidString))
        }
        if let relay {
            fragmentItems.append(URLQueryItem(name: "relay", value: relay.absoluteString))
        }
        var fragmentComponents = URLComponents()
        fragmentComponents.queryItems = fragmentItems
        components.fragment = String(fragmentComponents.url!.absoluteString.dropFirst())
        assert(components.queryItems == nil)
        return components.url!
    }

    /// Produces the Camera-friendly production journey. Pairing material stays
    /// in the fragment so it is not sent to Vercel, access logs, or referrers.
    public static func hostedIssue(credential: String, relay: URL? = nil) -> URL {
        var components = URLComponents(url: hostedOrigin, resolvingAgainstBaseURL: false)!
        components.path = "/pair"
        var fragmentComponents = URLComponents()
        var items = [URLQueryItem(name: "token", value: credential)]
        if let relay {
            items.append(URLQueryItem(name: "relay", value: relay.absoluteString))
        }
        fragmentComponents.queryItems = items
        components.fragment = String(fragmentComponents.url!.absoluteString.dropFirst())
        components.queryItems = nil
        return components.url!
    }

    /// A Camera-compatible LAN URL. iOS Camera reliably recognizes http(s) QR
    /// payloads, while it may label custom-scheme QR payloads as "No Usable
    /// Data" even when Continuum is installed. The Mac serves this URL as a
    /// tiny local landing page that opens the embedded `continuum://pair` link.
    public static func cameraBootstrapURL(pairingURL: URL, endpoint: URL) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = "/open-continuum-pairing"
        components.queryItems = [URLQueryItem(name: "link", value: pairingURL.absoluteString)]
        components.fragment = nil
        return components.url!
    }

    public static func embeddedPairingURL(in url: URL) -> URL? {
        guard url.scheme == "http" || url.scheme == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == "/open-continuum-pairing",
              let link = components.queryItems?.first(where: { $0.name == "link" })?.value,
              let embedded = URL(string: link),
              acceptedCustomSchemes.contains(embedded.scheme?.lowercased() ?? ""),
              embedded.host == host else {
            return nil
        }
        return embedded
    }

    public static func parse(_ url: URL) -> String? {
        parsePayload(url)?.token
    }

    public static func parsePayload(_ url: URL) -> Payload? {
        if let embedded = embeddedPairingURL(in: url) {
            return parsePayload(embedded)
        }
        guard let items = fragmentItems(in: url),
              let token = items.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else {
            return nil
        }
        let endpoint = items.first(where: { $0.name == "endpoint" })?.value.flatMap(URL.init(string:))
        let scopes = items.first(where: { $0.name == "scopes" || $0.name == "scope" })?
            .value
            .flatMap(Int.init)
            .map(Scope.init(rawValue:))
        let instanceId = items.first(where: { $0.name == "instance" || $0.name == "instanceId" })?
            .value
            .flatMap(UUID.init(uuidString:))
        let relay = items.first(where: { $0.name == "relay" })?.value.flatMap(URL.init(string:))
        return Payload(token: token, endpoint: endpoint, scopes: scopes, instanceId: instanceId, relay: relay)
    }

    private static func fragmentItems(in url: URL) -> [URLQueryItem]? {
        let scheme = url.scheme?.lowercased() ?? ""
        let isCustomPairing = acceptedCustomSchemes.contains(scheme) && url.host == host
        let isHostedPairing = scheme == "https"
            && url.host?.lowercased() == hostedOrigin.host
            && url.path == "/pair"
            && url.port == nil
        guard isCustomPairing || isHostedPairing,
              let fragment = url.fragment,
              !fragment.isEmpty else {
            return nil
        }
        return URLComponents(string: "?\(fragment)")?.queryItems
    }

    private static let acceptedCustomSchemes = Set([scheme, legacyScheme])
}
