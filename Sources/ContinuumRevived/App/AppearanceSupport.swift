import AppKit
import ContinuumRevivedAgentUI

// Ticket: docs/38-tickets/87-agent-ui-component-framework.md
//
// AppKit trap: `NSColor.windowBackgroundColor.cgColor` does NOT resolve against
// the view's (or the app's) appearance — it resolves against
// `NSAppearance.current`, which outside a draw cycle is the SYSTEM appearance.
// So on a light-mode Mac, every layer background assigned this way came out
// light while NSTextField colors (resolved by AppKit at draw time) came out
// correct — producing white-on-white chrome once the app pinned dark.
//
// Always route dynamic colors through here when assigning to a CALayer.
extension NSColor {
    /// This color resolved in the app's effective appearance, safe for CALayer.
    var appResolvedCGColor: CGColor {
        var resolved = cgColor
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            resolved = self.cgColor
        }
        return resolved
    }

    /// The same, at a reduced alpha.
    ///
    /// P1.9 found the trap this exists for: `windowBackgroundColor
    /// .withAlphaComponent(0.92).appResolvedCGColor` does NOT resolve in the app's
    /// appearance. `withAlphaComponent` on a dynamic catalog colour resolves it
    /// immediately, against whatever appearance is current at that moment, and hands
    /// back a plain colour — so `appResolvedCGColor` is left with nothing dynamic to
    /// re-resolve. Measured: inside a `.darkAqua` drawing block with the app pinned
    /// `.aqua`, that spelling yields 0.12 grey where the correct value is white.
    /// Resolve first, then apply alpha.
    func appResolvedCGColor(alpha: CGFloat) -> CGColor {
        appResolvedCGColor.copy(alpha: alpha) ?? appResolvedCGColor
    }
}

// Ticket: docs/38-tickets/90-agent-ux/P1.9-live-appearance-switching.md
//
// `appResolvedCGColor` fixed the *value* an assignment produces. It cannot fix
// the *timing*: a CGColor is a resolved colour — there is no dynamic one — so a
// layer keeps whatever it was handed until somebody assigns again. Nothing in
// this app ever did, which is why pinning `.darkAqua` turned text white while
// every CALayer fill stayed light.
//
// `TokenThemed.applyTokens()` is the one place a view assigns its layer colours,
// called from `init` AND from `viewDidChangeEffectiveAppearance`. The gate that
// keeps it honest is `UIProbeAppearance` (inside `--ui-probe-check`): it writes a
// sentinel over every layer colour a TokenThemed view owns, flips the appearance
// for real, and fails on any sentinel that survived — i.e. on any layer colour
// assigned anywhere other than `applyTokens()`.

extension NSAppearance {
    /// Which leaf of a `TokenColor` this appearance resolves to. The one mapping
    /// in the codebase: `ContinuumRevivedAgentUI` is Foundation-only on purpose,
    /// so NSAppearance → `TokenTheme` belongs to the platform layer.
    var tokenTheme: TokenTheme {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

extension NSView {
    /// The theme this view is currently drawing in.
    var effectiveTokenTheme: TokenTheme { effectiveAppearance.tokenTheme }
}

extension TokenColor {
    /// This token's value for `theme`, ready to hand to a CALayer. Deliberately
    /// NOT routed through `appResolvedCGColor`: a token already carries both
    /// values, so there is nothing to resolve against `NSAppearance.current` —
    /// the caller names the theme, which is also what lets a gate predict the
    /// exact colour a layer must be holding after a flip.
    func cgColor(for theme: TokenTheme) -> CGColor {
        StatusChipNSView.nsColor(resolved(for: theme)).cgColor
    }

    /// The same, resolved in the theme `view` is drawing in — the form
    /// `applyTokens()` implementations use.
    func cgColor(in view: NSView) -> CGColor { cgColor(for: view.effectiveTokenTheme) }

    /// This token as an `NSColor`, for the AppKit properties that are not layer
    /// colours: `NSTextField.textColor`, `NSTextView.backgroundColor`,
    /// `NSButton.contentTintColor`, and `setFill()`/`setStroke()` inside `draw(_:)`.
    ///
    /// P1.11 added this because those properties are the majority of what the
    /// chrome and the content tiles paint, and every one of them was reaching for
    /// `StatusChipNSView.nsColor(token.resolved(for:))` by hand. One bridge, beside
    /// the `cgColor` ones, so a call site never spells the resolution itself.
    func nsColor(for theme: TokenTheme) -> NSColor { StatusChipNSView.nsColor(resolved(for: theme)) }

    /// The same, resolved in the theme `view` is drawing in.
    func nsColor(in view: NSView) -> NSColor { nsColor(for: view.effectiveTokenTheme) }
}

// Ticket: docs/38-tickets/90-agent-ux/P1.10-adopt-tokens-tile.md
//
// `Typography` and `Metrics` are Foundation-only on purpose — both files say
// mapping `TokenWeight` to `NSFont.Weight` and `EdgeInsetsToken` to
// `NSEdgeInsets` is "the thin view layer's job (P1.10/P1.11 adopt)". This is
// that layer, and it lives beside the `TokenColor` bridges above so there is
// exactly ONE of each conversion for every adopting call site to share rather
// than a copy per view file.

extension NSFont.Weight {
    /// The AppKit weight for a neutral `TokenWeight`.
    init(_ weight: TokenWeight) {
        switch weight {
        case .regular: self = .regular
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        }
    }
}

extension NSFont {
    /// The font a `TextRole` renders in.
    ///
    /// `TextStyle.monospaced` maps to `monospacedSystemFont`, not
    /// `monospacedDigitSystemFont`: a true mono face is tabular by construction,
    /// so it satisfies `captionMono`'s "must not reflow as digits change" as well
    /// as `bodyMono`'s column alignment. One flag, one mapping — keying the two
    /// mono roles to different faces would smuggle a second axis into the scale
    /// that `TextStyle` does not carry.
    static func token(_ role: TextRole) -> NSFont {
        let style = Typography.style(for: role)
        let weight = NSFont.Weight(style.weight)
        return style.monospaced
            ? .monospacedSystemFont(ofSize: style.size, weight: weight)
            : .systemFont(ofSize: style.size, weight: weight)
    }
}

extension NSEdgeInsets {
    /// An `Inset` token as AppKit insets — what `NSStackView.edgeInsets` wants.
    init(_ token: EdgeInsetsToken) {
        self.init(top: token.top, left: token.left, bottom: token.bottom, right: token.right)
    }
}

/// A view that owns layer colours and re-applies them when the appearance moves.
/// Conformance is the greppable marker for "this view's colours are live", and
/// what `UIProbeAppearance` enumerates.
@MainActor
protocol TokenThemed: NSView {
    /// Assign EVERY layer colour this view owns, from scratch.
    ///
    /// Must be idempotent and cheap: AppKit calls `viewDidChangeEffectiveAppearance`
    /// on the view *and* on each descendant, so one flip runs this once per view.
    /// Never build or re-parent views here.
    func applyTokens()
}
