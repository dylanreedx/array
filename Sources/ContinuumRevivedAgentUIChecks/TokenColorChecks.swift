import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P1.2-tokencolor-light-dark.md
//
// Deterministic checks for the two-value colour token. The point of every
// assertion here is that a LATER token gate cannot be fooled: if `resolved`
// returned the same leaf for both themes, or if `TokenTheme.allCases` lost a
// case, a per-appearance contrast gate would silently check one theme twice and
// report green. So resolution, the single-value initializer, and theme
// coverage are each pinned, and each is framed by its own counter-case.
func runTokenColorChecks() {
    let ink = ChipColor(r: 0.08, g: 0.09, b: 0.11)
    let paper = ChipColor(r: 0.98, g: 0.98, b: 0.99)

    // 1. Theme coverage — allCases is what drives every later gate, so a
    //    dropped case must be caught here rather than as a quietly halved gate.
    expect(TokenTheme.allCases == [.light, .dark],
           "TokenColor: TokenTheme.allCases must be exactly [light, dark] (got \(TokenTheme.allCases.map(\.rawValue)))")

    // 2. Resolution — each theme returns ITS leaf, not the other one. Asserted
    //    with distinct values in both directions so a hardcoded `light` and a
    //    hardcoded `dark` both go red.
    let themed = TokenColor(light: ink, dark: paper)
    expect(themed.resolved(for: .light) == ink, "TokenColor: .light resolves to the light leaf")
    expect(themed.resolved(for: .dark) == paper, "TokenColor: .dark resolves to the dark leaf")
    let flipped = TokenColor(light: paper, dark: ink)
    expect(flipped.resolved(for: .light) == paper, "TokenColor: .light resolves to the light leaf when the leaves swap")
    expect(flipped.resolved(for: .dark) == ink, "TokenColor: .dark resolves to the dark leaf when the leaves swap")

    // 3. Single-value initializer — equal in both themes, and equal to the
    //    two-argument form with the same colour on both sides.
    let unthemed = TokenColor(ink)
    expect(unthemed.resolved(for: .light) == unthemed.resolved(for: .dark),
           "TokenColor: the single-value initializer must yield the same colour in both themes")
    expect(unthemed.resolved(for: .light) == ink, "TokenColor: the single-value initializer keeps the colour it was given")
    expect(unthemed == TokenColor(light: ink, dark: ink),
           "TokenColor: TokenColor(x) must equal TokenColor(light: x, dark: x)")

    // 4. Detectability — a token whose two themes differ must be visible as
    //    such through `hexKey`, so a token declared "themed" but accidentally
    //    given the same colour twice can be found by a later lint/gate. Both
    //    sides are asserted: differing leaves differ, identical leaves match.
    expect(themed.resolved(for: .light).hexKey != themed.resolved(for: .dark).hexKey,
           "TokenColor: a themed token's per-theme hexKeys must differ (\(themed.resolved(for: .light).hexKey))")
    expect(unthemed.resolved(for: .light).hexKey == unthemed.resolved(for: .dark).hexKey,
           "TokenColor: an unthemed token's per-theme hexKeys must match")

    // 5. The leaf is still a ChipColor, so WCAGContrast applies per theme with
    //    no adapter — that is the whole reason ChipColor was reused. Anchored
    //    against the known ~21:1 extreme rather than a bare "> 1".
    let extreme = TokenColor(light: ChipColor(r: 0, g: 0, b: 0), dark: ChipColor(r: 1, g: 1, b: 1))
    let ratio = WCAGContrast.ratio(extreme.resolved(for: .light), extreme.resolved(for: .dark))
    expect(ratio >= 20.9 && ratio <= 21.1,
           "TokenColor: resolved leaves feed WCAGContrast unchanged (black/white must be ~21:1, got \(String(format: "%.2f", ratio)))")

    print("TokenColor checks passed: \(TokenTheme.allCases.count) themes resolve to their own leaf, single-value init equal in both, themed/unthemed distinguishable by hexKey, leaves feed WCAGContrast (\(String(format: "%.1f", ratio)):1)")
}
