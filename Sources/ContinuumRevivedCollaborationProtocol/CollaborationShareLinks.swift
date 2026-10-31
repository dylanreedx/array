import Foundation

/// Bearer share links (IN-CANVAS.md, Round 2). The slug is a readable name and
/// is not a secret; the token in the URL fragment is what admits. Whoever holds
/// a valid token joins the area as an editor.
extension Collaboration {
    public enum ShareLinkLifetime: String, Codable, Sendable, CaseIterable {
        /// "Works once": spent by the first accept.
        case once
        /// "Until revoked": reusable until the owner revokes it.
        case untilRevoked
    }
    public struct ShareLinkRequest: Codable, Sendable {
        public let slug: String
        public let lifetime: ShareLinkLifetime
        public init(slug: String, lifetime: ShareLinkLifetime) { self.slug = slug; self.lifetime = lifetime }
    }
    /// Returned once, when the link is created. It is the only value that holds
    /// the token; the service keeps only its hash.
    public struct ShareLink: Codable, Equatable, Sendable {
        public let id: UUID
        public let area: SharedArea.ID<SharedArea.Area>
        public let slug: String
        public let token: String
        public let lifetime: ShareLinkLifetime
        public let createdAt: Date
        public init(id: UUID, area: SharedArea.ID<SharedArea.Area>, slug: String, token: String,
                    lifetime: ShareLinkLifetime, createdAt: Date) {
            self.id = id; self.area = area; self.slug = slug; self.token = token
            self.lifetime = lifetime; self.createdAt = createdAt
        }
        /// What Copy link copies.
        public var url: URL { ShareLinkURL.web(slug: slug, token: token) }
        public var appURL: URL { ShareLinkURL.app(slug: slug, token: token) }
    }
    public struct AcceptShareLink: Codable, Sendable {
        public let slug: String
        public let token: String
        public init(slug: String, token: String) { self.slug = slug; self.token = token }
    }
    public struct ShareLinkPerson: Codable, Equatable, Sendable {
        public let person: SharedArea.ID<SharedArea.Person>
        public let label: String
        public let admittedAt: Date
        /// False once the person was removed or the link was revoked.
        public let active: Bool
        public init(person: SharedArea.ID<SharedArea.Person>, label: String, admittedAt: Date, active: Bool) {
            self.person = person; self.label = label; self.admittedAt = admittedAt; self.active = active
        }
    }
    /// One row of the sharing popover. Never carries the token.
    public struct ShareLinkAccess: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable { case active, used, revoked }
        public let id: UUID
        public let area: SharedArea.ID<SharedArea.Area>
        public let slug: String
        public let lifetime: ShareLinkLifetime
        public let status: Status
        public let createdAt: Date
        public let people: [ShareLinkPerson]
        public init(id: UUID, area: SharedArea.ID<SharedArea.Area>, slug: String, lifetime: ShareLinkLifetime,
                    status: Status, createdAt: Date, people: [ShareLinkPerson]) {
            self.id = id; self.area = area; self.slug = slug; self.lifetime = lifetime
            self.status = status; self.createdAt = createdAt; self.people = people
        }
    }
}

/// `https://arrayapp.dev/s/<slug>#<token>` and `array://s/<slug>#<token>`.
public enum ShareLinkURL {
    public static let webHost = "arrayapp.dev"
    public static let appScheme = "array"
    /// The fixed part of the popover's link field.
    public static let webPrefix = "arrayapp.dev/s/"

    /// Lowercase letters, digits and single inner hyphens, 1-64 characters.
    public static func isValidSlug(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count), !value.hasPrefix("-"), !value.hasSuffix("-"),
              !value.contains("--") else { return false }
        return value.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
    /// "Map the checkout state machine" -> "map-the-checkout-state-machine".
    public static func suggestedSlug(from title: String) -> String {
        var slug = ""
        for scalar in title.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) { slug.unicodeScalars.append(scalar) }
            else if !slug.isEmpty, !slug.hasSuffix("-") { slug.append("-") }
            if slug.utf8.count >= 64 { break }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "shared" : slug
    }
    /// 32 random bytes, base64url without padding: safe in a URL fragment.
    public static func isValidToken(_ value: String) -> Bool {
        (16...128).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }
    public static func web(slug: String, token: String) -> URL {
        URL(string: "https://\(webHost)/s/\(slug)#\(token)")!
    }
    public static func app(slug: String, token: String) -> URL {
        URL(string: "\(appScheme)://s/\(slug)#\(token)")!
    }
    /// Both forms, nothing else. Returns nil for a link without a usable slug
    /// or token rather than guessing.
    public static func parse(_ url: URL) -> (slug: String, token: String)? {
        let path: [String]
        switch url.scheme?.lowercased() {
        case appScheme?:
            guard url.host?.lowercased() == "s" else { return nil }
            path = url.path.split(separator: "/").map(String.init)
        case "https"?:
            guard let host = url.host?.lowercased(), host == webHost || host == "www." + webHost else { return nil }
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.first == "s" else { return nil }
            path = Array(parts.dropFirst())
        default: return nil
        }
        guard path.count == 1, let token = url.fragment, isValidSlug(path[0]), isValidToken(token) else { return nil }
        return (path[0], token)
    }
}
