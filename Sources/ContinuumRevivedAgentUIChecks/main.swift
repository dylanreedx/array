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

// Selected iOS companion indicator: shared pure geometry/status/lifecycle contract.
runDualPlaneGyroChecks()

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

// Ticket: docs/38-tickets/94-sidebar-native-ux/P0.5-row-token-vocabulary.md
runSidebarSurfaceChecks()

// Ticket: docs/38-tickets/91-agent-tile-ux/P4.6-send-stop-intent-state.md
runComposerActionPresentationChecks()

// Ticket: docs/38-tickets/94-sidebar-native-ux/P0.3-row-fixture-corpus.md
runSidebarDefectCorpusChecks()

print("ContinuumRevivedAgentUIChecks passed")

// MARK: - Selected Dual-Plane Gyro — pure iOS companion contract

func runDualPlaneGyroChecks() {
    let bounds = CGRect(x: 0, y: 0, width: DualPlaneGyroIndicatorModel.side, height: DualPlaneGyroIndicatorModel.side)
    let states = DualPlaneGyroIndicatorModel.nodeStates(in: bounds, phase: DualPlaneGyroIndicatorModel.reducedMotionPhase)

    expect(DualPlaneGyroIndicatorModel.side == 18, "Dual-Plane Gyro: footprint must remain 18×18")
    expect(DualPlaneGyroIndicatorModel.primaryTiltDegrees == 28
        && DualPlaneGyroIndicatorModel.secondaryTiltDegrees == -28,
        "Dual-Plane Gyro: two planes must retain ±28° tilt")
    expect(DualPlaneGyroIndicatorModel.masterDuration == 7.20
        && DualPlaneGyroIndicatorModel.primaryOrbitPeriod == 2.40
        && DualPlaneGyroIndicatorModel.secondaryOrbitPeriod == 3.60,
        "Dual-Plane Gyro: deterministic 7.20s master / 2.40s + 3.60s orbit periods")
    expect(states.count == 3
        && states.filter({ $0.plane == .primary }).count == 2
        && states.filter({ $0.plane == .secondary }).count == 1,
        "Dual-Plane Gyro: two primary nodes and one secondary node")
    expect(states.map { $0.token.rawValue } == [
        AccentToken.accentWorking.rawValue,
        AccentToken.accentInput.rawValue,
        AccentToken.accentApproval.rawValue
    ], "Dual-Plane Gyro: node accents must be the three semantic tokens")
    expect(DualPlaneGyroIndicatorModel.sampledPathFitsFootprint(in: bounds),
           "Dual-Plane Gyro: sampled nodes must remain inside the 18×18 footprint")
    expect(DualPlaneGyroIndicatorModel.minimumCenterClearance(in: bounds) > 0,
           "Dual-Plane Gyro: center must remain open at every sampled phase")

    expect(DualPlaneGyroIndicatorModel.normalizedPhase(1) == 0
        && DualPlaneGyroIndicatorModel.nodeStates(in: bounds, phase: 0)
            == DualPlaneGyroIndicatorModel.nodeStates(in: bounds, phase: 1),
        "Dual-Plane Gyro: master-cycle phase must be deterministic")
    expect(DualPlaneGyroIndicatorModel.nodeStates(in: bounds, phase: .nan)
        == DualPlaneGyroIndicatorModel.nodeStates(in: bounds, phase: 0),
        "Dual-Plane Gyro: malformed phase must settle to the deterministic origin")
    expect(DualPlaneGyroIndicatorModel.accessibilityLabel == "Agent thinking",
           "Dual-Plane Gyro: accessibility label must be concise and stable")

    for status in AgentStatus.allCases {
        let expected = status == .working || status == .configuring
        expect(DualPlaneGyroIndicatorModel.isActive(status: status) == expected,
               "Dual-Plane Gyro: activity must follow synced status only for \(status.rawValue)")
    }
    expect(DualPlaneGyroIndicatorModel.shouldAnimate(
        active: true, windowAttached: true, viewVisible: true, sceneActive: true,
        reducedMotion: false, bounds: bounds),
        "Dual-Plane Gyro: foreground attached visible active view may animate")
    expect(!DualPlaneGyroIndicatorModel.shouldAnimate(
        active: true, windowAttached: false, viewVisible: true, sceneActive: true,
        reducedMotion: false, bounds: bounds)
        && !DualPlaneGyroIndicatorModel.shouldAnimate(
            active: true, windowAttached: true, viewVisible: true, sceneActive: false,
            reducedMotion: false, bounds: bounds)
        && !DualPlaneGyroIndicatorModel.shouldAnimate(
            active: true, windowAttached: true, viewVisible: true, sceneActive: true,
            reducedMotion: true, bounds: bounds),
        "Dual-Plane Gyro: lifecycle and Reduced Motion gates must stop compositor motion")

    let light = AccentToken.accentWorking.color.resolved(for: .light)
    let dark = AccentToken.accentWorking.color.resolved(for: .dark)
    expect(light != dark && LineToken.separator.color.resolved(for: .light)
        != LineToken.separator.color.resolved(for: .dark),
        "Dual-Plane Gyro: semantic accent and guide tokens must rebuild for both themes")
    print("Dual-Plane Gyro checks passed: geometry, semantic accents, phase, Reduced Motion, AX, theme, and lifecycle")
}

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

