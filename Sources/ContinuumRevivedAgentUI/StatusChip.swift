import Foundation

// Ticket: docs/38-tickets/87-agent-ui-component-framework.md
//
// First agent-UI building block, shared across macOS and iOS. This file is
// the PRESENTATION MODEL only — a pure (status → display) mapping with NO
// AppKit/UIKit import, so it compiles into both apps through
// ContinuumRevivedAgentUI and is tested once in the matrix
// (ContinuumRevivedAgentUIChecks → runStatusChipChecks). Each platform ships a
// thin view that only paints a StatusChipDisplay; the view holds no logic.
//
// Placement note: this started out in ContinuumRevivedCore to avoid standing up
// an SPM target + iOS project.yml dependency before the pattern was proven.
// Ticket P1.1 (docs/38-tickets/90-agent-ux/P1.1-agentui-module.md) moved it,
// behaviour unchanged, into the dedicated ContinuumRevivedAgentUI module that
// the Phase-1 token system also lives in.

/// A platform-neutral sRGB colour, components in 0…1. Views convert it to
/// NSColor / SwiftUI Color. Opaque by design — chip translucency is a view
/// concern, and contrast is defined against opaque fills.
public struct ChipColor: Equatable, Sendable {
    public let r: Double
    public let g: Double
    public let b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Stable identity used by the distinctness check and any dedup.
    public var hexKey: String {
        func component(_ value: Double) -> String {
            String(format: "%02X", Int((min(max(value, 0), 1) * 255).rounded()))
        }
        return component(r) + component(g) + component(b)
    }
}

/// WCAG 2.x relative luminance and contrast ratio. Pure math on sRGB, so the
/// contrast of any (foreground, background) pair is a deterministic,
/// matrix-testable property. This is what makes "the text is legible on its
/// background" a red-green invariant rather than an eyeball judgement.
public enum WCAGContrast {
    public static func relativeLuminance(_ color: ChipColor) -> Double {
        func linearize(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(color.r)
            + 0.7152 * linearize(color.g)
            + 0.0722 * linearize(color.b)
    }

    /// Contrast ratio in the range 1…21.
    public static func ratio(_ a: ChipColor, _ b: ChipColor) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        let lighter = max(la, lb)
        let darker = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// Everything a status view needs to paint. Colours are explicit — never a
/// system semantic colour or a colour-by-name — so the chip owns its own
/// contrast and it can be verified in the matrix.
///
/// Two shapes, because P1.8 found the six duplicate maps needed both: a FILLED
/// PILL (`foreground` on `background`, a light-appearance pastel that reads on
/// any tile) and a BARE GLYPH/DOT (`accent`, for the title bar, the managed-tile
/// header, the sidebar and the iOS status dot, which want the hue itself with no
/// fill behind it). A caller picks one; it never mixes a pill fill with an accent
/// foreground.
public struct StatusChipDisplay: Equatable, Sendable {
    public let label: String
    public let glyph: String
    public let foreground: ChipColor
    public let background: ChipColor
    /// The status hue for an un-filled caller, sourced from the P1.3 palette
    /// (`AccentToken` / `TextToken.textSecondary`) rather than re-picked here —
    /// which is what makes it appearance-aware and contrast-gated on all eleven
    /// surfaces in both themes by `runDesignTokenChecks`. Callers resolve it for
    /// the appearance they are painting into.
    public let accent: TokenColor

    public init(
        label: String,
        glyph: String,
        foreground: ChipColor,
        background: ChipColor,
        accent: TokenColor
    ) {
        self.label = label
        self.glyph = glyph
        self.foreground = foreground
        self.background = background
        self.accent = accent
    }
}

/// Maps an `AgentStatus` to its presentation. THE single source: ticket
/// docs/38-tickets/90-agent-ux/P1.8-one-status-presenter.md deleted five desktop
/// duplicates plus `AgentsBoardProjection`'s stringly-typed `colorToken` channel
/// and pointed every one of them here, because those six maps had drifted into
/// three disagreeing glyph sets and contradictory hues (`configuring` was purple
/// in the tile, teal on the board and invisible-grey in the sidebar; `◌` meant
/// *stale* in the sidebar and *configuring* in the tile).
///
/// The pill palette is a tinted pastel fill with a dark same-family foreground;
/// every pair clears WCAG AA (proven in `runStatusChipChecks`).
///
/// ACCENT PROVENANCE — every accent is an existing gated token, never a fresh
/// value, so this file cannot become a seventh palette:
///
///   configuring    accentInput      violet — matches the tile's shipped purple
///   working        accentWorking    blue
///   needsAttention accentApproval   amber
///   done           accentDone       green
///   idle           textSecondary    muted
///   stale          textSecondary    muted
///
/// `idle` and `stale` deliberately COLLAPSE onto the muted text token: neither
/// state asks anything of you, muted is the honest read, and it is what the
/// sidebar already painted for both (`SidebarAgentStatusKind` folds
/// `configuring`/`idle` into `.unknown` → `tertiaryLabelColor`). They stay
/// distinguishable by glyph (`○` vs `◌`) and label. This is the one place the
/// pill and the accent diverge in hue — `idle`'s pill is teal-family while its
/// accent is neutral — and that divergence is pinned as a fact in
/// `runStatusChipChecks` rather than left to drift. `AccentToken.accentFailed`
/// has no `AgentStatus`; it belongs to the error card and to Phase 4's failed
/// lifecycle state.
public enum StatusChipPresenter {
    public static func display(for status: AgentStatus) -> StatusChipDisplay {
        switch status {
        case .configuring:
            return StatusChipDisplay(
                label: "Configuring", glyph: "◐",
                foreground: ChipColor(r: 0.25, g: 0.10, b: 0.36),
                background: ChipColor(r: 0.91, g: 0.86, b: 0.98),
                accent: AccentToken.accentInput.color)
        case .working:
            return StatusChipDisplay(
                label: "Working", glyph: "●",
                foreground: ChipColor(r: 0.06, g: 0.20, b: 0.46),
                background: ChipColor(r: 0.83, g: 0.90, b: 0.99),
                accent: AccentToken.accentWorking.color)
        case .idle:
            return StatusChipDisplay(
                label: "Idle", glyph: "○",
                foreground: ChipColor(r: 0.04, g: 0.30, b: 0.32),
                background: ChipColor(r: 0.83, g: 0.95, b: 0.95),
                accent: TextToken.textSecondary.color)
        case .needsAttention:
            return StatusChipDisplay(
                label: "Needs attention", glyph: "◆",
                foreground: ChipColor(r: 0.45, g: 0.26, b: 0.02),
                background: ChipColor(r: 0.99, g: 0.92, b: 0.79),
                accent: AccentToken.accentApproval.color)
        case .done:
            return StatusChipDisplay(
                label: "Done", glyph: "✓",
                foreground: ChipColor(r: 0.07, g: 0.35, b: 0.13),
                background: ChipColor(r: 0.85, g: 0.96, b: 0.86),
                accent: AccentToken.accentDone.color)
        case .stale:
            return StatusChipDisplay(
                label: "Stale", glyph: "◌",
                foreground: ChipColor(r: 0.27, g: 0.30, b: 0.34),
                background: ChipColor(r: 0.90, g: 0.91, b: 0.93),
                accent: TextToken.textSecondary.color)
        }
    }
}
