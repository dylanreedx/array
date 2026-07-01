# No-mirror real-path check (I2)

Rests on **D19** (grouped-session naming/cleanup) and **D20** (two tiles on the same
window are a *deliberate* shared view, explicitly exempt from I2). It is part of the
**D26** phase-0 harness spine and honours the D26 UX-testing contract (real-path check +
non-degenerate visual gate + dogfood snippet; manifests carry measured values, never
`{passed:true}`).

## What this delivers

After this ticket lands, the invariant "distinct tiles show distinct windows" is not a
claim the code makes about itself — it is a fact a real tmux daemon has confirmed. The
check spawns a real project session, attaches two genuine grouped view sessions against
it, pins each to a different window via `select-window`, then queries tmux directly for
each view session's active-window target. The assertion is simple: the two targets must
differ. If they match, the de-mirror mechanism is broken and a human looking at two tiles
would see the same screen.

The check also confirms the **D20 deliberate shared-view exemption** does the right thing
— and, critically, that it does the right thing *for the right reason*. The exemption is
driven by a **declared per-tile intent** (each tile records the window target it is
*supposed* to show), not by observing that two targets happen to be equal. The check
proves two things that equal targets alone cannot distinguish:

- **Deliberate shared view** — two tiles that *declared the same intended window* and are
  observed on that window: exempt, not a violation.
- **Accidental mirror** — two tiles that *declared distinct intended windows* but are
  nonetheless observed on the same window: a **violation**, even though their observed
  targets are equal. This is the exact failure D20 carves out of the exemption, and the
  check has a case that FAILS if this were wrongly treated as exempt.

No new user-facing feature ships here. What ships is confidence that the grouped-session
de-mirror logic — which is doing real tmux work that cannot be proven by a pure in-memory
check — behaves as the architecture requires before any tile UI is built on top of it.

## How it fits

This ticket is the acceptance gate for the grouped-view-session work (D19). That ticket
delivers the mechanism: a `continuum-view-<tileId>` session grouped onto
`continuum-proj-<projectId>`, with a `select-window` call that pins it to the tile's
window immediately after attach. This ticket drives that mechanism against a real daemon
and reads back what tmux actually recorded, bridging the gap between "the commands were
issued" and "the invariant holds."

It builds on the target-capture work (D25): the `tmuxWindowTarget` (`%pane_id`) that was
captured and persisted synchronously at spawn is exactly what gets passed to
`select-window` here, and its window's `window_id` is the value this check reads back from
`tmux display` to assert distinctness. Without a reliable, persisted pane id, the
`select-window` call would have nothing stable to pin to, and the check would be asserting
on a moving target.

In the other direction, the D20 shared-view path depends on this check existing first —
its "done when" criteria explicitly require that the no-mirror check is in place and
passing before the exemption is wired, so the exemption cannot be introduced as a
regression vector.

## The approach

The check runs entirely against a real tmux daemon using the real `TmuxControl`
implementation — the same `ProcessTmuxControl` that production code will use. No mock, no
in-memory fake, no subprocess-level bypass. If tmux is not available on the machine
running the check, it skips through a **structured skip path** (described precisely below):
it writes a partial manifest carrying `tmux_absent: true`, prints a skip line to stdout,
and leaves the enclosing labelled block without running any subprocess. A skip is not a
pass; the CI matrix must have tmux available on at least one host.

The check sets up a minimal but real topology: one project session with two windows (one
per tile), then two view sessions each grouped onto the project session and pinned to
different windows. It reads the active-window target of each view session via `tmux
display` and asserts they differ. It then exercises the **exemption seam** by driving a
third view session under two *declared intents* and asserting the exemption verdict is
correct in each — accepting the deliberate shared view, rejecting the accidental mirror.

All state is created with deterministic names derived from a single run UUID and is torn
down in a `defer` block regardless of assertion outcome, so no orphan sessions accumulate
even if the check fails partway through.

## Where it lives

**Primary seam — the check itself:**

