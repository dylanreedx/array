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
        self.scheme = scheme.lowercased()
        self.host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self.port = port
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
        guard isSameOrigin(savedOrigin, documentOrigin) else { return .deny }
        if let frameOrigin, !isSameOrigin(documentOrigin, frameOrigin) { return .deny }
        if let formActionOrigin, !isSameOrigin(documentOrigin, formActionOrigin) { return .deny }

        if documentOrigin.scheme == "https" {
            return .allow
        }

        if documentOrigin.scheme == "http" {
            guard policy.loopbackHTTPExceptionEnabled,
                  policy.publicHTTPFill == .allow,
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

    public static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized == "localhost" || normalized == "::1" { return true }
        let parts = normalized.split(separator: ".")
        guard parts.count == 4, let first = Int(parts[0]) else { return false }
        return first == 127 && parts.allSatisfy { Int($0) != nil }
    }
}
