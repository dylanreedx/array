# Status-derivation golden table — exhaustive signal-coverage check for I6

## What this delivers

After this ticket, Invariant I6 — "every `working`/`done`/`needsAttention` is backed by
fresh evidence; an input with no positive evidence must resolve to `idle` (or `stale` if
the engine has gone cold), never a fabricated richer status" — has a **table-driven,
exhaustive core check** that a future implementer or autonomous loop can run in under a
second and trust completely. Each row in the table is one named input signal-set, its
expected output status, and a brief rationale. The check exercises the pure
`deriveAgentStatus` function (shipped immediately before this ticket in the build order,
by the pure status-derivation-function ticket) against every semantically distinct input
combination and verifies, row by row, that the output matches expectation.

**A note on the six-case status enum, because it is the crux of this ticket.** The status
type is `AgentStatus` at `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85`,
and it is a **closed six-case enum: `configuring`, `working`, `idle`, `needsAttention`,
`done`, `stale`. There is no `.unknown` case and this ticket does not add one.** The
"unknown-agent" concept lives on the *input* side, as `AgentKind.unknown` — a tile whose
provider we cannot identify — not on the *output* side. When the derivation function has
no positive evidence for a richer status, it falls through to **`.idle`**. That `.idle`
fallback **is** the "never fabricate" guarantee: `.idle` is the honest floor, chosen
precisely because it claims nothing the evidence does not support. This ticket's Group A
therefore expects `.idle` (or `.stale`) for every no-evidence row — never a synthesized
`working`/`done`/`needsAttention`, and never a non-existent `.unknown`. This matches the
pure-derivation-function ticket's reference cascade exactly, whose final line
`return .idle` is annotated "the unknown never fabricates guarantee."

The two properties that matter most for system trustworthiness are explicitly gated here:

1. **Attention beats running.** A pending attention signal — whether from a managed
   agent's structured approval (`hasPendingApproval`), a managed user-input question
   (`hasPendingUserInput`), or an observed Claude shell tile's hook breadcrumb
   (`hookBreadcrumbPresent`) — must resolve to `needsAttention` even when a concurrent
   `isRunning` signal is also present. Blue must never hide orange.
2. **No fabrication.** An absent or unrecognized signal must not invent a positive status.
   The check has a dedicated row class for this: every zero- or noise-only input must
   produce `.idle` (or `.stale` when the engine reports cold evidence), never `.working`,
   `.done`, or `.needsAttention`.

This check is the machine-verifiable definition of "the status logic is correct" for this
entire program — it replaces faith with a numbered, named, exit-code-bearing contract.

## How it fits

The golden table builds directly on the pure `deriveAgentStatus` function introduced by
the **pure status-derivation-function ticket**, which separated status computation from
signal ingestion and made it a pure, time-free, side-effect-free function that takes a
typed signal set and returns an `AgentStatus`. That function — and its input struct
`StatusSignals` — is the only thing this check exercises; the whole point of keeping
derivation pure was to make this exact check easy to write.

**Two names, taken verbatim from the dependency, so nothing here diverges from what will
actually exist in the code:**

- The input struct is named **`StatusSignals`** (not `AgentSignalSet`). Every row literal
  in this ticket constructs a `StatusSignals`, and the function is
  `deriveAgentStatus(signals: StatusSignals) -> AgentStatus`.
- Both `StatusSignals` and `deriveAgentStatus` live in the **existing** file
  `Sources/ContinuumRevivedCore/AgentStatusEngine.swift`, appended below the existing
  `AgentStatusEngine` struct. **There is no new `AgentStatusDerivation.swift` file**; this
  ticket imports the derivation function through the existing `ContinuumRevivedCore` module
  boundary, the same way every other core check does.

The existing `AgentStatusEngine` (at
`Sources/ContinuumRevivedCore/AgentStatusEngine.swift:3`) is the current stateful
accumulator of raw tmux-layer signals; it already has partial coverage in
`ContinuumRevivedCoreChecks` (the `// MARK: - Agent status engine` block). This ticket
does not replace or alter those existing checks. It adds a **distinct block** that targets
the pure derivation function directly, with exhaustive table coverage, rather than the
stateful engine's hysteresis mechanics.

