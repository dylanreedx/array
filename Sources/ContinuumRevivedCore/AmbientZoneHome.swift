import Foundation

/// Resolves the root directory used when creating a group (ambient) zone — a zone
/// with no project (`projectId == nil`). Persisted via UserDefaults so users can
/// configure a home directory other than `$HOME`:
///
///     defaults write com.continuum.revived continuum.ambientZoneHome /Users/dylan/Projects
///
/// Empty, whitespace-only, or non-existent directory overrides fall back to
/// `$HOME` so a typo can never root an ambient zone at a bogus path.
public enum AmbientZoneHome: Sendable {
    public static let userDefaultsKey = "continuum.ambientZoneHome"
    public static var fallback: String { NSHomeDirectory() }

    public static var current: String {
        resolvedFromDefaults().path
    }

    public static func resolvedFromDefaults(
        standardDefaults: UserDefaults = .standard,
        directoryExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    ) -> AmbientZoneHomeResolution {
        guard let raw = standardDefaults.string(forKey: userDefaultsKey) else {
            return AmbientZoneHomeResolution(path: fallback, rawValue: nil, source: .fallbackDefault)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard !trimmed.isEmpty,
              expanded.hasPrefix("/"),
              directoryExists(expanded) else {
            return AmbientZoneHomeResolution(path: fallback, rawValue: raw, source: .fallbackDefault)
        }
        let normalized = URL(fileURLWithPath: expanded, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return AmbientZoneHomeResolution(path: normalized, rawValue: raw, source: .standardDomain)
    }
}

public struct AmbientZoneHomeResolution: Equatable, Sendable {
    public enum Source: String, Sendable {
        case standardDomain = "standard-domain"
        case fallbackDefault = "fallback-default"
    }

    public let path: String
    public let rawValue: String?
    public let source: Source

    public init(path: String, rawValue: String?, source: Source) {
        self.path = path
        self.rawValue = rawValue
        self.source = source
    }
}
