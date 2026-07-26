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

/// Status accents. One per state, hue stable across themes.
public enum AccentToken: String, CaseIterable, Sendable {
    case accentWorking
    case accentApproval
    case accentInput
    case accentFailed
    case accentDone

    public var color: TokenColor {
        switch self {
        // Light values are the darkened (-600/-700) variants that clear 4.5:1 on
        // a near-white surface; dark values are the lighter (-300) ones. Both
        // ends hold the hue: 217/213 blue, 36/35 amber, 265/267 violet,
        // 2/3 red, 139/140 green.
        case .accentWorking: return TokenColor(light: srgb(0x1257C7), dark: srgb(0x5FA8FF))
        case .accentApproval: return TokenColor(light: srgb(0x845000), dark: srgb(0xFFB347))
        case .accentInput: return TokenColor(light: srgb(0x6B2FBF), dark: srgb(0xC08CFF))
        case .accentFailed: return TokenColor(light: srgb(0xB92420), dark: srgb(0xFF8A85))
        case .accentDone: return TokenColor(light: srgb(0x186630), dark: srgb(0x4FD07A))
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