The **invariant-spine-harness ticket** stood up an I6 block in `main.swift` that asserts
basic non-fabrication and attention precedence against the *stateful engine*, writing a
manifest with `outcome: "pass"` and four measured signal combinations. This ticket adds a
**second, adjacent I6 block** for the *pure derivation function* — it does not delete or
overwrite the harness's engine-facing I6 block (that block tests a different code path and
stays). The two blocks share the invariant id family but are distinguishable by a `via`
measurement (see below), so the overnight loop can tell the engine leg from the
golden-table leg. This is the graduation the harness anticipated when it named the pure
derivation function as I6's companion.

Once this check is green and in the matrix, the reader work (the Pi/Claude/Codex readers
and the **reader-golden-fixtures ticket**) has a stable acceptance gate to point at: any
new signal path that feeds `deriveAgentStatus` must not break this table.

## The approach

The golden table lives as a sequence of named `struct`-literal rows, each carrying a
`signals` value (a `StatusSignals`, the input to `deriveAgentStatus`) and an `expected`
`AgentStatus`. The check iterates the table with `for row in goldenTable` and calls
`expect(result == row.expected, row.name)`. Every row has a human-readable name —
`shell_running_no_agent`, `attention_beats_running`, `no_signals_falls_to_idle`, and so on
— so any failure names itself precisely.

The derivation function is a strict priority ladder, restated here so every expected value
in the table is traceable to a rung (the ladder is owned by the pure-derivation-function
ticket; this is a faithful copy, not a redefinition):

1. `hasPendingApproval` → `.needsAttention`
2. `hasPendingUserInput` → `.needsAttention`
3. `hookBreadcrumbPresent` (with a fresh `hookBreadcrumbAge` under the 300 s stale
   threshold) → `.needsAttention`
4. `isError` → `.idle` (surface detail via `AgentDescriptor`; there is no `.failed` case)
5. `isStarting` → `.configuring`
6. `isRunning` → `.working`
7. `isCompleted` → `.done`
8. `engineStatus == .stale` → `.stale` (the only path to `.stale`; the pure function does
   no time arithmetic of its own — cold-evidence detection lives in the engine and arrives
   pre-computed on the `engineStatus` field)
9. fallback → `.idle` (the "never fabricate" floor)

The table is organized into four named groups, rendered with inline comments marking the
group boundary:

**Group A — honest floor / no fabrication.** Every input that lacks positive evidence
must yield `.idle` — or `.stale` when `engineStatus` is `.stale`. This includes: zero
signals; a process alive but `agentKind == .unknown` with no run-state flag set (a
detected-but-unidentified tile — `.idle`, never a guessed deep status); an `isError` input
(→ `.idle`, per rung 4, no fabricated `.failed`/`.done`); and a `engineStatus == .stale`
input with no positive flags (→ `.stale`). Note the honest-floor value is `.idle`, not a
non-existent `.unknown`.

**Group B — running, configuring, and idle.** Well-evidenced `isRunning` signals from each
of the four reader kinds (`shell`, `claude`, `codex`, `pi`) yield `.working`. An
`isStarting` signal yields `.configuring`. A signal-set with only the default
`engineStatus == .idle` and no positive flags yields `.idle` — the honest resting state.
An `AgentKind.unknown` tile with `isRunning = true` yields `.working` (a live process is
enough for working/idle; readers add depth but are not required for the basic states).

**Group C — attention precedence.** These are the rows that matter most to system
trustworthiness. Each row in this group has both a running signal and an attention signal
present simultaneously. Expected output is always `.needsAttention`, never `.working`. The
rows cover, one per attention rung plus the honest-negative:
- **Managed agent, pending approval:** `hasPendingApproval = true` alongside
  `isRunning = true` → `.needsAttention` wins, authoritative and unconditional (rung 1).
  This is the load-bearing managed row (see the stub note below for when the managed tier
  is not yet built).
- **Managed agent, pending user-input:** `hasPendingUserInput = true` alongside
  `isRunning = true` → `.needsAttention` (rung 2). Both `hasPendingApproval` and
  `hasPendingUserInput` are real, distinct fields on `StatusSignals` (per the
  pure-derivation-function ticket); this row exercises the second rung independently of
  the first.
- **Observed Claude shell tile, hook breadcrumb:** `hookBreadcrumbPresent = true` with a
  fresh `hookBreadcrumbAge` alongside `isRunning = true` → `.needsAttention` wins,
  best-effort (rung 3).
