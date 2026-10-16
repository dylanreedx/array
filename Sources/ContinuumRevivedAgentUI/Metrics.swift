import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P1.5-spacing-radius-scale.md
//
// Today the agent surfaces carry five different vertical paddings (3/6/8/10/12)
// against the same horizontal 12, four corner radii with no rule, and a tile
// radius of 6 that nests cards at radius 8 — inverted nesting, which is what
// makes the tile read as sloppy. The fixed heights (52 header / 92 dock / 44
// compose / 24 answer field) are hardcoded, so P1.4's type moves clip silently.
//
// This file is the scale. Foundation only, like the rest of the module:
// `EdgeInsetsToken` is a neutral struct and converting it to `NSEdgeInsets` /
// SwiftUI `EdgeInsets` is the thin view layer's job. Nothing adopts here —
// P1.10/P1.11 do the adopting.
//
// PROVENANCE of the line-height multiple. Measured with
// `NSLayoutManager.defaultLineHeight(for:)` on macOS 15, over the P1.4 ladder:
//
//     9pt → 11 (1.2222)   11pt → 13 (1.1818)   13pt → 16 (1.2308)
//    15pt → 18 (1.2000)   18pt → 21 (1.1667)   mono matches its base size
//
// The largest real ratio is 1.2308 (13pt, the `body`/`bodyMono` size), so
// `lineHeightMultiple` = 1.25 is the smallest quarter-point step that is at or
// above EVERY measured ratio. Derived heights therefore never under-report what
// AppKit will actually lay out, which is the whole point — an under-report is a
// clipped row. Those measurements are pinned as literals in `MetricsChecks`, so
// the claim is asserted rather than remembered.

/// Neutral edge insets. Deliberately platform-free — no `NSEdgeInsets` here.
public struct EdgeInsetsToken: Equatable, Sendable {
    public let top: Double
    public let left: Double
    public let bottom: Double
    public let right: Double

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    /// Both vertical edges at once — the term that makes a row taller.
    public var vertical: Double { top + bottom }
    /// Both horizontal edges at once — the term that narrows available text width.
    public var horizontal: Double { left + right }
}

/// The 2pt-grid spacing ladder. Every gap in the agent UI is one of these.
public enum Space {
    public static let xs = 2.0
    public static let s = 4.0
    public static let m = 8.0
    public static let l = 12.0
    public static let xl = 16.0
    public static let xxl = 24.0

    /// Smallest-first, for the checks that gate the grid and the ordering.
    public static let ladder: [Double] = [xs, s, m, l, xl, xxl]
    /// The grid every value must land on. 2pt, not 4pt: `xs` = 2 is the
    /// existing 2pt gap between a tile's name and its phase label.
    public static let grid = 2.0
}

/// Corner radii, with one rule: a container's radius is LARGER than the radius
/// of the cards nested inside it. Today's tile (6) nesting cards (8) violates
/// that, and the violation is the regression witness in `MetricsChecks`.
public enum Radius {
    /// A transcript card, a user-input card, a text field — anything nested.
    /// Resolved through the app-wide `CornerStyle`: 6 at Default.
    public static var card: Double { CornerRole.card.radius }
    /// A tile, a dock, a popover — anything that CONTAINS cards. 10 at Default.
    public static var container: Double { CornerRole.popover.radius }
    /// Fully rounded. Large enough that any view clamps it to half its height,
    /// so a status chip stays a pill at every height it is ever given. A pill
    /// stays a capsule at Default and Rounded and becomes a rectangle at Sharp.
    public static var pill: Double { CornerRole.pill.radius }
}

// MARK: - Corner style

