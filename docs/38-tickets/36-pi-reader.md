# Pi reader: locate by runId and read status.json

## What this delivers

After this ticket lands, the agent-awareness system can hand a `runId` to a Pi reader and
get back an `AgentSnapshot` — a body-free, I5-clean metadata bundle carrying the derived
`AgentStatus`, the role label, the `asOf` evidence clock, and the source proof string. That
snapshot feeds `AgentDescriptor.status` on the tile, which is the field the entire UI
(sidebar tree, zone-chrome rollup, activity dock) already consumes. A Pi run tile that was
previously stuck on `.configuring` or `.stale` becomes live-updating: its status turns
`working` while the run is in flight and `done` the moment `run.json` records it, without
anyone having to poll a terminal or declare state by hand.

From a system perspective, this is the first concrete implementation of the `AgentStateReader`
protocol, which makes the protocol real rather than speculative. Every later reader (Claude,
Codex) slots into the same interface with the same fixture harness, the same I5 assertions,
and the same I6 golden-table discipline.

## How it fits

The reader protocol — the thin contract with `detect`, `locate`, and `read` — is defined by the
reader-protocol seam. The Pi reader is the **first concrete conformance** of that
protocol. It builds directly on two things that already exist in the codebase: the
`RunArtifactsReader` and `RunArtifactsWatcher` types in
`Sources/ContinuumRevivedCore/RunArtifactsReader.swift` and `RunArtifactsWatcher.swift`,
which already handle reading `run.json` and `events.jsonl` from a run directory and watching
for changes with a debounced, rate-limited signature scan.

The Pi reader extends that existing machinery in two ways. First, it adds a proper locate step
that checks the project-local `.pi/agent-runs/<runId>/` root first, then falls back to
`~/.pi/agent-runs/<runId>/`, because Continuum's own harness writes project-local (as
confirmed in `Sources/ContinuumRevived/App/ContinuumApp.swift:3812` and
`Sources/ContinuumRevivedCore/HarnessRoleRun.swift:108`). Second, it adds a status-mapping
layer that translates the explicit `run.json` `.status` string into the shared `AgentStatus`
vocabulary, cross-checked by the tail of `events.jsonl` when the status is absent or
unrecognized.

This ticket is blocked by the reader-protocol seam because the protocol type and
`AgentSnapshot` struct live there. It unblocks the reader golden fixtures, which
replay recorded stores through all three readers in one harness, and indirectly unblocks the
SessionObserver, which calls locate-then-read in its per-tile loop.

## The approach

The Pi reader is a pure value type conforming to `AgentStateReader`. Its `detect` step checks
whether the `pane_current_command` string is `"pi"` — Pi sets `process.title` so its comm
value is reliably `pi`, not `node` (verified by observing 8 live Pi processes on disk). Its
`locate` step constructs the run directory URL from a `runId` by checking project-local first,
then the global `~/.pi/agent-runs/` root, returning `nil` if neither exists. Its `read` step
delegates `run.json` and `events.jsonl` parsing to the existing `RunArtifactsReader`, then
runs the status-mapping table to produce an `AgentSnapshot`.

Because Pi is the only agent among the three that carries an **explicit first-class status
field** in `run.json`, the mapping is the most straightforward and least guess-dependent of
the three readers. The `run.json` `.status` string is the primary signal; `events.jsonl` tail
is the cross-check and fallback. The reader does not read `output.json`, `final.md`,
`summary.md`, or any other body file — those are out of scope per the I5 privacy rule.

The watch discipline is inherited from `RunArtifactsWatcher` without modification: the
existing watcher already watches a `rootURL` directory for per-runId signatures, debounces at
250 ms (the configurable `debounceInterval`), and rate-limits reads with `maxReadsPerSecond`.
The Pi reader does not reimplement this; the SessionObserver drives an instance
of `RunArtifactsWatcher` configured to the project-local `.pi/agent-runs/` root, and the
reader's `read` method is what the watcher calls on each dirty runId.

