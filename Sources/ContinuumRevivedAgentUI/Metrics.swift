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
    public static let card = 6.0
    /// A tile, a dock, a popover — anything that CONTAINS cards.
    public static let container = 10.0
    /// Fully rounded. Large enough that any view clamps it to half its height,
    /// so a status chip stays a pill at every height it is ever given.
    public static let pill = 999.0
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
    /// The tile itself.
    public static let tile = 12.0
    /// The composer's field surface.
    public static let composer = 10.0
    /// A structured artifact: tool call, plan, diff, fenced code.
    public static let artifact = 8.0

    /// Outermost-first, for the checks that gate the nesting rule.
    public static let ladder: [Double] = [tile, composer, artifact]
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
    public static let hairline = 0.5
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

    /// The height a row of `lines` lines of `role` needs, including `insets`.
    /// This is what replaces the hardcoded 52/44/24: a row's height is a
    /// FUNCTION of its type, so P1.4's size moves cannot clip it.
    ///
    /// `lines` below 1 is clamped to 1 — a row that holds text holds at least
    /// one line, and returning something smaller would be a silent clip.
    public static func rowHeight(for role: TextRole, lines: Int = 1, insets: EdgeInsetsToken = Inset.row) -> Double {
        Double(max(1, lines)) * lineHeight(for: role) + insets.vertical
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