/// The app-wide corner roundness the owner picks in Settings › Appearance ›
/// Corner style. Every rounded surface resolves its radius through a
/// `CornerRole`, and a role's radius through the current style:
///
///  * **Sharp** — 0 everywhere. Pills become rectangles.
///  * **Default** — exactly the radii the app has always drawn.
///  * **Rounded** — friendly and bubbly but realistic: each Default radius
///    × `roundedScale`, rounded to a whole point and capped at `roundedCap`.
///    A capsule stays a capsule.
///
/// Rounded is a function of the Default radius alone, so ONE rule covers every
/// role and the corner census (`--corner-style-check`) can predict any surface's
/// radius under any style from what it draws at Default.
public enum CornerStyle: String, CaseIterable, Sendable {
    case sharp
    case standard = "default"
    case rounded

    /// The `UserDefaults` key of the setting.
    public static let defaultsKey = "array.appearance.cornerStyle"
    public static let fallback: CornerStyle = .standard
    public static let roundedScale = 1.8
    public static let roundedCap = 28.0

    /// The style every radius resolves against. Written only by the app's
    /// corner-style controller (which also re-renders what is on screen);
    /// checks that are not about corner style see `.standard`.
    nonisolated(unsafe) public static var current: CornerStyle = .standard

    public static func resolve(_ rawValue: String?) -> CornerStyle {
        rawValue.flatMap(CornerStyle.init(rawValue:)) ?? fallback
    }

    public var title: String {
        switch self {
        case .sharp: return "Sharp"
        case .standard: return "Default"
        case .rounded: return "Rounded"
        }
    }

    /// The radius this style draws for a surface whose Default radius is
    /// `base`. A capsule base (`CornerRole.pill`'s) is left a capsule.
    public func radius(_ base: Double) -> Double {
        switch self {
        case .sharp: return 0
        case .standard: return base
        case .rounded:
            guard base < CornerRole.capsuleBase else { return base }
            return min((base * Self.roundedScale).rounded(), max(base, Self.roundedCap))
        }
    }
}

/// What a rounded surface IS, which decides its radius. Each role's Default
/// value is the radius that surface already drew; `radius` resolves it in the
/// current `CornerStyle`.
public enum CornerRole: String, CaseIterable, Sendable {
    /// A canvas tile and its chrome.
    case tile
    /// A zone, its outline and fill, and the moving highlight that previews one.
    case zone
    /// The settings card, the ⌘K palette, the task detail sheet.
    case modal
    /// A menu, popover, hover card, toast, dock: anything that CONTAINS rows.
    case popover
    /// A nested card or row: transcript cards, menu rows, inbox cards.
    case card
    /// A structured transcript artifact: code, tables, tool rows, plans.
    case artifact
    /// The composer's field.
    case input
    /// A button or small control.
    case control
    /// A small badge or chip.
    case badge
    /// A capsule: status pills, the floating toolbar, hover labels.
    case pill

    /// The Default radius for a capsule: large enough that every view clamps
    /// it to half its height.
    public static let capsuleBase = 999.0

    public var base: Double {
        switch self {
        case .tile: return 10
        case .zone: return 12
        case .modal: return 14
        case .popover: return 10
        case .card: return 6
        case .artifact: return 8
        case .input: return 10
        case .control: return 6
        case .badge: return 8
        case .pill: return Self.capsuleBase
        }
    }

    /// This role's radius in the current style.
    public var radius: Double { CornerStyle.current.radius(base) }

    /// A one-off Default radius (a surface that predates the roles and draws a
    /// value no role has) resolved in the current style.
    public static func radius(base: Double) -> Double { CornerStyle.current.radius(base) }
}

// Ticket: docs/38-tickets/91-agent-tile-ux/P0.3-semantic-tile-tokens.md
/// The v2 tile's radii. Additive: `Radius` keeps its shipped values (card 6,
/// container 10) so nothing already adopting it moves, and `runAgentTileTokenChecks`
/// asserts that preservation rather than trusting it.
///
/// The bands come from `_DESIGN.md` §11 — tile ≈12, composer 10–12, artifact
/// 8–10 — and the values are the ones inside those bands that also land on
/// `Space.grid` and keep the nesting rule `Radius` established: a container's
/// radius exceeds the radius of whatever nests inside it. The tile contains the
/// composer, the composer and the transcript contain artifacts, and an artifact
/// may still contain a `Radius.card` (6), so the whole ladder is strictly
/// decreasing: 12 > 10 > 8 > 6.
public enum AgentTileRadius {
    /// The tile itself. 12 at Default (resolved through `CornerStyle`).
    public static var tile: Double { CornerRole.radius(base: 12) }
    /// The composer's field surface. 10 at Default.
    public static var composer: Double { CornerRole.input.radius }
    /// A structured artifact: tool call, plan, diff, fenced code. 8 at Default.
    public static var artifact: Double { CornerRole.artifact.radius }