- **Observed Codex tile, honest negative:** Codex has no structured attention channel and
  no hook, so with `agentKind = .codex, isRunning = true` and every attention flag left
  `false`, the expected output is `.working`, **not** `.needsAttention` — this row
  confirms the *absence* of fabricated attention (the honest under-claim from the Codex
  same-cwd decision).

That is four Group C rows, and the table below contains exactly those four — no more.

**Group D — done and stale.** A cleanly completed turn (`isCompleted = true`, no attention
flags) yields `.done` (rung 7). A cold engine (`engineStatus == .stale`) yields `.stale`
even when a prior positive flag like `isCompleted` is *absent* — but note the ladder order:
because rungs 5–7 sit above the stale rung, a set with both `isRunning = true` **and**
`engineStatus == .stale` resolves to `.working` (the live signal wins over the engine's
cold read). The `.stale` row therefore sets `engineStatus == .stale` with **no** competing
positive flag, which is the only combination that actually reaches rung 8. This is a
deliberate, documented consequence of the ladder, and the row's rationale comment says so.

The check writes a `manifest.json` via `InvariantManifestWriter` (the type introduced by
the **invariant-spine-harness ticket**) with measured fields: `rows_checked` (an `Int`
matching the table length), a per-group count, `attention_beats_running_all_pass` (a
`Bool`), `fabrication_rows_all_pass` (a `Bool`), a `via: "pure_derivation_golden_table"`
tag that distinguishes this from the harness's engine-facing I6 manifest, and
`outcome: "pass"`. This manifest is machine-readable by the overnight loop and by any
downstream check that wants to assert "the pure-derivation leg of I6 is green."

## Where it lives

All new code lives in **one existing file** — no new files, no new build targets, no new
modules.

**Existing file: `Sources/ContinuumRevivedCoreChecks/main.swift`** — a new golden-table
check block is appended. Location: immediately after the existing
`// MARK: - Invariant I6: Status soundness` block that the invariant-spine-harness ticket
created (which tests the stateful engine). The new block is marked
`// MARK: - Invariant I6: Status soundness (pure derivation golden table)` so the two I6
legs are visually distinct and neither overwrites the other. Existing checks above and
below are untouched.

Key symbols the check consumes (all pre-existing by the time this ticket runs — this is
why it depends on the tickets named in "Depends on / unblocks"):

- `deriveAgentStatus(signals:)` — `Sources/ContinuumRevivedCore/AgentStatusEngine.swift`
  (from the pure status-derivation-function ticket; must be present for this to compile)
- `StatusSignals` — same file; the typed struct of all possible input signals, with a
  memberwise initializer whose boolean fields all default to `false` so
  `StatusSignals(agentKind: .shell)` is the "no positive evidence" case
- `AgentKind` — `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift` (from the
  closed-AgentKind-enum ticket; cases `shell | claude | codex | pi | managed | unknown`,
  defined immediately above `AgentStatus` in that file — **not** in any derivation file)
- `AgentStatus` — `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85` (the
  closed six-case enum; the return type)
- `InvariantManifest`, `InvariantManifestWriter`, `InvariantOutcome`, `JSONValue` —
  `Sources/ContinuumRevivedCore/InvariantManifest.swift` (from the
  invariant-spine-harness ticket)

**The managed tier's `AgentApprovalRequest` type is *not* consumed directly by this check.**
The Group C managed rows drive the derivation function through the `hasPendingApproval` /
`hasPendingUserInput` **booleans on `StatusSignals`**, which exist unconditionally (they
are part of the pure-derivation contract). Whether `AgentApprovalRequest` itself exists yet
is irrelevant to this check's ability to compile and run — see the stub note below for what
the managed rows assert before versus after the managed tier lands.

## Implementation breadcrumbs

