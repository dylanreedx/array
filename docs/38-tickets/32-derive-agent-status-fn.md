# Pure status-derivation function for the agent fleet

## What this delivers

A single, pure Swift function — `deriveAgentStatus(signals:)` — that maps a structured
set of evidence signals into one of the six `AgentStatus` values (`configuring`,
`working`, `idle`, `needsAttention`, `done`, `stale`). The function is the definitive
arbiter of what a tile's status is at any moment. It is the one code path feeding both the
fleet sidebar tree and, later, the push service. There is no per-tier branch: reader
evidence and managed-adapter evidence both arrive as the same `StatusSignals` struct, and
the function derives the same enum from them.

From the user's point of view, every tile in the canvas, zone rollup, and sidebar is
showing a status the system actually *proved*, not guessed. The priority ordering is
guaranteed by construction: an attention signal always wins over a working signal. Orange
is never hiding behind blue.

From the system's point of view, invariant I6 ("status soundness: every `working`/`done`/
`needsAttention` is backed by fresh evidence; unknown ⇒ `unknown`, never a fabricated
status") becomes a theorem proven by a golden table driven in the core check suite, not
an editorial promise in a comment.

## How it fits

This function keys off a closed `AgentKind` enum so it can understand which evidence
fields are meaningful for a given tile. Without a closed set of kinds, readers and the UI
can silently disagree on what "claude" means; with it, every case is exhaustively handled.
That enum is a locked decision (`docs/38-locked-decisions.md`, D14: `shell | claude |
codex | pi | managed | unknown`).

**This ticket does not depend on any other ticket having landed first.** The closed-enum
migration of `AgentDescriptor.agentKind` (currently `String`) is a *separate* piece of
work owned by the agent-kind-enum ticket, and it is deliberately kept out of this ticket's
scope. To stay self-contained and unblocked, this ticket introduces the `AgentKind` enum
itself *if it does not already exist* (a small additive type — see "Where it lives"), and
`StatusSignals` carries its own `AgentKind` field independent of `AgentDescriptor`. Nothing
here reads or writes `AgentDescriptor.agentKind`, so the two efforts can land in either
order. If the agent-kind-enum ticket has already introduced `AgentKind`, this ticket reuses
that exact type and adds no duplicate.

This function is itself the prerequisite for several downstream pieces. The observer that
watches sessions, the concrete Claude/Pi/Codex file readers, and the managed-approval path
all write into `StatusSignals` and read back the derived `AgentStatus`; they cannot be
verified without a proven derivation function under them. The status-derivation golden
table (the companion I6 harness ticket) is the check that immediately follows and pins
every row of the priority ladder in CI, importing this same `StatusSignals` type.

The existing `AgentStatusEngine` in
`Sources/ContinuumRevivedCore/AgentStatusEngine.swift` is a stateful struct that ingests
tmux-layer signals (title strings, output activity, prompt observations) and applies
hysteresis and timeouts. That engine is *not* replaced here — it handles the raw
signal-level smoothing for terminal tiles. What this ticket adds is a **pure, stateless
outer derivation layer** that sits above the engine, takes its output (plus the
reader/adapter evidence), and enforces the priority ladder with no mutable state of its
own.

## The approach

The function takes a `StatusSignals` value type — a plain struct that carries all
evidence a caller has assembled — and returns an `AgentStatus`. It is a pure function:
same inputs, same output, always. No Date(), no file I/O, no tmux, no dispatch queue.

The priority ladder is encoded directly in the function body as a strict cascade of
guards, matching the order established by the architecture doc (section C) and confirmed
by the t3code `resolveThreadAwarenessPhase` pattern
(`docs/2026-06-30-t3code-steal/06-agent-ux-approvals-mobile-push.md`, verified at
`t3:packages/shared/src/agentAwareness.ts:85–106`):

1. `hasPendingApproval` → `.needsAttention` (managed agents; authoritative, no file scan)
2. `hasPendingUserInput` → `.needsAttention` (distinct signal, same outcome; collapses per D24)
3. `hookBreadcrumbPresent` → `.needsAttention` (observed Claude shell tiles; best-effort,
   consent-gated hook per D11)
