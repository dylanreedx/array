import Foundation

/// Controls whether tile delete actions present a confirmation alert before
/// destroying the tile. Persisted via UserDefaults so the user can change the
/// behavior without restarting the app:
///
///     defaults write dev.arrayapp.macos continuum.deleteConfirmPolicy never
///     defaults write dev.arrayapp.macos continuum.deleteConfirmPolicy runtimes
///     defaults write dev.arrayapp.macos continuum.deleteConfirmPolicy always
///
/// Default `.runtimes` confirms only `.terminal` and `.browser` tiles, where a
/// running PTY or WKWebView session may be lost. Notes/files/file-tree tiles
/// delete instantly because their state is on disk and recoverable from
/// version control.
public enum DeleteConfirmPolicy: String, Sendable {
    case never
    case runtimes
    case always

    public static let userDefaultsKey = "continuum.deleteConfirmPolicy"
    public static let bundledDefaultsDomain = "dev.arrayapp.macos"
    public static let legacyDefaultsDomain = "continuum-revived"

    public static var current: DeleteConfirmPolicy {
        resolvedFromDefaults().policy
    }

    public static func resolvedFromDefaults(
        standardDefaults: UserDefaults = .standard,
        legacyDefaults: UserDefaults? = UserDefaults(suiteName: legacyDefaultsDomain)
    ) -> DeleteConfirmPolicyResolution {
        if let raw = standardDefaults.string(forKey: userDefaultsKey) {
            return DeleteConfirmPolicyResolution(
                policy: DeleteConfirmPolicy(rawValue: raw) ?? .runtimes,
                rawValue: raw,
                source: .standardDomain
            )
        }

        if let raw = legacyDefaults?.string(forKey: userDefaultsKey),
           let policy = DeleteConfirmPolicy(rawValue: raw) {
            standardDefaults.set(raw, forKey: userDefaultsKey)
            return DeleteConfirmPolicyResolution(
                policy: policy,
                rawValue: raw,
                source: .legacyDomainMigrated
            )
        }

        return DeleteConfirmPolicyResolution(
            policy: .runtimes,
            rawValue: nil,
            source: .fallbackDefault
        )
    }

    public func requiresConfirmation(for kind: TileKind) -> Bool {
        switch self {
        case .never: return false
        case .always: return true
        case .runtimes: return kind == .terminal || kind == .browser
        }
    }

    public func alertConfiguration(for kind: TileKind) -> DeleteConfirmAlertConfiguration {
        let informative: String
        switch kind {
        case .terminal:
            informative = "The running session will be terminated."
        case .browser:
            informative = "The browser process and any unsaved page state will be lost."
        case .browserInspector:
            informative = "The linked inspector view will be closed."
        default:
            informative = "This action cannot be undone."
        }

        return DeleteConfirmAlertConfiguration(
            message: "Delete this \(kind.rawValue) tile?",
            informative: informative,
            buttonTitles: ["Cancel", "Delete"],
            cancelKeyEquivalent: "\r",
            destructiveKeyEquivalent: "",
            destructiveIndex: 1,
            defaultIsCancel: true
        )
    }
}

public struct DeleteConfirmPolicyResolution: Equatable, Sendable {
    public enum Source: String, Sendable {
        case standardDomain = "standard-domain"
        case legacyDomainMigrated = "legacy-domain-migrated"
        case fallbackDefault = "fallback-default"
    }

    public let policy: DeleteConfirmPolicy
    public let rawValue: String?
    public let source: Source
}

public struct DeleteConfirmAlertConfiguration: Equatable, Sendable {
    public let message: String
    public let informative: String
    public let buttonTitles: [String]
    public let cancelKeyEquivalent: String
    public let destructiveKeyEquivalent: String
    /// Zero-based index in the rendered alert button list.
    public let destructiveIndex: Int
    public let defaultIsCancel: Bool

    public init(
        message: String,
        informative: String,
        buttonTitles: [String],
        cancelKeyEquivalent: String,
        destructiveKeyEquivalent: String,
        destructiveIndex: Int,
        defaultIsCancel: Bool
    ) {
        self.message = message
        self.informative = informative
        self.buttonTitles = buttonTitles
        self.cancelKeyEquivalent = cancelKeyEquivalent
        self.destructiveKeyEquivalent = destructiveKeyEquivalent
        self.destructiveIndex = destructiveIndex
        self.defaultIsCancel = defaultIsCancel
    }
}
