import Foundation

public enum BrowserCredentialDecision: String, Equatable, Sendable {
    case allow
    case confirm
    case deny
}

public struct BrowserCredentialPolicy: Equatable, Sendable {
    public var publicHTTPFill: BrowserCredentialDecision
    public var loopbackHTTPExceptionEnabled: Bool

    public init(
        publicHTTPFill: BrowserCredentialDecision = .deny,
        loopbackHTTPExceptionEnabled: Bool = false
    ) {
        self.publicHTTPFill = publicHTTPFill
        self.loopbackHTTPExceptionEnabled = loopbackHTTPExceptionEnabled
    }

    public static let `default` = BrowserCredentialPolicy()
}

public struct CredentialOrigin: Equatable, Sendable {
    public var scheme: String
    public var host: String
    public var port: Int?

    public init(scheme: String, host: String, port: Int? = nil) {
        let canonicalScheme = scheme.lowercased()
        self.scheme = canonicalScheme
        self.host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self.port = CredentialOriginMatcher.canonicalPort(forScheme: canonicalScheme, explicitPort: port)
    }
}

public enum CredentialOriginMatcher {
    public static func fillDecision(
        savedOrigin: CredentialOrigin,
        documentOrigin: CredentialOrigin,
        frameOrigin: CredentialOrigin? = nil,
        formActionOrigin: CredentialOrigin? = nil,
        policy: BrowserCredentialPolicy = .default
    ) -> BrowserCredentialDecision {
        guard isValidOrigin(savedOrigin), isValidOrigin(documentOrigin), isSameOrigin(savedOrigin, documentOrigin) else { return .deny }
        if let frameOrigin {
            guard isValidOrigin(frameOrigin), isSameOrigin(documentOrigin, frameOrigin) else { return .deny }
        }
        if let formActionOrigin {
            guard isValidOrigin(formActionOrigin), isSameOrigin(documentOrigin, formActionOrigin) else { return .deny }
        }

        if documentOrigin.scheme == "https" {
            return .allow
        }

        if documentOrigin.scheme == "http" {
            guard policy.loopbackHTTPExceptionEnabled,
                  isLoopbackHost(documentOrigin.host),
                  isLoopbackHost(savedOrigin.host),
                  savedOrigin.port == documentOrigin.port else {
                return .deny
            }
            return .allow
        }

        return .deny
    }

    public static func isSameOrigin(_ lhs: CredentialOrigin, _ rhs: CredentialOrigin) -> Bool {
        lhs.scheme == rhs.scheme && lhs.host == rhs.host && lhs.port == rhs.port
    }

    public static func canonicalPort(forScheme scheme: String, explicitPort: Int?) -> Int? {
        if let explicitPort { return explicitPort }
        switch scheme.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    public static func isValidPort(_ port: Int?) -> Bool {
        guard let port else { return true }
        return (1...65_535).contains(port)
    }

    public static func isValidOrigin(_ origin: CredentialOrigin) -> Bool {
        !origin.scheme.isEmpty && !origin.host.isEmpty && isValidPort(origin.port)
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized == "localhost" || normalized == "::1" { return true }
        let parts = normalized.split(separator: ".")
        guard parts.count == 4,
              let first = Int(parts[0]), first == 127 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }
}
