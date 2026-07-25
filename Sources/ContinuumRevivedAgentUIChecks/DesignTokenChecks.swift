import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P1.3-surface-text-border-tokens.md
//
// The packet's warning is that this is the ticket most likely to be "finished"
// with plausible-but-unchecked colours. So nothing here trusts a value: every
// documented pair is measured in BOTH themes, the loop is framed by a broken
// pair that must fail (so a green run cannot be vacuous), and the two colours
// the P0.4 audit named as root causes are pinned as regression witnesses —
// white@0.25 on white@0.10 (1.68:1, the tile border) and a tertiary-label grey
// on the message card (2.07:1) must both FAIL, while the token that replaced
// each one passes on the same background.
//
// Counts are pinned too: deleting a token, or quietly narrowing a token's
// `legalBackgrounds`, shrinks `documentedPairs` and goes red by name rather than
// reducing coverage in silence.

/// Hue in degrees, for the "an accent keeps its identity across themes"
/// assertion. Verification-only, hence here and not in the module.
private func hueDegrees(_ color: ChipColor) -> Double {
    let maxC = max(color.r, color.g, color.b)
    let minC = min(color.r, color.g, color.b)
    let delta = maxC - minC
    guard delta > 0 else { return 0 }
    let hue: Double
    if maxC == color.r {
        hue = 60 * ((color.g - color.b) / delta).truncatingRemainder(dividingBy: 6)
    } else if maxC == color.g {
        hue = 60 * (((color.b - color.r) / delta) + 2)
    } else {
        hue = 60 * (((color.r - color.g) / delta) + 4)
    }
    return hue < 0 ? hue + 360 : hue
}

private func hueDrift(_ token: TokenColor) -> Double {
    let raw = abs(hueDegrees(token.light) - hueDegrees(token.dark))
    return min(raw, 360 - raw)
}

private func f(_ value: Double) -> String { String(format: "%.2f", value) }

