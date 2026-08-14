import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P1.3-surface-text-border-tokens.md
//
// The named palette. Today the "same" dark background exists as three different
// values (desktop tile 0.08/0.10/0.13, its snapshot backing the same, iOS
// 0.05/0.06/0.08), the tile border is white@0.25 on white@0.10 (1.68:1), and
// muted text is Apple's `secondaryLabelColor` (3.95:1 on white) or
// `tertiaryLabelColor` (2.07:1 on the message card) — both of which cannot clear
// AA by construction. P0.4's gate measured 177 failing pairs over the real view
// tree; `P0.4-FINDINGS.md` lists every one. Those failures are this file's input.
//
// Semantic names only, never colour names: `accentWorking`, not `blue`. Nothing
// adopts these yet — P1.10 (tile) and P1.11 (chrome) do the adopting, P1.12 the
// iOS side, and P1.6 turns `--ui-contrast-check` on against the real tree.
//
// HOW THE VALUES WERE CHOSEN — every one is a computed ratio, not taste:
//
//  * Dark surfaces start from the shipped literals (the transcript card fills are
//    the existing 0.13/0.15/0.18 family, re-expressed on a hex grid) and are
//    ordered canvas < panel < tileBody < tileChrome < overlay so a tile reads as
//    an object sitting ON something.
//  * Light surfaces are DESIGNED, not inverted (ruling 3): in light appearance
//    the card fills become light tints carrying dark text. Keeping dark fills
//    under Aqua is the shipped black-on-dark bug (~25 of the 177 pairs).
//  * `textSecondary` is a house colour (ruling 1) — white-ish 0xAFB6C2 on dark,
//    black-ish 0x54585F on light — verified against EVERY documented surface.
//    Worst dark pair 6.53:1 (on `cardUserMessage`), worst light pair 5.99:1 (on
//    `canvas`). Apple's semantic label colours are not used anywhere here.
//  * Accents carry a darker light-appearance variant and a lighter dark one
//    (ruling 2), with the hue held steady across themes so a status reads the
//    same everywhere: measured hue drift is 0.9°–4.5° per accent, gated at ≤10°.
//    Contrast is symmetric, so one value per theme serves accent-as-text AND
//    accent-as-fill (with `textOnAccent`) — hence no separate `accentXText`.
//    Worst accent-on-surface pair: 5.27:1 light, 5.35:1 dark.
//  * `border` is 0x7A8290 / 0x767C86: worst 3.44:1 dark, 3.52:1 light. This is
//    the tile outline, which delineates the tile as an object and therefore is
//    NOT decorative (ruling 4) — the old white@0.25-on-white@0.10 at 1.68:1 is
//    the "canvas looks like mush" defect, and it is a regression witness in
//    `DesignTokenChecks`.
//
// MEASURED WORST CASE per foreground token, over its own legal backgrounds.
// These are pinned to ±0.01 in `runDesignTokenChecks`, so a colour tweak that
// still clears the floor goes red until this table is updated — the provenance
// cannot go stale while the suite stays green:
//
//   token           light            dark               floor
//   textPrimary     15.05 (canvas)   12.09 (cardUserMsg)  4.5
//   textSecondary    5.99 (canvas)    6.53 (cardUserMsg)  4.5
//   textOnAccent     6.29 (accFailed) 7.82 (accInput)      4.5
//   border           3.52 (canvas)    3.44 (cardUserMsg)  3.0
//   borderStrong     6.91 (canvas)    6.09 (cardUserMsg)  3.0
//   accentWorking    5.47 (canvas)    5.41 (cardUserMsg)  4.5
//   accentApproval   5.62 (canvas)    7.48 (cardUserMsg)  4.5
//   accentInput      6.32 (canvas)    5.35 (cardUserMsg)  4.5
//   accentFailed     5.27 (canvas)    5.85 (cardUserMsg)  4.5
//   accentDone       5.90 (canvas)    6.74 (cardUserMsg)  4.5
//   accentReview     5.41 (canvas)    7.35 (cardUserMsg)  4.5
//
// The worst background is `canvas` in light and `cardUserMessage` in dark for
// every token — the two ends of the surface ladder — which is what makes
// "clears its worst case" mean "clears all eleven surfaces".
//
// Every documented text/surface pair, both themes, is asserted in
// `runDesignTokenChecks`. Pairing is explicit (`legalBackgrounds` /
// `legalSurfaces`) so P1.6 gates real pairs rather than a cross-product.

/// A token's background: either a surface or an accent used as a fill. Text
/// tokens name which of these they are legal on, which is what makes the
/// documented-pair set finite and enumerable.
public enum TokenBackground: Equatable, Sendable {
    case surface(SurfaceToken)
    case accentFill(AccentToken)

    public var name: String {
        switch self {
        case .surface(let token): return token.rawValue
        case .accentFill(let token): return token.rawValue
        }
    }

    public var color: TokenColor {
        switch self {
        case .surface(let token): return token.color
        case .accentFill(let token): return token.color
        }
    }
}

