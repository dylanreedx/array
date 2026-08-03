import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P1.1-agentui-module.md
//
// Layer-1 check suite for the shared agent-UI module. Its only dependency is
// ContinuumRevivedAgentUI — that is the point: if a token or presenter ever
// reaches back into Core, this executable stops compiling.
//
// `expect` is the same shape as every other checks target's (see
// ContinuumRevivedCoreChecks/main.swift, ContinuumRevivedPaletteChecks): fail
// loud on stderr, exit 1 on the first failure.
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        Foundation.exit(1)
    }
}

if CommandLine.arguments.contains("--composer-action-negative-witness") {
    let unsupported = AgentComposerPresentation.resolve(
        state: .working,
        capabilities: AgentComposerPresentedCapabilities(
            canSend: true, canStop: false, canSteer: false, canQueue: false
        ),
        hasDraft: true
    )
    // Deliberately assert the named regression against the production resolver.
    // The parent process below requires this exact assertion to be observed red.
    expect(unsupported.title == "Steer",
           "negative witness: working without Stop falsely advertised Steer")
    Foundation.exit(0)
}

// Ticket: docs/38-tickets/87-agent-ui-component-framework.md
runStatusChipChecks()

// Ticket: docs/38-tickets/90-agent-ux/P1.2-tokencolor-light-dark.md
runTokenColorChecks()

// Ticket: docs/38-tickets/90-agent-ux/P1.6-token-contrast-gate.md
runTokenContrastChecks()

// Ticket: docs/38-tickets/90-agent-ux/P1.3-surface-text-border-tokens.md
runDesignTokenChecks()

// Ticket: docs/38-tickets/90-agent-ux/P1.4-type-scale.md
runTypographyChecks()

// Ticket: docs/38-tickets/90-agent-ux/P1.5-spacing-radius-scale.md
runMetricsChecks()

// Ticket: docs/38-tickets/90-agent-ux/P3.1-inbox-row-model.md
runAgentInboxRowChecks()

// Ticket: docs/38-tickets/90-agent-ux/P3.4-frozen-sort.md
runInboxSortChecks()

// Ticket: docs/38-tickets/90-agent-ux/P3.8-scope-dropdown.md
runInboxScopeChecks()

// Ticket: docs/38-tickets/90-agent-ux/P4.1-lifecycle-state.md
runAgentLifecycleChecks()

// Ticket: docs/38-tickets/90-agent-ux/P4.2-effective-settled.md
runEffectiveLifecycleChecks()

// Ticket: docs/38-tickets/90-agent-ux/P4.5-snooze-presets.md
runSnoozePresetChecks()

// Ticket: docs/38-tickets/90-agent-ux/P4.6-snooze-raised-hand.md
runSnoozeRaisedHandChecks()

// Ticket: docs/38-tickets/90-agent-ux/P4.13-precedence-matrix.md
runPrecedenceMatrixChecks()

// Ticket: docs/38-tickets/91-agent-tile-ux/P0.3-semantic-tile-tokens.md
runAgentTileTokenChecks()

// Ticket: docs/38-tickets/91-agent-tile-ux/P4.6-send-stop-intent-state.md
runComposerActionPresentationChecks()

print("ContinuumRevivedAgentUIChecks passed")

// MARK: - P4.6 — truthful composer intents, capabilities and action state