    /// Outermost-first, for the checks that gate the nesting rule.
    public static var ladder: [Double] { [tile, composer, artifact] }
}

// Ticket: docs/38-tickets/94-sidebar-native-ux/P0.5-row-token-vocabulary.md
/// Stroke widths. A width is a token for the same reason a colour or an
/// alpha is: a literal `0.5` at a call site is a boundary decision made
/// where nothing can measure it.
public enum LineWidth {
    /// THE hairline. Queue 94's `_DESIGN.md` caps any boundary the sidebar
    /// keeps at 0.5 pt, drawn from `AgentLineRole` — the sidebar is this
    /// token's first consumer, and ticket 93
    /// (docs/38-tickets/93-global-border-audit.md) will sweep every other
    /// border in the app onto it. One declaration, so "at most 0.5 pt" is a
    /// value `runSidebarSurfaceChecks` pins rather than a convention call
    /// sites remember. `Double`, like every metric here — views convert.
    ///
    /// It is also the CEILING on every border in the app: the sweep is done,
    /// and `--border-census-check` walks the real chrome (every tile kind, the
    /// composer, sidebar, palette, settings card, toast, zone chrome, canvas
    /// menus) and fails on any outline wider than this outside its listed
    /// exemptions (the focus ring, the moving highlight, glyph strokes, native
    /// control chrome). A hairline is a device property, not a metric: it never
    /// scales with a page zoom.
    public static let hairline = 0.5
    /// An authorship rule: a state-bearing edge, not a decorative boundary, so
    /// it does not reuse `hairline` or `Space.xs` (a SPACING token that happens
    /// to share this value today but is not guaranteed to keep doing so in a
    /// STROKE slot). First consumer: `UserPromptView`'s left-edge rule.
    public static let rule = 2.0
}

/// The two padding shapes. Collapsing today's 3/6/8/10/12 into exactly two is
/// the ticket: a card is generous on all four edges, a row is compact
/// vertically and keeps the card's horizontal rhythm so text left-aligns down
/// the whole tile.
public enum Inset {
    /// A card's interior: `Space.l` on every edge.
    public static let card = EdgeInsetsToken(top: Space.l, left: Space.l, bottom: Space.l, right: Space.l)
    /// A row's interior: `Space.m` vertical, `Space.l` horizontal.
    public static let row = EdgeInsetsToken(top: Space.m, left: Space.l, bottom: Space.m, right: Space.l)
}

public enum Metrics {
    // Ticket: docs/38-tickets/94-sidebar-native-ux/P2.2-measured-fit-tiers.md
    /// The width an `NSTextField` cell keeps for itself, on top of the width the
    /// string measures. ONE declaration, in the leaf module, because three
    /// places have to agree about it or the disagreement is invisible: the
    /// layout's guaranteed-minimum floor, the QA geometry seam that reports what
    /// a label NEEDED, and the gate that compares the two. Before this constant
    /// existed the floor measured `"0000"` raw and the seam added a literal 4 —
    /// so the floor was exactly wide enough to measure the string and AppKit
    /// elided it anyway, and the gate could not see it because both halves were
    /// off by the same amount in opposite directions.
    ///
    /// 4.0, measured rather than chosen: an `NSTextField(labelWithString:)`
    /// draws its string inset by 2pt on each side of its cell, which is why a
    /// frame-only or `stringValue`-only assertion cannot witness elision.
    /// `Double`, like every metric here — views convert.
    public static let cellTextInset = 4.0

