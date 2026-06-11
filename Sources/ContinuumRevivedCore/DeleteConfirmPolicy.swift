import Foundation

/// Controls whether tile delete actions present a confirmation alert before
/// destroying the tile. Persisted via UserDefaults so the user can change the
/// behavior without restarting the app:
///
///     defaults write com.continuum.revived continuum.deleteConfirmPolicy never
///     defaults write com.continuum.revived continuum.deleteConfirmPolicy runtimes
///     defaults write com.continuum.revived continuum.deleteConfirmPolicy always
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

    public static var current: DeleteConfirmPolicy {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? "runtimes"
        return DeleteConfirmPolicy(rawValue: raw) ?? .runtimes
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