/// Backgrounds. The first five are chrome (what the app is made of); the last
/// six are the transcript card fills, one per `ManagedTranscriptCardKind`.
public enum SurfaceToken: String, CaseIterable, Sendable {
    /// Behind the tiles. The darkest/lightest extreme, so a tile reads as raised.
    case canvas
    /// A tile's content area.
    case tileBody
    /// A tile's header and compose strip — one step off `tileBody`.
    case tileChrome
    /// The sidebar and Settings.
    case panel
    /// Popovers, menus, the approval dock — floats above everything.
    case overlay

    case cardMessage
    case cardUserMessage
    case cardTool
    case cardPlan
    case cardDiff
    case cardError

    public var color: TokenColor {
        switch self {
        case .canvas: return TokenColor(light: srgb(0xE9EBEF), dark: srgb(0x0B0D10))
        case .tileBody: return TokenColor(light: srgb(0xFAFBFC), dark: srgb(0x14171C))
        case .tileChrome: return TokenColor(light: srgb(0xF1F3F6), dark: srgb(0x1C212A))
        case .panel: return TokenColor(light: srgb(0xF5F6F9), dark: srgb(0x101318))
        case .overlay: return TokenColor(light: srgb(0xFFFFFF), dark: srgb(0x232935))
        case .cardMessage: return TokenColor(light: srgb(0xF0F2F5), dark: srgb(0x212630))
        // Your own messages read as a distinct, slightly blue surface — the one
        // card fill that carries a hue on purpose.
        case .cardUserMessage: return TokenColor(light: srgb(0xE5EEFB), dark: srgb(0x26303F))
        case .cardTool: return TokenColor(light: srgb(0xE8F3F5), dark: srgb(0x1F2A2D))
        case .cardPlan: return TokenColor(light: srgb(0xEFEBFA), dark: srgb(0x262330))
        case .cardDiff: return TokenColor(light: srgb(0xE6F4E9), dark: srgb(0x1F2B23))
        case .cardError: return TokenColor(light: srgb(0xFBE9E9), dark: srgb(0x33191B))
        }
    }

    /// The five chrome surfaces, for the tokens that only ever sit on chrome.
    public static let chrome: [SurfaceToken] = [.canvas, .tileBody, .tileChrome, .panel, .overlay]
    /// The six transcript card fills.
    public static let cards: [SurfaceToken] = [.cardMessage, .cardUserMessage, .cardTool, .cardPlan, .cardDiff, .cardError]
}

/// Foreground text. `legalBackgrounds` is the contract P1.6 gates.
public enum TextToken: String, CaseIterable, Sendable {
    /// Body and titles — the content itself.
    case textPrimary
    /// Metadata one step down. A HOUSE colour, not `secondaryLabelColor`
    /// (3.95:1 on white) and never `tertiaryLabelColor` (2.07:1 on a card).
    case textSecondary
    /// On an accent fill — a filled button, a badge.
    case textOnAccent

    public var color: TokenColor {
        switch self {
        case .textPrimary: return TokenColor(light: srgb(0x14171C), dark: srgb(0xF2F4F8))
        case .textSecondary: return TokenColor(light: srgb(0x54585F), dark: srgb(0xAFB6C2))
        case .textOnAccent: return TokenColor(light: srgb(0xFFFFFF), dark: srgb(0x0B0D10))
        }
    }

    /// Where this token is legal. Anything not listed here is a bug at the call
    /// site, not a colour to be re-tuned.
    public var legalBackgrounds: [TokenBackground] {
        switch self {
        case .textPrimary, .textSecondary:
            return SurfaceToken.allCases.map(TokenBackground.surface)
        case .textOnAccent:
            // Deliberately NOT legal on a surface: on `canvas` the light value
            // is white-on-near-white.
            return AccentToken.allCases.map(TokenBackground.accentFill)
        }
    }
}

/// Lines. Two are gated; one is an explicit, reasoned exemption.
public enum LineToken: String, CaseIterable, Sendable {
    /// The outline of an object — a tile, a dock, a text field. Delineates, so
    /// WCAG 1.4.11 applies and `contrastFloor` is 3.0.
    case border
    /// Focus and selection. State-conveying, so also gated.
    case borderStrong
    /// A hairline dividing content INSIDE an already-delineated surface.
    case separator

    public var color: TokenColor {
        switch self {
        case .border: return TokenColor(light: srgb(0x767C86), dark: srgb(0x7A8290))
        case .borderStrong: return TokenColor(light: srgb(0x4A4F57), dark: srgb(0xA8B0BD))
        case .separator: return TokenColor(light: srgb(0xDDE0E6), dark: srgb(0x2E343E))
        }
    }

    public var legalSurfaces: [SurfaceToken] {
        switch self {
        case .border, .borderStrong: return SurfaceToken.allCases
        case .separator: return SurfaceToken.allCases
        }
    }

    /// `nil` means exempt — and an exemption must state why (`exemptionReason`).
    /// Never a blanket waiver: `border` at 1.68:1 was exactly the defect.
    public var contrastFloor: Double? {
        switch self {
        case .border, .borderStrong: return 3.0
        case .separator: return nil
        }
    }

    /// The whole exemption list, per ruling 4. One entry.
    public var exemptionReason: String? {
        switch self {
        case .border, .borderStrong: return nil
        case .separator:
            return "Purely decorative: separates content inside a surface that "
                + "`border` has already delineated, conveys no state, and "
                + "bounds no control. WCAG 1.4.11 does not reach it."
        }
    }
}