- `Sources/ContinuumRevivedCoreChecks/main.swift` — a new **labelled** top-level `do`
  block following the existing convention (every check in this file is a bare top-level
  `do { … }`; there is no enclosing loop or function). The block is labelled both with a
  `// MARK: - I2 No-mirror real-path check` comment **and** with a Swift statement label
  `i2Check:` so the skip path has a structured target. The manifest struct is
  `NoMirrorCheckManifest` (a `Codable` struct defined at file scope alongside the block)
  and is written to `qa-runs/no-mirror-<runId>/manifest.json` using the same `JSONEncoder`
  + atomic-write pattern already present in the existing real-path checks in this file.

**Skip control flow — resolved, not left to the implementer:**

Because these checks are **top-level `do` blocks at file scope**, there is no loop to
`continue` and no function to `return` from, and a bare `break` inside a bare `do {}` is a
Swift compile error. The skip therefore uses a **labelled block statement**, which *is*
valid Swift at file scope: the block is written `i2Check: do { … }` and the skip path
executes `break i2Check`. `break <label>` on a labelled `do` exits that block and falls
through to the code after it — it does not abort the check binary (so every later check in
`main.swift` still runs) and it is not a compile error. `Foundation.exit(...)` is
**forbidden** for the skip: it would kill the whole checks process and silently skip every
subsequent check.

The skip must write its partial manifest *before* it breaks. Concretely, on skip:

1. Build a `NoMirrorCheckManifest` in its **skip shape**: `tmuxAbsent: true`, `runId` set,
   all measured fields (`paneA`, `paneB`, `activeWindowA`, `activeWindowB`,
   `activeWindowShared`) left as empty strings, and both verdict booleans (`i2Distinct`,
   `sharedViewExemptionCorrect`) set to `false` (a skip proves nothing, so it must not
   read as a pass).
2. Write it to `qa-runs/no-mirror-<runId>/manifest.json` with the same
   `createDirectory(withIntermediateDirectories:)` + atomic write used on the pass path.
3. Print the structured skip line to **stdout** (so CI can grep it):
   `SKIP I2: tmux not found — tmux_absent:true — manifest at <path>`.
4. `break i2Check`.

Because the skip runs before any session is created, its `defer` teardown is a no-op
(`try?` kills of never-created sessions), which is safe.

**Supporting seam — the grouped-view-session attach helper (D19):**

The D19 grouped-session work introduces a function —
`TmuxSession.groupedViewSessionArguments(viewSessionName:projectSessionName:)` — that
produces the `new-session -t <projectSession> -s <viewSessionName>` argv. This check calls
that function directly to construct the attach command rather than hand-rolling the argv,
so the check exercises the same helper production code will use. If the D19 ticket has not
landed yet, this check cannot be written — it has a hard prerequisite on that helper being
present in `TmuxSession.swift`.

**Supporting seam — the select-window helper (D19):**

D19 also introduces
`TmuxSession.selectWindowArguments(viewSessionName:paneTarget:)`, producing `select-window
-t <viewSessionName>:<paneTarget>` argv. The check uses this helper for pinning, for the
same reason: it must drive the real production helper, not a locally hand-crafted command.

**Supporting seam — the active-window query:**

`TmuxSession.activeWindowTargetArguments(viewSessionName:)` produces the `display -p -t
<viewSessionName> '#{window_id}'` argv used to read back what window a view session is
currently showing. If this helper does not exist in the D19 ticket, **this check adds it
to `TmuxSession.swift` as part of its own scope.**

**Supporting seam — window-id validation (owned here):**

