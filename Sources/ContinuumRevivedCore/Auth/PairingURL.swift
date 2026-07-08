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
    public static let scheme = "continuum"
    public static let host = "pair"

    public struct Payload: Equatable, Sendable {
        public var token: String
        public var endpoint: URL?
        public var scopes: Scope?
        public var instanceId: UUID?

        public init(token: String, endpoint: URL?, scopes: Scope?, instanceId: UUID?) {
            self.token = token
            self.endpoint = endpoint
            self.scopes = scopes
            self.instanceId = instanceId
        }
    }

    public static func issue(credential: String, scopes: Scope, instanceId: UUID? = nil, endpoint: URL? = nil) -> URL {
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
        var fragmentComponents = URLComponents()
        fragmentComponents.queryItems = fragmentItems
        components.fragment = String(fragmentComponents.url!.absoluteString.dropFirst())
        assert(components.queryItems == nil)
        return components.url!
    }

    public static func parse(_ url: URL) -> String? {
        fragmentItems(in: url)?
            .first(where: { $0.name == "token" })?
            .value
    }

    public static func parsePayload(_ url: URL) -> Payload? {
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
        return Payload(token: token, endpoint: endpoint, scopes: scopes, instanceId: instanceId)
    }

    private static func fragmentItems(in url: URL) -> [URLQueryItem]? {
        guard url.scheme == scheme,
              url.host == host,
              let fragment = url.fragment,
              !fragment.isEmpty else {
            return nil
        }
        return URLComponents(string: "?\(fragment)")?.queryItems
    }
}