// Ticket: docs/38-tickets/91-agent-tile-ux/P0.3-semantic-tile-tokens.md
//
// The v2 agent tile's own vocabulary: five surfaces the shipped palette has no
// name for (a composer field, a structured artifact, a fenced-code interior, a
// selected row, a hovered row) and the four LINE ROLES `_DESIGN.md` §11 splits
// meaning from decoration with.
//
// WHY THESE ARE NEW TYPES RATHER THAN NEW CASES. `SurfaceToken`/`LineToken` are
// pinned by P1.3 down to a 22-token count, a 104-pair set and a per-token
// worst-ratio table. Growing those enums would move numbers in
// `DesignTokenChecks`/`TokenContrastChecks`, which this packet's file fence does
// not include and which no v2 ticket has earned the right to renumber. So the
// tile ladder is ADDITIVE and gated by its own pair set (`AgentTileTokens`),
// leaving every shipped floor exactly where it is. The two sets merge into one
// when the live tile migrates and the compatibility path is removed.
//
// NOTHING ADOPTS THESE HERE, by packet instruction ("no baseline moves"): P3.x
// renderers and P4.x composer do the adopting.
//
// THE LINE-ROLE SPLIT is the point of the ticket. The prior pass applied WCAG
// 1.4.11's 3:1 non-text floor to every edge, including decorative ones, which is
// why the transcript reads as a stack of boxed cards. `_DESIGN.md` §11 splits:
//
//   decorativeHairline — containment and section separation. Conveys no state,
//                        bounds no control, so 1.4.11 does not reach it. EXEMPT,
//                        and measurably so: it does NOT clear 3:1 on any tile
//                        surface (1.02–1.37:1), which is exactly why a semantic
//                        role aliased onto it would be invisible as state.
//   controlBoundary    — the outline of an interactive shape. Gated at 3.0.
//   focusRing          — keyboard focus and selection. State-bearing, gated 3.0.
//   attention          — approval, error, warning. Gated at the TEXT floor 4.5,
//                        not 3.0, because the same accent labels the state in
//                        words as well as drawing the ring (P1.6 made that call
//                        for the approval dock; it holds here).
//
// Each role's colour IS a P1.3 token, never a fresh value: controlBoundary is
// `border`, focusRing is `borderStrong`, attention takes its hue from the status
// accent it reports, and only the decorative role resolves to the one exempt
// token, `separator`. So every role is already gated on the eleven shipped
// surfaces by P1.3's own sweep, and this file only has to gate it on the five new
// ones. `runAgentTileTokenChecks` asserts that mapping by value, both themes,
// which is what makes "a semantic line cannot be aliased to the hairline" a
// measurement rather than a naming convention.
//
// MEASURED WORST CASE over the five new surfaces (pinned to ±0.01 in
// `runAgentTileTokenChecks`, so a value tweak that still clears the floor goes
// red until this table is updated):
//
//   foreground                 light            dark            floor
//   textPrimary               13.98            11.20             4.5
//   textSecondary              5.56             6.04             4.5
//   controlBoundary            3.27             3.18             3.0
//   focusRing                  6.42             5.64             3.0
//   attention(approval)        5.23             6.92             4.5
//   attention(error)           4.90             5.42             4.5
//
// The worst background is `rowSelected` in BOTH themes for every one of them —
// it is the darkest light surface and the lightest dark one, i.e. the end of this
// ladder — which is what makes "clears its worst case" mean "clears all five".
//
// HOW THE SURFACE VALUES WERE CHOSEN. Light luminance runs 0.767–0.920 and dark
// 0.011–0.035, so every one is unambiguously a light surface under Aqua and a dark
// one under dark (the rule P1.3 applies to `SurfaceToken`, asserted here too).
// Where they land relative to the SHIPPED ladder, stated precisely because the
// obvious claim — "all five sit inside it" — is FALSE and was caught in review:
//
//   * `composer`/`artifact`/`rowHover` do sit inside it, between `tileBody`
//     (light 0.963466 / dark 0.008454) and the card fills.
//   * `codeSubdued` light is 0.827565, a hair BELOW the shipped light floor
//     `canvas` at 0.829723. Deliberate: a fenced-code interior is the most
//     recessed thing in a tile, and it is still 15.01:1 under `textPrimary`.
//   * `rowSelected` is past BOTH shipped ends — 0.767396 light against the
//     shipped light minimum (`canvas`, 0.829723) and 0.035147 dark against the
//     shipped dark maximum (`cardUserMessage`, 0.028849; `overlay.dark` is
//     0.022002, so the dark extreme is a card fill, not the overlay). Also
//     deliberate, and
//     structural rather than incidental: a selected row has to out-step every card
//     fill, which is exactly why it is every foreground's worst background in the
//     pinned table above. `runAgentTileTokenChecks` asserts that extremity over
//     all sixteen surfaces, so the pins cannot silently start describing a
//     different surface. Note that this narrows an older claim without editing
//     it: `SurfaceToken.canvas` is documented above as "the darkest/lightest
//     extreme", and it remains exactly that for the ELEVEN shipped surfaces and
//     for P1.3's own pinned table. Across all sixteen it is `rowSelected`, and
//     P1.3's numbers are untouched because its pair set does not include these
//     surfaces.
//
// `rowSelected`/`rowHover` are steps AWAY from `tileBody` measured against it:
// 1.24/1.46:1 selected versus 1.06/1.10:1 hover (light/dark). Hover is
// deliberately a whisper — it is transient pointer feedback — and selection is
// deliberately the stronger step; neither carries state alone, since a selected
// row also draws `focusRing`.

