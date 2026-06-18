import Foundation

public enum FocusTarget: Equatable, Sendable {
    case tile(UUID)
    case zone(UUID)
}

public struct CameraSnapshot: Equatable, Sendable {
    public var viewport: CanvasViewport
    public var focusedTileId: UUID?
    public var focusedZoneId: UUID?

    public init(viewport: CanvasViewport, focusedTileId: UUID? = nil, focusedZoneId: UUID? = nil) {
        self.viewport = viewport
        self.focusedTileId = focusedTileId
        self.focusedZoneId = focusedZoneId
    }
}

public enum FocusHistoryEventReason: Equatable, Sendable {
    case directTileActivation
    case completedTileJump
    case completedZoneJump
    case paletteJump
    case previousNavigation
}

public struct DistinctToggleHistory<ID: Hashable & Sendable>: Equatable, Sendable {
    private var current: ID?
    private var previous: ID?

    public init() {}

    public var pair: (current: ID?, previous: ID?) { (current, previous) }

    public mutating func record(_ id: ID) {
        guard current != id else { return }
        previous = current
        current = id
    }

    public mutating func toggle(valid: (ID) -> Bool = { _ in true }) -> ID? {
        if let prior = previous, valid(prior) {
            swap(&current, &previous)
            return current
        }
        if let current, !valid(current) {
            self.current = nil
        }
        previous = nil
        return nil
    }
}

public struct FocusHistory: Equatable, Sendable {
    public private(set) var recentTiles = DistinctToggleHistory<UUID>()
    public private(set) var recentZones = DistinctToggleHistory<UUID>()
    public private(set) var lastViewBeforeProgrammaticJump: CameraSnapshot?
    public private(set) var lastFocusedTileByZone: [UUID: UUID] = [:]

    public init() {}

    public mutating func recordViewBeforeProgrammaticJump(_ snapshot: CameraSnapshot) {
        lastViewBeforeProgrammaticJump = snapshot
    }

    public mutating func recordTileFocus(_ tileId: UUID, zoneId: UUID? = nil, reason: FocusHistoryEventReason) {
        switch reason {
        case .directTileActivation, .completedTileJump, .paletteJump, .previousNavigation:
            recentTiles.record(tileId)
            if let zoneId { lastFocusedTileByZone[zoneId] = tileId }
        case .completedZoneJump:
            if let zoneId { lastFocusedTileByZone[zoneId] = tileId }
        }
    }

    public mutating func recordZoneFocus(_ zoneId: UUID, reason: FocusHistoryEventReason) {
        switch reason {
        case .completedZoneJump, .paletteJump, .previousNavigation:
            recentZones.record(zoneId)
        case .directTileActivation, .completedTileJump:
            break
        }
    }

    public mutating func previousView() -> CameraSnapshot? {
        defer { lastViewBeforeProgrammaticJump = nil }
        return lastViewBeforeProgrammaticJump
    }

    public mutating func previousTile(valid: (UUID) -> Bool = { _ in true }) -> UUID? {
        recentTiles.toggle(valid: valid)
    }

    public mutating func previousZone(valid: (UUID) -> Bool = { _ in true }) -> UUID? {
        recentZones.toggle(valid: valid)
    }
}