func runComposerActionPresentationChecks() {
    // Exhaust all 2 states × 16 capability combinations × draft/no-draft.
    // Every row must resolve to exactly one primary presentation, while future
    // secondary actions appear only when their explicit capability is present.
    var rows = 0
    for state in AgentComposerTurnPresentationState.allCases {
        for bits in 0..<16 {
            let capabilities = AgentComposerPresentedCapabilities(
                canSend: bits & 1 != 0,
                canStop: bits & 2 != 0,
                canSteer: bits & 4 != 0,
                canQueue: bits & 8 != 0
            )
            for hasDraft in [false, true] {
                rows += 1
                let value = AgentComposerPresentation.resolve(
                    state: state, capabilities: capabilities, hasDraft: hasDraft
                )
                expect(!value.title.isEmpty && !value.symbolName.isEmpty && !value.accessibilityLabel.isEmpty,
                       "ComposerAction: every row must have one complete primary presentation")

                switch state {
                case .ready where capabilities.canSend:
                    expect(value.primaryAction == .send,
                           "ComposerAction: ready + canSend must present Send")
                    expect(value.isEnabled == hasDraft,
                           "ComposerAction: Send is enabled exactly when a draft exists")
                // P5.5 consolidation: Stop presents whenever stopping is possible
                // — .working, and the .ready spawn/drain windows where only the
                // capability knows a runner is in flight. One interrupt affordance
                // from submit until the turn is over, CLI-style.
                case _ where capabilities.canStop:
                    expect(value.primaryAction == .stop && value.isEnabled,
                           "ComposerAction: canStop must present an enabled Stop in every state")
                default:
                    expect(value.primaryAction == .unavailable && !value.isEnabled,
                           "ComposerAction: an unsupported primary operation must not be advertised")
                }

                let expectedSecondary: Set<AgentComposerSecondaryAction> = state == .working
                    ? Set(([capabilities.canSteer ? .steer : nil,
                            capabilities.canQueue ? .queue : nil]).compactMap { $0 })
                    : []
                expect(value.secondaryActions == expectedSecondary,
                       "ComposerAction: secondary actions must equal explicit working capabilities")
            }
        }
    }
    expect(rows == 64, "ComposerAction: expected exhaustive 64-row truth table, got \(rows)")

    // Required negative witness: today's compiled floor has no steer/queue RPC.
    // Working without Stop must be passive status, never a fake Steer action.
    let noRPC = AgentComposerPresentation.resolve(
        state: .working,
        capabilities: AgentComposerPresentedCapabilities(
            canSend: true, canStop: false, canSteer: false, canQueue: false
        ),
        hasDraft: true
    )
    expect(noRPC.primaryAction == .unavailable && noRPC.title == "Working"
        && noRPC.secondaryActions.isEmpty && !noRPC.isEnabled,
        "ComposerAction: working without RPC must show passive Working, never fake Steer/Queue")

    let loadingStop = AgentComposerPresentation.resolve(
        state: .working,
        capabilities: AgentComposerPresentedCapabilities(
            canSend: false, canStop: true, canSteer: false, canQueue: false
        ),
        hasDraft: false,
        isExecutingPrimaryAction: true
    )
    expect(loadingStop.primaryAction == .stop && loadingStop.isLoading && !loadingStop.isEnabled,
           "ComposerAction: an executing Stop stays identifiable but cannot be fired twice")
    expect(loadingStop.title == "Stopping…" && loadingStop.symbolName == "hourglass"
        && loadingStop.accessibilityLabel == "Stopping current agent turn",
        "ComposerAction: loading Stop must have a visible and accessible state distinct from disabled Stop")

    // Required negative witness: launch this same compiled check against the
    // production resolver and deliberately demand the forbidden fake-Steer result.
    // Passing requires the named assertion to be observed red, not a source-text
    // proxy or a comment claiming a mutation would fail.
    let witness = Process()
    witness.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    witness.arguments = ["--composer-action-negative-witness"]
    let witnessError = Pipe()
    witness.standardError = witnessError
    do {
        try witness.run()
    } catch {
        expect(false, "ComposerAction: could not launch negative witness: \(error)")
    }
    witness.waitUntilExit()
    let witnessOutput = String(
        data: witnessError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
    ) ?? ""
    let expectedWitness = "FAIL: negative witness: working without Stop falsely advertised Steer"
    expect(witness.terminationStatus != 0,
           "ComposerAction: fake-Steer negative witness must be observed red")
    expect(witnessOutput.contains(expectedWitness),
           "ComposerAction: negative witness must fail at the named production assertion")

    print("Composer action negative witness observed red (exit \(witness.terminationStatus)): \(expectedWitness)")
    print("Composer action checks passed: \(rows) state/capability/draft rows and conservative no-RPC presentation")
}