/// The v2 tile's surfaces. Additive to `SurfaceToken`: these are the fills the
/// shipped palette has no name for, and every one carries a light and a dark leaf.
public enum AgentSurfaceRole: String, CaseIterable, Sendable {
    /// The composer's editing field — a real surface, not a bezelled `NSTextField`.
    case composer
    /// A structured block's container: tool call, plan, diff, approval.
    case artifact
    /// A fenced code interior. Recedes rather than shouts: routine work should
    /// not out-contrast the prose around it.
    case codeSubdued
    /// A selected transcript row. Paired with `focusRing`, never the sole cue.
    case rowSelected
    /// A hovered transcript row. Transient pointer feedback only.
    case rowHover

    public var color: TokenColor {
        switch self {
        case .composer: return TokenColor(light: srgb(0xF4F6FA), dark: srgb(0x1A1F28))
        case .artifact: return TokenColor(light: srgb(0xEDF0F5), dark: srgb(0x1E2430))
        case .codeSubdued: return TokenColor(light: srgb(0xE7EBF1), dark: srgb(0x171C24))
        case .rowSelected: return TokenColor(light: srgb(0xD8E4F6), dark: srgb(0x2B3547))
        case .rowHover: return TokenColor(light: srgb(0xF2F4F7), dark: srgb(0x1B2028))
        }
    }

    /// The two row emphases, and the surface they are a step away from. Held as
    /// data so the "a selection you cannot see" failure is assertable.
    public static let rowEmphases: [AgentSurfaceRole] = [.rowSelected, .rowHover]
    /// What a row emphasis is measured against: a row sits on the tile body.
    public static let rowBase: SurfaceToken = .tileBody
}

/// What a line MEANS, which is what decides whether WCAG 1.4.11 reaches it.
/// Every role's colour is a P1.3 token — see the note above.
public enum AgentLineRole: String, CaseIterable, Sendable {
    /// Decorative containment and section separation. Not state-bearing.
    case decorativeHairline
    /// The boundary of an interactive shape.
    case controlBoundary
    /// Keyboard focus and selection.
    case focusRing
    /// Approval, error, warning.
    case attention

    public var color: TokenColor {
        switch self {
        case .decorativeHairline: return LineToken.separator.color
        case .controlBoundary: return LineToken.border.color
        case .focusRing: return LineToken.borderStrong.color
        // The primary attention hue. An attention line takes the hue of the
        // status it reports — see `attentionAccents`.
        case .attention: return AccentToken.accentApproval.color
        }
    }

    /// `nil` means exempt, and an exemption must say why. Same contract as
    /// `LineToken.contrastFloor`, deliberately: one rule for lines, applied to
    /// meaning instead of to every edge.
    public var contrastFloor: Double? {
        switch self {
        case .decorativeHairline: return nil
        case .controlBoundary, .focusRing: return DesignTokens.lineFloor
        // The text floor, not the line floor: this accent is also the label
        // colour for the same state.
        case .attention: return DesignTokens.textFloor
        }
    }

    public var exemptionReason: String? {
        switch self {
        case .controlBoundary, .focusRing, .attention: return nil
        case .decorativeHairline:
            return "Purely decorative: contains and separates content that is "
                + "already delineated by `controlBoundary`, conveys no state, and "
                + "bounds no control. WCAG 1.4.11 does not reach it — and it "
                + "measurably does not clear 3:1 on any tile surface, which is "
                + "why no state-bearing role may resolve to this value."
        }
    }

    /// True when this role is meaning-bearing and therefore gated.
    public var isSemantic: Bool { contrastFloor != nil }

    /// The accents an attention line may take its hue from: an approval waiting
    /// on you, and an error. Both are gated on every tile surface, so a warning
    /// ring cannot be introduced later at an unmeasured hue.
    public static let attentionAccents: [AccentToken] = [.accentApproval, .accentFailed]
}

/// The v2 tile's pair set. Separate from `DesignTokens.documentedPairs` on
/// purpose (see the note above): this gates the FIVE NEW surfaces, and the
/// shipped eleven remain P1.3's to gate.
public enum AgentTileTokens {
    /// Text that is painted on a tile surface. `textOnAccent` is absent for the
    /// same reason it is absent from `SurfaceToken` pairs — it is white on
    /// near-white anywhere but an accent fill.
    public static let surfaceTextTokens: [TextToken] = [.textPrimary, .textSecondary]