`TmuxSession.isValidWindowId(_:)` validates that a string is a well-formed tmux
`window_id` (the `@` prefix followed by digits, e.g. `@3`), mirroring the existing
`TmuxSession.isValidPaneId(_:)` (the `%` prefix) from the D25 target-capture work.
**Ownership and scope are explicit: `isValidWindowId` lives in
`Sources/ContinuumRevivedCore/TmuxSession.swift`, alongside `isValidPaneId`, and if it is
not already present it is added by THIS ticket** (it is a peer of the
`activeWindowTargetArguments` helper this ticket already scopes to that file). It is used
in two places, both in this ticket: (a) a pure logic check asserts its accept/reject
behaviour on the `@` prefix, and (b) the real-path breadcrumb asserts *every read-back
window id is `isValidWindowId`* before any `activeA != activeB` comparison — never compare
two window ids without first proving both are well-formed, exactly as the breadcrumb
already asserts `isValidPaneId` on the pane-id side.

**Exemption seam — where the exemption verdict is decided:**

The exemption is **not** decided by comparing observed targets. It is decided by a pure
function that takes both the **declared intent** and the **observed reality** for a pair
of tiles:

```swift
// Lives in Sources/ContinuumRevivedCore/TmuxSession.swift (or a small sibling type),
// added by this ticket if D19 has not already introduced it.
// intendedA / intendedB : the window_id each tile DECLARED it should show (from the
//                          per-tile tmuxWindowTarget's window, D19/D25 — production input).
// observedA / observedB : the window_id each view session is ACTUALLY showing (tmux read-back).
func i2Verdict(intendedA: String, intendedB: String,
               observedA: String, observedB: String) -> I2Verdict
```

with

```swift
enum I2Verdict: Equatable {
    case distinct              // observed targets differ — invariant holds
    case deliberateSharedView  // both tiles DECLARED the same window and are on it — D20 exempt
    case accidentalMirror      // tiles DECLARED distinct windows but landed on the same one — VIOLATION
}
```

The rule, stated once:

- `observedA != observedB` → `.distinct`.
- `observedA == observedB` **and** `intendedA == intendedB` → `.deliberateSharedView`
  (the shared view was *asked for*; D20 exempts it).
- `observedA == observedB` **and** `intendedA != intendedB` → `.accidentalMirror` (each
  tile asked for a different window but the de-mirror mechanism failed to deliver it — an
  I2 violation *despite* equal observed targets).

This is the load-bearing distinction gap #2 demanded: the exemption flag originates in
production from the **declared per-tile intent** (the `window_id` of each tile's persisted
`tmuxWindowTarget`), *not* from comparing what tmux happened to return. Equal observed
targets are necessary but not sufficient for the exemption; the intent is what separates
a feature (D20) from a bug (I2).

**Existing seam — TmuxLocator and ProcessTmuxControl:**

- `Sources/ContinuumRevivedCore/TmuxSession.swift` — `TmuxLocator.resolve(defaults:)`
  provides the tmux binary path; the check calls this once at the top of its block and
  takes the skip path if nil.
- `Sources/ContinuumRevivedCore/Substrates/TmuxControl.swift` — `ProcessTmuxControl`
  (introduced by the injectable substrates work, D26) is the real implementation the check
  instantiates with the resolved path.

## Implementation breadcrumbs

The full control flow in order, with the key types and calls. Note the labelled block and
the structured skip.