// MARK: - P0.3 (94-sidebar-native-ux) — the sidebar defect corpus's gates
//
// Ticket: docs/38-tickets/94-sidebar-native-ux/P0.3-row-fixture-corpus.md
//
// The corpus itself lives in `LabFixtures` (Sources/ContinuumRevived/App/
// ComponentLab.swift) because the app-module probe renders it, and this target
// deliberately depends on ContinuumRevivedAgentUI ALONE (see Package.swift) —
// so the corpus VALUES are not linkable from here, and by the P1.1 direction
// they must never become so. The gates below therefore read the corpus the way
// `ContinuumRevivedAgentContentChecks` reads its production seams: off the
// SOURCE, between two pinned markers, with comments stripped by a real
// scanner before any structural claim is made. What stays value-level here is
// the vocabulary the coverage matrix is derived FROM — `InboxState.allCases`,
// `InboxAttention.allCases`, `RowVariant.allCases`, `AgentInboxRow.maxDepth`
// are compiled in from AgentUI, so a state or variant added later demands a
// fixture without this file being touched. What stays value-level in the APP
// is the rendering half of the parity gate: `--sidebar-ux-check` materializes
// the corpus and asserts cells == rows, every state painted, and each cell's
// class matching its row's variant.
//
// NEGATIVE WITNESSES — each mutation made against the final ComponentLab.swift
// corpus, run, observed red at exit 1, and reverted with the reversion proved
// by `git diff`. Quoted, not predicted:
//
//   (a) a home path planted in the wide-project fixture's projectName
//       (`"/Users/plantedwitness/checkouts/wide"`):
//         FAIL: SidebarDefectCorpus: I5 hygiene violation — home-path shape
//         '/Users/plantedwitness' in the corpus region; fixtures are written,
//         never captured
//   (b) a key-shaped string planted in the dead-space fixture's title
//       (`"ssh-rsa AAAAB3NzaC1yc2E dead space"`):
//         FAIL: SidebarDefectCorpus: I5 hygiene violation — key-material shape
//         'ssh-rsa' in the corpus region; fixtures are written, never captured
//   (c) the corpus's one failed-state fixture removed (`state: .failed` →
//       `state: .ready` on the combiningMarksRTLName row):
//         FAIL: SidebarDefectCorpus: no fixture carries state: .failed — every
//         InboxState needs at least one corpus row
func runSidebarDefectCorpusChecks() {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ContinuumRevivedAgentUIChecks
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // repo root
    let componentLabURL = repoRoot
        .appendingPathComponent("Sources/ContinuumRevived/App/ComponentLab.swift")
    let probeURL = repoRoot
        .appendingPathComponent("Sources/ContinuumRevived/App/UIProbeGeometry.swift")
    guard let componentLab = try? String(contentsOf: componentLabURL, encoding: .utf8) else {
        expect(false, "SidebarDefectCorpus: could not read \(componentLabURL.path)")
        return
    }
    guard let probeSource = try? String(contentsOf: probeURL, encoding: .utf8) else {
        expect(false, "SidebarDefectCorpus: could not read \(probeURL.path)")
        return
    }

    // The corpus region, marker to marker. The markers are the contract that
    // lets this file find the corpus without linking it; losing one is red, not
    // a silent no-op scan.
    let beginMarker = "===== P0.3 SIDEBAR DEFECT CORPUS BEGIN"
    let endMarker = "===== P0.3 SIDEBAR DEFECT CORPUS END"
    expect(componentLab.components(separatedBy: beginMarker).count == 2,
           "SidebarDefectCorpus: ComponentLab.swift must contain the BEGIN marker exactly once")
    expect(componentLab.components(separatedBy: endMarker).count == 2,
           "SidebarDefectCorpus: ComponentLab.swift must contain the END marker exactly once")
    guard let beginRange = componentLab.range(of: beginMarker),
          let endRange = componentLab.range(of: endMarker),
          beginRange.upperBound < endRange.lowerBound else {
        expect(false, "SidebarDefectCorpus: corpus markers are missing or out of order")
        return
    }
    let rawRegion = String(componentLab[beginRange.upperBound..<endRange.lowerBound])

    // A real comment stripper — line comments, nested block comments, string
    // literals honoured (a `//` inside a string is content, and a planted
    // secret inside a comment is still scanned because HYGIENE runs on the raw
    // region). Structural claims below are made on the stripped text only, so
    // a `state: .failed` in a comment cannot satisfy a coverage gate.
    func stripComments(_ source: String) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(source.unicodeScalars)
        var i = 0
        var blockDepth = 0
        var inLine = false
        var inString = false
        while i < scalars.count {
            let c = scalars[i]
            let next: Unicode.Scalar? = i + 1 < scalars.count ? scalars[i + 1] : nil
            if inLine {
                if c == "\n" { inLine = false; out.append(c) }
            } else if blockDepth > 0 {
                if c == "/", next == "*" { blockDepth += 1; i += 1 } else if c == "*", next == "/" {
                    blockDepth -= 1
                    i += 1
                } else if c == "\n" {
                    out.append(c)
                }
            } else if inString {
                out.append(c)
                if c == "\\", let next {
                    out.append(next)
                    i += 1
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "/", next == "/" {
                inLine = true
                i += 1
            } else if c == "/", next == "*" {
                blockDepth = 1
                i += 1
            } else {
                out.append(c)
                if c == "\"" { inString = true }
            }
            i += 1
        }
        return String(String.UnicodeScalarView(out))
    }
    let region = stripComments(rawRegion)

    func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            expect(false, "SidebarDefectCorpus: invalid scan pattern \(pattern)")
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: match.numberOfRanges > 1 ? 1 : 0), in: text).map { String(text[$0]) }
        }
    }
    func braceBlock(startingAt anchor: String, in text: String) -> String? {
        guard let anchorRange = text.range(of: anchor),
              let openIndex = text[anchorRange.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = openIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { return String(text[openIndex...i]) }
            }
            i = text.index(after: i)
        }
        return nil
    }

    // 1. DECLARATION/USAGE PARITY, both directions. The declaration is the
    //    `SidebarRowFixture` enum; the usage is `sidebarDefectRows(for:)`'s
    //    switch. The switch is also compile-exhaustive in the app module — this
    //    gate is what makes the pairing visible to the fast layer-1 leg, and
    //    what catches a `default:` shortcut the compiler would happily accept.
    guard let enumBlock = braceBlock(startingAt: "enum SidebarRowFixture", in: region) else {
        expect(false, "SidebarDefectCorpus: the corpus region no longer declares enum SidebarRowFixture")
        return
    }
    let declared = Set(matches(#"case\s+([a-z][A-Za-z0-9_]*)"#, in: enumBlock))
    guard let switchBlock = braceBlock(startingAt: "switch fixture", in: region) else {
        expect(false, "SidebarDefectCorpus: sidebarDefectRows(for:) lost its switch over the declared fixtures")
        return
    }
    let arms = Set(matches(#"case\s+\.([A-Za-z0-9_]+)\s*:"#, in: switchBlock))
    expect(!switchBlock.contains("default:"),
           "SidebarDefectCorpus: the corpus switch must stay exhaustive — a default: arm lets a declared fixture render nothing")
    for name in declared.subtracting(arms).sorted() {
        expect(false, "SidebarDefectCorpus: declared fixture .\(name) has no corpus rows — a declared case nobody renders is dead vocabulary")
    }
    for name in arms.subtracting(declared).sorted() {
        expect(false, "SidebarDefectCorpus: corpus arm .\(name) is not a declared SidebarRowFixture case")
    }
    // Rows must only be built inside the declared arms: an AgentInboxRow
    // constructed elsewhere in the region is a fixture nobody declared.
    if let blockRange = region.range(of: switchBlock) {
        var outside = region
        outside.removeSubrange(blockRange)
        expect(!outside.contains("AgentInboxRow("),
               "SidebarDefectCorpus: an AgentInboxRow is constructed outside the fixture switch — every corpus row must trace to a declared case")
    } else {
        expect(false, "SidebarDefectCorpus: could not relocate the fixture switch inside the corpus region")
    }
    expect(region.contains("SidebarRowFixture.allCases.flatMap"),
           "SidebarDefectCorpus: sidebarDefectCorpus() must iterate SidebarRowFixture.allCases, so no declared case can be skipped")

    // 2. The packet's REQUIRED shapes, by name. Deleting or renaming one is
    //    red here even though parity above would still balance.
    let required: Set<String> = [
        "titleIsModelId", "nilRoleNilBranch", "elapsedThreeDigitHour",
        "unobservedNoSnapshot", "fanOutFortyChildren", "depthChainToCap",
        "projectNameWiderThanRow", "combiningMarksRTLName",
        "snoozedOnShelf", "settledSlimTail", "archivedCard",
    ]
    for name in required.subtracting(declared).sorted() {
        expect(false, "SidebarDefectCorpus: required defect shape .\(name) is no longer declared")
    }

    // 3. COVERAGE MATRIX, derived from the compiled vocabulary wherever the
    //    vocabulary is enumerable — a sixth InboxState lands and this gate
    //    demands its fixture with no edit here.
    for state in InboxState.allCases {
        expect(switchBlock.contains("state: .\(state.rawValue)"),
               "SidebarDefectCorpus: no fixture carries state: .\(state.rawValue) — every InboxState needs at least one corpus row")
    }
    for attention in InboxAttention.allCases {
        expect(switchBlock.contains("attention: .\(attention.rawValue)"),
               "SidebarDefectCorpus: no fixture carries attention: .\(attention.rawValue) — every InboxAttention needs at least one corpus row")
    }
    // InboxLifecycle carries associated values, so it cannot be CaseIterable;
    // the four spellings are pinned by hand and this comment is the reminder
    // that a fifth lifecycle case must be added here too.
    for lifecycle in ["lifecycle: .active", "lifecycle: .snoozed(until:", "lifecycle: .settled(at:", "lifecycle: .archived"] {
        expect(switchBlock.contains(lifecycle),
               "SidebarDefectCorpus: no fixture carries \(lifecycle) — every InboxLifecycle needs at least one corpus row")
    }
    for variant in RowVariant.allCases {
        expect(switchBlock.contains("variant: .\(variant.rawValue)"),
               "SidebarDefectCorpus: no fixture carries variant: .\(variant.rawValue) — both RowVariant values need a corpus row")
    }
    for depth in 0...AgentInboxRow.maxDepth {
        expect(switchBlock.contains("depth: \(depth),"),
               "SidebarDefectCorpus: no fixture is written at depth \(depth) — depths 0…\(AgentInboxRow.maxDepth) each need a corpus row (the sort confirms the hint from the parentId chain)")
    }

    // 4. Per-shape teeth, so a required case cannot be kept in name while its
    //    defect quietly leaves the row. Arm text is the stripped source between
    //    one `case .name:` and the next.
    var armText: [String: String] = [:]
    do {
        let pattern = #"case\s+\.([A-Za-z0-9_]+)\s*:"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            expect(false, "SidebarDefectCorpus: invalid arm pattern")
            return
        }
        let range = NSRange(switchBlock.startIndex..<switchBlock.endIndex, in: switchBlock)
        let found = regex.matches(in: switchBlock, range: range)
        for (index, match) in found.enumerated() {
            guard let nameRange = Range(match.range(at: 1), in: switchBlock),
                  let armStart = Range(match.range, in: switchBlock)?.upperBound else { continue }
            let armEnd = index + 1 < found.count
                ? (Range(found[index + 1].range, in: switchBlock)?.lowerBound ?? switchBlock.endIndex)
                : switchBlock.endIndex
            armText[String(switchBlock[nameRange])] = String(switchBlock[armStart..<armEnd])
        }
    }
    func arm(_ name: String) -> String { armText[name] ?? "" }
    func literal(_ argument: String, in text: String) -> String? {
        matches("\(argument): \"([^\"]*)\"", in: text).first
    }
    expect(arm("titleIsModelId").contains("title: \"openai-codex/gpt-5.6-sol\""),
           "SidebarDefectCorpus: titleIsModelId must use the fully qualified provider/model id as the row's NAME")
    for field in ["model: nil", "role: nil", "branch: nil"] {
        expect(arm("nilRoleNilBranch").contains(field),
               "SidebarDefectCorpus: nilRoleNilBranch lost \(field) — the dead-space shape needs both empty lines")
    }
    expect(arm("elapsedThreeDigitHour").contains("elapsed: sidebarThreeDigitHourElapsed"),
           "SidebarDefectCorpus: elapsedThreeDigitHour must set the named three-digit-hour constant directly on the fixture")
    if let seconds = matches(#"sidebarThreeDigitHourElapsed: TimeInterval = ([0-9_]+)"#, in: region).first,
       let value = Double(seconds.replacingOccurrences(of: "_", with: "")) {
        expect(value >= 100 * 3_600,
               "SidebarDefectCorpus: sidebarThreeDigitHourElapsed is \(Int(value))s, under the 100-hour floor a three-digit-hour fixture exists for")
    } else {
        expect(false, "SidebarDefectCorpus: sidebarThreeDigitHourElapsed lost its parseable declaration")
    }
    if let count = matches(#"sidebarFanOutChildCount = ([0-9_]+)"#, in: region).first {
        expect(count == "40",
               "SidebarDefectCorpus: sidebarFanOutChildCount is \(count), not the packet's forty")
    } else {
        expect(false, "SidebarDefectCorpus: sidebarFanOutChildCount lost its parseable declaration")
    }
    expect(arm("fanOutFortyChildren").contains("(1...sidebarFanOutChildCount)")
        && arm("fanOutFortyChildren").contains("parentId: parent.id"),
           "SidebarDefectCorpus: fanOutFortyChildren must build its forty rows under one parent from the named count")
    expect(arm("depthChainToCap").contains("parentId: root.id")
        && arm("depthChainToCap").contains("parentId: child.id"),
           "SidebarDefectCorpus: depthChainToCap lost its parent → child → grandchild chain")
    if let projectName = literal("projectName", in: arm("projectNameWiderThanRow")) {
        expect(projectName.count >= 40,
               "SidebarDefectCorpus: projectNameWiderThanRow's project is \(projectName.count) characters — too short to outrun a 220pt row")
    } else {
        expect(false, "SidebarDefectCorpus: projectNameWiderThanRow lost its project name literal")
    }
    if let title = literal("title", in: arm("combiningMarksRTLName")) {
        let scalars = title.unicodeScalars
        expect(scalars.contains { $0.properties.generalCategory == .nonspacingMark },
               "SidebarDefectCorpus: combiningMarksRTLName's title carries no combining mark")
        expect(scalars.contains { (0x0590...0x08FF).contains(Int($0.value)) || (0xFB1D...0xFEFF).contains(Int($0.value)) },
               "SidebarDefectCorpus: combiningMarksRTLName's title carries no right-to-left run")
    } else {
        expect(false, "SidebarDefectCorpus: combiningMarksRTLName lost its title literal")
    }
    expect(region.contains("static func sidebarUnobservedAgentIds"),
           "SidebarDefectCorpus: the unobserved-agent flag declaration is gone — P3.4 renders it, and losing it now orphans the fixture")

    // 5. WIRING: the probe must render THIS corpus. Rendering itself is gated
    //    value-level in the app (`--sidebar-ux-check` asserts cells == rows and
    //    every InboxState painted); this leg pins that the wiring cannot be
    //    quietly pointed back at the baseline fixtures.
    expect(probeSource.contains("LabFixtures.inboxDefectRows()"),
           "SidebarDefectCorpus: UIProbeGeometry no longer renders the defect corpus — every declared shape must reach a check leg")

    // 6. I5 HYGIENE over the RAW region — comments included, because a pasted
    //    transcript lands in comments as easily as in literals. Red on any
    //    real-session shape: home paths, key material, token shapes, secret
    //    runs, hostname shapes, or this machine's own user names.
    func hygieneViolations(in text: String) -> [String] {
        var violations: [String] = []
        for path in matches(#"(/(?:Users|home)/[A-Za-z0-9._-]+)"#, in: text) {
            violations.append("home-path shape '\(path)'")
        }
        if text.contains("~/") { violations.append("home-path shape '~/'") }
        for key in ["ssh-rsa", "ssh-ed25519", "ssh-dss", "ecdsa-sha2", "-----BEGIN", "PRIVATE KEY"] where text.contains(key) {
            violations.append("key-material shape '\(key)'")
        }
        for token in matches(#"(AKIA[0-9A-Z]{16})"#, in: text) {
            violations.append("AWS-key shape '\(token)'")
        }
        for token in matches(#"(ghp_[A-Za-z0-9]{30,}|xox[abprs]-[A-Za-z0-9-]+)"#, in: text) {
            violations.append("token shape '\(token)'")
        }
        for run in matches(#"([A-Za-z0-9+/=]{40,})"#, in: text) {
            violations.append("secret-looking run '\(run.prefix(20))…' (\(run.count) chars)")
        }
        for host in matches(#"\b([A-Za-z0-9][A-Za-z0-9-]*\.(?:local|lan|internal|corp|com|net|org|io|dev|ai))\b"#, in: text) {
            violations.append("hostname shape '\(host)'")
        }
        let userNames = [NSUserName(), FileManager.default.homeDirectoryForCurrentUser.lastPathComponent]
        for name in Set(userNames.map { $0.lowercased() }) where name.count >= 4 {
            if text.lowercased().contains(name) { violations.append("real user name '\(name)'") }
        }
        return violations
    }
    for violation in hygieneViolations(in: rawRegion) {
        expect(false, "SidebarDefectCorpus: I5 hygiene violation — \(violation) in the corpus region; fixtures are written, never captured")
    }

    print("SidebarDefectCorpus checks passed: \(declared.count) declared shapes ↔ \(arms.count) corpus arms in two-way parity with no default:, "
        + "coverage pinned for \(InboxState.allCases.count) states / \(InboxAttention.allCases.count) attention values / 4 lifecycles / \(RowVariant.allCases.count) variants / depths 0…\(AgentInboxRow.maxDepth), "
        + "forty-child fan-out and \(Int(100 * 3_600))s-floor elapsed parsed from source, bidi title carries combining marks and an RTL run, "
        + "probe wiring verified, and the I5 hygiene scan found nothing in the raw corpus region")
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


// MARK: - P0.5 — the sidebar's interaction fill ladder and the hairline width
//
// Ticket: docs/38-tickets/94-sidebar-native-ux/P0.5-row-token-vocabulary.md
//
// Lives in this main rather than in a new file because the packet's file
// fence names exactly three paths and a new file is not one of them.
//
// What this suite exists to catch, in the order the failures matter:
//
//  1. AN INVERTED LADDER — selection painted louder than hover. The
//     sidebar's locked decision is the opposite of the tile's: hover is
//     transient feedback, selection is a resting state. Gated BY MEASUREMENT
//     (contrast of each resolved fill against the resting panel, both
//     themes, strictly ordered), never by naming — so swapping two alphas
//     goes red even though every name still reads correctly.
//  2. AN IMPERCEPTIBLE STEP — an emphasis that collapses onto the panel.
//     Nonzero floors per role, plus ±0.01 provenance pins.
//  3. A FILL THAT ORPHANS ITS FOREGROUNDS — text, a status accent, or a
//     semantic line role that no longer clears its own floor on a fill.
//  4. THE TILE LADDER MOVING UNDER THIS PACKET — `rowSelected`/`rowHover`
//     are consumed live (ChoiceListView, ChoiceButton, ComposerTextView,
//     ApprovalRenderer); P0.5 is additive, so their values are pinned here
//     by hexKey.
//  5. THE HAIRLINE DRIFTING — `_DESIGN.md` caps any sidebar boundary at
//     0.5 pt and ticket 93 sweeps the whole app with this one token, so a
//     1.0 "just this once" is exactly the regression.
//
// NEGATIVE WITNESSES — each edit made against this final code, run, and
// observed red at exit 1. Quoted, not predicted:
//
//   (a) the alphas of `selected` and `hover` swapped in DesignTokens.swift
//       (0.07 ↔ 0.08 — the inverted pair, every name still "correct"):
//         FAIL: SidebarTokens: hover (1.15:1) must be a stronger step than
//         selected (1.17:1) against panel in light — hover is transient
//         feedback, selection is a resting state, and an inverted ladder
//         paints selection louder
//   (b) `LineWidth.hairline` 0.5 → 1.0 in Metrics.swift:
//         FAIL: LineWidth: the shared hairline must stay 0.5 pt, got 1.0 —
//         _DESIGN.md caps any sidebar boundary at 0.5 pt, and ticket 93
//         sweeps the whole app with this one token
func runSidebarSurfaceChecks() {
    func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

    // 0. Metric anchor, same as the tile suite: without it every ratio below
    //    could be meaningless and the suite would still print green.
    let anchor = WCAGContrast.ratio(ChipColor(r: 1, g: 1, b: 1), ChipColor(r: 0, g: 0, b: 0))
    expect(anchor >= 20.9 && anchor <= 21.1,
           "SidebarTokens: white/black must be ~21:1, got \(fmt(anchor)) — the ratio function is broken")

    // 1. Additive contract. P0.5 adds a NEW TYPE; the tile's pinned enum has
    //    its own count gate above, and the tile row values that live views
    //    consume (ChoiceListView/ChoiceButton/ComposerTextView/
    //    ApprovalRenderer) must not move under cover of this packet.
    expect(SidebarSurfaceRole.allCases.count == 4,
           "SidebarTokens: expected 4 sidebar roles, got \(SidebarSurfaceRole.allCases.count)")
    expect(AgentSurfaceRole.rowSelected.color.light.hexKey == "D8E4F6"
        && AgentSurfaceRole.rowSelected.color.dark.hexKey == "2B3547",
           "SidebarTokens: the tile's adopted rowSelected moved (\(AgentSurfaceRole.rowSelected.color.light.hexKey)/\(AgentSurfaceRole.rowSelected.color.dark.hexKey)) — P0.5 adds a sidebar ladder, it does not retune the tile's")
    expect(AgentSurfaceRole.rowHover.color.light.hexKey == "F2F4F7"
        && AgentSurfaceRole.rowHover.color.dark.hexKey == "1B2028",
           "SidebarTokens: the tile's adopted rowHover moved (\(AgentSurfaceRole.rowHover.color.light.hexKey)/\(AgentSurfaceRole.rowHover.color.dark.hexKey)) — P0.5 adds a sidebar ladder, it does not retune the tile's")

    // 2. Resting is the panel ITSELF — "at rest it is unfilled" as an
    //    identity the evaluator can measure, not a view-layer promise.
    expect(SidebarSurfaceRole.rowBase == .panel,
           "SidebarTokens: the sidebar rests on \(SidebarSurfaceRole.rowBase.rawValue), not panel — P1.3 names panel as the sidebar's surface")
    expect(SidebarSurfaceRole.resting.emphasisAlpha == 0,
           "SidebarTokens: resting must mix nothing over the panel, got alpha \(SidebarSurfaceRole.resting.emphasisAlpha)")
    for theme in TokenTheme.allCases {
        expect(SidebarSurfaceRole.resting.color.resolved(for: theme).hexKey
            == SurfaceToken.panel.color.resolved(for: theme).hexKey,
               "SidebarTokens: resting in \(theme.rawValue) is \(SidebarSurfaceRole.resting.color.resolved(for: theme).hexKey), not panel's \(SurfaceToken.panel.color.resolved(for: theme).hexKey) — a resting row paints NO fill")
        expect(SidebarTokens.rowEmphasisRatio(.resting, theme: theme) == 1.0,
               "SidebarTokens: resting must measure exactly 1.00:1 against panel in \(theme.rawValue), got \(fmt(SidebarTokens.rowEmphasisRatio(.resting, theme: theme)))")
    }
    expect(!SidebarSurfaceRole.rowEmphases.contains(.resting)
        && Set(SidebarSurfaceRole.rowEmphases + [.resting]) == Set(SidebarSurfaceRole.allCases)
        && SidebarSurfaceRole.rowEmphases.count == 3,
           "SidebarTokens: the emphases must be exactly the three fills — resting is not an emphasis, and no fill may be missing")

    // 3. No invented colours: every role is exactly `textPrimary` composited
    //    over `panel` at the role's own alpha, in both themes. If `color`
    //    ever decouples from its declared ingredients, this goes red.
    for role in SidebarSurfaceRole.allCases {
        for theme in TokenTheme.allCases {
            let derived = TextToken.textPrimary.color.resolved(for: theme)
                .composited(over: SurfaceToken.panel.color.resolved(for: theme), alpha: role.emphasisAlpha)
            expect(role.color.resolved(for: theme).hexKey == derived.hexKey,
                   "SidebarTokens: \(role.rawValue) in \(theme.rawValue) is \(role.color.resolved(for: theme).hexKey), not textPrimary over panel at \(role.emphasisAlpha) (\(derived.hexKey)) — a sidebar fill reuses existing tokens, it never invents a value")
        }
    }

    // 4. Every fill is themed, in range, and unambiguously light-under-Aqua
    //    / dark-under-dark — the same rule P1.3 and P0.3 apply.
    for role in SidebarSurfaceRole.rowEmphases {
        let token = role.color
        expect(token.light.hexKey != token.dark.hexKey,
               "SidebarTokens: \(role.rawValue) has the same value in both themes (\(token.light.hexKey)) — it is not themed")
        for theme in TokenTheme.allCases {
            let c = token.resolved(for: theme)
            expect(c.r >= 0 && c.r <= 1 && c.g >= 0 && c.g <= 1 && c.b >= 0 && c.b <= 1,
                   "SidebarTokens: \(role.rawValue).\(theme.rawValue) is out of the 0…1 sRGB range")
        }
        expect(WCAGContrast.relativeLuminance(token.light) > 0.5,
               "SidebarTokens: \(role.rawValue) light is not a light surface (luminance \(fmt(WCAGContrast.relativeLuminance(token.light))))")
        expect(WCAGContrast.relativeLuminance(token.dark) < 0.2,
               "SidebarTokens: \(role.rawValue) dark is not a dark surface (luminance \(fmt(WCAGContrast.relativeLuminance(token.dark))))")
    }

    // 5. Distinctness within the ladder, per theme: resting and the three
    //    fills are four different values, or the ladder lost a step.
    for theme in TokenTheme.allCases {
        var keys: [String: String] = [:]
        for role in SidebarSurfaceRole.allCases {
            let key = role.color.resolved(for: theme).hexKey
            expect(keys[key] == nil,
                   "SidebarTokens: \(role.rawValue) in \(theme.rawValue) is the same value as \(keys[key] ?? "?") (\(key)) — the ladder lost a step")
            keys[key] = role.rawValue
        }
    }

    // 6. THE ORDERING, by measurement — the packet's headline. Hover must be
    //    a strictly stronger step than selection, and route-active stronger
    //    than hover, in BOTH appearances; each step also clears a
    //    perceptibility floor so "quieter" can never decay into "absent".
    var emphasisSummary: [String] = []
    for theme in TokenTheme.allCases {
        let selected = SidebarTokens.rowEmphasisRatio(.selected, theme: theme)
        let hover = SidebarTokens.rowEmphasisRatio(.hover, theme: theme)
        let active = SidebarTokens.rowEmphasisRatio(.active, theme: theme)
        expect(selected >= 1.10,
               "SidebarTokens: selected is \(fmt(selected)):1 against panel in \(theme.rawValue), under its 1.10:1 perceptibility floor — a selection you cannot see")
        expect(hover >= 1.10,
               "SidebarTokens: hover is \(fmt(hover)):1 against panel in \(theme.rawValue), under its 1.10:1 perceptibility floor — a hover you cannot see")
        expect(active >= 1.20,
               "SidebarTokens: active is \(fmt(active)):1 against panel in \(theme.rawValue), under its 1.20:1 perceptibility floor — the open agent's row must answer \"where am I\"")
        expect(hover > selected,
               "SidebarTokens: hover (\(fmt(hover)):1) must be a stronger step than selected (\(fmt(selected)):1) against panel in \(theme.rawValue) — hover is transient feedback, selection is a resting state, and an inverted ladder paints selection louder")
        expect(active > hover,
               "SidebarTokens: active (\(fmt(active)):1) must be a stronger step than hover (\(fmt(hover)):1) against panel in \(theme.rawValue) — the route-active row is the ladder's loudest step")
        emphasisSummary.append("\(theme.rawValue) \(fmt(selected))/\(fmt(hover))/\(fmt(active))")
    }

    // 7. Provenance pins, ±0.01 — the measured table in DesignTokens.swift's
    //    P0.5 note cannot go stale while this stays green.
    let pinnedEmphasis: [(role: SidebarSurfaceRole, theme: TokenTheme, ratio: Double)] = [
        (.selected, .light, 1.15), (.selected, .dark, 1.18),
        (.hover, .light, 1.17), (.hover, .dark, 1.21),
        (.active, .light, 1.25), (.active, .dark, 1.32)
    ]
    expect(Set(pinnedEmphasis.map(\.role)) == Set(SidebarSurfaceRole.rowEmphases),
           "SidebarTokens: the emphasis provenance table must cover exactly the three fills")
    for pin in pinnedEmphasis {
        let ratio = SidebarTokens.rowEmphasisRatio(pin.role, theme: pin.theme)
        expect(abs(ratio - pin.ratio) <= 0.01,
               "SidebarTokens: \(pin.role.rawValue) in \(pin.theme.rawValue) is \(fmt(ratio)):1 against panel, but the documented provenance says \(fmt(pin.ratio)):1 — update the P0.5 table in DesignTokens.swift with the new measurement")
    }

    // 8. Pair identity, derived here independently of `documentedPairs`:
    //    3 fills x (2 text + 5 accents + controlBoundary + focusRing) = 27.
    //    Resting is deliberately absent — it IS panel, which P1.3 gates.
    let pairs = SidebarTokens.documentedPairs
    var expectedPairs: Set<String> = []
    for surface in SidebarSurfaceRole.rowEmphases {
        for text in SidebarTokens.surfaceTextTokens {
            expectedPairs.insert("\(text.rawValue)|\(surface.rawValue)|\(fmt(DesignTokens.textFloor))")
        }
        for accent in SidebarTokens.statusAccents {
            expectedPairs.insert("\(accent.rawValue)|\(surface.rawValue)|\(fmt(DesignTokens.textFloor))")
        }
        for role in SidebarTokens.gatedLineRoles {
            guard let floor = role.contrastFloor else { continue }
            expectedPairs.insert("\(role.rawValue)|\(surface.rawValue)|\(fmt(floor))")
        }
    }
    expect(pairs.count == 27, "SidebarTokens: expected 27 documented sidebar pairs, got \(pairs.count)")
    let actualKeys = pairs.map { "\($0.foreground)|\($0.background)|\(fmt($0.floor))" }
    expect(Set(actualKeys).count == actualKeys.count,
           "SidebarTokens: the sidebar pairs contain duplicates (\(actualKeys.count) pairs, \(Set(actualKeys).count) distinct) — a duplicated easy pair can hide a lost hard one")
    let missing = expectedPairs.subtracting(actualKeys).sorted()
    let extra = Set(actualKeys).subtracting(expectedPairs).sorted()
    expect(missing.isEmpty && extra.isEmpty,
           "SidebarTokens: the gated sidebar pairs do not match the declarations — missing \(missing), unexpected \(extra)")
    expect(!pairs.contains { $0.background == SidebarSurfaceRole.resting.rawValue },
           "SidebarTokens: resting must contribute no pair — it resolves to panel, and panel is P1.3's to gate")

    // 8b. Line-role hygiene: only semantic roles are gated on a fill, the
    //     decorative hairline is never one of them, and attention lines are
    //     covered BY VALUE because both attention accents are gated as
    //     status accents at the same 4.5 floor `attention` itself carries.
    expect(SidebarTokens.gatedLineRoles.allSatisfy(\.isSemantic),
           "SidebarTokens: every gated sidebar line role must be semantic")
    expect(!SidebarTokens.gatedLineRoles.contains(.decorativeHairline),
           "SidebarTokens: the decorative hairline is exempt and must never be gated as a sidebar line role — a state-bearing line may not resolve to it")
    for accent in AgentLineRole.attentionAccents {
        expect(SidebarTokens.statusAccents.contains(accent),
               "SidebarTokens: attention lines take \(accent.rawValue)'s hue, so the sidebar pair set must include it — an attention ring on a fill would otherwise be unmeasured")
    }
    expect(AgentLineRole.attention.contrastFloor == DesignTokens.textFloor,
           "SidebarTokens: attention's floor moved off the text floor — the by-value coverage above assumed 4.5, so re-derive the sidebar pair set")

    // 9. Every pair, both themes, against its own floor.
    var rows: [String] = []
    var failures: [String] = []
    for pair in pairs.sorted(by: { ($0.foreground, $0.background) < ($1.foreground, $1.background) }) {
        for theme in TokenTheme.allCases {
            let ratio = pair.ratio(for: theme)
            let ok = ratio >= pair.floor
            rows.append(String(
                format: "  %-16@ on %-16@ %-5@ %6@:1  floor %@:1  %@",
                pair.foreground as NSString, pair.background as NSString, theme.rawValue as NSString,
                fmt(ratio) as NSString, fmt(pair.floor) as NSString, (ok ? "ok" : "FAIL") as NSString))
            if !ok {
                failures.append("\(pair.foreground) on \(pair.background) in \(theme.rawValue) is \(fmt(ratio)):1, below its \(fmt(pair.floor)):1 floor")
            }
        }
    }
    print("SidebarTokens: \(pairs.count) sidebar pairs x \(TokenTheme.allCases.count) themes")
    for row in rows { print(row) }
    expect(failures.isEmpty,
           "SidebarTokens: \(failures.count) pair(s) below floor:\n  - " + failures.joined(separator: "\n  - "))

    // 10. Pin the MARGIN, not just the floor, and the worst background too:
    //     `sidebarActive` — the strongest mix, the end of the ladder — for
    //     every foreground in both themes, so the pins cannot silently start
    //     describing a different fill.
    let pinnedWorst: [(foreground: String, theme: TokenTheme, ratio: Double)] = [
        ("textPrimary", .light, 13.28), ("textPrimary", .dark, 12.77),
        ("textSecondary", .light, 5.28), ("textSecondary", .dark, 6.89),
        ("accentWorking", .light, 4.83), ("accentWorking", .dark, 5.71),
        ("accentApproval", .light, 4.96), ("accentApproval", .dark, 7.89),
        ("accentInput", .light, 5.58), ("accentInput", .dark, 5.65),
        ("accentFailed", .light, 4.65), ("accentFailed", .dark, 6.18),
        ("accentDone", .light, 5.21), ("accentDone", .dark, 7.12),
        ("controlBoundary", .light, 3.11), ("controlBoundary", .dark, 3.63),
        ("focusRing", .light, 6.10), ("focusRing", .dark, 6.43)
    ]
    expect(Set(pinnedWorst.map(\.foreground)) == Set(pairs.map(\.foreground)),
           "SidebarTokens: the pinned-margin table must cover exactly the gated foregrounds (table \(Set(pinnedWorst.map(\.foreground)).sorted()) vs gated \(Set(pairs.map(\.foreground)).sorted()))")
    for pin in pinnedWorst {
        let candidates = pairs.filter { $0.foreground == pin.foreground }
        guard let measured = candidates.min(by: { $0.ratio(for: pin.theme) < $1.ratio(for: pin.theme) }) else {
            expect(false, "SidebarTokens: \(pin.foreground) has no documented pair to measure a margin against")
            return
        }
        let ratio = measured.ratio(for: pin.theme)
        expect(abs(ratio - pin.ratio) <= 0.01,
               "SidebarTokens: \(pin.foreground) in \(pin.theme.rawValue) has worst ratio \(fmt(ratio)):1, but the documented provenance says \(fmt(pin.ratio)):1 — update the P0.5 table in DesignTokens.swift with the new measurement")
        expect(measured.background == SidebarSurfaceRole.active.rawValue,
               "SidebarTokens: \(pin.foreground)'s worst background in \(pin.theme.rawValue) is \(measured.background), not \(SidebarSurfaceRole.active.rawValue) — the sidebar ladder moved")
    }

    // 11. The hairline width token. One declaration, pinned: `_DESIGN.md`
    //     caps any sidebar boundary at 0.5 pt, and ticket 93's app-wide
    //     sweep consumes this same token, so a drift here drifts everywhere.
    expect(LineWidth.hairline > 0,
           "LineWidth: the hairline must be a positive width, got \(LineWidth.hairline)")
    expect(LineWidth.hairline == 0.5,
           "LineWidth: the shared hairline must stay 0.5 pt, got \(LineWidth.hairline) — _DESIGN.md caps any sidebar boundary at 0.5 pt, and ticket 93 sweeps the whole app with this one token")

    print("SidebarSurface checks passed: \(SidebarSurfaceRole.allCases.count) roles resolve from existing tokens (resting IS panel), "
        + "emphasis selected/hover/active measured " + emphasisSummary.joined(separator: ", ")
        + " with hover > selected and active > hover in both themes, "
        + "\(pairs.count * TokenTheme.allCases.count) measurements clear their floor (worst always on \(SidebarSurfaceRole.active.rawValue)), "
        + "tile rowSelected/rowHover values unmoved, hairline pinned at \(LineWidth.hairline) pt")
}
