import Foundation

// WS5: per-managed-agent-tile page zoom.
//
// This is the whole policy: a finite ladder of discrete steps, a current rung,
// and the arithmetic that derives scaled metrics from it. Foundation only, like
// the rest of this module — the AppKit bridges live in the app target.
//
// The value is DELIBERATELY not Codable and carries no persistence affordance.
// Page zoom is a transient property of a MOUNTED tile view: a recreated tile
// starts at `.default` because nothing ever wrote the old value anywhere it
// could be read back from.

/// One rung of the page-zoom ladder, held as an integer percent so the
/// measurement cache can key on it exactly (a `Double` factor would make two
/// nominally equal buckets hash differently).
public struct AgentPageZoom: Hashable, Sendable {
    /// The ladder, smallest first. Locked product contract — six steps.
    public static let steps: [Int] = [80, 90, 100, 110, 125, 150]

    /// The rung every tile starts on, and the rung `reset()` returns to.
    public static let defaultPercent = 100

    public static let `default` = AgentPageZoom(percent: defaultPercent)

    /// Always one of `steps`.
    public let percent: Int

    /// Snaps to the nearest rung; ties resolve to the smaller rung so the value
    /// can never round up past the ceiling.
    public init(percent: Int) {
        if let exact = Self.steps.first(where: { $0 == percent }) {
            self.percent = exact
            return
        }
        let clamped = min(max(percent, Self.steps[0]), Self.steps[Self.steps.count - 1])
        var best = Self.steps[0]
        var bestDistance = Int.max
        for step in Self.steps {
            let distance = abs(step - clamped)
            if distance < bestDistance {
                bestDistance = distance
                best = step
            }
        }
        self.percent = best
    }

    /// The multiplier a metric is scaled by.
    public var factor: Double { Double(percent) / 100.0 }

    public var isDefault: Bool { percent == Self.defaultPercent }

    private var index: Int { Self.steps.firstIndex(of: percent) ?? Self.steps.firstIndex(of: Self.defaultPercent)! }

    public var canZoomIn: Bool { index + 1 < Self.steps.count }
    public var canZoomOut: Bool { index > 0 }

    /// Clamps at the top rung — repeated zoom-in at 150% is a no-op, not a wrap.
    public func zoomedIn() -> AgentPageZoom {
        guard canZoomIn else { return self }
        return AgentPageZoom(percent: Self.steps[index + 1])
    }

    /// Clamps at the bottom rung.
    public func zoomedOut() -> AgentPageZoom {
        guard canZoomOut else { return self }
        return AgentPageZoom(percent: Self.steps[index - 1])
    }

    public func reset() -> AgentPageZoom { .default }

    /// What the menu shows. Integer percent — no locale-dependent decimal.
    public var displayPercentage: String { "\(percent)%" }

    // MARK: - Scaled metric arithmetic
    //
    // Every scaled length lands on a half point. Half points, not whole points:
    // a whole-point rule would collapse `Space.xs` (2) and `Space.s` (4) onto the
    // same value at 80% (1.6 -> 2, 3.2 -> 3 is fine, but 90% gives 1.8 -> 2 and
    // 3.6 -> 4, and 110% gives 2.2 -> 2 — the xs step would stop moving at all).
    // Half points are also exactly representable on both 1x and 2x backing.

    public static func quantize(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * 2).rounded() / 2
    }

    /// Scale a length (spacing, inset, control height, icon side, corner radius).
    public func scaled(_ value: Double) -> Double {
        Self.quantize(value * factor)
    }

    /// Scale an `EdgeInsetsToken` edge by edge.
    public func scaled(_ token: EdgeInsetsToken) -> EdgeInsetsToken {
        EdgeInsetsToken(
            top: scaled(token.top),
            left: scaled(token.left),
            bottom: scaled(token.bottom),
            right: scaled(token.right)
        )
    }

    /// The point size a `TextRole` renders at under this zoom.
    ///
    /// No `minimumRenderedSize` floor is applied: that floor exists for CANVAS
    /// zoom, where the tile is drawn smaller than its layout. Page zoom-out is
    /// the reader deliberately asking for more content per tile, and clamping
    /// `caption` at 9 while `body` shrank to 10.5 would invert the ladder.
    public func fontSize(for role: TextRole) -> Double {
        scaled(Typography.style(for: role).size)
    }

    /// One rendered line of `role` at this zoom, rounded UP to a whole point for
    /// the same reason `Metrics.lineHeight` is: rounding down is a clipped row.
    public func lineHeight(for role: TextRole) -> Double {
        (fontSize(for: role) * Metrics.lineHeightMultiple).rounded(.up)
    }

    /// `Metrics.rowHeight(for:lines:insets:)` at this zoom.
    public func rowHeight(for role: TextRole, lines: Int = 1, insets: EdgeInsetsToken = Inset.row) -> Double {
        let scaledInsets = scaled(insets)
        return lineHeight(for: role) * Double(max(1, lines)) + scaledInsets.vertical
    }
}