```swift
// Sources/ContinuumRevivedCoreChecks/main.swift
// Appended AFTER the existing engine-facing I6 block from the invariant-spine-harness
// ticket. This is a SECOND I6 block, not a replacement.

// MARK: - Invariant I6: Status soundness (pure derivation golden table)

do {
    // The reference date is fixed — wall-clock Date() is banned in core checks.
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    // A golden row: one named scenario and its expected output.
    struct GoldenRow {
        let name: String
        let signals: StatusSignals      // the input type from the derivation ticket
        let expected: AgentStatus       // the closed six-case enum (no .unknown)
        let group: Character            // 'A', 'B', 'C', or 'D'
    }

    // A fresh hook age, comfortably under the 300 s stale threshold the derivation uses.
    let freshHookAge: TimeInterval = 5

    let goldenTable: [GoldenRow] = [

        // --- Group A: honest floor / no fabrication (expected .idle or .stale only) ---

        GoldenRow(name: "no_signals_falls_to_idle",
                  // Only the memberwise defaults: all flags false, engineStatus == .idle.
                  signals: StatusSignals(agentKind: .shell),
                  expected: .idle,                 // the "never fabricate" floor, NOT .unknown
                  group: "A"),

        GoldenRow(name: "unknown_kind_no_runstate_falls_to_idle",
                  // A detected-but-unidentified tile with no positive run-state signal.
                  signals: StatusSignals(agentKind: .unknown),
                  expected: .idle,                 // never a guessed deep status
                  group: "A"),

        GoldenRow(name: "error_maps_to_idle_not_fabricated_terminal",
                  // isError surfaces detail via AgentDescriptor; it must NOT fabricate
                  // .done or a .failed case (there is no .failed).
                  signals: StatusSignals(agentKind: .claude, isError: true),
                  expected: .idle,                 // rung 4
                  group: "A"),

        GoldenRow(name: "engine_stale_no_positive_signals_is_stale",
                  // The engine reported cold evidence; no positive flag competes for a
                  // higher rung, so the ladder reaches rung 8.
                  signals: StatusSignals(agentKind: .claude, engineStatus: .stale),
                  expected: .stale,
                  group: "A"),

        // --- Group B: running / configuring / idle ---

        GoldenRow(name: "shell_running_working",
                  signals: StatusSignals(agentKind: .shell, isRunning: true),
                  expected: .working,
                  group: "B"),

        GoldenRow(name: "claude_running_working",
                  signals: StatusSignals(agentKind: .claude, isRunning: true),
                  expected: .working,
                  group: "B"),

        GoldenRow(name: "codex_running_working",
                  signals: StatusSignals(agentKind: .codex, isRunning: true),
                  expected: .working,
                  group: "B"),

        GoldenRow(name: "pi_running_working",
                  signals: StatusSignals(agentKind: .pi, isRunning: true),
                  expected: .working,
                  group: "B"),

        GoldenRow(name: "unknown_kind_running_working",
                  // A live process alone is enough for .working even without a reader.
                  signals: StatusSignals(agentKind: .unknown, isRunning: true),
                  expected: .working,
                  group: "B"),

        GoldenRow(name: "starting_is_configuring",
                  signals: StatusSignals(agentKind: .claude, isStarting: true),
                  expected: .configuring,          // rung 5
                  group: "B"),

        GoldenRow(name: "engine_idle_no_signals_is_idle",
                  signals: StatusSignals(agentKind: .shell, engineStatus: .idle),
                  expected: .idle,
                  group: "B"),

        // --- Group C: attention beats running (the load-bearing rows) ---

        // Managed agent: a pending approval is authoritative above everything else.
        // Driven through the hasPendingApproval BOOLEAN on StatusSignals — this compiles
        // and runs whether or not the managed-tier AgentApprovalRequest type exists yet.
        // See the stub note below for what this row means before the managed tier lands.
        GoldenRow(name: "managed_pending_approval_beats_running",
                  signals: StatusSignals(agentKind: .managed,
                                         hasPendingApproval: true,
                                         isRunning: true),
                  expected: .needsAttention,       // rung 1 wins over rung 6
                  group: "C"),

        // Managed agent: a pending user-input question is a distinct rung, same outcome.
        GoldenRow(name: "managed_pending_user_input_beats_running",
                  signals: StatusSignals(agentKind: .managed,
                                         hasPendingUserInput: true,
                                         isRunning: true),
                  expected: .needsAttention,       // rung 2 wins over rung 6
                  group: "C"),

        // Observed Claude shell tile: a fresh hook breadcrumb beats a running signal.
        GoldenRow(name: "claude_hook_breadcrumb_beats_running",
                  signals: StatusSignals(agentKind: .claude,
                                         hookBreadcrumbPresent: true,
                                         hookBreadcrumbAge: freshHookAge,
                                         isRunning: true),
                  expected: .needsAttention,       // rung 3 wins over rung 6
                  group: "C"),

        // Codex: no structured attention channel and no hook — confirm no fabrication.
        GoldenRow(name: "codex_no_fabricated_attention",
                  signals: StatusSignals(agentKind: .codex, isRunning: true),
                  expected: .working,              // .working, NOT .needsAttention
                  group: "C"),

        // --- Group D: done and stale ---

        GoldenRow(name: "completed_turn_is_done",
                  signals: StatusSignals(agentKind: .claude, isCompleted: true),
                  expected: .done,                 // rung 7
                  group: "D"),

        GoldenRow(name: "pi_completed_turn_is_done",
                  signals: StatusSignals(agentKind: .pi, isCompleted: true),
                  expected: .done,
                  group: "D"),

        // Ladder-order proof: a live signal beats the engine's cold read. This row has
        // BOTH isRunning and engineStatus == .stale; rung 6 sits above rung 8, so the
        // honest answer is .working, not .stale.
        GoldenRow(name: "running_beats_engine_stale",
                  signals: StatusSignals(agentKind: .claude,
                                         isRunning: true,
                                         engineStatus: .stale),
                  expected: .working,
                  group: "D"),

        // The only combination that actually reaches the .stale rung: engine cold AND no
        // competing positive flag.
        GoldenRow(name: "engine_stale_wins_when_no_live_signal",
                  signals: StatusSignals(agentKind: .claude, engineStatus: .stale),
                  expected: .stale,
                  group: "D"),
    ]

    // Run the table.
    var groupCounts: [Character: Int] = ["A": 0, "B": 0, "C": 0, "D": 0]
    var attentionAllPass = true
    var fabricationAllPass = true

    for row in goldenTable {
        let result = deriveAgentStatus(signals: row.signals)
        let pass = result == row.expected
        expect(pass, "I6 golden[\(row.name)]: expected \(row.expected), got \(result)")
        groupCounts[row.group, default: 0] += 1
        if row.group == "C" && !pass { attentionAllPass = false }
        if row.group == "A" && !pass { fabricationAllPass = false }
    }

    // Write the manifest — measured fields, not {passed: true}. The `via` tag is what
    // distinguishes this from the engine-facing I6 manifest in the artifact directory.
    let manifest = InvariantManifest(
        invariantId: "I6-status-soundness",
        runId: UUID().uuidString,
        measuredAt: ISO8601DateFormatter().string(from: epoch),
        measurements: [
            "via": .string("pure_derivation_golden_table"),
            "rows_checked": .int(goldenTable.count),
            "group_A_no_fabrication": .int(groupCounts["A"] ?? 0),
            "group_B_running_idle": .int(groupCounts["B"] ?? 0),
            "group_C_attention_precedence": .int(groupCounts["C"] ?? 0),
            "group_D_done_stale": .int(groupCounts["D"] ?? 0),
            "attention_beats_running_all_pass": .bool(attentionAllPass),
            "fabrication_rows_all_pass": .bool(fabricationAllPass),
        ],
        outcome: InvariantOutcome.pass.rawValue,
        failureReason: nil
    )
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-i6-golden-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    try InvariantManifestWriter.write(manifest, to: tmpDir)

    // Self-check: read the manifest back and assert round-trip equality.
    let writtenURL = tmpDir.appendingPathComponent(
        "invariant-\(manifest.invariantId)-\(manifest.runId).json")
    let readBack = try JSONDecoder().decode(
        InvariantManifest.self, from: Data(contentsOf: writtenURL))
    expect(readBack.invariantId == manifest.invariantId, "I6 golden manifest round-trips invariantId")
    expect(readBack.outcome == "pass", "I6 golden manifest round-trips outcome")
}
```

