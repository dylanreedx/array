import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
protocol FocusSurfaceAdapter: AnyObject {
    var focusSurfaceID: FocusSurfaceID { get }
    var focusSurfaceKind: FocusSurfaceKind { get }
    func acquireFocus(reason: FocusRequest) -> Bool
    func releaseFocus(reason: FocusRequest)
    func canHandleReservedShortcut(_ shortcut: ReservedShortcut) -> Bool
}

@MainActor
final class FocusBroker {
    private var adapters: [FocusSurfaceID: FocusSurfaceAdapter] = [:]
    private var modalSnapshots: [FocusModalKind: FocusSurfaceID?] = [:]
    private var tileSpawnedDuringModal = false

    var navKeymap: NavKeymap = .default
    private(set) var activeSurface: FocusSurfaceID?
    var onAcceptedTileFocus: ((UUID) -> Void)?
    /// Reason-aware mirror for app-level history. The canvas lockstep hook stays
    /// reason-agnostic; history must be able to ignore modal restores/recovery.
    var onAcceptedTileFocusWithReason: ((UUID, FocusRequest) -> Void)?
    /// Fires whenever scope settles on the canvas (i.e. leaves all tiles).
    /// Mirrors `onAcceptedTileFocus`; lets the canvas clear the focus border
    /// when the scope is no longer a tile (`onAcceptedTileFocus` covers the
    /// tile→tile transition, this covers tile→canvas).
    var onAcceptedCanvasScope: (() -> Void)?
    var activationFallbackSurfaces: (() -> [FocusSurfaceID])?

    func register(_ adapter: FocusSurfaceAdapter) {
        adapters[adapter.focusSurfaceID] = adapter
    }

    func unregister(_ id: FocusSurfaceID) {
        if activeSurface == id {
            adapters[id]?.releaseFocus(reason: .recovery)
            activeSurface = nil
        }
        adapters.removeValue(forKey: id)
    }

    func acceptExistingFocus(_ id: FocusSurfaceID, reason: FocusRequest) {
        guard case .modal = id else {
            guard adapters[id] != nil else { return }
            if let previous = activeSurface, previous != id {
                adapters[previous]?.releaseFocus(reason: reason)
            }
            activeSurface = id
            if case let .tile(tileId) = id {
                notifyAcceptedTileFocus(tileId, reason: reason)
            } else {
                onAcceptedCanvasScope?()
            }
            return
        }
        activeSurface = id
        onAcceptedCanvasScope?()
    }

    @discardableResult
    func requestFocus(_ id: FocusSurfaceID, reason: FocusRequest) -> Bool {
        if reason == .tileSpawned, !modalSnapshots.isEmpty {
            tileSpawnedDuringModal = true
        }

        if case .modal = id {
            activeSurface = id
            onAcceptedCanvasScope?()
            return true
        }

        guard let adapter = adapters[id], adapter.acquireFocus(reason: reason) else {
            return false
        }

        if let previous = activeSurface, previous != id {
            adapters[previous]?.releaseFocus(reason: reason)
        }
        activeSurface = id
        if case let .tile(tileId) = id {
            notifyAcceptedTileFocus(tileId, reason: reason)
        } else {
            onAcceptedCanvasScope?()
        }
        return true
    }

    private func notifyAcceptedTileFocus(_ tileId: UUID, reason: FocusRequest) {
        onAcceptedTileFocus?(tileId)
        onAcceptedTileFocusWithReason?(tileId, reason)
    }

    /// The single funnel for entering a non-modal focus scope. Routes through
    /// the existing `requestFocus`/`acceptExistingFocus` so `activeSurface` is
    /// set exactly as before, and (via `onAcceptedTileFocus`, fired by both of
    /// those for `.tile`) keeps `CanvasState.lastActiveTileId` in lockstep with
    /// `activeSurface` so the scope and the visual/z-order selection can't
    /// drift. `acceptingExisting` skips re-acquiring first responder when the
    /// live responder is already inside the target tile (a content click that
    /// must not steal focus back to the tile root). Modal handling is unchanged.
    @discardableResult
    func enterScope(_ scope: FocusSurfaceID, reason: FocusRequest, acceptingExisting: Bool = false) -> Bool {
        if acceptingExisting {
            acceptExistingFocus(scope, reason: reason)
            return true
        }
        return requestFocus(scope, reason: reason)
    }

    func openModal(_ kind: FocusModalKind) {
        modalSnapshots[kind] = activeSurface
        _ = requestFocus(.modal(kind), reason: .modalOpened)
    }

    func closeModal(_ kind: FocusModalKind) {
        let snapshot = modalSnapshots.removeValue(forKey: kind) ?? nil
        let shouldRestoreSnapshot = !tileSpawnedDuringModal
        if modalSnapshots.isEmpty {
            tileSpawnedDuringModal = false
        }
        guard shouldRestoreSnapshot, let snapshot else { return }
        _ = requestFocus(snapshot, reason: .modalDismissed)
    }

    func applicationDidBecomeActive() {
        if let activeSurface {
            if case .modal = activeSurface {
                return
            }
            if adapters[activeSurface]?.acquireFocus(reason: .appActivated) == true {
                return
            }
        }
        for fallback in activationFallbackSurfaces?() ?? [] {
            if requestFocus(fallback, reason: .appActivated) {
                return
            }
        }
        recoverToCanvas(reason: .appActivated)
    }

    func applicationDidResignActive() {
        if let activeSurface {
            adapters[activeSurface]?.releaseFocus(reason: .recovery)
        }
    }

    func reservedShortcut(for event: NSEvent) -> ReservedShortcut? {
        ReservedShortcut.classify(keyCode: event.keyCode, modifiers: FocusKeyModifiers(event.modifierFlags), keymap: navKeymap)
    }

    func shouldSurfaceReceive(_ shortcut: ReservedShortcut, surface: FocusSurfaceID) -> Bool {
        if !modalSnapshots.isEmpty, activeSurface != surface {
            return false
        }
        return adapters[surface]?.canHandleReservedShortcut(shortcut) ?? false
    }

    @discardableResult
    func recoverFocus(candidates: [FocusSurfaceID], reason: FocusRequest) -> Bool {
        for candidate in candidates {
            if requestFocus(candidate, reason: reason) {
                return true
            }
        }
        return requestFocus(.canvas, reason: reason)
    }

    func recoverToCanvas(reason: FocusRequest) {
        _ = requestFocus(.canvas, reason: reason)
    }
}

private extension FocusKeyModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var value: FocusKeyModifiers = []
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.control) { value.insert(.control) }
        self = value
    }
}