    /// Every pair the tile ladder claims is legal, derived from the roles' own
    /// declarations. Adding a surface or a role without pairing it is therefore
    /// impossible, and an exempt role contributes nothing rather than a floor of 1.
    public static var documentedPairs: [TokenPair] {
        var pairs: [TokenPair] = []
        for surface in AgentSurfaceRole.allCases {
            for text in surfaceTextTokens {
                pairs.append(TokenPair(
                    foreground: text.rawValue, background: surface.rawValue,
                    color: text.color, backgroundColor: surface.color,
                    floor: DesignTokens.textFloor))
            }
            for role in AgentLineRole.allCases {
                guard let floor = role.contrastFloor else { continue }
                if role == .attention {
                    for accent in AgentLineRole.attentionAccents {
                        pairs.append(TokenPair(
                            foreground: "\(role.rawValue)(\(accent.rawValue))",
                            background: surface.rawValue,
                            color: accent.color, backgroundColor: surface.color, floor: floor))
                    }
                } else {
                    pairs.append(TokenPair(
                        foreground: role.rawValue, background: surface.rawValue,
                        color: role.color, backgroundColor: surface.color, floor: floor))
                }
            }
        }
        return pairs
    }

    /// The decorative roles, each with its reason. A list rather than an absence,
    /// so an exemption is visible and countable.
    public static var decorativeExemptions: [(role: AgentLineRole, reason: String)] {
        AgentLineRole.allCases.compactMap { role in
            guard role.contrastFloor == nil, let reason = role.exemptionReason else { return nil }
            return (role, reason)
        }
    }

    /// How far a row emphasis is from the row's own base surface, as a ratio the
    /// same evaluator measures. A selection that equals `tileBody` is invisible.
    public static func rowEmphasisRatio(_ role: AgentSurfaceRole, theme: TokenTheme) -> Double {
        WCAGContrast.ratio(
            role.color.resolved(for: theme),
            AgentSurfaceRole.rowBase.color.resolved(for: theme))
    }
}

// Ticket: docs/38-tickets/94-sidebar-native-ux/P0.5-row-token-vocabulary.md
//
// The sidebar's interaction fill ladder: resting, multi-selected, hovered,
// route-active. Queue 94's locked decision is that SURFACE IS RESERVED FOR
// INTERACTION — a sidebar row paints no perimeter border and no status fill;
// at rest it is the panel itself, and the only fills it ever takes are these
// three, with SELECTION QUIETER THAN HOVER because hover is transient pointer
// feedback and selection is a resting state you park on. That is T3 Code's
// model (plan-sidebar-t3code-study.md: hover 8%, route-active 11%, selected 7%
// foreground mixes), and it is deliberately the OPPOSITE loudness order from
// the tile's `rowSelected`/`rowHover` above: a selected transcript row must
// out-step every card fill and pairs with `focusRing`, so the tile ladder
// steps 1.24/1.46:1 selected vs 1.06/1.10:1 hover. An inbox list has no card
// fills to beat, and a selection you park on must not shout.
//
// WHY A NEW TYPE RATHER THAN NEW CASES. `AgentSurfaceRole` is pinned to five
// cases in `runAgentTileTokenChecks`, its `rowSelected` extremity across the
// sixteen-surface ladder is load-bearing for that suite's pinned worst-case
// table, and its values are consumed live (ChoiceListView, ChoiceButton,
// ComposerTextView, ApprovalRenderer) — so the tile enum must not grow and
// its values must not move. Same call P0.3 made against P1.3's pinned enums;
// `runSidebarSurfaceChecks` pins the tile row values to make it enforceable.
//
// NO INVENTED COLOURS. Every fill is `textPrimary` composited over `panel`
// (the sidebar's own P1.3 surface) at a named alpha, using the same
// `composited(over:alpha:)` model P3.5 gates the in-flight fade with. The
// only new numbers are the three mix strengths, and they are T3 Code's, not
// taste: selected 0.07 < hover 0.08 < active 0.11.
//
// MEASURED, both appearances, pinned to ±0.01 in `runSidebarSurfaceChecks`
// (emphasis = contrast ratio of the resolved fill against the resting
// `panel`):
//
//   role        alpha   light   dark    floor
//   resting     0       1.00    1.00    —  (identity: it IS panel)
//   selected    0.07    1.15    1.18    1.10
//   hover       0.08    1.17    1.21    1.10
//   active      0.11    1.25    1.32    1.20
//
// so hover > selected and active > hover hold BY MEASUREMENT in both themes,
// and the suite asserts the strict ordering itself, not these pins alone.
//
// Every foreground the sidebar paints on the three fills is gated at its own
// floor, worst case pinned (±0.01). The worst background is `sidebarActive`
// in BOTH themes for every foreground — the strongest mix, the end of the
// ladder:
//
//   foreground        light   dark    floor
//   textPrimary       13.28   12.77    4.5
//   textSecondary      5.28    6.89    4.5
//   accentWorking      4.83    5.71    4.5
//   accentApproval     4.96    7.89    4.5
//   accentInput        5.58    5.65    4.5
//   accentFailed       4.65    6.18    4.5
//   accentDone         5.21    7.12    4.5
//   accentReview       4.77    7.75    4.5
//   controlBoundary    3.11    3.63    3.0
//   focusRing          6.10    6.43    3.0
//
// `resting` contributes no pair: it resolves to `panel` exactly, and P1.3
// already gates every text, accent, and line token there. Attention lines
// are covered by value: `AgentLineRole.attentionAccents` are gated here as
// status accents at the same 4.5 floor `attention` itself carries.
//
// NOTHING ADOPTS THESE YET, by packet instruction ("no baseline can move in
// this packet"): the P1.x row work does the adopting.

