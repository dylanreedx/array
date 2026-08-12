import Foundation

/// The activation decision for a semantic link destination. This is pure policy:
/// renderers must re-evaluate it at activation time rather than treating a
/// parsed link as authorization.
public enum AgentLinkDisposition: String, Codable, Equatable, Sendable {
    case openExternally
    case openInternally
    /// A destination *shaped* like a file in the responding agent's checkout.
    /// This grants nothing on its own: the host still resolves it against that
    /// agent's live working directory and enforces containment before anything
    /// opens (`AgentLocalFileLinkResolver`).
    case openLocalFile
    case displayOnly
    case reject
}

/// Platform-neutral link activation policy. It classifies authored text only;
/// it never resolves a destination against a working directory.
public enum AgentLinkPolicy {
    public static func disposition(for destination: String) -> AgentLinkDisposition {
        guard !destination.isEmpty,
              destination == destination.trimmingCharacters(in: .whitespacesAndNewlines),
              !destination.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !destination.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
        else { return .reject }

        // A Windows path is readable text on macOS and nothing else.
        if AgentLocalFileDestination.isForeignPlatformPath(destination) { return .displayOnly }

        // Local paths and local `file:` URLs are candidates for host resolution.
        // The content layer still neither resolves nor authorizes them.
        if AgentLocalFileDestination.isCandidate(destination) { return .openLocalFile }
        guard hasValidPercentEncoding(destination) else { return .reject }

        guard let components = URLComponents(string: destination) else { return .reject }
        guard let rawScheme = components.scheme else { return .displayOnly }
        let scheme = rawScheme.lowercased()

        switch scheme {
        case "http", "https":
            guard let host = components.host, !host.isEmpty else { return .reject }
            return .openExternally
        case "mailto":
            guard !components.path.isEmpty else { return .reject }
            return .openExternally
        case "continuum":
            guard components.host?.isEmpty == false || !components.path.isEmpty else { return .reject }
            return .openInternally
        case "javascript", "data":
            return .displayOnly
        case "file":
            // Reached only when `isCandidate` rejected it: a remote authority,
            // credentials, a query, or an empty path.
            return .displayOnly
        default:
            // Unknown/custom schemes are visible and copyable, but require an
            // explicit future policy addition before they can activate.
            return .displayOnly
        }
    }

    private static func hasValidPercentEncoding(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x25 else { index += 1; continue }
            guard index + 2 < bytes.count,
                  isHexDigit(bytes[index + 1]), isHexDigit(bytes[index + 2])
            else { return false }
            index += 3
        }
        return true
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}

/// The syntactic half of local-file link classification: shape only, no
/// filesystem, no working directory. `AgentLocalFileLinkResolver` (Core) owns the
/// resolving half.
public enum AgentLocalFileDestination {
    /// True when `destination` is *shaped* like a local file an agent could be
    /// pointing at. Says nothing about whether it exists or is reachable.
    public static func isCandidate(_ destination: String) -> Bool {
        guard !destination.isEmpty,
              destination == destination.trimmingCharacters(in: .whitespacesAndNewlines),
              !destination.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !destination.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
        else { return false }

        if hasFileScheme(destination) {
            guard let url = URL(string: destination),
                  url.user == nil, url.password == nil, url.query == nil,
                  isLocalFileHost(url.host), !url.path.isEmpty
            else { return false }
            return true
        }

        if isForeignPlatformPath(destination) { return false }

        // Any other explicit scheme belongs to someone else's policy. A scheme
        // never contains a dot, which is what separates `data:x` from the
        // authored coordinate form `App.swift:42`.
        if let colon = destination.firstIndex(of: ":") {
            let head = String(destination[destination.startIndex..<colon])
            if looksLikeScheme(head), !head.contains(".") { return false }
        }
        if destination.hasPrefix("//") { return false }
        if destination.hasPrefix("#") { return false }
        // `~` is a shell convenience, not a checkout-relative path.
        if destination.hasPrefix("~") { return false }

        if destination.hasPrefix("/") { return true }
        if destination.hasPrefix("./") || destination.hasPrefix("../") { return true }
        if destination.contains("/") { return true }
        // A bare word ("readme") stays prose; `App.swift:42` does not.
        let path = splitNavigation(destination).path
        return path.contains(".") && !path.hasPrefix(".") && !path.hasSuffix(".")
    }

    /// Splits authored `path:line:column` / `path#L42C8` navigation metadata from
    /// the path itself. Pure string work: it never touches the filesystem, so a
    /// filename that genuinely ends in `:2` is only misread when that suffix is
    /// also a valid coordinate — the same ambiguity every editor accepts.
    public static func splitNavigation(_ destination: String) -> (path: String, line: Int?, column: Int?) {
        // `#L42` / `#L42C8` — the GitHub-style fragment form.
        if let hashIndex = destination.lastIndex(of: "#") {
            let fragment = String(destination[destination.index(after: hashIndex)...])
            let head = String(destination[destination.startIndex..<hashIndex])
            if !head.isEmpty, let coordinate = parseFragmentCoordinate(fragment) {
                return (head, coordinate.line, coordinate.column)
            }
        }

        // `path:line[:column]` — trailing all-digit segments only.
        var path = destination
        var trailing: [Int] = []
        while trailing.count < 2, let colonIndex = path.lastIndex(of: ":") {
            let candidate = String(path[path.index(after: colonIndex)...])
            guard !candidate.isEmpty,
                  candidate.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(candidate), value > 0
            else { break }
            let remainder = String(path[path.startIndex..<colonIndex])
            // `file:` and a `C:` drive letter are not coordinates.
            guard !remainder.isEmpty, !remainder.hasSuffix(":") else { break }
            trailing.insert(value, at: 0)
            path = remainder
        }
        guard !path.isEmpty else { return (destination, nil, nil) }
        switch trailing.count {
        case 2: return (path, trailing[0], trailing[1])
        case 1: return (path, trailing[0], nil)
        default: return (path, nil, nil)
        }
    }

    public static func hasFileScheme(_ value: String) -> Bool {
        value.lowercased().hasPrefix("file:")
    }

    /// A UNC share or a `C:\` drive path: displayable text, never a local file
    /// this host can resolve.
    public static func isForeignPlatformPath(_ value: String) -> Bool {
        if value.hasPrefix("\\\\") { return true }
        let characters = Array(value)
        guard characters.count >= 3, characters[1] == ":" else { return false }
        return characters[0].isLetter && (characters[2] == "\\" || characters[2] == "/")
    }

    /// Only this machine. `file://host/share/x` is another computer's filesystem.
    public static func isLocalFileHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return true }
        return host.lowercased() == "localhost"
    }

    private static func parseFragmentCoordinate(_ fragment: String) -> (line: Int, column: Int?)? {
        guard fragment.hasPrefix("L") || fragment.hasPrefix("l") else { return nil }
        let body = String(fragment.dropFirst())
        let parts = body.split(separator: "C", omittingEmptySubsequences: false)
        guard let lineText = parts.first, let line = Int(lineText), line > 0 else { return nil }
        switch parts.count {
        case 1:
            return (line, nil)
        case 2:
            guard let column = Int(parts[1]), column > 0 else { return nil }
            return (line, column)
        default:
            return nil
        }
    }

    private static func looksLikeScheme(_ value: String) -> Bool {
        guard let first = value.first, first.isLetter else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }
}
