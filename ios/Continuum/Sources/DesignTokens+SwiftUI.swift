import SwiftUI
import ContinuumRevivedAgentUI

// Ticket: docs/38-tickets/90-agent-ux/P1.12-ios-consumes-tokens.md
//
// THE ONE PLACE iOS turns a design token into something SwiftUI can paint.
// Before this file the phone carried its own palette (`AppColors`: two dark-only
// literals plus a status accent pinned to `.dark`), so "build once, render
// twice" was false in both directions — the phone disagreed with the desktop's
// surfaces, and it had no light appearance at all.
//
// Two rules make it the ONLY place, and `scripts/check-color-hygiene.sh` enforces
// both mechanically:
//
//   * Rule 1 (P1.7) bans raw colour construction in the scanned iOS sources.
//     `Color(.sRGB, red:…)` below is the explicit-colour-space form ticket 87's
//     watch-out #1 requires — a `Color(red:…)` would be device RGB, which is not
//     where the tokens' ratios were measured — so rule 1 must let it through.
//   * Rule 4 (this ticket) therefore bans BOTH of the routes that leaves open,
//     anywhere else under `ios/Continuum/Sources`: `resolved(for:)` or a
//     `TokenTheme` literal (a call site pinning itself to one appearance, which
//     is exactly what `AppColors.statusAccent(for:)` did), and the
//     explicit-colour-space initialiser itself (the one raw spelling rule 1 has
//     to allow, hence the one a call site could use to bypass this file).
//
// Theme resolution therefore happens HERE, from `@Environment(\.colorScheme)`,
// which is the trait SwiftUI already keeps correct through appearance changes.
// The modifiers below read it themselves so an ordinary call site needs no
// plumbing at all; `TokenPalette` is for the handful of places that need a
// `Color` *value* (a `Shape.fill`, a `ZStack` backdrop) rather than a modifier.

extension TokenTheme {
    /// SwiftUI's `ColorScheme` has exactly the two cases `TokenTheme` has today;
    /// anything Apple adds later is treated as light rather than silently dark,
    /// because a dark leaf on an unknown-but-light background is the failure mode
    /// this phase exists to remove.
    init(_ colorScheme: ColorScheme) {
        self = colorScheme == .dark ? .dark : .light
    }
}

extension Color {
    /// Explicit sRGB, per ticket 87 watch-out #1: `ChipColor`/`TokenColor`
    /// components ARE sRGB, and that is the space `WCAGContrast` measured the
    /// gated ratios in.
    ///
    /// This is the sRGB bridge for both shapes of `StatusChipDisplay` — the pill's
    /// unthemed pastel (`ChipColor`) and, through `init(token:theme:)`, the
    /// appearance-aware accent.
    init(chip: ChipColor) {
        self.init(.sRGB, red: chip.r, green: chip.g, blue: chip.b, opacity: 1)
    }

    init(token: TokenColor, theme: TokenTheme) {
        self.init(chip: token.resolved(for: theme))
    }
}

/// A theme resolved once, for call sites that need a `Color` value. Overloaded
/// per token FAMILY rather than taking a bare `TokenColor`, so a fill asks for a
/// `SurfaceToken` and a label asks for a `TextToken` — the same kind-scoping the
/// desktop gate (`UIProbeAppearance` check 4) asserts, kept here at the type
/// level where it costs nothing.
struct TokenPalette {
    let theme: TokenTheme

    init(_ colorScheme: ColorScheme) {
        self.theme = TokenTheme(colorScheme)
    }

    func color(_ surface: SurfaceToken) -> Color { Color(token: surface.color, theme: theme) }
    func color(_ text: TextToken) -> Color { Color(token: text.color, theme: theme) }
    func color(_ line: LineToken) -> Color { Color(token: line.color, theme: theme) }
    func color(_ accent: AccentToken) -> Color { Color(token: accent.color, theme: theme) }
    /// For `StatusChipDisplay.accent`, which the presenter hands over already
    /// sourced from a gated token (`AccentToken` / `TextToken.textSecondary`).
    func color(token: TokenColor) -> Color { Color(token: token, theme: theme) }
}

private struct TokenForegroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let token: TokenColor

    func body(content: Content) -> some View {
        content.foregroundStyle(Color(token: token, theme: TokenTheme(colorScheme)))
    }
}

private struct TokenBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let surface: SurfaceToken
    let ignoringSafeArea: Bool

    func body(content: Content) -> some View {
        let color = Color(token: surface.color, theme: TokenTheme(colorScheme))
        return content.background {
            if ignoringSafeArea {
                color.ignoresSafeArea()
            } else {
                color
            }
        }
    }
}

extension View {
    /// A background is always a SURFACE. `TextToken`/`AccentToken` are not
    /// spellable here, so the black-on-dark inversion (a text token used as a
    /// fill) cannot be written in the first place.
    func tokenBackground(_ surface: SurfaceToken, ignoringSafeArea: Bool = false) -> some View {
        modifier(TokenBackgroundModifier(surface: surface, ignoringSafeArea: ignoringSafeArea))
    }

    func tokenForeground(_ token: TokenColor) -> some View {
        modifier(TokenForegroundModifier(token: token))
    }
}

// MARK: - Type

// iOS keeps its SEMANTIC styles rather than the desktop's fixed point sizes: the
// phone has real Dynamic Type and the Mac does not, so forcing 13pt body text
// onto iOS would break accessibility to gain a consistency nobody can see across
// two devices. `TextRole` therefore maps to the nearest semantic style BY ROLE,
// not by point size — a phone's `.body` is 17pt where the desktop's is 13, and
// that is the platform doing its job:
//
//   titleL     → .title3     tile-scale heading
//   title      → .headline   the name of a thing (semibold by construction)
//   body       → .body       running prose
//   bodyMono   → .body       + monospaced
//   label      → .caption    a short attached descriptor (12pt at default size —
//                            the size the status pill already shipped)
//   caption    → .caption2   least-important metadata
//   captionMono→ .caption2   + monospaced
//
// Weight comes from `Typography.style(for:)`, so the ladder stays the one place
// that decides it. Both mono roles get `.monospaced()`, following P1.10's
// reasoning on the desktop: a true mono face is tabular by construction, so one
// face serves both "must align by column" and "must not reflow as digits change".
extension Font {
    init(role: TextRole) {
        let style = Typography.style(for: role)
        let base: Font
        switch role {
        case .titleL: base = .title3
        case .title: base = .headline
        case .body, .bodyMono: base = .body
        case .label: base = .caption
        case .caption, .captionMono: base = .caption2
        }
        var font = base.weight(Font.Weight(style.weight))
        if style.monospaced {
            font = font.monospaced()
        }
        self = font
    }
}

extension Font.Weight {
    init(_ weight: TokenWeight) {
        switch weight {
        case .regular: self = .regular
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        }
    }
}
