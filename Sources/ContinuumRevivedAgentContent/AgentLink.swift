import Foundation

/// The activation decision for a semantic link destination. This is pure policy:
/// renderers must re-evaluate it at activation time rather than treating a
/// parsed link as authorization.
public enum AgentLinkDisposition: String, Codable, Equatable, Sendable {
    case openExternally
    case openInternally
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

        // Relative and absolute local paths remain useful transcript text, but
        // the content layer neither resolves nor authorizes them.
        if isLocalPath(destination) { return .displayOnly }
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
            return .displayOnly
        default:
            // Unknown/custom schemes are visible and copyable, but require an
            // explicit future policy addition before they can activate.
            return .displayOnly
        }
    }

    private static func isLocalPath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../") ||
            value.hasPrefix("~/") || value.hasPrefix("\\\\") ||
            (value.count >= 3 && value[value.index(after: value.startIndex)] == ":" &&
                (value[value.index(value.startIndex, offsetBy: 2)] == "\\" ||
                 value[value.index(value.startIndex, offsetBy: 2)] == "/"))
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