func runDesignTokenChecks() {
    // 1. Totality — every token exists, in the expected number, and carries a
    //    DIFFERENT value per theme. An accidentally unthemed token is the way a
    //    "light mode" ends up being dark mode that does not crash.
    expect(SurfaceToken.allCases.count == 11,
           "DesignTokens: expected 11 surfaces, got \(SurfaceToken.allCases.count)")
    expect(TextToken.allCases.count == 3,
           "DesignTokens: expected 3 text tokens, got \(TextToken.allCases.count)")
    expect(LineToken.allCases.count == 3,
           "DesignTokens: expected 3 line tokens, got \(LineToken.allCases.count)")
    expect(AccentToken.allCases.count == 5,
           "DesignTokens: expected 5 accents, got \(AccentToken.allCases.count)")
    expect(SurfaceToken.chrome.count + SurfaceToken.cards.count == SurfaceToken.allCases.count,
           "DesignTokens: chrome + cards must partition allCases (\(SurfaceToken.chrome.count) + \(SurfaceToken.cards.count) != \(SurfaceToken.allCases.count))")

    var everyToken: [(String, TokenColor)] = []
    everyToken += SurfaceToken.allCases.map { ($0.rawValue, $0.color) }
    everyToken += TextToken.allCases.map { ($0.rawValue, $0.color) }
    everyToken += LineToken.allCases.map { ($0.rawValue, $0.color) }
    everyToken += AccentToken.allCases.map { ($0.rawValue, $0.color) }
    expect(everyToken.count == 22, "DesignTokens: expected 22 tokens in total, got \(everyToken.count)")
    for (name, token) in everyToken {
        expect(token.light.hexKey != token.dark.hexKey,
               "DesignTokens: \(name) has the same value in both themes (\(token.light.hexKey)) — it is not themed")
        for theme in TokenTheme.allCases {
            let resolved = token.resolved(for: theme)
            expect(resolved.r >= 0 && resolved.r <= 1 && resolved.g >= 0 && resolved.g <= 1 && resolved.b >= 0 && resolved.b <= 1,
                   "DesignTokens: \(name).\(theme.rawValue) is out of the 0…1 sRGB range")
        }
    }

    // 2. Metric anchor — the suite cannot pass vacuously if the ratio function
    //    itself is broken.
    let anchor = WCAGContrast.ratio(ChipColor(r: 1, g: 1, b: 1), ChipColor(r: 0, g: 0, b: 0))
    expect(anchor >= 20.9 && anchor <= 21.1, "DesignTokens: white/black must be ~21:1, got \(f(anchor))")

    // 3. Light is actually light and dark is actually dark. Ruling 3: the card
    //    fills do NOT stay dark under Aqua — that is the shipped bug.
    for surface in SurfaceToken.allCases {
        let lightLum = WCAGContrast.relativeLuminance(surface.color.light)
        let darkLum = WCAGContrast.relativeLuminance(surface.color.dark)
        expect(lightLum > 0.5,
               "DesignTokens: \(surface.rawValue) light is not a light surface (luminance \(f(lightLum)))")
        expect(darkLum < 0.2,
               "DesignTokens: \(surface.rawValue) dark is not a dark surface (luminance \(f(darkLum)))")
    }

    // 4. Distinctness by hexKey, per theme — two surfaces that collide are one
    //    surface, and a card kind would stop being readable as its kind.
    for theme in TokenTheme.allCases {
        let surfaceKeys = SurfaceToken.allCases.map { $0.color.resolved(for: theme).hexKey }
        expect(Set(surfaceKeys).count == surfaceKeys.count,
               "DesignTokens: \(theme.rawValue) surfaces are not distinct (\(surfaceKeys.count) tokens, \(Set(surfaceKeys).count) values)")
        let accentKeys = AccentToken.allCases.map { $0.color.resolved(for: theme).hexKey }
        expect(Set(accentKeys).count == accentKeys.count,
               "DesignTokens: \(theme.rawValue) accents are not distinct (\(accentKeys.count) tokens, \(Set(accentKeys).count) values)")
        let lineKeys = LineToken.allCases.map { $0.color.resolved(for: theme).hexKey }
        expect(Set(lineKeys).count == lineKeys.count,
               "DesignTokens: \(theme.rawValue) line tokens are not distinct (\(lineKeys.count) tokens, \(Set(lineKeys).count) values)")
    }

    // 5. Hue identity across themes (ruling 2) — the light variant is a DARKENED
    //    version of the same colour, not a different colour. Measured drift is
    //    0.9°–4.5°; 10° is the ceiling.
    for accent in AccentToken.allCases {
        let drift = hueDrift(accent.color)
        expect(drift <= 10,
               "DesignTokens: \(accent.rawValue) changes hue across themes (\(f(drift))° > 10°) — the status would not read the same in both")
        let lightLum = WCAGContrast.relativeLuminance(accent.color.light)
        let darkLum = WCAGContrast.relativeLuminance(accent.color.dark)
        expect(lightLum < darkLum,
               "DesignTokens: \(accent.rawValue) light variant must be the DARKER one (light \(f(lightLum)) vs dark \(f(darkLum)))")
    }

    // 6. Every documented pair clears its floor in BOTH themes. The pair set is
    //    derived from the tokens' own declarations, so its size is pinned: 2
    //    text tokens x 11 surfaces + textOnAccent x 5 accent fills + 5 accents x
    //    11 surfaces + 2 gated line tokens x 11 surfaces = 104.
    let pairs = DesignTokens.documentedPairs
    expect(pairs.count == 104, "DesignTokens: expected 104 documented pairs, got \(pairs.count)")
    var worst: (pair: TokenPair, theme: TokenTheme, ratio: Double)?
    for pair in pairs {
        for theme in TokenTheme.allCases {
            let ratio = pair.ratio(for: theme)
            expect(ratio >= pair.floor,
                   "DesignTokens: \(pair.foreground) on \(pair.background) in \(theme.rawValue) is \(f(ratio)):1, below its \(f(pair.floor)):1 floor")
            if worst == nil || ratio - pair.floor < worst!.ratio - worst!.pair.floor {
                worst = (pair, theme, ratio)
            }
        }
    }
    guard let tightest = worst else {
        expect(false, "DesignTokens: documentedPairs is empty — nothing was measured")
        return
    }

    // 7. Pin the MARGIN, not just the floor. Every ratio the header comment of
    //    DesignTokens.swift claims is asserted here to ±0.01, and the table must
    //    name every foreground token — so a colour tweak that leaves the floor
    //    intact still goes red until the documented provenance is updated, and a
    //    new token cannot skip the table. Worst background is pinned too: it is
    //    `canvas` in light and `cardUserMessage` in dark for every one of these
    //    (the extremes of the surface ladder), which is the property that makes
    //    "clears its worst case" mean "clears all eleven".
    let pinnedWorst: [(foreground: String, theme: TokenTheme, background: String, ratio: Double)] = [
        ("textPrimary", .light, "canvas", 15.05), ("textPrimary", .dark, "cardUserMessage", 12.09),
        ("textSecondary", .light, "canvas", 5.99), ("textSecondary", .dark, "cardUserMessage", 6.53),
        ("textOnAccent", .light, "accentFailed", 6.29), ("textOnAccent", .dark, "accentInput", 7.82),
        ("border", .light, "canvas", 3.52), ("border", .dark, "cardUserMessage", 3.44),
        ("borderStrong", .light, "canvas", 6.91), ("borderStrong", .dark, "cardUserMessage", 6.09),
        ("accentWorking", .light, "canvas", 5.47), ("accentWorking", .dark, "cardUserMessage", 5.41),
        ("accentApproval", .light, "canvas", 5.62), ("accentApproval", .dark, "cardUserMessage", 7.48),
        ("accentInput", .light, "canvas", 6.32), ("accentInput", .dark, "cardUserMessage", 5.35),
        ("accentFailed", .light, "canvas", 5.27), ("accentFailed", .dark, "cardUserMessage", 5.85),
        ("accentDone", .light, "canvas", 5.90), ("accentDone", .dark, "cardUserMessage", 6.74)
    ]
    let gatedForegrounds = Set(pairs.map(\.foreground))
    expect(Set(pinnedWorst.map(\.foreground)) == gatedForegrounds,
           "DesignTokens: the pinned-margin table must cover exactly the gated foregrounds (table \(Set(pinnedWorst.map(\.foreground)).sorted()) vs gated \(gatedForegrounds.sorted()))")
    for pin in pinnedWorst {
        let candidates = pairs.filter { $0.foreground == pin.foreground }
        guard let measured = candidates.min(by: { $0.ratio(for: pin.theme) < $1.ratio(for: pin.theme) }) else {
            expect(false, "DesignTokens: \(pin.foreground) has no documented pair to measure a margin against")
            return
        }
        let ratio = measured.ratio(for: pin.theme)
        expect(abs(ratio - pin.ratio) <= 0.01,
               "DesignTokens: \(pin.foreground) in \(pin.theme.rawValue) has worst ratio \(f(ratio)):1, but its documented provenance says \(f(pin.ratio)):1 — update the comment in DesignTokens.swift with the new measurement")
        expect(measured.background == pin.background,
               "DesignTokens: \(pin.foreground)'s worst background in \(pin.theme.rawValue) is \(measured.background), not the documented \(pin.background) — the surface ladder moved")
    }

    // 8. Accents are as vivid as AA allows, not arbitrarily far from it. A
    //    near-black "blue" would pass every floor above and still fail the job an
    //    accent has. So each accent's worst pair must sit in a band: at or above
    //    4.5, and below 8.0 — beyond that it has stopped reading as a colour and
    //    become another shade of the text.
    for accent in AccentToken.allCases {
        for theme in TokenTheme.allCases {
            let worstAccent = accent.legalSurfaces
                .map { WCAGContrast.ratio(accent.color.resolved(for: theme), $0.color.resolved(for: theme)) }
                .min() ?? 0
            expect(worstAccent >= DesignTokens.textFloor && worstAccent <= 8.0,
                   "DesignTokens: \(accent.rawValue) in \(theme.rawValue) is \(f(worstAccent)):1 at worst — outside the 4.50…8.00 band an accent has to live in to clear AA and still read as its hue")
        }
    }

    // 9. The loop above is only meaningful if it can fail. A deliberately broken
    //    pair, evaluated by the same code path, must come out under its floor.
    let brokenPair = TokenPair(
        foreground: "witness.invisible", background: SurfaceToken.cardMessage.rawValue,
        color: TokenColor(light: SurfaceToken.cardMessage.color.light, dark: SurfaceToken.cardMessage.color.dark),
        backgroundColor: SurfaceToken.cardMessage.color, floor: DesignTokens.textFloor)
    for theme in TokenTheme.allCases {
        let ratio = brokenPair.ratio(for: theme)
        expect(ratio < DesignTokens.textFloor,
               "DesignTokens: a text token equal to its own background measured \(f(ratio)):1 in \(theme.rawValue) — the pair evaluator is not measuring anything")
    }

    // 10. Regression witnesses from P0.4-FINDINGS.md. Each is the OLD colour on a
    //    background it is actually painted on: it must fail, and the token that
    //    replaced it must pass on that same background.
    //    (a) The tile border: white@0.25 on white@0.10 = 1.68:1.
    let oldBorder = ChipColor(r: 0.25, g: 0.25, b: 0.25)
    let oldTileFill = ChipColor(r: 0.10, g: 0.10, b: 0.10)
    let oldBorderRatio = WCAGContrast.ratio(oldBorder, oldTileFill)
    expect(oldBorderRatio < DesignTokens.lineFloor,
           "DesignTokens: witness — white@0.25 on white@0.10 must FAIL the \(f(DesignTokens.lineFloor)):1 line floor, measured \(f(oldBorderRatio)):1")
    expect(oldBorderRatio >= 1.60 && oldBorderRatio <= 1.75,
           "DesignTokens: witness — the audited tile border was 1.68:1, measured \(f(oldBorderRatio)):1 (the witness itself drifted)")
    let newBorderRatio = WCAGContrast.ratio(
        LineToken.border.color.dark, SurfaceToken.tileBody.color.dark)
    expect(newBorderRatio >= DesignTokens.lineFloor,
           "DesignTokens: `border` on `tileBody` in dark is \(f(newBorderRatio)):1 — it did not fix the 1.68:1 defect")

    //    (b) Muted text: a tertiaryLabelColor-equivalent grey (white@0.25 over
    //        the dark window fill resolves to #565656) on the message card.
    let tertiaryEquivalent = ChipColor(r: 0x56 / 255.0, g: 0x56 / 255.0, b: 0x56 / 255.0)
    let tertiaryRatio = WCAGContrast.ratio(tertiaryEquivalent, SurfaceToken.cardMessage.color.dark)
    expect(tertiaryRatio < DesignTokens.textFloor,
           "DesignTokens: witness — a tertiary-label grey on `cardMessage` must FAIL AA, measured \(f(tertiaryRatio)):1")
    //    (c) secondaryLabelColor on white = #808080 = 3.95:1 — also under AA, and
    //        the reason `textSecondary` is a house colour (ruling 1).
    let secondaryEquivalent = ChipColor(r: 0.5, g: 0.5, b: 0.5)
    let secondaryRatio = WCAGContrast.ratio(secondaryEquivalent, SurfaceToken.overlay.color.light)
    expect(secondaryRatio < DesignTokens.textFloor,
           "DesignTokens: witness — secondaryLabelColor-equivalent #808080 on white must FAIL AA, measured \(f(secondaryRatio)):1")
    for surface in SurfaceToken.allCases {
        for theme in TokenTheme.allCases {
            let ratio = WCAGContrast.ratio(
                TextToken.textSecondary.color.resolved(for: theme), surface.color.resolved(for: theme))
            expect(ratio > max(secondaryRatio, tertiaryRatio),
                   "DesignTokens: `textSecondary` on \(surface.rawValue) in \(theme.rawValue) (\(f(ratio)):1) is no better than the AppKit colours it replaces")
        }
    }

    // 11. Exemptions are enumerable and reasoned (ruling 4), and an exempt token
    //    is genuinely absent from the gated set — never a floor of 1.
    let exemptions = DesignTokens.decorativeExemptions
    expect(exemptions.count == 1,
           "DesignTokens: expected exactly 1 decorative exemption, got \(exemptions.count) — every exemption must be listed, and the list must not grow silently")
    expect(exemptions.first?.token == .separator,
           "DesignTokens: the one exemption must be `separator`, got \(exemptions.first?.token.rawValue ?? "none")")
    for exemption in exemptions {
        expect(exemption.reason.count >= 40,
               "DesignTokens: \(exemption.token.rawValue) is exempt without a real reason")
        expect(!pairs.contains { $0.foreground == exemption.token.rawValue },
               "DesignTokens: \(exemption.token.rawValue) is exempt but still appears in documentedPairs")
    }
    for line in LineToken.allCases where line.contrastFloor != nil {
        expect(line.exemptionReason == nil,
               "DesignTokens: \(line.rawValue) is gated AND carries an exemption reason — one or the other")
        expect(pairs.contains { $0.foreground == line.rawValue },
               "DesignTokens: \(line.rawValue) is gated but has no documented pair")
    }

    print("DesignToken checks passed: \(everyToken.count) tokens x \(TokenTheme.allCases.count) themes, "
        + "\(pairs.count) documented pairs all clear their floor (tightest: \(tightest.pair.foreground) on "
        + "\(tightest.pair.background) in \(tightest.theme.rawValue) at \(f(tightest.ratio)):1 vs \(f(tightest.pair.floor))), "
        + "\(exemptions.count) reasoned exemption, witnesses fail (border \(f(oldBorderRatio)):1, tertiary \(f(tertiaryRatio)):1, secondary \(f(secondaryRatio)):1)")
}
