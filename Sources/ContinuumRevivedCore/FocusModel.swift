import Foundation

public typealias FocusTileID = UUID

public enum FocusModalKind: String, Codable, Equatable, Hashable, Sendable {
    case palette
    case settings
    case navMode
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
    case note
    case file
    case fileTree
    case ticketQueue
    case diffReview
    case runArtifacts
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

    /// Classifies app-reserved shortcuts from hardware key codes. The caller
    /// passes platform modifier state translated into `FocusKeyModifiers` so
    /// this pure model stays independent of AppKit.
    public static func classify(keyCode: UInt16, modifiers: FocusKeyModifiers) -> ReservedShortcut? {
        if modifiers == .control, keyCode == 49 {
            return .navModeLeader // Space
        }
        guard modifiers == .command else { return nil }
        switch keyCode {
        case 40: return .palette // K
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
