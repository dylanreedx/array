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

    public static func issue(credential: String, scopes: Scope) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.fragment = "token=\(credential)&scopes=\(scopes.rawValue)"
        assert(components.queryItems == nil)
        return components.url!
    }

    public static func parse(_ url: URL) -> String? {
        guard url.scheme == scheme,
              url.host == host,
              let fragment = url.fragment,
              !fragment.isEmpty else {
            return nil
        }
        return URLComponents(string: "?\(fragment)")?
            .queryItems?
            .first(where: { $0.name == "token" })?
            .value
    }
}