```swift
// MARK: - I2 No-mirror real-path check

let runId = String(UUID().uuidString.prefix(8))
let runDir = URL(fileURLWithPath: "qa-runs/no-mirror-\(runId)", isDirectory: true)

i2Check: do {
    // 1. Locate tmux; on absence take the STRUCTURED skip path (partial manifest + break).
    guard let tmuxPath = TmuxLocator.resolve() else {
        let skip = NoMirrorCheckManifest.skipped(runId: runId)   // tmuxAbsent: true, verdicts false
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let path = runDir.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(skip).write(to: path, options: .atomic)
        print("SKIP I2: tmux not found — tmux_absent:true — manifest at \(path.path)")
        break i2Check   // valid Swift: exits the LABELLED do-block; later checks still run.
    }
    let tmux = ProcessTmuxControl(tmuxPath: tmuxPath)

    // Deterministic names for this run.
    let projSession  = "continuum-proj-i2-\(runId)"
    let viewSessionA = "continuum-view-i2a-\(runId)"
    let viewSessionB = "continuum-view-i2b-\(runId)"
    let viewSessionS = "continuum-view-i2s-\(runId)"  // exercised under two declared intents

    // 2. Teardown guard — runs whether check passes, breaks, or throws. try? throughout so a
    //    never-created session cannot mask the original failure.
    defer {
        try? tmux.run(["kill-session", "-t", projSession])
        for vs in [viewSessionA, viewSessionB, viewSessionS] {
            try? tmux.run(["kill-session", "-t", vs])
        }
    }

    // 3. Create the project session with two windows.
    let paneA = try tmux.newSession(name: projSession, cwd: "/tmp", innerCommand: nil)
    let paneB = try tmux.newWindow(inSession: projSession, cwd: "/tmp", innerCommand: nil)
    assert(TmuxSession.isValidPaneId(paneA), "project session pane A must be valid: \(paneA)")
    assert(TmuxSession.isValidPaneId(paneB), "project session pane B must be valid: \(paneB)")
    assert(paneA != paneB, "two windows in one session must produce distinct pane ids")

    // 4. Attach two grouped view sessions; pin each to its window (D19 helpers).
    try tmux.run(TmuxSession.groupedViewSessionArguments(
        viewSessionName: viewSessionA, projectSessionName: projSession))
    try tmux.run(TmuxSession.selectWindowArguments(
        viewSessionName: viewSessionA, paneTarget: paneA))

    try tmux.run(TmuxSession.groupedViewSessionArguments(
        viewSessionName: viewSessionB, projectSessionName: projSession))
    try tmux.run(TmuxSession.selectWindowArguments(
        viewSessionName: viewSessionB, paneTarget: paneB))

    // 5. Read back the active-window target (window_id, "@N") of each view session.
    let activeA = try tmux.run(TmuxSession.activeWindowTargetArguments(viewSessionName: viewSessionA))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let activeB = try tmux.run(TmuxSession.activeWindowTargetArguments(viewSessionName: viewSessionB))
        .trimmingCharacters(in: .whitespacesAndNewlines)

    // 5a. Validate BOTH ids before any comparison — never compare unvalidated window ids.
    assert(TmuxSession.isValidWindowId(activeA), "view A active window id must be well-formed: \(activeA)")
    assert(TmuxSession.isValidWindowId(activeB), "view B active window id must be well-formed: \(activeB)")

    // 6. Assert I2 via the production verdict fn. Here A and B DECLARED distinct windows
    //    (paneA's window vs paneB's window), so equal observed targets would be an accidental mirror.
    let intendedA = activeA   // the window each tile was pinned to IS its declared intent here.
    let intendedB = activeB   // (in production these come from each tile's persisted tmuxWindowTarget.)
    let mainVerdict = TmuxSession.i2Verdict(
        intendedA: paneWindowId(paneA), intendedB: paneWindowId(paneB),
        observedA: activeA,             observedB: activeB)
    assert(mainVerdict == .distinct,
        "I2 VIOLATION: verdict=\(mainVerdict) — view A active=\(activeA), view B active=\(activeB)")

    // 7. Exemption seam — the D20 distinction, exercised for BOTH outcomes.

    // 7a. DELIBERATE shared view: point S at the SAME window A declared, with the SAME intent.
    try tmux.run(TmuxSession.groupedViewSessionArguments(
        viewSessionName: viewSessionS, projectSessionName: projSession))
    try tmux.run(TmuxSession.selectWindowArguments(
        viewSessionName: viewSessionS, paneTarget: paneA))
    let activeS = try tmux.run(TmuxSession.activeWindowTargetArguments(viewSessionName: viewSessionS))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    assert(TmuxSession.isValidWindowId(activeS), "view S active window id must be well-formed: \(activeS)")

    // Intent for S is paneA's window (deliberately shared) — same intent as A.
    let deliberateVerdict = TmuxSession.i2Verdict(
        intendedA: paneWindowId(paneA), intendedB: paneWindowId(paneA),   // SAME intent
        observedA: activeA,             observedB: activeS)               // SAME observed
    assert(deliberateVerdict == .deliberateSharedView,
        "D20: same declared intent + same observed window must be exempt, got \(deliberateVerdict)")

    // 7b. ACCIDENTAL mirror: S is observed on A's window (activeS == activeA) but S DECLARED
    //     paneB's window. Equal observed targets, DIFFERENT intent → must be a VIOLATION.
    //     This case FAILS the check if an accidental mirror were wrongly treated as exempt.
    let accidentalVerdict = TmuxSession.i2Verdict(
        intendedA: paneWindowId(paneB), intendedB: paneWindowId(paneA),   // DIFFERENT intent
        observedA: activeS,             observedB: activeA)               // SAME observed (activeS == activeA)
    assert(accidentalVerdict == .accidentalMirror,
        "I2: distinct declared intent but same observed window is an accidental mirror, got \(accidentalVerdict)")

    // 8. Write manifest with MEASURED values, never {passed: true}.
    let manifest = NoMirrorCheckManifest(
        runId: runId,
        tmuxAbsent: false,
        projSession: projSession,
        paneA: paneA, paneB: paneB,
        activeWindowA: activeA, activeWindowB: activeB, activeWindowShared: activeS,
        i2Distinct: mainVerdict == .distinct,
        sharedViewExemptionCorrect:
            deliberateVerdict == .deliberateSharedView && accidentalVerdict == .accidentalMirror)
    try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    try JSONEncoder().encode(manifest).write(
        to: runDir.appendingPathComponent("manifest.json"), options: .atomic)
    print("PASS I2: A=\(activeA) B=\(activeB) distinct; shared=\(activeS); " +
          "exemption deliberate=\(deliberateVerdict) accidental=\(accidentalVerdict)")
}

// paneWindowId(_:) — reads the window_id that owns a given %pane_id, via
// `display -p -t <pane> '#{window_id}'`. Small local helper in the block; used only to turn
// the pane ids we hold into the declared-intent window ids the verdict fn takes.

// Local manifest type — Codable, at file scope. Has a skip constructor so the skip path
// and the pass path share one shape.
struct NoMirrorCheckManifest: Codable {
    var runId: String
    var tmuxAbsent: Bool           // true on the structured skip path
    var projSession: String
    var paneA: String              // %pane_id of tile A's window
    var paneB: String              // %pane_id of tile B's window
    var activeWindowA: String      // window_id (@N) active in view session A
    var activeWindowB: String      // window_id (@N) active in view session B
    var activeWindowShared: String // window_id active in the shared/mirror-probe session
    var i2Distinct: Bool           // true = invariant holds
    var sharedViewExemptionCorrect: Bool  // true = BOTH exemption outcomes correct (7a AND 7b)

    static func skipped(runId: String) -> NoMirrorCheckManifest {
        NoMirrorCheckManifest(
            runId: runId, tmuxAbsent: true, projSession: "",
            paneA: "", paneB: "", activeWindowA: "", activeWindowB: "", activeWindowShared: "",
            i2Distinct: false, sharedViewExemptionCorrect: false)
    }
}
```