`StatusSignals` is the pure input type defined in `AgentStatusEngine.swift` by the
pure-derivation-function ticket. It carries: `agentKind: AgentKind`; the three attention
booleans `hasPendingApproval` / `hasPendingUserInput` / `hookBreadcrumbPresent` plus
`hookBreadcrumbAge: TimeInterval?`; the run-state booleans `isError` / `isStarting` /
`isRunning` / `isCompleted`; and `engineStatus: AgentStatus` (the stateful engine's
pre-computed output, which is the *only* source of a `.stale` verdict — the pure function
never touches a clock). The memberwise initializer defaults every boolean to `false` and
`engineStatus` to `.idle`, so `StatusSignals(agentKind:)` is the canonical "no positive
evidence" input.

### The managed-row stub path (stated precisely, no open choice left)

The managed tier — and the `AgentApprovalRequest` type behind it — is gated behind the
DRIVE fork (decision D1). This ticket does **not** wait for it, because the Group C managed
rows drive the derivation function through the `hasPendingApproval` / `hasPendingUserInput`
**booleans**, which are part of the pure-derivation contract and exist the moment that
ticket lands. There are therefore two states, and both are fully specified:

- **Managed tier not yet built (the expected state when this ticket first lands).** The two
  managed Group C rows stay **exactly as written above** —
  `hasPendingApproval: true, isRunning: true` → `.needsAttention`, and
  `hasPendingUserInput: true, isRunning: true` → `.needsAttention`. These are **not
  vacuous stubs**: they exercise the real rung-1 and rung-2 logic on a real input and
  assert the real, load-bearing precedence (attention beats running). Nothing about them is
  fake-green — the derivation function genuinely produces `.needsAttention` for these
  inputs today, because the booleans and the ladder both already exist. No `// STUB` marker
  is needed and none should be added; there is no deferred assertion here.
