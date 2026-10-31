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
    /// the token; the service keeps only its hash. `relay` is filled in by the
    /// creating client from its own endpoint, since a relay does not know the
    /// origin it is reached through.
    public struct ShareLink: Codable, Equatable, Sendable {
        public let id: UUID
        public let area: SharedArea.ID<SharedArea.Area>
        public let slug: String
        public let token: String
        public let lifetime: ShareLinkLifetime
        public let createdAt: Date
        public let relay: String?
        public init(id: UUID, area: SharedArea.ID<SharedArea.Area>, slug: String, token: String,
                    lifetime: ShareLinkLifetime, createdAt: Date, relay: String? = nil) {
            self.id = id; self.area = area; self.slug = slug; self.token = token
            self.lifetime = lifetime; self.createdAt = createdAt; self.relay = relay
        }
        public func with(relay: String) -> ShareLink {
            .init(id: id, area: area, slug: slug, token: token, lifetime: lifetime, createdAt: createdAt, relay: relay)
        }
        /// What Copy link copies.
        public var url: URL { ShareLinkURL.web(slug: slug, token: token, relay: relay) }
        public var appURL: URL { ShareLinkURL.app(slug: slug, token: token, relay: relay) }
    }
    /// A valid link token doubles as an enrollment: a person with no account
    /// on the relay joins with a display name and gets a device credential.
    public struct JoinShareLink: Codable, Sendable {
        public let slug: String
        public let token: String
        public let displayName: String
        public let deviceLabel: String
        public init(slug: String, token: String, displayName: String, deviceLabel: String) {
            self.slug = slug; self.token = token; self.displayName = displayName; self.deviceLabel = deviceLabel
        }
    }
    public struct ShareLinkJoin: Codable, Sendable {
        public let credential: Credential
        public let scope: Scope
        public init(credential: Credential, scope: Scope) { self.credential = credential; self.scope = scope }
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

/// `https://arrayapp.dev/s/<slug>?r=<relay>#<token>` and
/// `array://s/<slug>?r=<relay>#<token>`. `r` is the relay's host (and port or
/// path, if any) without its scheme; a link without it falls back to the
/// receiver's own relay account.
public enum ShareLinkURL {
    public static let webHost = "arrayapp.dev"
    /// Prod answers `array://`; Dev builds register `array-dev://` instead.
    public static let appScheme = "array"
    public static let devAppScheme = "array-dev"
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
    /// A relay host with an optional port and path. The client still builds a
    /// checked endpoint from it before any request.
    public static func isValidRelay(_ value: String) -> Bool {
        (1...300).contains(value.utf8.count) && value.first != "/" && value.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || ".-:/_[]".unicodeScalars.contains($0)
        }
    }
    public static func web(slug: String, token: String, relay: String? = nil) -> URL {
        build(scheme: "https", host: webHost, path: "/s/\(slug)", relay: relay, token: token)
    }
    public static func app(slug: String, token: String, relay: String? = nil, scheme: String = appScheme) -> URL {
        build(scheme: scheme, host: "s", path: "/\(slug)", relay: relay, token: token)
    }
    private static func build(scheme: String, host: String, path: String, relay: String?, token: String) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme; parts.host = host; parts.path = path
        if let relay { parts.queryItems = [URLQueryItem(name: "r", value: relay)] }
        parts.fragment = token
        return parts.url!
    }
    /// Both forms, both app schemes, nothing else. Returns nil for a link
    /// without a usable slug or token rather than guessing.
    public static func parse(_ url: URL) -> (slug: String, token: String, relay: String?)? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path: [String]
        switch parts.scheme?.lowercased() {
        case appScheme?, devAppScheme?:
            guard parts.host?.lowercased() == "s" else { return nil }
            path = parts.path.split(separator: "/").map(String.init)
        case "https"?:
            guard let host = parts.host?.lowercased(), host == webHost || host == "www." + webHost else { return nil }
            let segments = parts.path.split(separator: "/").map(String.init)
            guard segments.first == "s" else { return nil }
            path = Array(segments.dropFirst())
        default: return nil
        }
        let relays = (parts.queryItems ?? []).filter { $0.name == "r" }
        guard path.count == 1, let token = parts.fragment, isValidSlug(path[0]), isValidToken(token), relays.count <= 1 else { return nil }
        let relay = relays.first?.value
        if let relay, !isValidRelay(relay) { return nil }
        return (path[0], token, relay)
    }
}
