import Foundation

/// Resolves the flag for the minimal zone chrome overlay.
///
/// Default is on so each zone surfaces its header + agent/QA rollup.
/// Users can disable the overlay with:
///
///     defaults write dev.arrayapp.macos continuum.zoneChrome.enabled -bool false
public enum ZoneChromeFeature: Sendable {
    public static let userDefaultsKey = "continuum.zoneChrome.enabled"

    public static var current: Bool {
        resolvedFromDefaults().isEnabled
    }

    public static func resolvedFromDefaults(
        standardDefaults: UserDefaults = .standard,
        legacyDefaults: UserDefaults? = UserDefaults(suiteName: DeleteConfirmPolicy.legacyDefaultsDomain)
    ) -> ZoneChromeFeatureResolution {
        if standardDefaults.object(forKey: userDefaultsKey) != nil {
            return ZoneChromeFeatureResolution(
                isEnabled: standardDefaults.bool(forKey: userDefaultsKey),
                source: .standardDomain
            )
        }

        if let legacyDefaults, legacyDefaults.object(forKey: userDefaultsKey) != nil {
            let value = legacyDefaults.bool(forKey: userDefaultsKey)
            standardDefaults.set(value, forKey: userDefaultsKey)
            return ZoneChromeFeatureResolution(isEnabled: value, source: .legacyDomainMigrated)
        }

        return ZoneChromeFeatureResolution(isEnabled: true, source: .fallbackDefault)
    }
}

public struct ZoneChromeFeatureResolution: Equatable, Sendable {
    public enum Source: String, Sendable {
        case standardDomain = "standard-domain"
        case legacyDomainMigrated = "legacy-domain-migrated"
        case fallbackDefault = "fallback-default"
    }

    public let isEnabled: Bool
    public let source: Source

    public init(isEnabled: Bool, source: Source) {
        self.isEnabled = isEnabled
        self.source = source
    }
}