- **What the managed tier adds later.** When the managed-approval path
  (approvals → needsAttention) lands, it introduces the `AgentApprovalRequest` type and the
  pending-approvals store, and the `SessionObserver` becomes the thing that *sets*
  `hasPendingApproval = true` from a real pending row. That is a change to the *producer* of
  the boolean, not to this table. This table's managed rows do not change; the
  reader-golden-fixtures / observer real-path legs are where a real `AgentApprovalRequest`
  flows end-to-end. This table remains the pure-logic gate that both legs point at.

Because the managed rows are non-vacuous from day one, the
`attention_beats_running_all_pass` manifest field is **`true` and load-bearing
immediately** — it is not gated on the managed tier, and it must never be reported `true`
while any Group C row is silently skipped. Every Group C row runs, every cycle; there is no
"stubbed row that still counts toward the gate" ambiguity, because no Group C row is
stubbed.

## How we test it

### Logic (pure Core checks)

Running `swift build` and then `.build/debug/ContinuumRevivedCoreChecks` is the complete
test. Every row in the golden table becomes one `expect(...)` call. A failure names the
row precisely (e.g., `"I6 golden[managed_pending_approval_beats_running]: expected
needsAttention, got working"`), so there is no ambiguity about which case regressed. The
run exits nonzero on the first failing `expect`, so CI catches it.

The manifest self-check (read-back after write) is an additional logic assertion that
validates `InvariantManifestWriter` against the real filesystem without mocks.

Key assertions that must be green for the ticket to be done:

- Every Group A row produces `.idle` or `.stale` — never `.working`, `.done`, or
  `.needsAttention` without evidence, and never a (non-existent) `.unknown`.
- Every Group C row with a concurrent `isRunning` signal produces `.needsAttention` — the
  `attention_beats_running_all_pass` manifest field is `true`.
- The `rows_checked` manifest field matches the literal length of `goldenTable` at compile
  time (a reviewer can count the rows in the table and compare).
- `fabrication_rows_all_pass` is `true` in the written manifest.

### Backend (real-path / integration)

This ticket is a pure core check with no daemon, no filesystem agent stores, and no real
tmux process — the derivation function is fully in-process and deterministic. The
real-path leg of I6 is owned by the **reader-golden-fixtures ticket**, which replays
recorded on-disk agent stores through the real reader stack and asserts the resulting
`AgentStatus` values. That ticket depends on this one, and it writes its own manifest with
`via: "reader_golden_fixtures"` so the three legs of I6 (engine, pure derivation, readers)
are all distinguishable in the overnight artifact directory.

There is no real-path check in this ticket because there is nothing real to path through:
the pure derivation function has no external dependencies by design.

### UX (visual gate + dogfood snippet)

The golden table check has no AppKit surface, so there is no visual gate in this ticket.
The concrete dogfood verification is:

Open Terminal at the project root and run:

```
swift build 2>&1 | tail -3
.build/debug/ContinuumRevivedCoreChecks 2>&1
echo "Exit: $?"
```

A passing run exits with code 0 and produces no `FAIL:` lines. The block prints
`// MARK: - Invariant I6: Status soundness (pure derivation golden table)` at the top of
its output section (matching the existing MARK convention) and, on success, prints the
temp-dir path where the manifest was written. Opening that JSON file in any text editor
shows:

```json
{
  "invariantId": "I6-status-soundness",
  "measurements": {
    "attention_beats_running_all_pass": true,
    "fabrication_rows_all_pass": true,
    "group_A_no_fabrication": 4,
    "group_B_running_idle": 7,
    "group_C_attention_precedence": 4,
    "group_D_done_stale": 4,
    "rows_checked": 19,
    "via": "pure_derivation_golden_table"
  },
  "outcome": "pass"
}
```

The `rows_checked` count is the literal row count in the table — if it reads 15 instead of
19, a row was accidentally dropped. The `attention_beats_running_all_pass: true` field is
the machine assertion of the single most important property in this program's status model.
The `via` tag is how a reader tells this manifest apart from the engine-facing I6 manifest
that the invariant-spine-harness ticket writes.

## Execution mode

**Autonomous.** The entire check is a pure in-process computation over a deterministic
function with a fixed-epoch timestamp and a temp directory. There is no tmux daemon, no
real agent store, no clock dependency, no UI, and no network. The matrix runs the
executable, checks the exit code, and reads the manifest — no human eyes are needed and
there is nothing to observe visually. This ticket satisfies the autonomous execution
criteria exactly.

## Done when

- [ ] `deriveAgentStatus(signals:)` and `StatusSignals` are present in
  `Sources/ContinuumRevivedCore/AgentStatusEngine.swift` (the pure status-derivation
  function has landed) — this ticket imports them from the `ContinuumRevivedCore` module.
  No new `AgentStatusDerivation.swift` file is created by this ticket.
- [ ] A new `// MARK: - Invariant I6: Status soundness (pure derivation golden table)`
  block exists in `Sources/ContinuumRevivedCoreChecks/main.swift`, **appended after** the
  existing engine-facing I6 block from the invariant-spine-harness ticket (which is not
  deleted or overwritten). There are two I6 blocks; each writes a manifest with a distinct
  `via` measurement.
- [ ] The block contains a `goldenTable` array of at least 19 named `GoldenRow` values
  covering all four groups (A through D).
- [ ] Every expected value in the table is one of the six real `AgentStatus` cases
  (`configuring`, `working`, `idle`, `needsAttention`, `done`, `stale`). No row expects a
  `.unknown` value, and no `.unknown` case is added to `AgentStatus`.
- [ ] Every row has at least one `expect(...)` call whose message includes the row's `name`
  string.
- [ ] Group C contains at least two rows with both a running signal and an attention signal
  simultaneously present (one via `hasPendingApproval`, one via `hasPendingUserInput` or
  `hookBreadcrumbPresent`), and each such row's expected value is `.needsAttention`.
- [ ] The Group A no-fabrication rows expect only `.idle` or `.stale` — never `.working`,
  `.done`, or `.needsAttention`.
- [ ] The manifest is written and read back, and the self-check `expect` on the read-back
  `outcome` field passes.
- [ ] The written manifest contains `"attention_beats_running_all_pass": true` and
  `"fabrication_rows_all_pass": true` (measured in the manifest the overnight loop reads,
  not merely computed in-process) and a `"via": "pure_derivation_golden_table"` tag.
- [ ] `swift build` completes with zero warnings in `ContinuumRevivedCore` and
  `ContinuumRevivedCoreChecks`.
- [ ] `.build/debug/ContinuumRevivedCoreChecks` exits with code 0.

## Depends on / unblocks

This ticket depends on three earlier tickets, named by their deliverable so no ticket code
has to be decoded:

- The **closed-AgentKind-enum ticket** — provides `AgentKind`
  (`shell | claude | codex | pi | managed | unknown`) in
  `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`. Every row's `agentKind`
  field needs it.
