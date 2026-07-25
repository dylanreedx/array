import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P1.6-token-contrast-gate.md
//
// The palette's own contrast gate, and the one place the numbers are PRINTED.
//
// Division of labour, so this file is not a second copy of P1.3's suite:
//
//  * `runDesignTokenChecks` (P1.3) proves the palette's STRUCTURE — 22 tokens,
//    light really light, hue held across themes, exemptions enumerable, the
//    pinned provenance table. It asserts the floors as one of many properties.
//  * `--ui-contrast-check` (P0.4, wired into the matrix by this ticket) reads the
//    REAL view tree and catches a view that BYPASSES the tokens.
//  * This file is the middle one: the palette itself, every documented pair,
//    both themes, with the full ratio table on stdout so the numbers are
//    reviewable in the matrix log rather than hidden behind a pass/fail. A green
//    run you cannot read is a green run you cannot audit.
//
// Everything here is derived from `DesignTokens.documentedPairs` — the tokens'
// own declarations. There is no allowlist and no per-pair exception, by packet
// instruction: a failing pair means the token is wrong.
//
// REGRESSION WITNESSES. The packet names two colours that MUST fail. Both are
// executed below (`witnesses`), not described — a witness that is only a comment
// is a witness that has never run. Beyond those, the packet asks for the two real
// token edits as re-runnable snippets. Both were run against this code, and the
// output below is quoted, not predicted. In
// `Sources/ContinuumRevivedAgentUI/DesignTokens.swift`:
//
//   (1) textSecondary → a tertiaryLabelColor-equivalent grey:
//         case .textSecondary: return TokenColor(light: srgb(0x54585F), dark: srgb(0x565656))
//       Observed, exit 1:
//         FAIL: StatusChip: idle accent on canvas (dark) is 2.65:1, must be ≥ 4.5:1
//       NOTE: `runStatusChipChecks` runs first and speaks for this one, because
//       P1.8 sources the idle/stale accent FROM `textSecondary`. This gate would
//       have named 22 pairs; it does not get the chance, and that is fine — the
//       edit cannot ship either way.
//
//   (2) border → white 0.25 against tileBody's white 0.10:
//         case .border: return TokenColor(light: srgb(0x767C86), dark: srgb(0x404040))
//         case .tileBody: return TokenColor(light: srgb(0xFAFBFC), dark: srgb(0x1A1A1A))
//       Observed, exit 1, with the table showing each failing row inline:
//         border on canvas dark 1.88:1  floor 3.00:1  FAIL
//         FAIL: TokenContrast: 11 pair(s) below floor:
//           - border on canvas in dark is 1.88:1, below its 3.00:1 floor
//           - border on cardDiff in dark is 1.42:1, below its 3.00:1 floor
//           …
//
//   (3) `textSecondary.legalBackgrounds` narrowed to `[]` — the way coverage
//       disappears without any colour looking wrong. Observed, exit 1:
//         FAIL: TokenContrast: the documented pairs cover [… 9 tokens] but the
//         gated tokens are [… 10 tokens]
//
// This suite runs BEFORE `runDesignTokenChecks` deliberately: both catch a bad
// colour, but when one is wrong the RATIO is the useful message, not the
// provenance table that the same edit also invalidates.

private func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

/// One deliberately-broken pair, its expected ratio band, and what it stands for.
/// Held as data so the count is assertable — a witness cannot be quietly dropped.
private struct ContrastWitness {
    let label: String
    let foreground: ChipColor
    let background: ChipColor
    let floor: Double
    /// The ratio the audit measured, pinned so the witness itself cannot drift
    /// into being a different (and possibly passing) colour.
    let expected: Double
}