    /// See the PROVENANCE note above: at or above every measured AppKit
    /// `defaultLineHeight(for:) / size` ratio across the P1.4 ladder.
    public static let lineHeightMultiple = 1.25

    /// One rendered line of `role`, rounded UP to a whole point. Rounding down
    /// would reintroduce the clipping this ticket removes.
    public static func lineHeight(for role: TextRole) -> Double {
        (Typography.style(for: role).size * lineHeightMultiple).rounded(.up)
    }

    /// The height of a sequence of rendered text lines, including their shared
    /// insets and the gaps between them. The roles may differ — a sidebar card
    /// puts a title line between two label lines — so the view can derive its
    /// height from the content it actually draws without copying line-height
    /// arithmetic into the AppKit layer.
    ///
    /// An empty sequence still has the requested insets. Callers that draw text
    /// always include at least one role, but keeping the result well-defined makes
    /// the helper safe for a content-derived layout path.
    public static func rowHeight(
        for roles: [TextRole], insets: EdgeInsetsToken = Inset.row, spacing: Double = 0
    ) -> Double {
        let totalLineHeight = roles.reduce(0) { $0 + lineHeight(for: $1) }
        let gaps = Double(max(0, roles.count - 1)) * spacing
        return totalLineHeight + gaps + insets.vertical
    }

    /// The height a row of `lines` lines of `role` needs, including `insets`.
    /// This is what replaces the hardcoded 52/44/24: a row's height is a
    /// FUNCTION of its type, so P1.4's size moves cannot clip it.
    ///
    /// `lines` below 1 is clamped to 1 — a row that holds text holds at least
    /// one line, and returning something smaller would be a silent clip.
    public static func rowHeight(for role: TextRole, lines: Int = 1, insets: EdgeInsetsToken = Inset.row) -> Double {
        rowHeight(for: Array(repeating: role, count: max(1, lines)), insets: insets)
    }
}

// MARK: - Where today's numbers land (for P1.10/P1.11, which do the adopting)
//
//   TileNSView               cornerRadius   6            → Radius.container (6 → 10)
//   TranscriptCardViews      cornerRadius   8            → Radius.card      (8 → 6)
//                            edgeInsets     10/12/10/12  → Inset.card       (vertical 10 → 12)
//                            stack spacing  8            → Space.m
//   UserInputCardView        cornerRadius   8            → Radius.card      (8 → 6)
//                            edgeInsets     12/12/12/12  → Inset.card       (unchanged)
//                            answerField    height 24    → rowHeight(.body) (24 → 33)
//   StatusChipNSView         cornerRadius   9            → Radius.pill      (clamped, same look)
//   ManagedAgentTileNSView   cardStack      12/12/12/12  → Inset.card       (unchanged)
//                            cardStack sp.  8            → Space.m
//                            header insets  8/12/8/12    → Inset.row        (unchanged)
//                            header spacing 10           → Space.l          (10 → 12)
//                            textStack sp.  2            → Space.xs
//                            compose insets 6/12/6/12    → Inset.row        (vertical 6 → 8)
//                            header height  52           → derived          (52 → 54)
//                            compose height 44           → derived          (44 → 41)
//
// The two corner-radius moves are the inverted nesting being righted: the tile
// grows to `container`, the cards shrink to `card`. The height moves come out
// of `rowHeight`, not out of a new magic number:
//
//   header      = rowHeight(.title, lines: 2)      = 2 x 19 + 16 = 54
//   compose     = rowHeight(.body, insets: .card)  = 17 + 24     = 41
//   answerField = rowHeight(.body)                 = 17 + 16     = 33
//
// Those three are what the tokens SAY; if a control's own chrome needs more,
// P1.10 adds it from the control's real metrics — never by re-hardcoding.
//
// The 92pt approval dock is DELIBERATELY absent: it is a magic number that
// clips at the 320pt minimum tile width, so P1.10 derives it from the dock's
// real content rather than inheriting it as a token.