/// The sidebar row's interaction fills, quietest-first. Additive to
/// `AgentSurfaceRole` for the reasons above; the two ladders serve different
/// surfaces and deliberately disagree about selection loudness.
public enum SidebarSurfaceRole: String, CaseIterable, Sendable {
    /// A row at rest paints NO fill — this role resolves to `panel` itself,
    /// so "unfilled" is a measurable identity, not a view-layer promise.
    case resting = "sidebarResting"
    /// A multi-selected row. QUIETER than hover: selection is a resting
    /// state, and it is not the row you are pointing at.
    case selected = "sidebarSelected"
    /// A hovered row. Transient pointer feedback, one step louder than
    /// selection so the pointer's row always reads above a parked selection.
    case hover = "sidebarHover"
    /// The route-active row — the agent whose tile is open. The loudest
    /// step, because it answers "where am I" from anywhere in the list.
    case active = "sidebarActive"

    /// The strength of the `textPrimary` mix over `panel`. T3 Code's numbers
    /// (7/8/11%), ordered selected < hover < active; `resting` mixes nothing.
    public var emphasisAlpha: Double {
        switch self {
        case .resting: return 0
        case .selected: return 0.07
        case .hover: return 0.08
        case .active: return 0.11
        }
    }

    /// Resolved per theme by compositing existing tokens — never a fresh
    /// hex. At alpha 0 `composited` returns the background exactly, so
    /// `resting` IS `panel` by construction.
    public var color: TokenColor {
        let base = SidebarSurfaceRole.rowBase.color
        let mix = TextToken.textPrimary.color
        return TokenColor(
            light: mix.light.composited(over: base.light, alpha: emphasisAlpha),
            dark: mix.dark.composited(over: base.dark, alpha: emphasisAlpha))
    }

    /// The three fills, quietest-first — what `runSidebarSurfaceChecks`
    /// orders and floors by measurement.
    public static let rowEmphases: [SidebarSurfaceRole] = [.selected, .hover, .active]
    /// What an emphasis is measured against: a sidebar row rests on `panel`
    /// ("The sidebar and Settings" — P1.3).
    public static let rowBase: SurfaceToken = .panel
}

/// The sidebar ladder's pair set, mirroring `AgentTileTokens`: these gate
/// the THREE new fills, and `panel` (= `resting`) stays P1.3's to gate.
public enum SidebarTokens {
    /// Text painted on a sidebar fill. Same two as the tile, same reasoning.
    public static let surfaceTextTokens: [TextToken] = [.textPrimary, .textSecondary]
    /// A row carries its status as an accent word or glyph, so every accent
    /// must read on every fill. This superset of
    /// `AgentLineRole.attentionAccents` is what covers attention lines on
    /// these fills, by value, at the same 4.5 floor.
    public static let statusAccents: [AccentToken] = AccentToken.allCases
    /// The semantic line roles a sidebar fill can host. The decorative
    /// hairline is deliberately absent — exempt, and never state-bearing.
    public static let gatedLineRoles: [AgentLineRole] = [.controlBoundary, .focusRing]

    /// Every pair the sidebar ladder claims is legal, derived from the
    /// declarations above so a new fill cannot ship unpaired.
    public static var documentedPairs: [TokenPair] {
        var pairs: [TokenPair] = []
        for surface in SidebarSurfaceRole.rowEmphases {
            for text in surfaceTextTokens {
                pairs.append(TokenPair(
                    foreground: text.rawValue, background: surface.rawValue,
                    color: text.color, backgroundColor: surface.color,
                    floor: DesignTokens.textFloor))
            }
            for accent in statusAccents {
                pairs.append(TokenPair(
                    foreground: accent.rawValue, background: surface.rawValue,
                    color: accent.color, backgroundColor: surface.color,
                    floor: DesignTokens.textFloor))
            }
            for role in gatedLineRoles {
                guard let floor = role.contrastFloor else { continue }
                pairs.append(TokenPair(
                    foreground: role.rawValue, background: surface.rawValue,
                    color: role.color, backgroundColor: surface.color, floor: floor))
            }
        }
        return pairs
    }

    /// How far a fill steps from the resting panel, as a ratio the same
    /// evaluator measures. This is the number the ladder's ordering is
    /// asserted on — selection quieter than hover is a measurement here,
    /// never a naming convention.
    public static func rowEmphasisRatio(_ role: SidebarSurfaceRole, theme: TokenTheme) -> Double {
        WCAGContrast.ratio(
            role.color.resolved(for: theme),
            SidebarSurfaceRole.rowBase.color.resolved(for: theme))
    }
}

