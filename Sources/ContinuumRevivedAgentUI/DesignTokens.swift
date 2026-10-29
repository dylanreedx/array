import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P1.3-surface-text-border-tokens.md
// Neutral app palette: shared by the native canvas, tiles, sidebar and controls.
// Surface lightness retains the existing hierarchy; text and lines are neutral
// too. Only semantic status accents carry hue. Transcript kinds keep distinct
// neutral fills, with their labels and status accents carrying meaning.
// Both appearances are measured by DesignTokenChecks and TokenContrastChecks:
// text >= 4.5:1, semantic boundaries >= 3:1. Decorative separators are exempt.
// Current worst-pair measurements are pinned in those checks, not historical
// values copied from the former blue-tinted palette.

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

    public var color: TokenColor { color(for: AppTheme.current) }

    public func color(for theme: AppTheme) -> TokenColor {
        switch self {
        case .canvas: return theme.surface(light: srgb(0xEBEBEB), dark: srgb(0x0D0D0D), role: rawValue)
        case .tileBody: return theme.surface(light: srgb(0xFBFBFB), dark: srgb(0x171717), role: rawValue)
        case .tileChrome: return theme.surface(light: srgb(0xF3F3F3), dark: srgb(0x212121), role: rawValue)
        case .panel: return theme.surface(light: srgb(0xF6F6F6), dark: srgb(0x131313), role: rawValue)
        case .overlay: return theme.surface(light: srgb(0xFFFFFF), dark: srgb(0x292929), role: rawValue)
        case .cardMessage: return theme.surface(light: srgb(0xF2F2F2), dark: srgb(0x262626), role: rawValue)
        // Your own messages retain a distinct neutral surface.
        case .cardUserMessage: return theme.surface(light: srgb(0xEDEDED), dark: srgb(0x2F2F2F), role: rawValue)
        case .cardTool: return theme.surface(light: srgb(0xF1F1F1), dark: srgb(0x282828), role: rawValue)
        case .cardPlan: return theme.surface(light: srgb(0xECECEC), dark: srgb(0x252525), role: rawValue)
        case .cardDiff: return theme.surface(light: srgb(0xF0F0F0), dark: srgb(0x272727), role: rawValue)
        case .cardError: return theme.surface(light: srgb(0xEEEEEE), dark: srgb(0x202020), role: rawValue)
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
        case .textPrimary: return TokenColor(light: srgb(0x171717), dark: srgb(0xF4F4F4))
        case .textSecondary: return TokenColor(light: srgb(0x585858), dark: srgb(0xB5B5B5))
        case .textOnAccent: return TokenColor(light: srgb(0xFFFFFF), dark: srgb(0x0D0D0D))
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

/// Foregrounds for bundled brand silhouettes. These deliberately do not join
/// `TextToken`: a vendor mark is neither text nor a status accent, and its tiny
/// geometry needs the full black/white endpoint rather than the softened house
/// foreground used for words.
public enum BrandToken {
    public static let providerForeground = TokenColor(
        light: ChipColor(r: 0, g: 0, b: 0),
        dark: ChipColor(r: 1, g: 1, b: 1))
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
        case .border: return TokenColor(light: srgb(0x7C7C7C), dark: srgb(0x818181))
        case .borderStrong: return TokenColor(light: srgb(0x4F4F4F), dark: srgb(0xAFAFAF))
        case .separator: return TokenColor(light: srgb(0xE0E0E0), dark: srgb(0x343434))
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
// Neutral tile surfaces. Selection remains the strongest step in both themes.
// Line roles distinguish decorative containment from interactive boundaries,
// focus, authorship and attention. AgentTileTokens measures the same text and
// boundary floors on these additional surfaces; the check pins current margins.
/// Surface roles used by the native agent tile and shared choice controls.
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

    public var color: TokenColor { color(for: AppTheme.current) }

    public func color(for theme: AppTheme) -> TokenColor {
        switch self {
        case .composer: return theme.surface(light: srgb(0xF5F5F5), dark: srgb(0x1F1F1F), role: rawValue)
        case .artifact: return theme.surface(light: srgb(0xEFEFEF), dark: srgb(0x242424), role: rawValue)
        case .codeSubdued: return theme.surface(light: srgb(0xE9E9E9), dark: srgb(0x1C1C1C), role: rawValue)
        case .rowSelected: return theme.surface(light: srgb(0xE3E3E3), dark: srgb(0x353535), role: rawValue)
        case .rowHover: return theme.surface(light: srgb(0xF4F4F4), dark: srgb(0x1E1E1E), role: rawValue)
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
    /// Whose turn this is. The sole authorship signal on a user turn now that
    /// the turn carries no fill — meaning-bearing by construction, so it
    /// cannot resolve to `decorativeHairline` (see that case's
    /// `exemptionReason`). Distinct from `controlBoundary`: a user turn
    /// bounds no control, it identifies a speaker.
    case authorship

    public var color: TokenColor {
        switch self {
        case .decorativeHairline: return LineToken.separator.color
        case .controlBoundary: return LineToken.border.color
        case .focusRing: return LineToken.borderStrong.color
        // The primary attention hue. An attention line takes the hue of the
        // status it reports — see `attentionAccents`.
        case .attention: return AccentToken.accentApproval.color
        case .authorship: return LineToken.border.color
        }
    }

    /// `nil` means exempt, and an exemption must say why. Same contract as
    /// `LineToken.contrastFloor`, deliberately: one rule for lines, applied to
    /// meaning instead of to every edge.
    public var contrastFloor: Double? {
        switch self {
        case .decorativeHairline: return nil
        case .controlBoundary, .focusRing, .authorship: return DesignTokens.lineFloor
        // The text floor, not the line floor: this accent is also the label
        // colour for the same state.
        case .attention: return DesignTokens.textFloor
        }
    }

    public var exemptionReason: String? {
        switch self {
        case .controlBoundary, .focusRing, .attention, .authorship: return nil
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
// Sidebar interaction fills derive from the neutral foreground over panel.
// Resting has no fill; selected (7%) < hover (8%) < route-active (11%).
// SidebarTokens gates foreground contrast on each composite, and the checks
// pin the resolved emphasis and current worst-case margins in both themes.
/// The sidebar's neutral interaction ladder, quietest first.
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

/// A CONTROL drawn on a sidebar row — the settle nudge — as opposed to the
/// row's own fills above. It has to read as a button on a row at rest AND on
/// a hovered one, so its quietest step sits well above the row's loudest
/// (`SidebarSurfaceRole.active`, 11%): 18%, with hover and pressed one clear
/// step each beyond it. Same construction as the row ladder — `textPrimary`
/// over `panel`, never a fresh hex — so it is neutral in both themes and the
/// text on it keeps `textPrimary`'s contrast.
public enum SidebarControlRole: String, CaseIterable, Sendable {
    case resting = "sidebarControlResting"
    case hover = "sidebarControlHover"
    case pressed = "sidebarControlPressed"

    public var emphasisAlpha: Double {
        switch self {
        case .resting: return 0.18
        case .hover: return 0.24
        case .pressed: return 0.32
        }
    }

    public var color: TokenColor {
        let base = SidebarSurfaceRole.rowBase.color
        let mix = TextToken.textPrimary.color
        return TokenColor(
            light: mix.light.composited(over: base.light, alpha: emphasisAlpha),
            dark: mix.dark.composited(over: base.dark, alpha: emphasisAlpha))
    }
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
