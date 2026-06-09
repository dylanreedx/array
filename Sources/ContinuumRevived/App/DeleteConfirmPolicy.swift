import ContinuumRevivedCore
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
enum DeleteConfirmPolicy: String {
    case never
    case runtimes
    case always

    static let userDefaultsKey = "continuum.deleteConfirmPolicy"

    static var current: DeleteConfirmPolicy {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? "runtimes"
        return DeleteConfirmPolicy(rawValue: raw) ?? .runtimes
    }

    func requiresConfirmation(for kind: TileKind) -> Bool {
        switch self {
        case .never: return false
        case .always: return true
        case .runtimes: return kind == .terminal || kind == .browser
        }
    }
}
