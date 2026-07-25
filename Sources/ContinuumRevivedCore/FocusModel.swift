import ContinuumRevivedAgentUI
import Foundation

public typealias FocusTileID = UUID

public enum FocusModalKind: String, Codable, Equatable, Hashable, Sendable {
    case palette
    case settings
    case navMode
    case focusMode
    case leader
}

public enum FocusSurfaceID: Codable, Equatable, Hashable, Sendable {
    case canvas
    case tile(FocusTileID)
    case modal(FocusModalKind)
    case appChrome
    case settings
}

public enum FocusSurfaceKind: String, Codable, Equatable, Hashable, Sendable {
    case canvas
    case terminal
    case browser
    case browserInspector
    case note
    case file
    case fileTree
    case ticketQueue
    case conductorQueue
    case diffReview
    case runArtifacts
    case managedAgent
    case palette
    case settings
    case appChrome
}

public enum FocusRequest: String, Codable, Equatable, Hashable, Sendable {
    case userClick
    case appActivated
    case modalOpened
    case modalDismissed
    case tileSpawned
    case tileClosed
    case runtimeExited
    case recovery
}

public struct FocusKeyModifiers: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let command = FocusKeyModifiers(rawValue: 1 << 0)
    public static let shift = FocusKeyModifiers(rawValue: 1 << 1)
    public static let option = FocusKeyModifiers(rawValue: 1 << 2)
    public static let control = FocusKeyModifiers(rawValue: 1 << 3)
}

public enum ReservedShortcut: Equatable, Hashable, Sendable {
    case palette
    case spawnProfile(Int)
    case navModeLeader
    case focusMode
    case settings

    /// Classifies app-reserved shortcuts from hardware key codes. The caller
    /// passes platform modifier state translated into `FocusKeyModifiers` so
    /// this pure model stays independent of AppKit.
    public static func classify(keyCode: UInt16, modifiers: FocusKeyModifiers, keymap: NavKeymap = .default) -> ReservedShortcut? {
        if modifiers == keymap.leader.modifiers, keyCode == keymap.leader.keyCode {
            return .navModeLeader
        }
        guard modifiers == .command else { return nil }
        switch keyCode {
        case 3: return .focusMode // F
        case 40: return .palette // K
        case 43: return .settings // comma
        case 18: return .spawnProfile(1)
        case 19: return .spawnProfile(2)
        case 20: return .spawnProfile(3)
        case 21: return .spawnProfile(4)
        default: return nil
        }
    }
}

public enum NavLeaderDecision: Equatable, Sendable {
    case openNavMode
    case closeNavMode
    case closeNavModeAndPassThroughLiteral
    case ignore

    public static func decide(shortcut: ReservedShortcut?, navModeActive: Bool, eventOriginatedInFocusedSurface: Bool) -> NavLeaderDecision {
        guard shortcut == .navModeLeader else { return .ignore }
        if navModeActive {
            return eventOriginatedInFocusedSurface ? .closeNavModeAndPassThroughLiteral : .closeNavMode
        }
        return .openNavMode
    }
}

public struct FocusModePairingCandidate: Equatable, Sendable {
    public var tileId: FocusTileID
    public var zoneId: UUID
    public var isAgent: Bool
    public var status: AgentStatus?
    public var lastActiveAt: Date?

    public init(tileId: FocusTileID, zoneId: UUID, isAgent: Bool, status: AgentStatus?, lastActiveAt: Date?) {
        self.tileId = tileId
        self.zoneId = zoneId
        self.isAgent = isAgent
        self.status = status
        self.lastActiveAt = lastActiveAt
    }
}

public enum FocusModePairing {
    public static func companionAgent(
        for primaryTileId: FocusTileID,
        primaryZoneId: UUID,
        candidates: [FocusModePairingCandidate],
        manualOverride: FocusTileID? = nil
    ) -> FocusTileID? {
        let eligible = candidates.filter { candidate in
            candidate.tileId != primaryTileId && candidate.zoneId == primaryZoneId && candidate.isAgent
        }

        if let manualOverride,
           eligible.contains(where: { $0.tileId == manualOverride }) {
            return manualOverride
        }

        return eligible.sorted { lhs, rhs in
            let lhsNeedsAttention = lhs.status == .needsAttention
            let rhsNeedsAttention = rhs.status == .needsAttention
            if lhsNeedsAttention != rhsNeedsAttention { return lhsNeedsAttention }

            switch (lhs.lastActiveAt, rhs.lastActiveAt) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate > rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.tileId.uuidString < rhs.tileId.uuidString
            }
        }.first?.tileId
    }
}