The `asOf` field in `AgentSnapshot` is always set to the **file mtime of `run.json`**, not
`Date.now()`. This is mandatory per the configurable-first and TDD doctrines: the clock must
be injectable and deterministic, and wall-clock `Date()` is banned in the status hot path. The
status-mapping thresholds (`freshWorkingWindow`, `idleWindow`, `staleWindow`) are
user-configurable with persisted defaults and Settings entries — the reader accepts them as a
`Configuration` struct so they are never hardcoded.

The full status-mapping table is described in the implementation breadcrumbs section.

## Where it lives

**New file** — `Sources/ContinuumRevivedCore/PiAgentStateReader.swift`.

This file defines `PiAgentStateReader: AgentStateReader`, which is a value type with no
stored mutable state. All disk I/O routes through the same `FileManager` the injected
`RunArtifactsReader` already uses, keeping it testable.

**Existing files touched:**

- `Sources/ContinuumRevivedCore/AgentStatusEngine.swift` — no changes needed in this ticket.
  The reader does not interact with `AgentStatusEngine` directly; the SessionObserver (a
  later ticket) is the integration point.
- `Sources/ContinuumRevived/Canvas/RunArtifactsTileNSView.swift` — no changes in this ticket.
  This view currently reads `RunArtifactsSnapshot` directly; once the observer is wired it
  will be updated to consume `AgentSnapshot`, but that belongs to the activity surface tickets.
- `Sources/ContinuumRevivedCore/RunArtifactsReader.swift` — the reader delegates to the
  existing `RunArtifactsReader.readRunJSON(at:)` and `RunArtifactsReader.readEventsJSONL(at:)`
  static methods. No changes to those methods; they already do the right thing.
- `Sources/ContinuumRevivedCore/RunArtifactsWatcher.swift` — `RunArtifactsWatcher` is reused
  as the watch engine by the future observer. No structural changes in this ticket.
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:94` — `AgentDescriptor.runId`
  is the field the reader's `locate` step consumes. Already present and populated at spawn by
  `TileSpawner.swift:139-144` via `HarnessRoleRunBuilder.makeRunId(roleId:now:suffix:)` at
  `HarnessRoleRun.swift:73`.

**Test file** — `Tests/ContinuumRevivedCoreTests/PiAgentStateReaderTests.swift`.

The full fixture set lives under `Tests/Fixtures/agent-readers/pi/`.

## Implementation breadcrumbs

The types the reader depends on are defined in the reader-protocol seam. The
pseudo-code below assumes those types exist; treat them as the canonical interface.

```swift
// AgentStateReader protocol (from the reader-protocol seam):
//   func detect(processName: String) -> Bool
//   func locate(runId: String?, projectRoot: URL) -> URL?
//   func read(storeURL: URL, config: ReaderConfiguration, fileManager: FileManager) -> AgentSnapshot

public struct PiAgentStateReader: AgentStateReader {

    // DETECT — reliable because Pi sets process.title (verified: 8 live procs show "pi").
    // The meaningful negative is "node": node-shim agents (Codex is one) can surface
    // comm == "node", and detect must NOT claim those as Pi. "codex"/"claude" are also
    // rejected as any-other-agent inputs.
    public func detect(processName: String) -> Bool {
        processName == "pi"
    }

    // LOCATE — project-local first, then global ~/.pi
    // runId is the run-directory basename, e.g. "code-reviewer-20260611T124657Z-884e9d"
    public func locate(runId: String?, projectRoot: URL) -> URL? {
        guard let runId, !runId.isEmpty else { return nil }
        let projectLocal = projectRoot
            .appendingPathComponent(".pi/agent-runs", isDirectory: true)
            .appendingPathComponent(runId, isDirectory: true)
        if fileManager.fileExists(atPath: projectLocal.path) { return projectLocal }
        let global = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent-runs", isDirectory: true)
            .appendingPathComponent(runId, isDirectory: true)
        if fileManager.fileExists(atPath: global.path) { return global }
        return nil
    }