- The **pure status-derivation-function ticket** — provides `deriveAgentStatus(signals:)`
  and the `StatusSignals` input struct in
  `Sources/ContinuumRevivedCore/AgentStatusEngine.swift`. This is the function under test;
  the table cannot compile without it, and its field names are the authoritative contract
  this table is written against.
- The **invariant-spine-harness ticket** — provides `InvariantManifest`,
  `InvariantManifestWriter`, `InvariantOutcome`, and `JSONValue` in
  `Sources/ContinuumRevivedCore/InvariantManifest.swift`, and the existing engine-facing
  I6 block this ticket sits beside.

All three are earlier in the build order and must be green before this one starts.

What this ticket unblocks:

- The **reader-golden-fixtures ticket** can reference this golden table as its upstream
  gate — "the pure derivation is verified correct; now verify the readers feed it
  correctly." It adds the real-path leg of I6 with its own `via: "reader_golden_fixtures"`
  manifest.
- The **SessionObserver ticket** inherits this table as the acceptance criterion for its
  status output: whatever `StatusSignals` the observer assembles, the derived status must
  match this table.
- The **managed-approval-path ticket** (approvals → needsAttention), when it lands, does
  **not** change this table — it changes the *producer* of `hasPendingApproval`. Its
  end-to-end assertion (a real `AgentApprovalRequest` flowing to `.needsAttention`) is a
  real-path leg that points at this pure-logic gate.
- Any UX ticket that renders `AgentStatus` has a clean, numbered statement of what
  "correct" means to point at.

## Watch out for

**The output enum has six cases and none of them is `.unknown`.** The single most common
way to get this ticket wrong is to reach for a `.unknown` output value (or to try to add
one to `AgentStatus`). The honest floor for a no-evidence input is `.idle`, chosen by the
derivation function's fallback rung. The "unknown" concept lives only on the input side as
`AgentKind.unknown`. Do not add a case to `AgentStatus`; do not expect `.unknown` in any
row — the code will not compile and the dependency will never produce it.

**Use the dependency's names verbatim: `StatusSignals`, not `AgentSignalSet`.** The input
type is `StatusSignals`, defined in `AgentStatusEngine.swift`. Every field name in a row
literal must match the pure-derivation-function ticket exactly: `hasPendingApproval`,
`hasPendingUserInput`, `hookBreadcrumbPresent`, `hookBreadcrumbAge`, `isError`,
`isStarting`, `isRunning`, `isCompleted`, `engineStatus`, `agentKind`. There is no
`pendingApprovalCount`, no `piAttentionReason`, no `claudeHookAttentionBreadcrumb`, no
`lastEvidenceAge`, no `staleThreshold`, no `outputActivity`, and no `pendingUserInputCount`
field — if you find yourself typing one of those, you are inventing a struct shape the
derivation function does not have, and the row will not compile.

**`.stale` has exactly one source: `engineStatus == .stale`.** The pure derivation function
does no time arithmetic — there is no `lastEvidenceAge`/`staleThreshold` on `StatusSignals`.
A row that wants `.stale` sets `engineStatus: .stale` and leaves every positive flag false
(because rungs 5–7 outrank the stale rung, a live signal will beat the cold read — that is
the `running_beats_engine_stale` row's whole point). Do not try to fabricate staleness from
an age field that does not exist.

**Do not create `AgentStatusDerivation.swift`.** The derivation function and its input
struct live in the existing `AgentStatusEngine.swift`. This ticket adds no new files at all;
it appends one `do` block to `main.swift`.

**Do not delete or overwrite the engine-facing I6 block.** The invariant-spine-harness
ticket's I6 block tests the stateful `AgentStatusEngine`'s hysteresis and stale mechanics
and writes a manifest without the `via: "pure_derivation_golden_table"` tag. This ticket's
block tests the *pure derivation function*. They are different code paths and both stay.
The `via` measurement is what keeps their two manifests distinguishable in the overnight
artifact directory.

**Wall-clock `Date()` is banned.** The `measuredAt` field uses
`Date(timeIntervalSince1970: 1_800_000_000)`. The `hookBreadcrumbAge` in the Group C hook
row is a plain `TimeInterval` literal (e.g. `5`), not a computed age from `Date()`. A flake
caused by a slow CI runner is indistinguishable from a real regression in a fast-moving
autonomous build sequence; fixed values eliminate the entire class.
