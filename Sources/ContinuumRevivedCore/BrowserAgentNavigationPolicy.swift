import Foundation

/// Classifies a browser destination before the host asks for domain approval.
/// This is not a navigation delegate: the host must enforce it on initial
/// requests, redirects and popups before exposing browser automation.
public enum BrowserAgentNavigationPolicy {
    public enum Verdict: Equatable, Sendable {
        case local
        case approvalRequired(host: String)
        case denied
    }
    public static func classify(_ url: URL, checkoutRoot: URL) -> Verdict {
        guard let scheme = url.scheme?.lowercased() else { return .denied }
        if scheme == "about", url.absoluteString.lowercased() == "about:blank" { return .local }
        if scheme == "file" {
            guard url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
                  checkoutRoot.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return .denied }
            let root = checkoutRoot.resolvingSymlinksInPath().standardizedFileURL.path
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return path == root || path.hasPrefix(prefix) ? .local : .denied
        }
        guard scheme == "http" || scheme == "https",
              let rawHost = url.host, !rawHost.isEmpty,
              url.port.map({ (1...65_535).contains($0) }) ?? true else { return .denied }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let dnsHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !dnsHost.isEmpty, !dnsHost.contains("%") else { return .denied }
        if CredentialOriginMatcher.isLoopbackHost(dnsHost) || dnsHost.hasSuffix(".localhost") {
            return .local
        }
        return .approvalRequired(host: dnsHost)
    }
}
