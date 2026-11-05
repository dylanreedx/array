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
        if CredentialOriginMatcher.isLoopbackHost(dnsHost) || dnsHost.hasSuffix(".localhost") || isPrivateAddress(dnsHost) {
            return .local
        }
        return .approvalRequired(host: dnsHost)
    }
    private static func isPrivateAddress(_ host: String) -> Bool {
        if host == "0.0.0.0" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) {
            let bytes = parts.compactMap { UInt8($0) }
            return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
        }
        // Unique local and link-local IPv6 literals, never DNS names.
        guard host.contains(":"), let first = host.split(separator: ":").first,
              let prefix = UInt16(first, radix: 16) else { return false }
        return prefix & 0xfe00 == 0xfc00 || prefix & 0xffc0 == 0xfe80
    }
}