    // READ — delegate parsing to RunArtifactsReader; map to AgentSnapshot.
    // config.now is the INJECTED evidence clock (never Date()). The caller supplies it:
    // in production the SessionObserver constructs one ReaderConfiguration per observer
    // tick and threads config.now through every read on that tick; in the backend
    // real-path check (see "How we test it") the test injects config.now explicitly on
    // each read so the status transition is fully pinned.
    public func read(storeURL: URL, config: ReaderConfiguration, fileManager: FileManager) -> AgentSnapshot {
        let runArtifact = RunArtifactsReader.readRunJSON(
            at: storeURL.appendingPathComponent("run.json"))
        let events = RunArtifactsReader.readEventsJSONL(
            at: storeURL.appendingPathComponent("events.jsonl"))

        // asOf is the run.json file mtime — the only valid evidence clock for this reader.
        // MTIME-ABSENT CASE (run.json missing/unreadable): there is NO evidence timestamp,
        // so we do not invent one. asOf falls back to config.now (the injected clock — the
        // one value we know is real), and we short-circuit to .idle with evidence that
        // records the missing file. This is the honest I6 floor: no readable run.json means
        // no positive evidence, so never .working/.done. distantPast is deliberately NOT
        // used — it is neither the injected clock nor a real evidence timestamp, and it
        // would silently drive age past staleWindow rather than stating "no evidence".
        guard let mtime = mtime(of: storeURL.appendingPathComponent("run.json"),
                                fileManager: fileManager) else {
            return AgentSnapshot(
                kind: .pi,
                status: .idle,                       // no run.json ⇒ no positive evidence (I6)
                title: nil,
                mode: nil,
                asOf: config.now,                    // injected clock; the honest "as of when we looked"
                detail: nil,
                evidence: .init(
                    source: "pi:run.json:absent",    // falsifiable: evidence names the missing file
                    lastEventType: nil,
                    mtimeAgeSeconds: 0                // no age to compute against a nonexistent file
                )
            )
        }
        let asOf = mtime

        let status = deriveStatus(run: runArtifact, events: events, asOf: asOf, config: config)

        return AgentSnapshot(
            kind: .pi,
            status: status,
            title: runArtifact.task.map { String($0.prefix(80)) },   // truncate; never body
            mode: nil,                                               // Pi has no permission mode
            asOf: asOf,
            detail: nil,                                             // no reason string for single-shot
            evidence: .init(
                source: "pi:run.json",
                lastEventType: events.events.last?.type,
                mtimeAgeSeconds: config.now.timeIntervalSince(asOf)  // config.now = injected clock
            )
        )
    }
}
```

The status derivation function. Apply rules in order; the first match wins:

```swift
private func deriveStatus(
    run: RunArtifact,
    events: RunEventsArtifact,
    asOf: Date,
    config: ReaderConfiguration
) -> AgentStatus {
    // Rule 1 — stale clock beats everything (no working claim from an ancient file)
    let age = config.now.timeIntervalSince(asOf)
    if age > config.staleWindow { return .idle }   // "stale" as in "old but process may live"

    // Rule 2 — explicit terminal states in run.json
    switch run.status {
    case .done:    return .done
    case .failed, .killed: return .done          // terminal, surface via detail field later
    case .queued:  return .configuring
    case .running: break                         // fall through to cross-check with events
    case .unknown, .stale: break                 // fall through to events tail
    }

    // Rule 3 — events.jsonl tail cross-check
    // Last event determines in-progress vs idle
    let lastEventType = events.events.last?.type
    switch lastEventType {
    case "finished", "agent_end":
        return .done
    case "turn_start", "tool_execution_start", "message_start":
        // Open phase with no matching *_end and file is fresh → working
        if age <= config.freshWorkingWindow { return .working }
        return .idle
    case "turn_end", "tool_execution_end", "message_end":
        // Completed a phase; if run.status is running and file is fresh → working (between turns)
        if run.status == .running, age <= config.freshWorkingWindow { return .working }
        return .idle
    case "started", "session", "agent_start":
        return run.status == .running ? .working : .configuring
    default:
        break
    }

    // Rule 4 — endedAt-null heuristic: process alive inference
    // If run.json shows no endedAt and run.status is still .running → working
    if run.status == .running { return .working }

    // Rule 5 — unknown status with no clear tail → idle, never fabricate working (I6)
    return .idle
}
```

The `mtime` helper reads `URLResourceValues.contentModificationDate` — the same file attribute
`RunArtifactsWatcher.directorySignature` already reads for its signature. Use the same
`FileManager` instance so tests can inject a fake one.

```swift
private func mtime(of url: URL, fileManager: FileManager) -> Date? {
    let attrs = try? fileManager.attributesOfItem(atPath: url.path)
    return attrs?[.modificationDate] as? Date
}
```

The `ReaderConfiguration` struct (defined in the reader-protocol seam) carries `now: Date`
(injected, never `Date()`), `freshWorkingWindow: TimeInterval` (default 30 s),
`idleWindow: TimeInterval` (default 120 s), `staleWindow: TimeInterval` (default 900 s), and a
reference to a user-persisted `Settings` entry so the thresholds survive restarts. `now` is
the single evidence clock the whole reader consults: `read` uses it for the mtime-absent
fallback and for `evidence.mtimeAgeSeconds`, and `deriveStatus` uses it for every
`age = now − asOf` comparison. Who supplies `now` depends on who calls `read`. In production
the SessionObserver constructs one configuration per observer tick and threads it through, so
every tile read on that tick shares one clock. That observer is a later ticket — so for THIS
ticket the read() contract is exercised only by the fixture harness and the backend real-path
check, both of which inject `now` directly per read (the backend check states the exact value
it injects on each of its two reads, below). The reader itself is stateless and never reads a
wall clock.

## How we test it

### Logic (pure Core checks)

All tests in `PiAgentStateReaderTests.swift`, driven against fixture directories under
`Tests/Fixtures/agent-readers/pi/`. No daemon, no live disk, no real `Date.now()` — all
clocks injected via `ReaderConfiguration.now`.

**Fixture: `pi-done`** — `run.json` with `"status":"done"` and `events.jsonl` ending with a
`finished` event. Assert: `snapshot.status == .done`, `snapshot.kind == .pi`,
`snapshot.title` is a non-empty string truncated to ≤80 chars, `evidence.source == "pi:run.json"`.

**Fixture: `pi-working`** — synthesized `run.json` with `"status":"running"` and empty
`endedAt`, `events.jsonl` ending with `tool_execution_start` (no matching
`tool_execution_end`). Inject `config.now` at `asOf + 10 s` (within `freshWorkingWindow`).
Assert: `snapshot.status == .working`.

**Fixture: `pi-stale`** — same `pi-working` fixture but inject `config.now` at
`asOf + 1000 s` (beyond `staleWindow` of 900 s). Assert: `snapshot.status != .working` (must
not fabricate `working` from a stale file — I6).

**Fixture: `pi-configuring`** — `run.json` with `"status":"queued"`. Assert:
`snapshot.status == .configuring`.

**Fixture: `pi-runid-link`** — assert that `makeRunId(roleId: "code-reviewer", now: knownDate, suffix: "884e9d")` produces exactly `"code-reviewer-20260611T124657Z-884e9d"` (verifying the runId format matches the run-directory basename). Assert that `locate` checks project-local before global: give it a project root where the run dir exists locally, assert the returned URL is under the project root, not under `~/.pi`.

**Fixture: `pi-project-local-priority`** — both project-local and global run dirs exist for
the same runId (created in a temp directory). Assert `locate` returns the project-local URL.

**Fixture: `pi-not-found`** — `locate` receives a runId for which neither root has a
directory. Assert `locate` returns `nil`.

**Fixture: `pi-run-missing`** — a run directory that exists (so `locate` returns it) but whose
`run.json` is absent or unreadable, so `mtime` yields `nil`. Inject `config.now` at a known
date. Assert the mtime-absent branch: `snapshot.status == .idle` (no positive evidence — I6),
`snapshot.asOf == config.now` (the injected clock, never `Date.distantPast`),
`evidence.source == "pi:run.json:absent"`, `evidence.mtimeAgeSeconds == 0`, and
`snapshot.title == nil`. This pins the missing-file behavior so the branch is falsifiable.

**I5 taint check** — for every fixture, assert that no field of `AgentSnapshot` contains
a substring that was present in any body-adjacent field in the fixture files (task strings are
truncated, detail is nil, no content from `final.md` appears). Implemented as a
parameterized check over all fixtures.

**Round-trip (I7)** — for every fixture, encode the returned `AgentSnapshot` to JSON and
decode it back; assert `encoded == decoded`.

### Backend (real-path integration)

Drive the reader against a **real run directory on disk**, not a fixture. The run directory
must be created by the actual `HarnessRoleRunBuilder.processGroupControlScript` flow — either
a previously completed Pi run at `~/.pi/agent-runs/` or a freshly spawned short-lived run in
a temp project directory for the test.

The real-path check must:

1. Call `HarnessRoleRunBuilder.makeRunId(roleId:now:suffix:)` with a real date to generate a
   runId.
2. Create the run directory at `<tmpProjectRoot>/.pi/agent-runs/<runId>/` and write a minimal
   but structurally correct `run.json` and `events.jsonl` (not a fixture copy — the
   **actual file format** from a live or recently lived Pi run).
3. Call `PiAgentStateReader().locate(runId:projectRoot:)` and assert it returns the
   project-local URL.
4. Write `run.json` with `"status":"done"` and `events.jsonl` ending in `finished`. Call
   `PiAgentStateReader().read(storeURL:config:fileManager:)` with **`config.now` injected at
   the run.json mtime + 5 s** (well inside `staleWindow`, so the stale-clock rule does not
   fire and the explicit terminal status is honored). Assert `snapshot.status == .done` and
   `snapshot.asOf == <run.json mtime>`.
5. Mutate `run.json` to `"status":"running"` (which re-touches the file, advancing its mtime),
   then re-read the mtime and call `read` again with **`config.now` injected at the new mtime
   + 5 s** (again inside `freshWorkingWindow`, so a fresh running file maps to working). Assert
   `snapshot.status == .working`. Injecting `config.now` explicitly on each read is what pins
   the transition: the first read's clock is tied to the done-file mtime and the second read's
   clock to the running-file mtime, so the expected `done → working` transition is fully
   determined and cannot silently depend on wall-clock time between the two reads.

This check is gated on a real `FileManager` and a real temp directory — no mocked
`FileManager`. It proves the reader survives the actual on-disk layout that Pi produces,
including the `control.json` sidecar the `processGroupControlScript` writes.

### UX (visual gate + dogfood)

The reader itself has no direct UI surface — it is a Core type. The visual gate belongs to
the SessionObserver integration and the mock-rollup replacement, which are later tickets.
However, the dogfood check for this ticket is:

Open the app. Navigate to a tile running a live Pi agent (use the harness to spawn one from
the role picker if needed — menu `Workspace > Run Agent Role...`). With Xcode attached,
set a breakpoint in `PiAgentStateReader.read(storeURL:config:fileManager:)`. Confirm the
breakpoint is hit when the tile's status is refreshed, that `run.status` matches the
`run.json` on disk (`cat <projectRoot>/.pi/agent-runs/<runId>/run.json | python3 -m json.tool
| grep status`), and that the returned `AgentSnapshot.status` maps correctly. This is
sufficient to prove the reader's locate and read paths hit real disk without needing the full
observer wired. Once the mock-rollup replacement is landed, the full visual gate is: open the
app, spawn a Pi run, watch the tile header transition `configuring → working → done` without
any manual status declaration.

## Execution mode

**Autonomous.** The reader is a pure value type with no UI, no network, and no daemon
dependency. Its correctness is proven entirely by core golden-fixture checks and the
real-path integration check, both of which run in the CI matrix without human eyes. The
derivation function is deterministic given injected clocks and fixture inputs. The only
thing that cannot be run headlessly is the dogfood step above, but that step is a
supplementary verification tool, not part of the merge gate — merge is gated on the logic
and backend checks passing the matrix. Execution mode is autonomous because the full
test evidence is machine-checkable with no visual or UX judgment required.

## Done when

- [ ] `PiAgentStateReader` exists in `Sources/ContinuumRevivedCore/PiAgentStateReader.swift`
      and conforms to the `AgentStateReader` protocol from the reader-protocol seam.
- [ ] `detect("pi")` returns `true`; `detect("node")` returns `false` (the meaningful negative —
      node-shim agents such as Codex can surface `comm == "node"`, and detect must not claim
      those as Pi); `detect("codex")` and `detect("claude")` also return `false`. The `node`
      case is the load-bearing assertion: it proves detect discriminates Pi (which sets
      `process.title` to `pi`) from the node-titled agents that actually appear on disk, not
      from a string that never appears.
- [ ] `locate` checks project-local `.pi/agent-runs/<runId>/` before `~/.pi/agent-runs/<runId>/`
      and returns `nil` when neither exists — proven by `pi-runid-link` and `pi-project-local-priority`
      and `pi-not-found` fixture tests.
- [ ] Status mapping passes all fixture assertions: `done` → `.done`, `running`+fresh-events →
      `.working`, `running`+stale-clock → not `.working`, `queued` → `.configuring`.
- [ ] `asOf` is set to `run.json` file mtime when run.json is readable, never `Date.now()` —
      proven by the injected clock in the fixture harness (the stale fixture test would fail if
      `Date()` were used). When run.json is **missing or unreadable** (no mtime), `read` returns
      `.idle` with `asOf == config.now` and `evidence.source == "pi:run.json:absent"`, never
      `Date.distantPast` — proven by the `pi-run-missing` fixture test.
- [ ] No body fields are read: `output.json`, `final.md`, `summary.md` are never opened — proven by
      the I5 taint check across all fixtures.
- [ ] `AgentSnapshot` round-trips through `Codable` (I7) — proven by the parameterized round-trip
      check.
- [ ] `title` is truncated to ≤80 characters — asserted in the fixture checks.
- [ ] The real-path backend check passes against a real run directory created in a temp project
      root, exercising both the locate and read paths against actual file I/O.
- [ ] All new tests pass the CI matrix with measured values in their manifests (no `{passed:true}`
      result shapes).

## Depends on / unblocks

The Pi reader depends on the reader-protocol seam, which defines the
`AgentStateReader` protocol, the `AgentSnapshot` struct, and the `ReaderConfiguration` type.
The reader also depends on the agentKind closed-enum ticket, because `AgentSnapshot`
carries `kind: AgentKind` and `.pi` must be a member of that enum.

The Pi reader is a prerequisite for the reader golden fixtures, which replay
all three readers through a unified fixture harness — the Pi reader must exist first so the
harness has something to run. It is also a prerequisite for the SessionObserver,
which calls `locate` and `read` in its per-tile polling loop. The reader's locate logic
also serves as a concrete test of the two-root convention that the harness itself established
— any future change to where the harness writes run directories must keep that locate order.

## Watch out for

**The two-root ordering is a correctness invariant, not a preference.** The locate step must
always check project-local before global, because Continuum's own harness writes
project-local and a user might have a same-named run in their global `~/.pi/agent-runs/` from
a different project. Getting this backwards produces silent mislinkage — the reader would
silently return an unrelated completed run as the live status. The `pi-project-local-priority`
fixture test exists specifically to catch a regression here.

**`run.json` `.status` enum values beyond the verified set are real.** Only `done`, `running`,
and `stopped` (overnight) have been observed on disk. Any value outside
`{done, running, failed, killed, queued}` must be treated as unknown and fall through to the
events-tail heuristic, then to `.idle` — never to `.working`. I6 is violated the moment
an unrecognized value produces `working`.

**`events.jsonl` open phases must be bounded by the `freshWorkingWindow`.** The file
structure contains `turn_start` events with no matching `turn_end` whenever a run was
interrupted mid-turn. If the file is old (mtime beyond `freshWorkingWindow`) and the last
event is an open-phase marker, the correct answer is `.idle`, not `.working`. The stale
fixture test pins this behavior; removing that test or weakening its clock injection is a
stop condition.

**Do not read `output.json` or `final.md` for status.** Those files are body artifacts.
The only fields allowed from `run.json` are `id`, `role`, `status`, `task` (truncated),
`cwd`, `createdAt`, `updatedAt`, and `pid`. The I5 taint check in the fixture harness
enforces this at test time; if you add a new field read to the implementation, add a
corresponding taint assertion.

**The `control.json` sidecar is present in Continuum-spawned runs but not in standalone Pi
CLI runs.** Do not rely on it for status. It carries `processGroupId`, `pid`, and
`createdAt` — useful for liveness checks in the future, but out of scope for this ticket.
Read it only if the `SessionObserver` explicitly asks for it, not here.