4. `isError` → `.idle` (surface the detail via `AgentDescriptor`; no separate `.failed`
   case in the current `AgentStatus` enum)
5. `isStarting` → `.configuring`
6. `isRunning` → `.working`
7. `isCompleted` → `.done`
8. `isStale` (evidence is too old — the engine already flagged `.stale` via its
   `staleTimeout`) → `.stale`
9. fallback → `.idle` (never fabricate a richer status)

The function does **not** synthesize attention from output-activity heuristics or title
scraping for observed agents without the hook (per D11). When the hook breadcrumb is
absent for an observed Claude tile, steps 1–3 all miss and the cascade continues to
working/idle/stale as appropriate. Unknown-kind tiles (`AgentKind.unknown`) have no reader
evidence to supply beyond the tmux-layer signals, so they can only reach `.idle`,
`.working`, or `.stale` — they never reach `.needsAttention` or `.done`, by the cascade's
structure.

The `StatusSignals` struct carries fields for both the reader/observer tier and the managed
adapter tier. Fields that are irrelevant for a given tile kind are simply nil or false;
the cascade ignores them naturally. This is the "one code path" the architecture mandates.

## Where it lives

**Primary file:** `Sources/ContinuumRevivedCore/AgentStatusEngine.swift`

The new pure function and the `StatusSignals` type are added to this file alongside the
existing `AgentStatusEngine` struct. The existing struct (lines 3–112) is unchanged. New
additions start below the closing brace of `AgentStatusEngine`.

**The `AgentKind` enum.** This ticket needs the closed enum from D14. Two cases:

- If `AgentKind` does **not** yet exist in the codebase (grep confirms it does not today),
  introduce it in this ticket as a small additive type in `AgentStatusEngine.swift` (or a
  new `AgentKind.swift` in the same target):
  ```swift
  public enum AgentKind: String, Codable, Equatable, Sendable {
      case shell, claude, codex, pi, managed, unknown
  }
  ```
  This is additive and does not touch `AgentDescriptor.agentKind` (which stays `String`
  until the agent-kind-enum ticket migrates it — explicitly not this ticket's job).
- If the agent-kind-enum ticket has already introduced `AgentKind`, reuse that exact type;
  do not define a second copy.

**Touched type in the same file:**
- `AgentStatus` at `TerminalSessionDescriptor.swift:85` — the six-case enum that is the
  return type. No changes needed; confirm it matches all cases the derivation function
  can return (it does: `configuring`, `working`, `idle`, `needsAttention`, `done`, `stale`
  are all present at lines 85–92).

**Explicitly NOT touched:**
- `AgentDescriptor.agentKind` at `TerminalSessionDescriptor.swift:95` — stays
  `public var agentKind: String`. This ticket neither reads nor writes it. Migrating it to
  the closed enum is the agent-kind-enum ticket's work and is out of scope here. This is
  what keeps this ticket unblocked and independently completable.

**New symbols to create:**

`StatusSignals` — a `struct`, `Equatable`, `Sendable`, defined in `AgentStatusEngine.swift`
immediately below the existing `AgentStatusEngine` closing brace. Fields:

```
agentKind: AgentKind                  // from D14's closed enum (introduced here if absent)
hasPendingApproval: Bool              // managed agents: approval.requested without a resolve
hasPendingUserInput: Bool             // managed agents: user-input.requested without a resolve
hookBreadcrumbPresent: Bool           // observed Claude shell: hook wrote a breadcrumb
hookBreadcrumbAge: TimeInterval?      // if present, seconds since last breadcrumb write
isError: Bool                         // session or turn in error state
isStarting: Bool                      // session state == starting
isRunning: Bool                       // session or turn in running state
isCompleted: Bool                     // latest turn state == completed
engineStatus: AgentStatus             // the output of AgentStatusEngine.tick() / ingest()
                                      // (carries stale detection + hysteresis from the existing engine)
```

`deriveAgentStatus(signals: StatusSignals) -> AgentStatus` — a free function (not a
method) in `AgentStatusEngine.swift`. Public, pure, no side effects.

No existing symbols are removed or renamed.

## Implementation breadcrumbs

```swift
// StatusSignals — plain value, all evidence assembled by the caller
public struct StatusSignals: Equatable, Sendable {
    public var agentKind: AgentKind          // D14 closed enum
    public var hasPendingApproval: Bool      // managed adapter: pending approval row exists
    public var hasPendingUserInput: Bool     // managed adapter: user-input question outstanding
    public var hookBreadcrumbPresent: Bool   // observed Claude: hook wrote breadcrumb
    public var hookBreadcrumbAge: TimeInterval?  // seconds since breadcrumb mtime; nil if absent
    public var isError: Bool
    public var isStarting: Bool
    public var isRunning: Bool
    public var isCompleted: Bool
    public var engineStatus: AgentStatus     // AgentStatusEngine's current output (stale + hysteresis)

    public init(
        agentKind: AgentKind,
        hasPendingApproval: Bool = false,
        hasPendingUserInput: Bool = false,
        hookBreadcrumbPresent: Bool = false,
        hookBreadcrumbAge: TimeInterval? = nil,
        isError: Bool = false,
        isStarting: Bool = false,
        isRunning: Bool = false,
        isCompleted: Bool = false,
        engineStatus: AgentStatus = .idle
    ) { /* assign */ }
}

// The derivation function — strict priority ladder, no mutable state
public func deriveAgentStatus(signals: StatusSignals) -> AgentStatus {
    // Attention wins over everything — checked first, unconditionally
    if signals.hasPendingApproval || signals.hasPendingUserInput {
        return .needsAttention
    }

    // Hook breadcrumb: best-effort attention for observed Claude shell tiles.
    // Only fire if the breadcrumb is fresh (within the engine's staleTimeout).
    // For all other agentKinds this field is false by construction; no branch needed.
    if signals.hookBreadcrumbPresent,
       let age = signals.hookBreadcrumbAge,
       age < StatusSignals.hookFreshnessWindow {   // == AgentStatusEngine.Configuration().staleTimeout (300 s)
        return .needsAttention
    }

    // Error: surface as idle so the caller can show detail; no fabricated terminal state.
    if signals.isError { return .idle }

    // Run-state cascade — positive signals only, no guessing.
    if signals.isStarting  { return .configuring }
    if signals.isRunning   { return .working }
    if signals.isCompleted { return .done }

    // Delegate the stale + hysteresis decision to the engine.
    // This is the only place engineStatus flows through; the cascade above supersedes it
    // for any signal the caller has positive evidence for.
    if signals.engineStatus == .stale { return .stale }

    // No positive evidence → idle, never a fabricated richer status.
    // This is the "unknown never fabricates" guarantee from I6.
    return .idle
}
```

The key caller contract: the caller (the future session observer) assembles
`StatusSignals` from whatever tier feeds it — reader snapshot fields or managed-adapter
event projection — and calls `deriveAgentStatus`. The caller never sets
`hasPendingApproval = true` for an observed shell tile (that field has no source of truth
for that tier); it leaves it `false`. The cascade's structure then naturally excludes
`.needsAttention` from the managed-only path for shell tiles.

The hook-freshness window matches the existing engine's stale threshold. Do **not** hardcode
`300` in the derivation function. Define a single named constant and derive it from the
engine's real default so the two never drift:

```swift
extension StatusSignals {
    // Freshness window for the hook breadcrumb, tied to the engine's stale threshold
    // so there is one source of truth (no magic literal in the cascade).
    public static let hookFreshnessWindow: TimeInterval =
        AgentStatusEngine.Configuration().staleTimeout
}
```

(`AgentStatusEngine.Configuration().staleTimeout` is `300` today, confirmed at
`AgentStatusEngine.swift:15`. Referencing it, not a literal, is the requirement.)

## How we test it

**Test convention for this repo (read this first).** This project has **no `swift test`
target** — `Package.swift` declares no `.testTarget`, there is no `Tests/` directory, and
nothing imports `XCTest` or `Testing`. All checks are plain executable targets using a
hand-rolled harness: a top-level `expect(_ condition:, _ message:)` helper that calls
`Foundation.exit(1)` on failure (see `Sources/ContinuumRevivedCoreChecks/main.swift:6`).
The matrix runs them via `swift run` (see `scripts/run-matrix.sh:78`:
`run swift run ContinuumRevivedCoreChecks`). **Follow that convention exactly — do not
introduce a test target.** All three test kinds below are `expect(...)` blocks appended to
`Sources/ContinuumRevivedCoreChecks/main.swift`, run with `swift run ContinuumRevivedCoreChecks`.

### Logic (pure Core checks)

Append a table-driven block to `Sources/ContinuumRevivedCoreChecks/main.swift`. Each row is
a `StatusSignals` value and an expected `AgentStatus`, asserted with the existing `expect`
helper. Pattern:

```swift
// MARK: - deriveAgentStatus priority ladder
do {
    func check(_ signals: StatusSignals, _ expected: AgentStatus, _ label: String) {
        expect(deriveAgentStatus(signals: signals) == expected, "deriveAgentStatus: \(label)")
    }
    check(StatusSignals(agentKind: .managed, hasPendingApproval: true, isRunning: true),
          .needsAttention, "approval beats running")
    // ... one check(...) per row below ...
}
```

The table must cover every branch of the cascade explicitly:

- Managed agent with `hasPendingApproval = true`, `isRunning = true` → `.needsAttention`
  (attention beats running; this row directly asserts the t3code-verified priority).
- Managed agent with `hasPendingUserInput = true`, `isRunning = true` → `.needsAttention`.
- Both pending flags false, `hookBreadcrumbPresent = true` with a fresh age → `.needsAttention`.
- Hook breadcrumb present but stale (age ≥ the freshness window) → falls through to
  run-state, not `.needsAttention`.
- Hook breadcrumb absent for an observed Claude tile, `isRunning = true` → `.working`
  (no fabrication of attention without the hook, per D11).
- `isError = true`, any kind → `.idle`.
- `isStarting = true` → `.configuring`.
- `isRunning = true`, no attention signals → `.working`.
- `isCompleted = true`, no attention signals → `.done`.
- `engineStatus = .stale`, no positive signals → `.stale`.
- `AgentKind.unknown`, all boolean flags false, `engineStatus = .idle` → `.idle` (never
  fabricates a richer status).
- `AgentKind.unknown`, `isRunning = true` → `.working` (process signal alone is enough
  for working/idle; readers add depth but are not required for the basic states).

The golden table that formally pins these rows against I6 is the companion I6-harness
ticket; that ticket imports these same cases and adds the full fixture set. The logic check
here is the RED→GREEN prerequisite for that table.

Run the block: `swift run ContinuumRevivedCoreChecks` from the package root. The check must
pass with no process spawned, no clock query — pure struct-in / enum-out.

### Backend (real-path / integration, not bypassed)

The full real-path check for this function (reader → signal assembly → derivation →
`AgentDescriptor` write) is exercised by the session-observer integration check, which is
that ticket's responsibility: it drives a real tmux pane with a sentinel agent and asserts
the derived status matches the expected ladder given the live file state.

For *this* ticket specifically, there is one targeted, self-contained real-path check that
proves the derivation function's inputs come from a real Claude session file format, not a
hand-crafted struct — and it runs inside the same `ContinuumRevivedCoreChecks` executable
(no test bundle, no `swift test`):

1. **Write a fixture file to a temp path at check time.** In the check block, write a
   minimal two-event Claude session JSONL to a temporary file via
   `FileManager.default.temporaryDirectory` — a `session_started` line followed by an
   in-progress `assistant` turn line. (Writing it in-code keeps the fixture in the check
   and sidesteps the absent test-bundle-resource mechanism entirely.)
2. **Read and parse it from disk.** Read the file back with `String(contentsOf:)`, split by
   newline, decode the two JSON lines, and map the parsed event type to `StatusSignals`
   (`assistant` in-progress ⇒ `isRunning = true`, all attention flags false).
3. **Assert.** `expect(deriveAgentStatus(signals: signals) == .working, "claude working
   fixture derives working")`.
4. **Clean up** the temp file (`try? FileManager.default.removeItem(at:)`).

This is a genuine filesystem round-trip against the real Claude JSONL shape (a real file
path, real parse), not a network or live-tmux query — so it is a real-path check that needs
no daemon and no live process, and it lives in the executable check the matrix already runs.

This is not the full reader golden-fixture suite (that is the Claude-reader ticket's job);
it is the minimum real-file integration smoke check that proves the derivation function's
inputs come from real file formats.

### UX (visual gate + dogfood snippet)

The derivation function is pure logic; there is no UI to gate at this ticket's boundary.
The visual gate lives one step up: the status badge on a tile's canvas overlay and the
sidebar row both show the derived status. That gate is the responsibility of the
mock-rollup-replacement ticket and the dock-render ticket.

However, to avoid leaving UX verification entirely deferred, include this as part of the
ticket's acceptance criteria: with the function in place and the existing mock data in the
sidebar replaced by a hard-coded `StatusSignals` with `isRunning = true, agentKind = .claude`,
verify the sidebar row shows the blue "working" pulse (not a stale gray ring). This can be
done manually without the full observer pipeline:

Open the app → look at the sidebar or any tile with a live session → confirm the status
indicator color matches the expected `AgentStatus` from a hard-coded signal call placed
temporarily in the session-descriptor initialization path. Remove the hard-coded call
after the visual check passes.

The concrete dogfood snippet for the full pipeline will be: open the app → ensure a
Claude session is running in a tile → observe the tile's canvas status indicator and the
matching sidebar row → both show the blue working pulse → trigger the hook breadcrumb
(e.g., by sending a `SIGUSR1` to the breadcrumb-writing hook, or by manually writing a
breadcrumb file) → within the 250 ms debounce, the tile border and sidebar row flip to
orange with the diamond indicator, no manual refresh. That snippet is owned by the
consent-hook ticket, but its correctness depends on this derivation function being sound.

## Execution mode

**Autonomous.** The function is pure and deterministic: given a `StatusSignals` value it
returns an `AgentStatus` with no external calls. The logic check is a table of
struct-in / enum-out assertions that run with zero daemons, zero clock queries, and zero
network. The real-path smoke check writes and reads one temp file — a local filesystem
round-trip with no process spawning — inside the same `ContinuumRevivedCoreChecks`
executable the matrix already runs. The combined check (logic table + fixture round-trip)
fully proves the function correct per the verification doctrine: the matrix is satisfied,
the real-path is satisfied, and no human eyes are needed to verify a derivation function's
output given a table of inputs. The UX gate is deferred to the rollup ticket, which is
correctly marked supervised; this ticket does not claim to prove the visual layer.

## Done when

- [ ] `AgentKind` exists in the target (`shell | claude | codex | pi | managed | unknown`),
  either reused from the agent-kind-enum ticket if already present or introduced additively
  here if absent — without touching `AgentDescriptor.agentKind`.
- [ ] `StatusSignals` struct exists in `AgentStatusEngine.swift` with all nine fields and
  a public memberwise initializer with defaults for the boolean fields.
- [ ] `deriveAgentStatus(signals:)` exists in `AgentStatusEngine.swift` as a public free
  function, marked with no mutating keyword, taking and returning value types only.
- [ ] The priority cascade is in the exact order specified: `hasPendingApproval` →
  `hasPendingUserInput` → `hookBreadcrumbPresent` (with age guard) → `isError` →
  `isStarting` → `isRunning` → `isCompleted` → `engineStatus == .stale` → `.idle`.
- [ ] The hook-freshness window is referenced from
  `AgentStatusEngine.Configuration().staleTimeout` via a single named constant
  (`StatusSignals.hookFreshnessWindow`), not a magic `300` literal in the cascade.
- [ ] The table-driven logic check covers all twelve rows listed above and passes with
  `swift run ContinuumRevivedCoreChecks` (no daemon, no clock, no file I/O in this block).
- [ ] The real-path smoke check writes a minimal Claude session JSONL to a temp file,
  reads and parses it back, assembles `StatusSignals`, asserts `.working`, and cleans up —
  all inside `ContinuumRevivedCoreChecks`, passing under `swift run ContinuumRevivedCoreChecks`.
- [ ] `swift build` passes with no new warnings.
- [ ] No existing checks in `ContinuumRevivedCoreChecks/main.swift` are broken or deleted;
  `scripts/run-matrix.sh` stays green.

## Depends on / unblocks

**Depends on: nothing that must land first.** The only hard requirement is the closed
`AgentKind` enum (D14); this ticket introduces it additively if it is not already present,
so it is not blocked on the agent-kind-enum ticket. It does **not** depend on the
`AgentDescriptor.agentKind` string→enum migration — that is separate work, kept out of
scope here precisely so this ticket is independently completable.

This ticket unblocks the status-derivation golden table (the I6-harness ticket), which
imports the same `StatusSignals` type and adds the full I6 fixture set. It also unblocks
the reader protocol and the three concrete readers (Claude, Codex, Pi), each of which
writes into `StatusSignals` fields and calls `deriveAgentStatus` to produce the
`AgentStatus` written into `AgentDescriptor`. It further unblocks the managed-approval
path, which sets `hasPendingApproval = true` and expects `.needsAttention` out. And it is
the function that the session observer calls at the hot path of every observation cycle.

## Watch out for

**The single hardest thing to get right: the hookBreadcrumbPresent path must never fire
for non-observed-Claude tile kinds.** The `hookBreadcrumbPresent` field can only be `true`
for tiles where the Claude hook has been installed and the tile's `agentKind` is `.claude`.
If any caller accidentally sets this flag on a `pi` or `unknown` tile, that tile will
show `.needsAttention` with no real signal behind it — exactly the fabrication I6
prohibits. The check must include a row that sets `hookBreadcrumbPresent = true`
with `agentKind = .pi` and asserts that `.needsAttention` is *not* returned (because the
caller should never set the flag for that kind, and the function should not gate on
`agentKind` inside the cascade). The right solution is a caller-enforced invariant: the
session observer sets `hookBreadcrumbPresent` only when `agentKind == .claude && hookIsInstalled`.
The derivation function trusts the caller; the check pins the contract.

**Do not conflate the `AgentStatusEngine`'s `Signal` enum with `StatusSignals`.** The
existing `AgentStatusEngine.Signal` (lines 4–9 of `AgentStatusEngine.swift`) is a
different type — it feeds the stateful hysteresis engine from raw tmux observations.
`StatusSignals` is the distilled, post-hysteresis evidence struct that feeds the new pure
function. The two types serve different layers; keep them distinct.

**The `engineStatus` field carries `.stale` from the existing engine — do not re-implement
stale detection.** The 300-second timeout and the hysteresis logic already live in the
engine's recompute step (`AgentStatusEngine.swift:75` gates `.stale` off `staleTimeout`).
The derivation function checks `engineStatus == .stale` as a pass-through, not a
recomputation. If you find yourself adding a `Date` parameter to `deriveAgentStatus`, you
are re-implementing logic that belongs in `AgentStatusEngine`; stop and reassign it there.

**Do not add a `.failed` case to `AgentStatus`.** The error branch maps to `.idle`, not a
new case. Adding an enum case to `AgentStatus` is a cascading change across the entire
UI, serialization, and sidebar layers. The architecture doc explicitly chose six cases;
`isError = true` surfaces its detail through `AgentDescriptor`'s metadata, not by
splitting the status enum.
