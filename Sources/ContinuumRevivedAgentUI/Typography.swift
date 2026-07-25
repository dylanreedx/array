import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P1.4-type-scale.md
//
// Five ad-hoc sizes (10/11/12/13/18) with four different weights at size 12
// alone meant "change body text" was a grep-and-pray: size 12 was card title,
// card body, phase label, compose input and dock header at once. This file is
// the semantic layer — a call site asks for a ROLE, and the size/weight is one
// decision in one place.
//
// Foundation only, on purpose. `TokenWeight` is neutral; mapping it to
// `NSFont.Weight` / SwiftUI `Font.Weight` is the thin view layer's job
// (P1.10/P1.11 adopt; nothing adopts here).
//
// Sizes are anchored on AppKit's own control-size ladder rather than invented:
// `NSFont.systemFontSize(for:)` read 13.0 (regular), 11.0 (small), 9.0 (mini)
// on macOS 15 when this scale was authored. So `body` = 13, `label` = 11,
// `caption` = 9 are the system's own steps; `titleL` = 18 is the size (and
// weight) the agent tile's glyph already uses; `title` = 15 is body + the
// minimum ladder step, which is the one size that had to be chosen. It is
// deliberately NOT 12: the old 11 → 12 → 13 near-collapse is what this ticket
// removes. Those AppKit numbers are the ladder's PROVENANCE, not a runtime
// dependency — nothing here reads AppKit, and the checks pin the ladder itself.

/// Neutral font weight. Deliberately platform-free — no `NSFont.Weight` here.
public enum TokenWeight: String, CaseIterable, Sendable {
    case regular
    case medium
    case semibold
    case bold
}

/// What a piece of text IS, not how big it is.
///
/// A `…Mono` role differs from its base role **only** in `monospaced` — same
/// size, same weight. That invariant is gated (see `TypographyChecks`), so mono
/// text can never quietly drift onto a size of its own.
public enum TextRole: String, CaseIterable, Sendable {
    /// Tile-scale heading — the agent tile's glyph today.
    case titleL
    /// The name of a thing: a tile's agent name, a transcript card's title.
    case title
    /// Running prose: a card body, a compose field.
    case body
    /// Running prose that must align by column: a diff, a command, a path.
    case bodyMono
    /// A short attached descriptor: a phase label, a button title, a dock header.
    case label
    /// Least-important metadata, read only when looked for.
    case caption
    /// Metadata that must not reflow as digits change: elapsed time, counts.
    case captionMono
}

public struct TextStyle: Equatable, Sendable {
    public let size: Double
    public let weight: TokenWeight
    public let monospaced: Bool

    public init(size: Double, weight: TokenWeight, monospaced: Bool) {
        self.size = size
        self.weight = weight
        self.monospaced = monospaced
    }
}

public enum Typography {
    /// The five roles that form the visible size hierarchy, largest first. The
    /// mono roles are absent because they mirror a base role's size by design.
    public static let sizeLadder: [TextRole] = [.titleL, .title, .body, .label, .caption]

    /// Adjacent rungs of `sizeLadder` must differ by at least this much. A 1pt
    /// step (the old 11 → 12 → 13) does almost no work at reading distance, so
    /// the hierarchy has to be asserted, not hoped for.
    public static let minimumLadderStep: Double = 2.0

    /// The smallest size AppKit itself ships a system font at
    /// (`NSFont.systemFontSize(for: .mini)` == 9.0, measured on macOS 15).
    /// Below this, text is decoration rather than something a person reads —
    /// which is what makes it the right floor for the zoom arithmetic below.
    public static let minimumRenderedSize: Double = 9.0

    public static func style(for role: TextRole) -> TextStyle {
        switch role {
        // `.bold`, not `.semibold`: this is the weight the agent tile's 18pt
        // glyph ships today, and adopting a role must not silently restyle it.
        case .titleL: return TextStyle(size: 18, weight: .bold, monospaced: false)
        case .title: return TextStyle(size: 15, weight: .semibold, monospaced: false)
        case .body: return TextStyle(size: 13, weight: .regular, monospaced: false)
        case .bodyMono: return TextStyle(size: 13, weight: .regular, monospaced: true)
        case .label: return TextStyle(size: 11, weight: .medium, monospaced: false)
        case .caption: return TextStyle(size: 9, weight: .regular, monospaced: false)
        case .captionMono: return TextStyle(size: 9, weight: .regular, monospaced: true)
        }
    }