/// Status accents. One per state, hue stable across themes.
public enum AccentToken: String, CaseIterable, Sendable {
    case accentWorking
    case accentApproval
    case accentInput
    case accentFailed
    case accentDone
    // Ticket: docs/38-tickets/96-agent-sidebar-product-redesign/_DESIGN.md
    /// Work that FINISHED and nobody has looked at it.
    ///
    /// A sixth accent, and the argument for it is that the fifth cannot carry this.
    /// `accentDone` green says "this went well"; `accentApproval` amber says "make a
    /// decision". A finished turn nobody has read is neither — it wants your eyes,
    /// not your judgement, and it is not a problem. Painting it amber makes it
    /// indistinguishable from an approval that is actually blocking; painting it
    /// green makes it indistinguishable from the forty finished rows you already
    /// read, which is the exact failure program 96 added the state to prevent.
    ///
    /// Mint. The first attempt at this was a rose, `0xE5799B`, and it shipped for
    /// one round before Dylan rejected it on sight: it read as a second error
    /// colour. He was right, and it is measurable — the dark failure red is hue 3°
    /// and that rose was 342°, **21° apart**, with nothing in the gate to notice.
    ///
    /// Mint instead, because "unseen" belongs to the FINISHED family, not the alarm
    /// family: nothing is blocked, the work went well, it is simply sitting there.
    /// The family resemblance to a row you already read is the point — the only
    /// difference between those two rows is whether you looked.
    ///
    /// Which is why this can only be mint if a settled row stops being green. At 25°
    /// from `accentDone` it would have repeated the rose's failure one hue over, so
    /// program 96's row retires green (a settled row is the one row asking for
    /// nothing) and mint gets a 48° gap to its nearest neighbour — the widest in the
    /// palette. See `runAccentSeparationCheck`, which now enforces that gap so the
    /// next near-miss goes red instead of shipping.
    ///
    /// `0x4CD6B4` is Dylan's hue at a value that clears the accent band; the light
    /// one is the darkened variant that clears the 4.5:1 text floor on a near-white
    /// surface, exactly as every accent above is built.
    case accentReview

    public var color: TokenColor {
        switch self {
        // Light values are the darkened (-600/-700) variants that clear 4.5:1 on
        // a near-white surface; dark values are the lighter (-300) ones. Both
        // ends hold the hue: 217/213 blue, 36/35 amber, 265/267 violet,
        // 2/3 red, 139/140 green, 168/165 mint.
        case .accentWorking: return TokenColor(light: srgb(0x1257C7), dark: srgb(0x5FA8FF))
        case .accentApproval: return TokenColor(light: srgb(0x845000), dark: srgb(0xFFB347))
        case .accentInput: return TokenColor(light: srgb(0x6B2FBF), dark: srgb(0xC08CFF))
        case .accentFailed: return TokenColor(light: srgb(0xB92420), dark: srgb(0xFF8A85))
        case .accentDone: return TokenColor(light: srgb(0x186630), dark: srgb(0x4FD07A))
        case .accentReview: return TokenColor(light: srgb(0x096B57), dark: srgb(0x4CD6B4))
        }
    }

    /// An accent is legal as text or as a glyph on every surface — a status has
    /// to read on a card as well as on the tile. Held to the 4.5 text floor, not
    /// the 3.0 glyph floor, because these ARE used as label colours (root cause
    /// 3 of the 177: `#FF8D28` at 2.31:1 on white).
    public var legalSurfaces: [SurfaceToken] { SurfaceToken.allCases }
}

// Ticket: docs/38-tickets/90-agent-ux/P3.5-in-flight-fade.md
/// The only two strengths anything in the agent UI is painted at. An opacity is
/// a token for the same reason a colour is: a literal `0.6` at a call site is a
/// contrast decision made where nothing can measure it.
///
/// PROVENANCE of `receded` — DERIVED FROM THE FLOOR, not chosen. Fading a
/// foreground composites it toward its own background, so every point of alpha
/// spends contrast the palette does not have much of: `textSecondary` is the
/// tightest token at 5.99:1 (on `canvas`, light). Solving
/// `ratio(α·fg + (1-α)·bg, bg) = 4.5` over EVERY documented text pair in BOTH
/// themes puts the break-even at **α = 0.8724** (textSecondary on canvas,
/// light). `receded` is 0.88 — the smallest hundredth above that break-even, so
/// the fade is as deep as AA allows and not one step deeper. Worst faded pair
/// is then 4.58:1, and `runRowEmphasisChecks` measures all of them rather than
/// trusting this note.
///
/// This is the honest limit, and it is worth stating plainly: 0.88 is a subtle
/// dim, not a dramatic one. The packet's own rule ("fading is not a licence to
/// fail contrast") is what bounds it. A deeper fade would need a dimmer text
/// token that clears 4.5:1 at full strength — a palette change, which is P1.3's
/// to make, not this ticket's to sneak in under an alpha.
public enum Opacity {
    public static let full = 1.0
    public static let receded = 0.88
}

/// One (foreground, background) pair that the app is allowed to paint, with the
/// ratio it must clear. This is the enumerable contract P1.6 gates against the
/// real view tree — a finite, documented list, not a cross-product.
public struct TokenPair: Equatable, Sendable {
    public let foreground: String
    public let background: String
    public let color: TokenColor
    public let backgroundColor: TokenColor
    public let floor: Double

    public init(foreground: String, background: String, color: TokenColor, backgroundColor: TokenColor, floor: Double) {
        self.foreground = foreground
        self.background = background
        self.color = color
        self.backgroundColor = backgroundColor
        self.floor = floor
    }