func runTokenContrastChecks() {
    // 1. Metric anchor FIRST (packet "watch out"): if the luminance function is
    //    broken, every ratio below is meaningless and the table would still print.
    let anchor = WCAGContrast.ratio(ChipColor(r: 1, g: 1, b: 1), ChipColor(r: 0, g: 0, b: 0))
    expect(anchor >= 20.9 && anchor <= 21.1,
           "TokenContrast: white/black must be ~21:1, got \(fmt(anchor)) — the ratio function is broken, so nothing below means anything")
    let selfAnchor = WCAGContrast.ratio(ChipColor(r: 0.5, g: 0.5, b: 0.5), ChipColor(r: 0.5, g: 0.5, b: 0.5))
    expect(selfAnchor >= 0.99 && selfAnchor <= 1.01,
           "TokenContrast: a colour against itself must be 1.00:1, got \(fmt(selfAnchor))")

    // 2. The pair set must be non-empty and cover both themes. A gate that
    //    measured nothing would otherwise print a green line with an empty table.
    let pairs = DesignTokens.documentedPairs
    expect(!pairs.isEmpty, "TokenContrast: documentedPairs is empty — this gate would pass vacuously")
    expect(TokenTheme.allCases.count == 2,
           "TokenContrast: expected 2 themes, got \(TokenTheme.allCases.count) — a single-theme sweep cannot gate light AND dark")
    // 2b. PAIR IDENTITY, not just foreground coverage. The expected set is built
    //     here from the tokens' own `legalBackgrounds`/`legalSurfaces`/`contrastFloor`
    //     rather than read off `documentedPairs`, so this is an independent
    //     derivation and not a tautology — reusing `documentedPairs` on both sides
    //     would compare it to itself and could not catch a pair being swapped for
    //     another with the same foreground. Duplicates are rejected too: two copies
    //     of an easy pair would inflate the count while hiding a lost hard one.
    var expectedPairs: Set<String> = []
    for text in TextToken.allCases {
        for background in text.legalBackgrounds {
            expectedPairs.insert("\(text.rawValue)|\(background.name)|\(fmt(DesignTokens.textFloor))")
        }
    }
    for accent in AccentToken.allCases {
        for surface in accent.legalSurfaces {
            expectedPairs.insert("\(accent.rawValue)|\(surface.rawValue)|\(fmt(DesignTokens.textFloor))")
        }
    }
    for line in LineToken.allCases {
        guard let floor = line.contrastFloor else { continue }
        for surface in line.legalSurfaces {
            expectedPairs.insert("\(line.rawValue)|\(surface.rawValue)|\(fmt(floor))")
        }
    }
    let actualKeys = pairs.map { "\($0.foreground)|\($0.background)|\(fmt($0.floor))" }
    expect(Set(actualKeys).count == actualKeys.count,
           "TokenContrast: documentedPairs contains duplicates (\(actualKeys.count) pairs, \(Set(actualKeys).count) distinct) — a duplicated easy pair can hide a lost hard one")
    let missing = expectedPairs.subtracting(actualKeys).sorted()
    let extra = Set(actualKeys).subtracting(expectedPairs).sorted()
    expect(missing.isEmpty && extra.isEmpty,
           "TokenContrast: the gated pair set does not match the tokens' own declarations — missing \(missing), unexpected \(extra)")

    // 3. Every documented pair, both themes, against its own floor — and print
    //    the table. Rows are collected rather than printed inline so the log is
    //    ordered (foreground, then theme, then background) and diffable run to run.
    var rows: [String] = []
    var failures: [String] = []
    var tightest: (label: String, ratio: Double, floor: Double)?
    for pair in pairs.sorted(by: { ($0.foreground, $0.background) < ($1.foreground, $1.background) }) {
        for theme in TokenTheme.allCases {
            let ratio = pair.ratio(for: theme)
            let ok = ratio >= pair.floor
            rows.append(String(
                format: "  %-14@ on %-16@ %-5@ %6@:1  floor %@:1  %@",
                pair.foreground as NSString, pair.background as NSString, theme.rawValue as NSString,
                fmt(ratio) as NSString, fmt(pair.floor) as NSString, (ok ? "ok" : "FAIL") as NSString))
            if !ok {
                failures.append("\(pair.foreground) on \(pair.background) in \(theme.rawValue) is \(fmt(ratio)):1, below its \(fmt(pair.floor)):1 floor")
            }
            if tightest == nil || ratio - pair.floor < tightest!.ratio - tightest!.floor {
                tightest = ("\(pair.foreground) on \(pair.background) [\(theme.rawValue)]", ratio, pair.floor)
            }
        }
    }
    print("TokenContrast: \(pairs.count) documented pairs x \(TokenTheme.allCases.count) themes")
    for row in rows { print(row) }
    expect(failures.isEmpty,
           "TokenContrast: \(failures.count) pair(s) below floor:\n  - " + failures.joined(separator: "\n  - "))

    // 4. The witnesses. Same evaluator, same floors — these must come out UNDER
    //    their floor, or the sweep above is not discriminating and its "ok" column
    //    means nothing. Each is a colour the P0.4 audit actually measured.
    let witnesses: [ContrastWitness] = [
        // The packet's witness (1): tertiaryLabelColor over the dark window fill
        // resolves to #565656. The packet quotes 2.25:1 "on card fills"; measured
        // on the specific card P0.4-FINDINGS names it is 2.07:1, which is the
        // value pinned here and in P1.3's suite. Either way it is far under AA.
        ContrastWitness(
            label: "tertiaryLabelColor-equivalent #565656 on cardMessage.dark",
            foreground: ChipColor(r: 0x56 / 255.0, g: 0x56 / 255.0, b: 0x56 / 255.0),
            background: SurfaceToken.cardMessage.color.dark,
            floor: DesignTokens.textFloor, expected: 2.07),
        // The packet's witness (2): the shipped tile outline, white@0.25 on
        // white@0.10.
        ContrastWitness(
            label: "white@0.25 on white@0.10 (the shipped tile outline)",
            foreground: ChipColor(r: 0.25, g: 0.25, b: 0.25),
            background: ChipColor(r: 0.10, g: 0.10, b: 0.10),
            floor: DesignTokens.lineFloor, expected: 1.68),
        // Root cause 3 of the 177: an undarkened accent used as text on white.
        ContrastWitness(
            label: "systemOrange-equivalent #FF8D28 on white (accent as text)",
            foreground: ChipColor(r: 1.0, g: 0x8D / 255.0, b: 0x28 / 255.0),
            background: ChipColor(r: 1, g: 1, b: 1),
            floor: DesignTokens.textFloor, expected: 2.31)
    ]
    expect(witnesses.count == 3,
           "TokenContrast: expected 3 executed witnesses, got \(witnesses.count) — a witness must not be dropped")
    var witnessSummary: [String] = []
    for witness in witnesses {
        let ratio = WCAGContrast.ratio(witness.foreground, witness.background)
        expect(ratio < witness.floor,
               "TokenContrast: witness `\(witness.label)` measured \(fmt(ratio)):1 and PASSED its \(fmt(witness.floor)):1 floor — the gate is not discriminating")
        expect(abs(ratio - witness.expected) <= 0.01,
               "TokenContrast: witness `\(witness.label)` is \(fmt(ratio)):1 but the audit measured \(fmt(witness.expected)):1 — the witness itself drifted")
        witnessSummary.append("\(witness.label) \(fmt(ratio)):1")
    }

    // 5. Each witness's REPLACEMENT token must pass on the same background. A
    //    witness that fails while its replacement also fails would prove nothing.
    let borderOnTile = WCAGContrast.ratio(LineToken.border.color.dark, SurfaceToken.tileBody.color.dark)
    expect(borderOnTile >= DesignTokens.lineFloor,
           "TokenContrast: `border` on `tileBody` in dark is \(fmt(borderOnTile)):1 — it does not replace the 1.68:1 outline")
    let secondaryOnCard = WCAGContrast.ratio(TextToken.textSecondary.color.dark, SurfaceToken.cardMessage.color.dark)
    expect(secondaryOnCard >= DesignTokens.textFloor,
           "TokenContrast: `textSecondary` on `cardMessage` in dark is \(fmt(secondaryOnCard)):1 — it does not replace the tertiary grey")
    // The attention ring and the approval dock's outline are `accentApproval` on
    // `canvas`/`tileBody`, SOLID (`CanvasNSView.attentionAccent` dropped the 0.8
    // alpha so this is a documented pair rather than an ungatable composite).
    // Held to the TEXT floor, not the line floor: the accent is used as a label
    // colour as well as an outline, and 2.31:1 orange-as-text is the failure it
    // replaces — clearing 3.0 would not be enough to call that fixed.
    for surface in [SurfaceToken.canvas, .tileBody] {
        for theme in TokenTheme.allCases {
            let ratio = WCAGContrast.ratio(
                AccentToken.accentApproval.color.resolved(for: theme), surface.color.resolved(for: theme))
            expect(ratio >= DesignTokens.textFloor,
                   "TokenContrast: the attention ring (`accentApproval` on \(surface.rawValue), \(theme.rawValue)) is \(fmt(ratio)):1 — it does not replace the 2.31:1 systemOrange it was")
        }
    }

    // 6. The packet's witness (1), run through THIS gate's own sweep rather than
    //    only as a bare ratio. Editing `textSecondary.dark` to the tertiary grey
    //    goes red in `runStatusChipChecks` first (P1.8 sources the idle accent
    //    from that token), so that edit never reaches this code — which would
    //    leave the claim "this sweep would have caught it" unproven. So the swap
    //    is performed here on a synthetic token and pushed through the identical
    //    `TokenPair` evaluator over `textSecondary`'s real legal backgrounds.
    let brokenSecondary = TokenColor(
        light: TextToken.textSecondary.color.light,
        dark: ChipColor(r: 0x56 / 255.0, g: 0x56 / 255.0, b: 0x56 / 255.0))
    var brokenSecondaryFailures = 0
    var brokenSecondaryPairs = 0
    for background in TextToken.textSecondary.legalBackgrounds {
        let pair = TokenPair(
            foreground: "witness.textSecondary", background: background.name,
            color: brokenSecondary, backgroundColor: background.color, floor: DesignTokens.textFloor)
        for theme in TokenTheme.allCases {
            brokenSecondaryPairs += 1
            if pair.ratio(for: theme) < pair.floor { brokenSecondaryFailures += 1 }
        }
    }
    expect(brokenSecondaryPairs == pairs.filter { $0.foreground == TextToken.textSecondary.rawValue }.count * TokenTheme.allCases.count,
           "TokenContrast: the witness sweep covered \(brokenSecondaryPairs) measurements, not the same number the real token gets — it is not exercising the same path")
    expect(brokenSecondaryFailures >= 11,
           "TokenContrast: the tertiary-grey `textSecondary` witness failed only \(brokenSecondaryFailures) of \(brokenSecondaryPairs) measurements — the sweep does not catch the packet's regression")
    // And the shipped token must pass every one of those same measurements, so the
    // count above is discriminating rather than "everything fails".
    for background in TextToken.textSecondary.legalBackgrounds {
        for theme in TokenTheme.allCases {
            let ratio = WCAGContrast.ratio(
                TextToken.textSecondary.color.resolved(for: theme), background.color.resolved(for: theme))
            expect(ratio >= DesignTokens.textFloor,
                   "TokenContrast: the shipped `textSecondary` fails on \(background.name) in \(theme.rawValue) at \(fmt(ratio)):1")
        }
    }

    guard let worst = tightest else {
        expect(false, "TokenContrast: nothing was measured")
        return
    }
    print("TokenContrast checks passed: all \(pairs.count * TokenTheme.allCases.count) measurements clear their floor "
        + "(tightest \(worst.label) at \(fmt(worst.ratio)):1 vs \(fmt(worst.floor))); "
        + "pair identity matches the tokens' own declarations; anchor \(fmt(anchor)):1; "
        + "tertiary-grey textSecondary swept through the same evaluator fails \(brokenSecondaryFailures)/\(brokenSecondaryPairs); "
        + "witnesses fail as required — " + witnessSummary.joined(separator: ", "))
}
