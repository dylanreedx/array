import Foundation

/// Resolves the URL used when spawning a browser tile without an explicit URL.
/// Persisted via UserDefaults so users can override the product-safe default:
///
///     defaults write dev.arrayapp.macos continuum.defaultBrowserURL https://example.com
///
/// Invalid or empty values fall back to `about:blank` rather than launching an
/// arbitrary development server.
public enum DefaultBrowserURL: Sendable {
    public static let userDefaultsKey = "continuum.defaultBrowserURL"
    public static let fallback = "about:blank"

    public static var current: String {
        resolvedFromDefaults().url
    }

    public static func resolvedFromDefaults(
        standardDefaults: UserDefaults = .standard,
        legacyDefaults: UserDefaults? = UserDefaults(suiteName: DeleteConfirmPolicy.legacyDefaultsDomain)
    ) -> DefaultBrowserURLResolution {
        if let raw = standardDefaults.string(forKey: userDefaultsKey) {
            return resolution(for: raw, source: .standardDomain)
        }

        if let raw = legacyDefaults?.string(forKey: userDefaultsKey), isValidBrowserURL(raw) {
            standardDefaults.set(raw, forKey: userDefaultsKey)
            return DefaultBrowserURLResolution(url: raw, rawValue: raw, source: .legacyDomainMigrated)
        }

        return DefaultBrowserURLResolution(url: fallback, rawValue: nil, source: .fallbackDefault)
    }

    private static func resolution(for raw: String, source: DefaultBrowserURLResolution.Source) -> DefaultBrowserURLResolution {
        DefaultBrowserURLResolution(
            url: isValidBrowserURL(raw) ? raw : fallback,
            rawValue: raw,
            source: source
        )
    }

    private static func isValidBrowserURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == raw, let url = URL(string: raw) else { return false }
        if raw == fallback { return true }
        return url.scheme != nil
    }
}

public struct DefaultBrowserURLResolution: Equatable, Sendable {
    public enum Source: String, Sendable {
        case standardDomain = "standard-domain"
        case legacyDomainMigrated = "legacy-domain-migrated"
        case fallbackDefault = "fallback-default"
    }

    public let url: String
    public let rawValue: String?
    public let source: Source

    public init(url: String, rawValue: String?, source: Source) {
        self.url = url
        self.rawValue = rawValue
        self.source = source
    }
}
