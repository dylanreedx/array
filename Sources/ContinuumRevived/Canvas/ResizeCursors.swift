import AppKit
import ContinuumRevivedCore

/// The cursor a resize handle shows. Edges keep the stock left/right and
/// up/down cursors; corners get the system diagonal frame-resize cursor
/// (public since macOS 15). Before that there is no public diagonal cursor,
/// so corners fall back to the vertical one.
enum ResizeCursors {
    static func cursor(for edge: ResizeEdge) -> NSCursor {
        switch edge {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft: return corner(.topLeft)
        case .topRight: return corner(.topRight)
        case .bottomLeft: return corner(.bottomLeft)
        case .bottomRight: return corner(.bottomRight)
        }
    }

    private static func corner(_ position: CornerPosition) -> NSCursor {
        if #available(macOS 15.0, *) {
            switch position {
            case .topLeft: return .frameResize(position: .topLeft, directions: .all)
            case .topRight: return .frameResize(position: .topRight, directions: .all)
            case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
            case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
            }
        }
        return .resizeUpDown
    }

    private enum CornerPosition { case topLeft, topRight, bottomLeft, bottomRight }
}