    public func ratio(for theme: TokenTheme) -> Double {
        WCAGContrast.ratio(color.resolved(for: theme), backgroundColor.resolved(for: theme))
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.5-in-flight-fade.md
    /// The same pair as it is actually painted when the row it sits on has
    /// receded: the foreground composited over THIS pair's background at
    /// `alpha`, at full opacity. The floor is unchanged — a faded pair is still
    /// a pair the app paints, so it answers to the same ratio.
    ///
    /// Compositing rather than "an alpha the gate is told about" is the point:
    /// a translucent foreground IS its blend with what is behind it, and that
    /// blend is a colour `WCAGContrast` can measure. The two ends are exact —
    /// `alpha` 1 returns this pair's own colour and 0 returns the background,
    /// giving ratio 1.0.
    public func faded(_ alpha: Double) -> TokenPair {
        TokenPair(
            foreground: "\(foreground)@\(alpha)",
            background: background,
            color: TokenColor(
                light: color.light.composited(over: backgroundColor.light, alpha: alpha),
                dark: color.dark.composited(over: backgroundColor.dark, alpha: alpha)),
            backgroundColor: backgroundColor,
            floor: floor)
    }
}

extension ChipColor {
    // Ticket: docs/38-tickets/90-agent-ux/P3.5-in-flight-fade.md
    /// Source-over compositing of `self` at `alpha` onto an opaque `background`,
    /// per channel, in the sRGB space both operands are already expressed in.
    ///
    /// This is a TOKEN-LEVEL model of the blend, which is the level this module
    /// can honestly gate: it has no view tree and no colour space to ask. What
    /// the window server actually composites is `--ui-contrast-check`'s
    /// question — that gate reads real rendered pixels and already applies
    /// ancestor alpha and `layer.opacity` (P0.4) — so a receded row is measured
    /// there too once P3.6 paints one.
    public func composited(over background: ChipColor, alpha: Double) -> ChipColor {
        let a = min(max(alpha, 0), 1)
        return ChipColor(
            r: a * r + (1 - a) * background.r,
            g: a * g + (1 - a) * background.g,
            b: a * b + (1 - a) * background.b)
    }
}

public enum DesignTokens {
    /// The AA floor for text, and the 1.4.11 floor for lines and glyphs.
    public static let textFloor = 4.5
    public static let lineFloor = 3.0

    /// Every pair the palette claims is legal. Derived from the tokens' own
    /// declarations, so adding a token without pairing it is impossible and
    /// widening a token's legal set immediately widens what gets gated.
    public static var documentedPairs: [TokenPair] {
        var pairs: [TokenPair] = []
        for text in TextToken.allCases {
            for background in text.legalBackgrounds {
                pairs.append(TokenPair(
                    foreground: text.rawValue, background: background.name,
                    color: text.color, backgroundColor: background.color, floor: textFloor))
            }
        }
        for accent in AccentToken.allCases {
            for surface in accent.legalSurfaces {
                pairs.append(TokenPair(
                    foreground: accent.rawValue, background: surface.rawValue,
                    color: accent.color, backgroundColor: surface.color, floor: textFloor))
            }
        }
        for line in LineToken.allCases {
            guard let floor = line.contrastFloor else { continue }
            for surface in line.legalSurfaces {
                pairs.append(TokenPair(
                    foreground: line.rawValue, background: surface.rawValue,
                    color: line.color, backgroundColor: surface.color, floor: floor))
            }
        }
        return pairs
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.5-in-flight-fade.md
    /// Every documented TEXT pair as a receded row paints it. Derived from
    /// `documentedPairs`, so a new text token or a widened legal set is gated
    /// faded the moment it is gated at full strength — the fade cannot fall
    /// behind the palette.
    ///
    /// Text only, and that is the whole of what recedes: `RowEmphasis` fades a
    /// row's words, never its status accent (which stays full strength so a
    /// waiting row is still findable) and never a line token (a border is not
    /// on a row's text layer). Filtering on the text tokens' own raw values
    /// rather than on the floor keeps accents out even though they share the
    /// 4.5 floor.
    public static var recededTextPairs: [TokenPair] {
        let textNames = Set(TextToken.allCases.map(\.rawValue))
        return documentedPairs
            .filter { textNames.contains($0.foreground) }
            .map { $0.faded(Opacity.receded) }
    }

    /// Line tokens that are deliberately not gated, each with its reason. Kept
    /// as a list rather than an absence so an exemption is visible and countable.
    public static var decorativeExemptions: [(token: LineToken, reason: String)] {
        LineToken.allCases.compactMap { line in
            guard line.contrastFloor == nil, let reason = line.exemptionReason else { return nil }
            return (line, reason)
        }
    }
}

/// 0xRRGGBB → `ChipColor`. Hex because that is how the audit reported every one
/// of the 177 failing pairs, so a value here can be diffed against its finding.
func srgb(_ hex: UInt32) -> ChipColor {
    ChipColor(
        r: Double((hex >> 16) & 0xFF) / 255.0,
        g: Double((hex >> 8) & 0xFF) / 255.0,
        b: Double(hex & 0xFF) / 255.0)
}