Note on the `tmux.run([...])` calls above: `ProcessTmuxControl` exposes a lower-level
`run(_ arguments: [String]) throws -> String` alongside the higher-level typed methods.
The higher-level `newSession` and `newWindow` are used for setup (they return pane ids
directly); the raw `run` form is used for the `select-window` and `display` calls. Use
whichever surface the substrates ticket exposes — the key constraint is that
`ProcessTmuxControl` is always the real implementation, never the fake.

## How we test it

### Logic (pure Core checks)

The verdict logic — and the exemption distinction that is the whole point of D20 — is
proven without a daemon by exercising the pure `i2Verdict` function and the two validators.

Write one pure check suite in the same `ContinuumRevivedCoreChecks/main.swift` top-level
`do`-block structure, separately from the real-path check:

1. **Verdict truth table (the D20 distinction, proven).** Assert `TmuxSession.i2Verdict`:
   - `(intendedA: "@1", intendedB: "@2", observedA: "@1", observedB: "@2")` → `.distinct`.
   - `(intendedA: "@1", intendedB: "@1", observedA: "@1", observedB: "@1")` →
     `.deliberateSharedView` (same intent, same observed — D20 exempt).
   - `(intendedA: "@1", intendedB: "@2", observedA: "@1", observedB: "@1")` →
     `.accidentalMirror` (distinct intent, same observed — **this case FAILS if the
     implementation collapses the exemption to "equal observed → exempt"**; it is the
     direct guard demanded by gap #2).
2. **`isValidWindowId` accept/reject.** Assert `TmuxSession.isValidWindowId("@3") == true`,
   `isValidWindowId("%3") == false` (that is a pane id), `isValidWindowId("3") == false`
   (that is a window *index*), and `isValidWindowId("@") == false` / `isValidWindowId("") ==
   false`. Assert the peer `isValidPaneId("%7") == true` and `isValidPaneId("@7") == false`
   so the two validators are provably not interchangeable.
3. **Session name / attach argv construction.** Assert
   `TmuxSession.groupedViewSessionArguments(viewSessionName: "continuum-view-X", projectSessionName: "continuum-proj-Y")`
   produces an argv containing `"-t"` followed by `"continuum-proj-Y"` and `"-s"` followed
   by `"continuum-view-X"`. Pure argv-shape check, no subprocess.
4. **Active-window query construction.** Assert
   `TmuxSession.activeWindowTargetArguments(viewSessionName: "continuum-view-X")` produces
   an argv whose format string is `"#{window_id}"` (not `"#{window_index}"`, not
   `"#{pane_id}"`) and whose target argument is `"continuum-view-X"`. No subprocess.

These run in milliseconds and prove the helper argv shapes, the two validators, and — most
importantly — that an accidental mirror is a violation even when observed targets are
equal, independent of any daemon.

### Backend (real-path / integration)

The primary proof, described in full in "The approach" and "Implementation breadcrumbs".
Properties of a valid backend run:

- Runs against `ProcessTmuxControl` — the real `Process`-backed implementation.
- Creates a real project session and two real windows; does not pre-program results.
- Reads back what tmux actually recorded via `tmux display`, and validates every read-back
  window id with `isValidWindowId` before comparing.
- Decides I2 and the exemption through the production `i2Verdict` fn, fed by **declared
  intent** (each pane's window id) and **observed** read-back — not by comparing observed
  targets alone.
- Exercises **both** exemption outcomes on the real daemon: 7a (same intent + same
  observed → `.deliberateSharedView`) and 7b (distinct intent + same observed →
  `.accidentalMirror`). `sharedViewExemptionCorrect` is `true` only if **both** are right.
- The manifest records `activeWindowA`, `activeWindowB`, `activeWindowShared`, `paneA`,
  `paneB` as measured string values and `i2Distinct: true` — not `{passed: true}`. A
  reviewer should be able to open the manifest and read the actual window ids.
- On no-tmux, takes the structured skip path: writes a partial manifest with
  `tmux_absent: true` and both verdict booleans `false`, prints the stdout skip line, and
  `break i2Check` — so CI can distinguish "skipped" from "not run", and later checks run.
- Cleans up all created sessions in a `defer` block, including partial cleanup when the
  check fails mid-run.

The backend check proves I2 against the real tmux contract, not against a model of it.
That distinction is the entire reason this ticket exists.

### UX (visual gate + dogfood snippet)

The no-mirror invariant has a direct, concrete visual expression: open the app, spawn two
terminal tiles in the same project zone, and they must show independent shell prompts, not
the same one.

**Visual gate:** Add a "Two-tile de-mirror" fixture to the Component Lab that renders two
`GhosttyTerminalView` instances side by side, both attached via grouped view sessions to
the same project session but pinned to different windows. Gate criterion: type a command
in one tile — e.g. `echo tile-A` — and observe that the other tile does not echo or react;
each tile shows its own independent cursor position. A screenshot of this fixture with both
tiles showing independent content is the visual gate artifact, committed alongside the
check manifest.

**Dogfood snippet:** Open the app. In any project zone, spawn two terminal tiles (the
default spawn creates a new window per tile — D-A/D19 — so two spawns in the same zone
produce two windows in that project's session). In tile A, type `echo hello-from-A` and
press Return. In tile B, type `echo hello-from-B` and press Return. Tile A should show
`hello-from-A` in its own scrollback; tile B should show `hello-from-B` in its own
scrollback. Neither tile should show the other's output, and the prompts should be at
independent cursor positions. If either tile mirrors the other's output, the
`select-window` pinning is not working and the grouped-session attach is falling back to
tmux's default behavior of sharing the active window.

## Execution mode

**Needs-substrate.** The primary proof requires a real tmux daemon — a real local machine
(or a CI host with tmux installed), not a cloud account or iOS device, but a real
process-level substrate that `ProcessTmuxControl` can shell out to. The logic checks (the
`i2Verdict` truth table, the two validators, the argv shapes) are autonomous, but the check
as a whole cannot be marked autonomous because the invariant it certifies is a property of
real tmux behavior, not of the model. The visual gate likewise requires a running app with
real ghostty surfaces. A CI matrix with no tmux sees a skip on this check — acceptable, but
the check must not be treated as passing on that host.

## Done when

- [ ] The pure logic checks pass: `i2Verdict` returns `.distinct`,
  `.deliberateSharedView`, and `.accidentalMirror` for the three truth-table rows
  (including the distinct-intent/equal-observed row that must be `.accidentalMirror`);
  `isValidWindowId`/`isValidPaneId` accept and reject correctly and are not
  interchangeable; `groupedViewSessionArguments` and `activeWindowTargetArguments` produce
  the correct argv shapes (the latter using `#{window_id}`).
- [ ] `isValidWindowId(_:)` exists in `Sources/ContinuumRevivedCore/TmuxSession.swift`
  alongside `isValidPaneId(_:)` (added by this ticket if D19 did not).
- [ ] The real-path check runs against a real tmux daemon, creates a project session with
  two windows, attaches two grouped view sessions and pins each with `select-window`,
  validates each read-back window id with `isValidWindowId`, reads back `activeWindowA` and
  `activeWindowB` via `tmux display`, and asserts the verdict is `.distinct`.
- [ ] The exemption seam is proven on the real daemon in **both** directions: same
  declared intent + same observed window → `.deliberateSharedView` (exempt); distinct
  declared intent + same observed window → `.accidentalMirror` (violation).
  `sharedViewExemptionCorrect: true` requires both.
- [ ] The manifest at `qa-runs/no-mirror-<runId>/manifest.json` records `paneA`, `paneB`,
  `activeWindowA`, `activeWindowB` as distinct measured string values, and `i2Distinct:
  true`. Not `{passed: true}`.
- [ ] The structured skip works: with `TmuxLocator.resolve()` nil, the check writes a
  partial manifest (`tmux_absent: true`, verdict booleans `false`) to the run dir, prints
  the stdout skip line, and `break i2Check` — no subprocess runs, later checks still run,
  and the process does not `exit`.
- [ ] All created sessions (project session and all view sessions) are torn down in the
  `defer` block and do not appear in `tmux ls` after the check exits.
- [ ] The Component Lab fixture renders two tiles with independent content and a committed
  screenshot shows distinct output in each.
- [ ] The dogfood snippet passes: typing in one tile produces no echo in the other.
- [ ] No existing checks in `ContinuumRevivedCoreChecks/main.swift` regress.

## Depends on / unblocks

Depends on **D19** having shipped the mechanism it proves: the `continuum-view-<tileId>`
grouped-session attach and the `select-window` pinning call. Without those helpers in
`TmuxSession.swift`, the check has no real production path to drive. Depends on **D25**
target-capture for the `%pane_id` that `select-window` is given as its pin target — the
check must use a real, persisted pane id, not a hand-crafted one. Depends on the **D26**
injectable substrates work for `TmuxLocator`, `ProcessTmuxControl`, and the fake used by
the pure logic suite.

It unblocks the **D20** deliberate shared-view path: that work's "done when" criteria
require the no-mirror check to be in place and passing, so the exemption cannot regress
the invariant silently. Because the exemption verdict already lives in `i2Verdict` and is
driven by declared intent, D20 wires the same fn into the live `select-window` path and
confirms this check still reads `i2Distinct: true` for the non-exempt case and
`sharedViewExemptionCorrect: true` for both exemption outcomes.

## Watch out for

**The hardest thing: `window_id` versus `pane_id` versus `window_index`.** tmux has three
stable-looking identifiers that are easily confused. `%pane_id` (e.g. `%7`) is the pane
identifier — stable for the pane's lifetime, used in `select-window -t session:%7`.
`window_id` (e.g. `@3`) is the window identifier — stable for the window's lifetime, used
in `display -p '#{window_id}'`. `window_index` (e.g. `1`) is the window's position in the
session's window list — it renumbers when other windows close and must never be used for
binding. This check must use `#{window_id}` in the `display` format string, not
`#{window_index}`, and must pass the pane id (`%N`) to `select-window -t`. Mixing these up
produces a check that appears to pass but asserts on a value that silently changes when any
window closes. `isValidPaneId` validates the `%` prefix on the pane-id side;
`isValidWindowId` (owned by this ticket, in `TmuxSession.swift`) validates the `@` prefix
on the window-id side; **the breadcrumb asserts both before any comparison** — the
acceptance criteria and the reference implementation agree on this.

**Equal observed targets are not the exemption.** The exemption is D20's *deliberate*
shared view, decided by **declared intent**, not by observing that two windows match. An
accidental mirror also yields equal observed targets, and it is a **violation**. Route the
verdict through `i2Verdict(intendedA:intendedB:observedA:observedB:)`; never write `let
isSharedView = (activeA == activeS)` — that tautology proves nothing and would silently
pass an accidental mirror.

**The `select-window` call must complete before the `display` read.** tmux processes
commands in order within a session, but if `ProcessTmuxControl` issues two calls in quick
succession without waiting for each to exit, the read may land before the pin.
`ProcessTmuxControl` must call `Process.waitUntilExit()` after each subprocess — if the
existing implementation already does this, verify it; if not, this check produces a flaky
result that appears to fail on fast machines.

**Grouped sessions and the `-d` flag interaction.** When creating a grouped view session
with `new-session -t <project> -s <view>`, omit `-d` if the session creation needs to be
immediate and active. `-d` creates the session without a client; `select-window` still
works, but subsequent `display` calls require the session to exist server-side regardless
of client attachment. Verify the D19 `new-session` call does not suppress server-side
session creation with flags that only make sense in client-attach mode.

**Cleanup races on assertion failure.** If the check asserts mid-way — e.g. after creating
view session A but before B — the `defer` block must still attempt to kill all view session
names, even those never created. `kill-session` on a non-existent session errors; the
`defer` block must use `try?` per cleanup call so a missing session cannot mask the
original failure. The check failure should propagate via a thrown error the outer harness
catches (or via `expect`, which already `exit(1)`s with a message), so the `defer` block
fires normally.

**Do not run this check in the main matrix on hosts without tmux as if it were coverage.**
The check skips cleanly (partial manifest, `tmux_absent: true`), but a skip in every CI run
creates a false sense of permanent coverage. At least one CI configuration — the overnight
or nightly job — must run on a host with tmux available, and the orchestration runbook must
include a step that verifies the no-mirror manifest is present and both `i2Distinct: true`
and `sharedViewExemptionCorrect: true` in that run's artifacts. A check that always skips
is no check at all.