    // MARK: - Canvas zoom
    //
    // Composes with `ReadabilityPolicy` (ContinuumRevivedCore) by arithmetic,
    // not by import: the direction is Core → AgentUI, never the reverse, so the
    // zoom threshold is an ARGUMENT here and Core stays the only place that
    // owns which band a tile is in.
    //
    // A tile drawn at zoom z renders a `size`-point glyph at `size * z` points,
    // so what is legible at 1.0× need not be legible on a zoomed-out canvas: at
    // 0.35× an 11pt label renders under 4 points.
    //
    // Against `ReadabilityPolicy.band(for: .tile(.managedAgent), zoom:)`, whose
    // `.overviewLabelOnly` → `.readableSummary` boundary is 0.70×:
    //
    //   AT 0.70× exactly four roles clear `minimumRenderedSize`: `titleL`,
    //   `title`, `body` and `bodyMono`. `label` and `caption`/`captionMono` are
    //   already illegible there.
    //
    //   BELOW 0.70× the set keeps shrinking — `body`/`bodyMono` drop out
    //   immediately (they need ≥ 0.6923×), then `title` (≥ 0.60×), and only
    //   `titleL` survives down to 0.50×. Below 0.50× NO role is legible, which
    //   is precisely why `.overviewLabelOnly` cannot mean "the same text,
    //   smaller": a zoomed-out tile has to say what it is with something other
    //   than type.
    //
    //   `label` needs ≥ 0.8182×, and `caption`/`captionMono` need ≥ 1.0× — a
    //   caption is a 1:1-zoom-only role and must never be the sole carrier of
    //   information on a canvas that zooms.
    //
    // Each of those numbers is `minimumLegibleZoom(for:)` and is asserted, so
    // this comment cannot rot away from the code.

    /// The smallest role size that still renders legibly at `zoom`.
    /// `.infinity` for a non-positive zoom — nothing is legible there.
    public static func minimumLegibleSize(atZoom zoom: Double) -> Double {
        guard zoom > 0 else { return .infinity }
        return minimumRenderedSize / zoom
    }

    public static func isLegible(_ role: TextRole, atZoom zoom: Double) -> Bool {
        style(for: role).size >= minimumLegibleSize(atZoom: zoom)
    }

    /// The lowest canvas zoom at which `role` still renders legibly.
    public static func minimumLegibleZoom(for role: TextRole) -> Double {
        minimumRenderedSize / style(for: role).size
    }
}

// MARK: - Where today's sizes land (for P1.10/P1.11, which do the adopting)
//
//   ManagedAgentTileNSView   glyphLabel     18 bold      → titleL     (unchanged)
//                            nameLabel      13 semibold  → title       (13 → 15)
//                            phaseLabel     12 medium    → label       (12 → 11)
//                            elapsedLabel   11 monoDigit → captionMono (11 → 9)
//                            composeField   12 regular   → body        (12 → 13)
//   TranscriptCardViews      titleLabel     12 semibold  → title       (12 → 15)
//                            bodyLabel      13 regular   → body
//                            statusLabel    11 monoDigit → captionMono (11 → 9)
//   UserInputCardView        headerLabel    11 semibold  → label       (11)
//                            questionLabel  13 medium    → body        (13)
//                            answerField    12 regular   → body        (12 → 13)
//                            submitButton   11 medium    → label       (11)
//   ApprovalDockView         headerLabel    12 semibold  → label       (12 → 11)
//                            detailLabel    11 mono      → captionMono (11 → 9)
//                            button         11 medium    → label       (11)
//
// Every existing size is expressible, so no call site needs to invent one. The
// parenthesised moves are the point of the ticket, not a side effect: titles
// grow so the hierarchy reads, and the 12s collapse into `body` or `label`
// depending on which they actually were.