/// The four page-zoom commands, resolved from a key equivalent or a menu item.
public enum AgentPageZoomCommand: String, CaseIterable, Sendable {
    case zoomIn
    case zoomOut
    case reset

    /// Apply this command to a value. Returns the same value at an end stop.
    public func apply(to zoom: AgentPageZoom) -> AgentPageZoom {
        switch self {
        case .zoomIn: return zoom.zoomedIn()
        case .zoomOut: return zoom.zoomedOut()
        case .reset: return zoom.reset()
        }
    }

    /// Whether the command would actually move `zoom` — what drives the menu's
    /// disabled end stops.
    public func isEnabled(for zoom: AgentPageZoom) -> Bool {
        switch self {
        case .zoomIn: return zoom.canZoomIn
        case .zoomOut: return zoom.canZoomOut
        case .reset: return !zoom.isDefault
        }
    }
}

/// Pure keyboard routing for the page-zoom chords.
///
/// The normalisation is the whole reason this is a type rather than a `switch`
/// at the call site. `⌘+` is not a chord AppKit reports as `"+"`: on a US layout
/// the user presses Command-Shift-equal, and `charactersIgnoringModifiers`
/// returns `"="` (the unshifted character) while `characters` returns `"+"`.
/// On layouts where `+` is unshifted the reverse holds. Accepting BOTH forms,
/// from BOTH strings, is what makes the shortcut work on more than one layout.
public enum AgentPageZoomShortcut {
    /// The modifier set a page-zoom chord must carry, after masking away the
    /// device-dependent bits AppKit sets on every event.
    public static let requiredModifiers: Set<AgentPageZoomModifier> = [.command]

    /// Modifiers that may additionally be present without disqualifying a chord.
    /// Only Shift: Command-Shift-equal IS the zoom-in chord on a US layout.
    public static let toleratedModifiers: Set<AgentPageZoomModifier> = [.shift]

    /// Resolve a command from the two character strings AppKit reports plus the
    /// significant modifier set. Returns nil when the chord is not a page-zoom
    /// chord, which is what lets every unrelated key equivalent fall through to
    /// the responder chain untouched.
    public static func command(
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: Set<AgentPageZoomModifier>
    ) -> AgentPageZoomCommand? {
        guard modifiers.isSuperset(of: requiredModifiers) else { return nil }
        // Any modifier outside required ∪ tolerated disqualifies: ⌃⌘= and ⌥⌘-
        // belong to whatever else claims them, and silently eating them is the
        // hijack this guard exists to prevent.
        guard modifiers.subtracting(requiredModifiers).subtracting(toleratedModifiers).isEmpty else {
            return nil
        }
        let candidates = [characters, charactersIgnoringModifiers].compactMap { $0 }.filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }
        for candidate in candidates {
            switch candidate {
            case "+", "=":
                return .zoomIn
            case "-", "\u{2013}":
                // U+2013 EN DASH: some layouts emit it for Option-hyphen, but a
                // bare hyphen is what a Command chord reports. Included so a
                // layout that reports the dash still zooms out.
                return .zoomOut
            case "0":
                return .reset
            default:
                continue
            }
        }
        return nil
    }
}

/// A platform-neutral mirror of the modifier bits that matter here, so the
/// routing policy stays testable without AppKit.
///
/// Caps Lock and Function are DELIBERATELY absent: AppKit sets them in
/// `NSEvent.modifierFlags` independently of what the user pressed, so a set that
/// carried them would make every zoom chord fail while Caps Lock was on. The
/// AppKit bridge masks them out rather than tolerating them here, so the
/// "unknown modifier disqualifies" rule above stays strict.
public enum AgentPageZoomModifier: String, CaseIterable, Sendable {
    case command
    case shift
    case option
    case control
}
