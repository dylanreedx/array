import Foundation

/// Explicit failures keep a board-library action from silently creating a
/// duplicate when its existing canvas location cannot be presented.
enum BoardLibraryError: LocalizedError {
    case unavailable
    case multipleTiles
    case navigationBlocked
    case locationUnavailable
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "That board could not be loaded from this project."
        case .multipleTiles: return "This board already has multiple tiles. Close the extra tiles before opening it again."
        case .navigationBlocked: return "Finish editing this board before switching to another board."
        case .locationUnavailable: return "This board is already open, but its workspace or zone could not be opened."
        case let .rollbackFailed(message): return "The board change could not be restored: \(message)"
        }
    }
}