// MARK: - P0.3 — the v2 tile's surfaces, line roles and radii
//
// Ticket: docs/38-tickets/91-agent-tile-ux/P0.3-semantic-tile-tokens.md
//
// Lives in this main rather than beside `DesignTokenChecks.swift` because the
// packet's file fence names exactly four paths and a new file is not one of them.
//
// What this suite exists to catch, in the order the failures matter:
//
//  1. A SEMANTIC LINE ALIASED TO THE DECORATIVE HAIRLINE — the packet's named
//     requirement. Caught two ways that are independent: by value (no gated role
//     may resolve to `separator`'s colour in either theme) and by measurement
//     (the hairline does NOT clear 3:1 on any tile surface, while every gated
//     role does clear its own floor on all of them). The second is what makes
//     the first mean something: the classes are separated by contrast, not by
//     naming, so `focusRing = separator` fails even if someone also renames it.
//  2. A ROLE INVENTING A COLOUR. Every role's value must BE a P1.3 token, so the
//     eleven shipped surfaces are gated for it by P1.3's own sweep and this file
//     only has to gate the five new ones.
//  3. AN UNREADABLE NEW SURFACE — every new surface/foreground pair, both themes,
//     against its own floor, with the worst case pinned to ±0.01 so a value tweak
//     that still clears the floor goes red until the provenance is updated.
//  4. AN INVISIBLE SELECTION — a row emphasis that collapses onto `tileBody`.
//  5. A RADIUS LADDER THAT RE-INVERTS, or a shipped `Radius` value moved under
//     cover of adding new ones.
//
// NEGATIVE WITNESSES — each edit made against this final code, run, and observed
// red at exit 1. Quoted, not predicted:
//
//   (a) `AgentLineRole.focusRing` → `LineToken.separator.color` (the packet's
//       aliasing failure):
//         FAIL: AgentTileTokens: focusRing resolves to the same value as
//         decorativeHairline in light (DDE0E6) — a state-bearing line may not be
//         aliased to the exempt hairline
//   (b) the same edit with leg 3's by-value loop DELETED and leg 4's two identity
//       assertions short-circuited, to prove the measurement leg catches it on its
//       own rather than decorating a guard that already fired:
//         FAIL: AgentTileTokens: 10 pair(s) below floor:
//           - focusRing on artifact in light is 1.16:1, below its 3.00:1 floor
//           - focusRing on artifact in dark is 1.24:1, below its 3.00:1 floor
//           …
//   (c) `decorativeHairline.contrastFloor` → `DesignTokens.lineFloor` (exempting
//       nothing, i.e. re-applying 1.4.11 to decoration — the defect §11 names):
//         FAIL: AgentTileTokens: decorativeHairline must be the decorative role,
//         but it carries a floor
//   (d) `AgentSurfaceRole.rowHover.color` → `SurfaceToken.tileBody.color` (a hover
//       you cannot see). Caught by the distinctness leg first, which is the
//       earlier and stricter statement of the same defect:
//         FAIL: AgentTileTokens: rowHover in light is the same value as tileBody
//         (FAFBFC) — the ladder lost a step
//   (d2) so also `rowHover` → 0xF9FAFB/0x15181D — DISTINCT from `tileBody` but an
//        imperceptible step off it, which is what leg 10 exists for:
//         FAIL: AgentTileTokens: rowHover is 1.01:1 against tileBody in light — a
//         row emphasis that equals the surface it sits on is invisible
//   (e) `AgentTileRadius.composer` 10 → 14 (radius nesting re-inverted):
//         FAIL: AgentTileRadius: composer (14.0) is outside its 10.0…12.0 design
//         band
//   (f) `AgentTileTokens.surfaceTextTokens` narrowed to `[.textPrimary]` (coverage
//       disappearing with no colour looking wrong):
//         FAIL: AgentTileTokens: expected 30 documented tile pairs, got 25
//   (g) `Radius.container` 10 → 6 (a shipped value moved while adding new ones).
//       P1.5's own nesting rule speaks first, which is the right owner:
//         FAIL: Radius: container (6.0) must exceed card (6.0) — a container
//         inside its own cards' radius is the inverted nesting this ticket fixes
//   (g2) so also `Radius.container` 10 → 8, which still clears P1.5's rule and
//        therefore reaches the preservation assertion added here:
//         FAIL: Radius: the shipped container radius must stay 10.0, got 8.0 —
//         P0.3 adds roles, it does not move adopted ones
//   (h) `rowSelected` → 0xEDF1F8/0x202834, i.e. pulled back INSIDE the shipped
//       ladder so it is no longer its extreme — the state in which leg 9's pinned
//       "worst background" claims would start describing a different surface:
//         FAIL: AgentTileTokens: canvas is darker than rowSelected in light —
//         rowSelected must be the darkest light surface of all 16, because the
//         pinned worst-case table depends on it
func runAgentTileTokenChecks() {
    func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

    // 0. Metric anchor. Without this every ratio below could be meaningless and
    //    the suite would still print green.
    let anchor = WCAGContrast.ratio(ChipColor(r: 1, g: 1, b: 1), ChipColor(r: 0, g: 0, b: 0))
    expect(anchor >= 20.9 && anchor <= 21.1,
           "AgentTileTokens: white/black must be ~21:1, got \(fmt(anchor)) — the ratio function is broken")

    // 1. Totality. Five surfaces, four roles, every surface themed and in range,
    //    and light actually light / dark actually dark — the same rule P1.3
    //    applies to `SurfaceToken`, so a new fill cannot be a dark-only literal.
    expect(AgentSurfaceRole.allCases.count == 5,
           "AgentTileTokens: expected 5 tile surfaces, got \(AgentSurfaceRole.allCases.count)")
    expect(AgentLineRole.allCases.count == 4,
           "AgentTileTokens: expected 4 line roles, got \(AgentLineRole.allCases.count)")
    for surface in AgentSurfaceRole.allCases {
        let token = surface.color
        expect(token.light.hexKey != token.dark.hexKey,
               "AgentTileTokens: \(surface.rawValue) has the same value in both themes (\(token.light.hexKey)) — it is not themed")
        for theme in TokenTheme.allCases {
            let c = token.resolved(for: theme)
            expect(c.r >= 0 && c.r <= 1 && c.g >= 0 && c.g <= 1 && c.b >= 0 && c.b <= 1,
                   "AgentTileTokens: \(surface.rawValue).\(theme.rawValue) is out of the 0…1 sRGB range")
        }
        let lightLum = WCAGContrast.relativeLuminance(token.light)
        let darkLum = WCAGContrast.relativeLuminance(token.dark)
        expect(lightLum > 0.5,
               "AgentTileTokens: \(surface.rawValue) light is not a light surface (luminance \(fmt(lightLum)))")
        expect(darkLum < 0.2,
               "AgentTileTokens: \(surface.rawValue) dark is not a dark surface (luminance \(fmt(darkLum)))")
    }

    // 1b. `rowSelected` is the END of the sixteen-surface ladder in both themes:
    //     the darkest light surface and the lightest dark one. This is the
    //     STRUCTURAL reason it is every foreground's worst background in leg 9,
    //     so pinning it here means those pins cannot quietly start describing a
    //     different surface. Review caught the note above claiming all five new
    //     surfaces sit inside the shipped ladder; they do not, and this is the
    //     part of that which is load-bearing and therefore gated.
    let allSurfaceLuminances: [(name: String, color: TokenColor)] =
        SurfaceToken.allCases.map { ($0.rawValue, $0.color) }
        + AgentSurfaceRole.allCases.map { ($0.rawValue, $0.color) }
    for (name, token) in allSurfaceLuminances where name != AgentSurfaceRole.rowSelected.rawValue {
        let selected = AgentSurfaceRole.rowSelected.color
        expect(WCAGContrast.relativeLuminance(token.light) > WCAGContrast.relativeLuminance(selected.light),
               "AgentTileTokens: \(name) is darker than rowSelected in light — rowSelected must be the darkest light surface of all \(allSurfaceLuminances.count), because the pinned worst-case table depends on it")
        expect(WCAGContrast.relativeLuminance(token.dark) < WCAGContrast.relativeLuminance(selected.dark),
               "AgentTileTokens: \(name) is lighter than rowSelected in dark — rowSelected must be the lightest dark surface of all \(allSurfaceLuminances.count)")
    }

    // 2. Distinctness across the WHOLE ladder, per theme — the five new surfaces
    //    against each other and against the eleven shipped ones. Two surfaces
    //    with one value are one surface, and the tile would lose a step.
    for theme in TokenTheme.allCases {
        var keys: [String: String] = [:]
        for surface in SurfaceToken.allCases {
            keys[surface.color.resolved(for: theme).hexKey] = surface.rawValue
        }
        for surface in AgentSurfaceRole.allCases {
            let key = surface.color.resolved(for: theme).hexKey
            expect(keys[key] == nil,
                   "AgentTileTokens: \(surface.rawValue) in \(theme.rawValue) is the same value as \(keys[key] ?? "?") (\(key)) — the ladder lost a step")
            keys[key] = surface.rawValue
        }
        expect(keys.count == SurfaceToken.allCases.count + AgentSurfaceRole.allCases.count,
               "AgentTileTokens: \(theme.rawValue) has \(keys.count) distinct surface values for \(SurfaceToken.allCases.count + AgentSurfaceRole.allCases.count) surfaces")
    }

    // 3. THE ALIAS GUARD, leg one: by value. No state-bearing role may resolve to
    //    the exempt hairline's colour, in either theme.
    let hairline = AgentLineRole.decorativeHairline
    expect(!hairline.isSemantic,
           "AgentTileTokens: decorativeHairline must be the decorative role, but it carries a floor")
    for role in AgentLineRole.allCases where role.isSemantic {
        for theme in TokenTheme.allCases {
            let key = role.color.resolved(for: theme).hexKey
            expect(key != hairline.color.resolved(for: theme).hexKey,
                   "AgentTileTokens: \(role.rawValue) resolves to the same value as decorativeHairline in \(theme.rawValue) (\(key)) — a state-bearing line may not be aliased to the exempt hairline")
        }
    }

    // 4. Roles do not invent colours: each is exactly one P1.3 token, by value in
    //    BOTH themes. That is what carries the role's gating on the eleven
    //    shipped surfaces, so this suite only owes the five new ones.
    let expectedSources: [(role: AgentLineRole, source: String, color: TokenColor)] = [
        (.decorativeHairline, LineToken.separator.rawValue, LineToken.separator.color),
        (.controlBoundary, LineToken.border.rawValue, LineToken.border.color),
        (.focusRing, LineToken.borderStrong.rawValue, LineToken.borderStrong.color),
        (.attention, AccentToken.accentApproval.rawValue, AccentToken.accentApproval.color)
    ]
    expect(Set(expectedSources.map(\.role)) == Set(AgentLineRole.allCases),
           "AgentTileTokens: the role→token table must cover every role (table \(expectedSources.map(\.role.rawValue).sorted()) vs roles \(AgentLineRole.allCases.map(\.rawValue).sorted()))")
    for entry in expectedSources {
        for theme in TokenTheme.allCases {
            expect(entry.role.color.resolved(for: theme).hexKey == entry.color.resolved(for: theme).hexKey,
                   "AgentTileTokens: \(entry.role.rawValue) in \(theme.rawValue) is \(entry.role.color.resolved(for: theme).hexKey), not `\(entry.source)`'s \(entry.color.resolved(for: theme).hexKey) — a role must reuse a gated token, not invent a value")
        }
        // The decorative role maps onto P1.3's one exemption; every gated role
        // maps onto a P1.3 token that P1.3 itself gates. Asserted rather than
        // assumed, so a role cannot be pointed at an ungated token later.
        let sourceIsGated = LineToken.allCases.contains { $0.rawValue == entry.source && $0.contrastFloor != nil }
            || AccentToken.allCases.contains { $0.rawValue == entry.source }
        expect(entry.role.isSemantic == sourceIsGated,
               "AgentTileTokens: \(entry.role.rawValue) is \(entry.role.isSemantic ? "gated" : "exempt") but its source token `\(entry.source)` is \(sourceIsGated ? "gated" : "exempt") by P1.3 — the two must agree")
    }
    for accent in AgentLineRole.attentionAccents {
        expect(AccentToken.allCases.contains(accent),
               "AgentTileTokens: attention accent \(accent.rawValue) is not a shipped accent")
    }
    expect(AgentLineRole.attentionAccents.contains(.accentApproval)
        && AgentLineRole.attentionAccents.contains(.accentFailed),
           "AgentTileTokens: an attention line must cover approval AND error (got \(AgentLineRole.attentionAccents.map(\.rawValue)))")

    // 5. Exemptions are enumerable and reasoned, and an exempt role contributes
    //    no pair — never a floor of 1.
    let pairs = AgentTileTokens.documentedPairs
    let exemptions = AgentTileTokens.decorativeExemptions
    expect(exemptions.count == 1,
           "AgentTileTokens: expected exactly 1 decorative exemption, got \(exemptions.count) — a decorative role must stay exempt and listed, never gated at a floor it cannot clear")
    expect(exemptions.first?.role == .decorativeHairline,
           "AgentTileTokens: the one exemption must be decorativeHairline, got \(exemptions.first?.role.rawValue ?? "none")")
    for exemption in exemptions {
        expect(exemption.reason.count >= 40,
               "AgentTileTokens: \(exemption.role.rawValue) is exempt without a real reason")
        expect(!pairs.contains { $0.foreground.hasPrefix(exemption.role.rawValue) },
               "AgentTileTokens: \(exemption.role.rawValue) is exempt but still appears in the gated pairs")
    }
    for role in AgentLineRole.allCases {
        expect(role.isSemantic == (role.exemptionReason == nil),
               "AgentTileTokens: \(role.rawValue) is both gated and exempt (or neither) — one or the other")
        if role.isSemantic {
            expect(pairs.contains { $0.foreground.hasPrefix(role.rawValue) },
                   "AgentTileTokens: \(role.rawValue) is gated but has no documented pair")
        }
    }

    // 6. Pair identity, derived here independently of `documentedPairs` so this
    //    is not a tautology: 5 surfaces x (2 text + controlBoundary + focusRing +
    //    2 attention accents) = 30.
    var expectedPairs: Set<String> = []
    for surface in AgentSurfaceRole.allCases {
        for text in AgentTileTokens.surfaceTextTokens {
            expectedPairs.insert("\(text.rawValue)|\(surface.rawValue)|\(fmt(DesignTokens.textFloor))")
        }
        for role in AgentLineRole.allCases {
            guard let floor = role.contrastFloor else { continue }
            if role == .attention {
                for accent in AgentLineRole.attentionAccents {
                    expectedPairs.insert("\(role.rawValue)(\(accent.rawValue))|\(surface.rawValue)|\(fmt(floor))")
                }
            } else {
                expectedPairs.insert("\(role.rawValue)|\(surface.rawValue)|\(fmt(floor))")
            }
        }
    }
    expect(pairs.count == 30, "AgentTileTokens: expected 30 documented tile pairs, got \(pairs.count)")
    let actualKeys = pairs.map { "\($0.foreground)|\($0.background)|\(fmt($0.floor))" }
    expect(Set(actualKeys).count == actualKeys.count,
           "AgentTileTokens: the tile pairs contain duplicates (\(actualKeys.count) pairs, \(Set(actualKeys).count) distinct) — a duplicated easy pair can hide a lost hard one")
    let missing = expectedPairs.subtracting(actualKeys).sorted()
    let extra = Set(actualKeys).subtracting(expectedPairs).sorted()
    expect(missing.isEmpty && extra.isEmpty,
           "AgentTileTokens: the gated tile pairs do not match the roles' own declarations — missing \(missing), unexpected \(extra)")

    // 7. Every pair, both themes, against its own floor.
    var rows: [String] = []
    var failures: [String] = []
    for pair in pairs.sorted(by: { ($0.foreground, $0.background) < ($1.foreground, $1.background) }) {
        for theme in TokenTheme.allCases {
            let ratio = pair.ratio(for: theme)
            let ok = ratio >= pair.floor
            rows.append(String(
                format: "  %-28@ on %-12@ %-5@ %6@:1  floor %@:1  %@",
                pair.foreground as NSString, pair.background as NSString, theme.rawValue as NSString,
                fmt(ratio) as NSString, fmt(pair.floor) as NSString, (ok ? "ok" : "FAIL") as NSString))
            if !ok {
                failures.append("\(pair.foreground) on \(pair.background) in \(theme.rawValue) is \(fmt(ratio)):1, below its \(fmt(pair.floor)):1 floor")
            }
        }
    }
    print("AgentTileTokens: \(pairs.count) tile pairs x \(TokenTheme.allCases.count) themes")
    for row in rows { print(row) }
    expect(failures.isEmpty,
           "AgentTileTokens: \(failures.count) pair(s) below floor:\n  - " + failures.joined(separator: "\n  - "))

    // 8. THE ALIAS GUARD, leg two: by measurement, and independent of leg 3. The
    //    hairline must FAIL the line floor on every tile surface — that is the
    //    property that makes it decoration, and the reason a semantic role
    //    resolving to it would be a state you cannot see.
    var hairlineWorst = 0.0
    for surface in AgentSurfaceRole.allCases {
        for theme in TokenTheme.allCases {
            let ratio = WCAGContrast.ratio(
                hairline.color.resolved(for: theme), surface.color.resolved(for: theme))
            expect(ratio < DesignTokens.lineFloor,
                   "AgentTileTokens: decorativeHairline on \(surface.rawValue) in \(theme.rawValue) is \(fmt(ratio)):1, which CLEARS the \(fmt(DesignTokens.lineFloor)):1 component floor — it is no longer distinguishable from a semantic line, so the exemption is doing work it should not")
            hairlineWorst = max(hairlineWorst, ratio)
        }
    }

    // 9. Pin the MARGIN, not just the floor, and pin the worst background too.
    //    Every ratio DesignTokens.swift's P0.3 note claims is asserted here, and
    //    the table must name exactly the gated foregrounds — so a new foreground
    //    cannot skip it and a value tweak cannot silently invalidate it.
    let pinnedWorst: [(foreground: String, theme: TokenTheme, background: String, ratio: Double)] = [
        ("textPrimary", .light, "rowSelected", 13.98), ("textPrimary", .dark, "rowSelected", 11.20),
        ("textSecondary", .light, "rowSelected", 5.56), ("textSecondary", .dark, "rowSelected", 6.04),
        ("controlBoundary", .light, "rowSelected", 3.27), ("controlBoundary", .dark, "rowSelected", 3.18),
        ("focusRing", .light, "rowSelected", 6.42), ("focusRing", .dark, "rowSelected", 5.64),
        ("attention(accentApproval)", .light, "rowSelected", 5.23),
        ("attention(accentApproval)", .dark, "rowSelected", 6.92),
        ("attention(accentFailed)", .light, "rowSelected", 4.90),
        ("attention(accentFailed)", .dark, "rowSelected", 5.42)
    ]
    expect(Set(pinnedWorst.map(\.foreground)) == Set(pairs.map(\.foreground)),
           "AgentTileTokens: the pinned-margin table must cover exactly the gated foregrounds (table \(Set(pinnedWorst.map(\.foreground)).sorted()) vs gated \(Set(pairs.map(\.foreground)).sorted()))")
    for pin in pinnedWorst {
        let candidates = pairs.filter { $0.foreground == pin.foreground }
        guard let measured = candidates.min(by: { $0.ratio(for: pin.theme) < $1.ratio(for: pin.theme) }) else {
            expect(false, "AgentTileTokens: \(pin.foreground) has no documented pair to measure a margin against")
            return
        }
        let ratio = measured.ratio(for: pin.theme)
        expect(abs(ratio - pin.ratio) <= 0.01,
               "AgentTileTokens: \(pin.foreground) in \(pin.theme.rawValue) has worst ratio \(fmt(ratio)):1, but the documented provenance says \(fmt(pin.ratio)):1 — update the P0.3 table in DesignTokens.swift with the new measurement")
        expect(measured.background == pin.background,
               "AgentTileTokens: \(pin.foreground)'s worst background in \(pin.theme.rawValue) is \(measured.background), not the documented \(pin.background) — the tile ladder moved")
    }

    // 10. A row emphasis is a visible step away from the row's own surface, and
    //     selection is the stronger step. Ratios pinned, so "subtle" cannot decay
    //     into "absent" and hover cannot quietly overtake selection.
    let pinnedEmphasis: [(role: AgentSurfaceRole, theme: TokenTheme, ratio: Double, floor: Double)] = [
        (.rowSelected, .light, 1.24, 1.20), (.rowSelected, .dark, 1.46, 1.20),
        (.rowHover, .light, 1.06, 1.05), (.rowHover, .dark, 1.10, 1.05)
    ]
    expect(Set(pinnedEmphasis.map(\.role)) == Set(AgentSurfaceRole.rowEmphases),
           "AgentTileTokens: the row-emphasis table must cover exactly the row emphases")
    for pin in pinnedEmphasis {
        let ratio = AgentTileTokens.rowEmphasisRatio(pin.role, theme: pin.theme)
        expect(ratio >= pin.floor,
               "AgentTileTokens: \(pin.role.rawValue) is \(fmt(ratio)):1 against \(AgentSurfaceRole.rowBase.rawValue) in \(pin.theme.rawValue) — a row emphasis that equals the surface it sits on is invisible")
        expect(abs(ratio - pin.ratio) <= 0.01,
               "AgentTileTokens: \(pin.role.rawValue) in \(pin.theme.rawValue) is \(fmt(ratio)):1, but the documented provenance says \(fmt(pin.ratio)):1")
    }
    for theme in TokenTheme.allCases {
        let selected = AgentTileTokens.rowEmphasisRatio(.rowSelected, theme: theme)
        let hover = AgentTileTokens.rowEmphasisRatio(.rowHover, theme: theme)
        expect(selected > hover,
               "AgentTileTokens: selection (\(fmt(selected)):1) must be a stronger step than hover (\(fmt(hover)):1) in \(theme.rawValue)")
    }

    // 11. The radius ladder: inside its design bands, on the spacing grid,
    //     strictly decreasing outermost-first, and still above the shipped
    //     nested-card radius. `Radius`'s own adopted values are asserted
    //     unchanged, because "add roles" must not become "move numbers".
    expect(Radius.card == 6.0, "Radius: the shipped card radius must stay 6.0, got \(Radius.card) — P0.3 adds roles, it does not move adopted ones")
    expect(Radius.container == 10.0, "Radius: the shipped container radius must stay 10.0, got \(Radius.container) — P0.3 adds roles, it does not move adopted ones")
    expect(Radius.pill == 999.0, "Radius: the shipped pill radius must stay 999.0, got \(Radius.pill)")
    let bands: [(name: String, value: Double, low: Double, high: Double)] = [
        ("tile", AgentTileRadius.tile, 11.0, 13.0),
        ("composer", AgentTileRadius.composer, 10.0, 12.0),
        ("artifact", AgentTileRadius.artifact, 8.0, 10.0)
    ]
    expect(AgentTileRadius.ladder == bands.map(\.value),
           "AgentTileRadius: the ladder must be exactly the banded roles, outermost first (got \(AgentTileRadius.ladder))")
    for band in bands {
        expect(band.value >= band.low && band.value <= band.high,
               "AgentTileRadius: \(band.name) (\(band.value)) is outside its \(band.low)…\(band.high) design band")
        expect((band.value / Space.grid).rounded() * Space.grid == band.value,
               "AgentTileRadius: \(band.name) (\(band.value)) is off the \(Space.grid)pt grid")
    }
    for (outer, inner) in zip(AgentTileRadius.ladder, AgentTileRadius.ladder.dropFirst()) {
        expect(outer > inner,
               "AgentTileRadius: the ladder must strictly decrease outermost-first (got \(outer) then \(inner)) — a container inside its own contents' radius is the inverted nesting P1.5 fixed")
    }
    guard let innermost = AgentTileRadius.ladder.last else {
        expect(false, "AgentTileRadius: the ladder is empty")
        return
    }
    expect(innermost > Radius.card,
           "AgentTileRadius: the innermost tile radius (\(innermost)) must still exceed the nested card radius (\(Radius.card))")

    print("AgentTileToken checks passed: \(AgentSurfaceRole.allCases.count) tile surfaces x \(TokenTheme.allCases.count) themes distinct across the full \(SurfaceToken.allCases.count + AgentSurfaceRole.allCases.count)-surface ladder, "
        + "\(pairs.count * TokenTheme.allCases.count) measurements clear their floor, "
        + "\(AgentLineRole.allCases.filter(\.isSemantic).count) semantic roles all reuse a gated P1.3 token and none aliases the hairline "
        + "(which peaks at \(fmt(hairlineWorst)):1, under the \(fmt(DesignTokens.lineFloor)):1 component floor), "
        + "\(exemptions.count) reasoned exemption, radii \(AgentTileRadius.ladder.map { Int($0) }) nest above card \(Int(Radius.card))")
}
