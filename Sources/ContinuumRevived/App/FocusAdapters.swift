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
        case .browserInspector: return .browserInspector
        case .note: return .note
        case .file: return .file
        case .fileTree: return .fileTree
        case .ticketQueue: return .ticketQueue
        case .conductorQueue: return .conductorQueue
        case .diffReview: return .diffReview
        case .runArtifacts: return .runArtifacts
        case .managedAgent: return .managedAgent
        }
    }

}
