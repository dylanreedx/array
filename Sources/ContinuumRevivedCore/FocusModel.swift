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

    /// Is this focus a VISIT — a human deliberately going to look at something —
    /// or the app putting focus back where it was?
    ///
    /// WS4: read-state may only be cleared by a visit. `appActivated` (the broker
    /// re-acquiring the remembered surface when Array comes forward),
    /// `modalDismissed` (the snapshot restored after a sheet closes) and
    /// `recovery` all deliver an accepted-tile-focus callback that is
    /// indistinguishable from a click at the callback site — which is how a
    /// completion that arrived while the app was in the background got marked
    /// read by the act of coming back to the app at all.
    ///
    /// Everything else stays a visit, including `tileSpawned`: that is the reason
    /// the inbox reveal path uses (`jumpToTileFromPalette`), and clicking an inbox
    /// row is the canonical deliberate visit.
    public var isDeliberateVisit: Bool {
        switch self {
        case .appActivated, .modalDismissed, .recovery: return false
        case .userClick, .modalOpened, .tileSpawned, .tileClosed, .runtimeExited: return true
        }
    }
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

// Ticket: docs/38-tickets/90-agent-ux/P3.10-jump-shortcuts.md
/// ⌘1–⌘9 → an inbox row, by position in the list you are looking at. The order is
/// frozen (P3.4), so the same chord keeps hitting the same agent.
///
/// THE COLLISION, RESOLVED BY SCOPE RATHER THAN BY THEFT. ⌘1–⌘4 are
/// `ReservedShortcut.spawnProfile(1...4)` and this ticket does NOT move them:
/// `classify` is unchanged, `FocusDispatch.resolve` is unchanged, and every one of
/// those four chords still spawns its launch profile everywhere in the app. A jump
/// is a SECOND reading of the same chord that applies only while the inbox list
/// itself holds first responder — which is why this is a separate function and not
/// a `ReservedShortcut` case: a reserved shortcut is global by construction, and a
/// new case there would have taken ⌘1 away from the profile that owns it (and gone
/// red in `ShortcutCatalog`'s own intra-scope uniqueness check, which is the
/// collision surfacing exactly as the packet says it should).
///
/// The consequence, stated plainly for the owner rather than hidden: revealing an
/// agent moves focus to its tile (P3.9), so a jump hands the keyboard to the canvas
/// and a second jump needs the inbox focused again. Scoping is what buys ⌘1–4
/// keeping their meaning; the alternative the packet offers — re-homing the four
/// launch profiles onto other chords — would break four documented global bindings
/// for it.
public enum InboxJump: Sendable {
    /// Nine, because ⌘0 is not a row: a zero-indexed digit row would make "the
    /// first agent" ambiguous, and ten rows of hint pill is already more than a
    /// glance can hold.
    public static let maximumRows = 9

    /// Row 1…9's key codes, in order (`kVK_ANSI_1`… — note 5/6 and 7/8/9 are not
    /// contiguous on this keyboard layout, which is the whole reason this is a
    /// table and not arithmetic on a base code).
    static let keyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// The chord that jumps to row `number` (1-based), or nil outside 1…9.
    public static func chord(forRowNumber number: Int) -> KeyChord? {
        guard (1...maximumRows).contains(number) else { return nil }
        return KeyChord(keyCode: keyCodes[number - 1], modifiers: .command)
    }

    /// The ZERO-based row this chord jumps to, or nil if it is not a jump chord.
    /// `⌘` exactly: ⌘⇧1 and a bare 1 are somebody else's events, and the modifier
    /// set is compared rather than tested with `contains` so a chord that merely
    /// includes ⌘ cannot be read as a jump.
    public static func rowIndex(keyCode: UInt16, modifiers: FocusKeyModifiers) -> Int? {
        guard modifiers == .command else { return nil }
        return keyCodes.firstIndex(of: keyCode)
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
