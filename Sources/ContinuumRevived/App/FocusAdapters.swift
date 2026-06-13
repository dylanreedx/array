import AppKit
import ContinuumRevivedCore

@MainActor
extension CanvasNSView: FocusSurfaceAdapter {
    var focusSurfaceID: FocusSurfaceID { .canvas }
    var focusSurfaceKind: FocusSurfaceKind { .canvas }

    func acquireFocus(reason: FocusRequest) -> Bool {
        window?.makeFirstResponder(self)
        return true
    }

    func releaseFocus(reason: FocusRequest) {}
    func canHandleReservedShortcut(_ shortcut: ReservedShortcut) -> Bool { false }
}

@MainActor
extension TileNSView: FocusSurfaceAdapter {
    var focusSurfaceID: FocusSurfaceID { .tile(tile.id) }

    var focusSurfaceKind: FocusSurfaceKind {
        switch tile.kind {
        case .terminal: return .terminal
        case .browser: return .browser
        case .note: return .note
        case .file: return .file
        case .fileTree: return .fileTree
        case .ticketQueue: return .ticketQueue
        }
    }

}

