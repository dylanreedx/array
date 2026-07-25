import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/87-agent-ui-component-framework.md
//
// Per-component Layer-1 check suite for the StatusChip — the first agent-UI
// building block. Moved from ContinuumRevivedCoreChecks by ticket P1.1 with the
// assertions unchanged. These are the DETERMINISTIC tests (mapping totality,
// label/glyph presence, WCAG contrast, distinctness). Pixel appearance is a
// separate Layer-2 vision-QA gate in the Component Lab, not tested here.
//
// The contrast assertion is the deterministic guard for the exact bug we hit
// in the managed-agent tile: black text on a dark-blue fill. It is encoded
// below both as a live invariant (every chip pair ≥ 4.5:1) and as a
// regression witness (the original bad pairing must FAIL the metric).
func runStatusChipChecks() {
    // 1. Totality — every status maps; no default hole, no empty content.
    for status in AgentStatus.allCases {
        let d = StatusChipPresenter.display(for: status)
        expect(!d.label.isEmpty, "StatusChip: \(status.rawValue) has a non-empty label")
        expect(!d.glyph.isEmpty, "StatusChip: \(status.rawValue) has a non-empty glyph")
    }

    // 2. Contrast — every chip owns its fg/bg and the pair meets WCAG AA (4.5:1).
    for status in AgentStatus.allCases {
        let d = StatusChipPresenter.display(for: status)
        let ratio = WCAGContrast.ratio(d.foreground, d.background)
        expect(ratio >= 4.5,
               "StatusChip: \(status.rawValue) fg/bg contrast \(String(format: "%.2f", ratio)):1 must be ≥ 4.5:1")
    }

    // 3. Distinctness — no two statuses share a background (they must read apart).
    var seenBackgrounds: [String: AgentStatus] = [:]
    for status in AgentStatus.allCases {
        let key = StatusChipPresenter.display(for: status).background.hexKey
        expect(seenBackgrounds[key] == nil,
               "StatusChip: \(status.rawValue) background collides with \(seenBackgrounds[key]?.rawValue ?? "?")")
        seenBackgrounds[key] = status
    }

    // 4. Metric anchor — frame the ratio so a broken WCAGContrast.ratio() can't
    //    make (2) vacuously pass, and pin the original bug as a regression witness.
    let white = ChipColor(r: 1, g: 1, b: 1)
    let black = ChipColor(r: 0, g: 0, b: 0)
    let wb = WCAGContrast.ratio(white, black)
    expect(wb >= 20.9 && wb <= 21.1, "StatusChip: white/black contrast must be ~21:1 (got \(String(format: "%.2f", wb)))")
    let tileDarkBlue = ChipColor(r: 0.11, g: 0.13, b: 0.16)  // the managed-tile fill from the bug
    expect(WCAGContrast.ratio(black, tileDarkBlue) < 4.5,
           "StatusChip: the original bug pairing (black on dark blue) must FAIL the metric")

    // ---- P1.8: this presenter is now the ONLY status→appearance mapping. ----
    //
    // Five desktop duplicates and `AgentsBoardProjection`'s `colorToken` string
    // channel were deleted and pointed here. The assertions below are what stops
    // a seventh palette re-forming: an accent may only ever BE an existing gated
    // token, and the glyph set has to stay unambiguous.

    // 5. Glyph distinctness — the shipped bug was `◌` meaning *stale* in the
    //    sidebar and *configuring* in the tile, so one glyph may name one state.
    var seenGlyphs: [String: AgentStatus] = [:]
    for status in AgentStatus.allCases {
        let glyph = StatusChipPresenter.display(for: status).glyph
        expect(seenGlyphs[glyph] == nil,
               "StatusChip: glyph \(glyph) for \(status.rawValue) collides with \(seenGlyphs[glyph]?.rawValue ?? "?")")
        seenGlyphs[glyph] = status
    }

    // 6. Accent PROVENANCE — every accent is a value the P1.3 palette already
    //    declares (an `AccentToken`, or `textSecondary` for the two muted
    //    states). This is the load-bearing one: a hand-picked accent here would
    //    be a colour outside `DesignTokens.documentedPairs`, i.e. outside what
    //    P1.6 gates, and it goes red on the spot instead of shipping ungated.
    let paletteKeys: Set<String> = Set(
        (AccentToken.allCases.map(\.color) + [TextToken.textSecondary.color])
            .flatMap { token in TokenTheme.allCases.map { token.resolved(for: $0).hexKey } })
    for status in AgentStatus.allCases {
        let accent = StatusChipPresenter.display(for: status).accent
        for theme in TokenTheme.allCases {
            let key = accent.resolved(for: theme).hexKey
            expect(paletteKeys.contains(key),
                   "StatusChip: \(status.rawValue) accent #\(key) (\(theme.rawValue)) is not a declared "
                     + "AccentToken/textSecondary value — accents may not be re-picked here")
        }
    }

    // 7. Accent legibility on every surface, both themes. It follows from (6)
    //    plus `runDesignTokenChecks`, but a bare glyph on a card is what the
    //    migrated call sites actually paint, so it gets its own witness here
    //    rather than an inference two files away.
    for status in AgentStatus.allCases {
        let accent = StatusChipPresenter.display(for: status).accent
        for theme in TokenTheme.allCases {
            for surface in SurfaceToken.allCases {
                let ratio = WCAGContrast.ratio(accent.resolved(for: theme), surface.color.resolved(for: theme))
                expect(ratio >= DesignTokens.textFloor,
                       "StatusChip: \(status.rawValue) accent on \(surface.rawValue) (\(theme.rawValue)) is "
                         + "\(String(format: "%.2f", ratio)):1, must be ≥ \(DesignTokens.textFloor):1")
            }
        }
    }

    // 8. Pill/accent coherence, and the ONE deliberate divergence pinned as a
    //    fact. The four accent-carrying statuses must agree in hue with their
    //    pill foreground — otherwise a tile dot and a board chip claim different
    //    things about the same state. `idle` and `stale` collapse onto the muted
    //    token on purpose (see StatusChipPresenter), so their accents must be
    //    NEUTRAL while `idle`'s pill stays teal-family: asserted, so the
    //    divergence cannot silently spread to a third status.
    func saturation(_ color: ChipColor) -> Double {
        let maxC = max(color.r, color.g, color.b)
        guard maxC > 0 else { return 0 }
        return (maxC - min(color.r, color.g, color.b)) / maxC
    }
    for status in AgentStatus.allCases {
        let d = StatusChipPresenter.display(for: status)
        switch status {
        case .idle, .stale:
            for theme in TokenTheme.allCases {
                let sat = saturation(d.accent.resolved(for: theme))
                expect(sat <= 0.15,
                       "StatusChip: \(status.rawValue) accent must stay neutral/muted (\(theme.rawValue) "
                         + "saturation \(String(format: "%.3f", sat)) > 0.15)")
            }
        case .configuring, .working, .needsAttention, .done:
            for theme in TokenTheme.allCases {
                let drift = abs(hueDegrees(d.accent.resolved(for: theme)) - hueDegrees(d.foreground))
                let wrapped = min(drift, 360 - drift)
                expect(wrapped <= 30,
                       "StatusChip: \(status.rawValue) accent hue drifts \(String(format: "%.1f", wrapped))° "
                         + "from its pill foreground in \(theme.rawValue) — pill and dot must read as one state")
            }
        }
    }

    print("StatusChip checks passed: \(AgentStatus.allCases.count) statuses map with labels+glyphs, all fg/bg pairs ≥ 4.5:1, backgrounds+glyphs distinct, every accent is a declared token and clears \(DesignTokens.textFloor):1 on all \(SurfaceToken.allCases.count) surfaces in both themes, metric anchored (white/black \(String(format: "%.1f", wb)):1, bug pairing correctly fails)")
}
