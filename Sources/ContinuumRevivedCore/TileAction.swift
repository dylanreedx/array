import Foundation

/// A chord that claims a tile-local action. Reuses `NavKeymap.KeyChord`
/// (modifiers + keyCode) so globals, nav, and tile actions share one model.
public typealias TileChord = KeyChord

public enum TileSizePreset: String, Equatable, Sendable {
    case compact
    case `default`
    case large
    case fillViewport
}

public enum TileActionDirection: String, Equatable, Sendable {
    case up
    case down
    case left
    case right
}

/// Tile-local actions dispatched from a focused tile's chord. Flat and
/// extensible: new actions are added as cases plus catalog entries.
public enum TileAction: Equatable, Sendable {
    // Universal — any focused tile.
    case resizeToPreset(TileSizePreset)
    case throwToNeighbor(TileActionDirection)
    // Browser.
    case browserFind
    case browserFocusURL
    case browserReload
    case browserBack
    case browserForward
    // Note.
    case noteExport
}
