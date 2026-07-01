# Capture tmuxWindowTarget at spawn — the make-or-break seam

**Grounding:** `docs/2026-06-30-orchestration-spikes/TOPOLOGY.md`, `docs/2026-06-30-t3code-steal/04-orchestration-sessions-projections.md`, `docs/38-locked-decisions.md` (**D25**, D16, D26).

Rests primarily on **D25** ("Upgrade migration: start fresh project sessions … **bind via `tmuxWindowTarget` (`%pane_id`)**, captured-at-spawn"): D25 names this field the make-or-break seam and states "Capturing `%pane_id` at spawn is the seam that keeps I1/I8 intact — done lazily, restarts silently re-create windows." This ticket is the concrete implementation of that captured-at-spawn requirement. It also rests on **D16** (close tile = `kill-window`, project release = detach-never-kill) for who consumes the captured target downstream, and on **D26** (phase-0 harness: injectable substrates + the I1–I8 spine + the UX-testing contract) for the `TmuxControl` fake this ticket drives and the measured-manifest / real-path-plus-visual-gate contract its checks follow.

## What this delivers

After this ticket lands, every terminal tile that spawns in a project session has its
`%pane_id` — the tmux pane identifier that outlives every client detach and reattach —
captured synchronously and persisted to disk as `tmuxWindowTarget` on the
`TerminalSessionDescriptor`. Nothing about the existing spawn user experience changes: tiles
appear, ghostty forks, agents run. What changes is that the descriptor now records the
durable address of the tile's window in the shared session, making it possible for every
subsequent piece of the topology work to ask "which window belongs to tile X?" and get a
reliable, stable answer.

Without this field, N tiles sharing one project session are indistinguishable from each
other after any ghostty client teardown. The whole promise of durability — restart and land
in the right window, rebind to the right pane, close exactly the right window on tile delete
— depends on having this identity captured before anything can go wrong. Captured lazily
it becomes a race condition. Captured only in memory it evaporates on crash. Captured
synchronously at spawn and persisted immediately it is load-bearing.

## How it fits

This ticket builds directly on the "new tile = new-window" work, which changes the spawn
path from `tmux new-session -A -s continuum-<tileId>` to `tmux new-window -t
continuum-proj-<projectId> -P -F '#{pane_id}'`. That `-P -F '#{pane_id}'` flag is the
mechanism this ticket consumes: it causes tmux to print the new pane id to stdout, and this
ticket captures that output and writes it into the descriptor before the spawn function
returns. The two tickets are strictly ordered — there is nothing to capture until there is a
`new-window` command that emits the pane id.

In the other direction, almost everything downstream in the session topology phase depends
on this ticket. The dead-target recovery work needs a stored target to probe. The close-tile
work needs a target to pass to `kill-window`. The grouped-view session work needs the target
for `select-window`. The private managed-agent session record, which carries the window
target in its opaque `runtimePayload`, builds on this field as the source of the value it
stores. The injectable substrates work provides the fake `TmuxControl` that lets this
ticket's spawn path be driven without a real daemon in logic tests.

The schema change itself — adding `tmuxWindowTarget: String?` to the descriptor and bumping
`currentSchemaVersion` from 2 to 3 — is small and load-bearing. The decode path for v2
files uses `decodeIfPresent` so every session file on disk before this ticket lands loads
cleanly with `tmuxWindowTarget == nil`, which the fallback path in the rebind work then
handles correctly by creating a new window.

## The approach

The approach is: pre-create the tmux window out-of-band before the ghostty surface launches,
capture the pane id from that command's stdout, persist it synchronously in the descriptor,
and only then launch the ghostty surface pointed at the new window. This is the "pre-create
path" the topology spike identifies as cleaner for a deterministic target.

Concretely, the `new-window` call runs via `TmuxControl` — the injectable protocol from the
substrates work — with `-d` (detached, so no client attaches yet), `-t
continuum-proj-<projectId>`, `-c <cwd>`, `-P`, `-F '#{pane_id}'`. The trimmed stdout is the
pane id string, for example `%7`. That string is written into `descriptor.tmuxWindowTarget`
before `projectStore.saveSession(descriptor)` is called. If capturing the pane id fails —
the command errors, or the output is empty or malformed (does not begin with `%`) — the
spawn aborts and returns `.failure`, and the just-created window (if any) is cleaned up
with `kill-window -t <target>` as a compensating action. There must be no window without a
tile and no tile without a window target: atomicity is enforced by the compensating action,
not by tmux.

The ghostty surface's attach argv then becomes a grouped-session attach pointing at the
pre-created window (that is the de-mirror work's concern), or in the interim phase remains
the per-tile session as before, depending on which ticket lands first. This ticket's
responsibility ends at "target is captured and persisted." It does not change the ghostty
attach argv itself.

The schema bump: `currentSchemaVersion` moves from 2 to 3 in
`TerminalSessionDescriptor.swift:4`. The new property `public var tmuxWindowTarget: String?`
is added after `scrollback`. The `CodingKeys` enum gains `.tmuxWindowTarget`. The custom
decoder uses `decodeIfPresent` for the new key, mirroring the existing `scrollback` pattern
at line 75.

For ambient tiles, where the spawn path is still the per-tile session fallback (the
per-workspace ambient session work is a later ticket), there is no project session and no
`new-window` invocation, so `tmuxWindowTarget` stays nil. That is correct: the fallback
`continuum-<tileId>` per-tile path does not need a window target because the session name
alone is sufficient to rebind.

## Where it lives

**Primary seam — the descriptor type:**

- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:4` — `currentSchemaVersion
  = 2`; bump to `3`.
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:21` — after `scrollback:
  String?`, add `public var tmuxWindowTarget: String?`.
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:37` — `init(...)` gains
  `tmuxWindowTarget: String? = nil` parameter; stored as `self.tmuxWindowTarget =
  tmuxWindowTarget`.
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:55-58` — `CodingKeys` gains
  `.tmuxWindowTarget`.
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:74-76` — decoder gains
  `tmuxWindowTarget = try container.decodeIfPresent(String.self, forKey:
  .tmuxWindowTarget)`.

**Primary seam — the spawn path:**

- `Sources/ContinuumRevived/App/TileSpawner.swift:151-215` — the private `spawnTerminal`
  function. This is where the pre-create-window + capture-pane-id logic inserts, between the
  `tmuxWrappedProfileIfAvailable` call at line 176-178 and the `TerminalSessionDescriptor`
  initializer at line 194. The captured pane id is passed into the descriptor initializer as
  `tmuxWindowTarget`.
- `Sources/ContinuumRevived/App/TileSpawner.swift:221-227` — `tmuxWrappedProfileIfAvailable`
  is the gating function for the tmux path; the pre-create call lives in the same gated
  block, using the same `tmuxPath` already resolved here.

**Supporting seam — TmuxControl protocol (from the injectable substrates ticket):**

- `Sources/ContinuumRevivedCore/TmuxControl.swift` (new, created by the substrates ticket)
  — the `run(arguments: [String]) throws -> String` or async equivalent that both the real
  impl (wrapping `Process`) and the in-memory fake implement. This ticket calls it with the
  `new-window` arguments and reads stdout.

**Supporting seam — TmuxSession (this ticket adds `newWindowArguments` + `isValidPaneId`):**

- `Sources/ContinuumRevivedCore/TmuxSession.swift:12-25` — the existing `wrap` function
  produces the `new-session -A` argv for ambient tiles and stays unchanged for the fallback
  path. This ticket adds a new `newWindowArguments(projectSessionName: String, cwd: String,
  innerCmd: [String]) -> [String]` static function producing the `new-window -d -t
  <projectSessionName> -c <cwd> -P -F '#{pane_id}'` argv, and a new `isValidPaneId(_ s:
  String) -> Bool` guard. The function takes a **pre-built** session name (a `String`), not a
  `projectId` — it does not construct the `continuum-proj-<projectId>` name itself. That
  construction is owned by `TmuxSession.projectSessionName(projectId:)`.

**Dependency seam — `TmuxSession.projectSessionName(projectId:)` (delivered by the project-session-naming ticket, not this one):**

- `Sources/ContinuumRevivedCore/TmuxSession.swift` — `projectSessionName(projectId: UUID) ->
  String` returning exactly `"continuum-proj-\(projectId.uuidString)"`. This is **created by
  the project-session-naming ticket** (which states it "unblocks … the new-window spawn work,
  which needs `projectSessionName(projectId:)` to exist before it can form its `new-window -t`
  target"). This ticket **calls** it to turn a `projectId` into the session name it passes into
  `newWindowArguments(projectSessionName:…)`; it does not define it. No `continuum-proj-` name
  is constructed by hand anywhere in this ticket's code.

**Dependency seam — the project id source (wired by the new-tile-new-window ticket):**

- `Sources/ContinuumRevived/App/TileSpawner.swift:45` — `terminalProjectContextProvider: (()
  -> ProjectEntry?)?`. The active project's UUID is `terminalProjectContextProvider?()?.id`
  (`ProjectEntry.id`, `Registry.swift:165`). This provider is wired to
  `activeZoneProjectEntry()` at `ContinuumApp.swift:2423-2425`, which resolves
  `canvasView?.activeZone?.projectId ?? workspaceRuntime?.activeController?.project.id`
  (`ContinuumApp.swift:6970`). When it returns `nil` (ambient zone, no active project) there
  is no project session, so this ticket skips the pre-create path and leaves
  `tmuxWindowTarget == nil`. This provider is already present on `TileSpawner`; the
  new-tile-new-window ticket is what threads it into the spawn dispatch, and this ticket
  consumes the resulting `projectId`.

## Implementation breadcrumbs

The key types and control flow, in order:

```swift
// In TmuxSession.swift — alongside the existing wrap function.
public static func newWindowArguments(
    projectSessionName: String,   // "continuum-proj-<projectId>"
    cwd: String,
    innerCmd: [String]            // [] for shell; [cmd, args...] for profiles
) -> [String] {
    var args = ["new-window", "-d",
                "-t", projectSessionName,
                "-c", cwd,
                "-P", "-F", "#{pane_id}"]
    if !innerCmd.isEmpty { args += innerCmd }
    return args
}

// Helper: validate the captured pane id string.
public static func isValidPaneId(_ s: String) -> Bool {
    s.hasPrefix("%") && s.dropFirst().allSatisfy(\.isNumber)
}
```

The capture logic is inserted **into the existing single `spawnTerminal` function**
(`TileSpawner.swift:151-215`) — there is no new `spawnWithTarget` helper. The insertion point
is between the `tmuxWrappedProfileIfAvailable` call (line 176-178) and the
`TerminalSessionDescriptor` initializer (line 194). A local `windowTarget: String?`, defaulting
to `nil`, is computed before the descriptor is built and threaded into it. When the pre-create
path is skipped (tmux disabled/unavailable, or no active project) the local simply stays `nil`
and the rest of `spawnTerminal` runs exactly as it does today.

```swift
// Inside the existing private spawnTerminal(...) — inserted between the
// tmuxWrappedProfileIfAvailable call (line 176-178) and the
// TerminalSessionDescriptor initializer (line 194). No new helper function.

// A single local carries the captured target; nil means "no window topology"
// (ambient / tmux off) and the existing spawn path is unchanged.
var windowTarget: String? = nil

// Pre-create only when tmux persistence is allowed AND a project is active.
// projectId comes from the wired provider (see "Where it lives") — not an invented seam.
if allowTmuxPersistence,
   TmuxPersistenceConfig.enabled(defaults: defaults),
   let tmuxPath = tmuxPathResolver(defaults),
   let projectId = terminalProjectContextProvider?()?.id {

    // 1. Turn the projectId into the shared session name via the project-session-naming
    //    ticket's helper (this ticket does NOT construct the name by hand).
    let sessionName = TmuxSession.projectSessionName(projectId: projectId)

    // 2. Pre-create the window out-of-band via the injectable TmuxControl (from the
    //    substrates ticket, D26). tmuxPath is the resolved binary; the fake ignores it.
    let newWindowArgs = TmuxSession.newWindowArguments(
        projectSessionName: sessionName,
        cwd: launchProfile.cwd,
        innerCmd: shouldPassInnerCommand(profile) ? [profile.command] + profile.arguments : []
    )
    let rawOutput: String
    do {
        rawOutput = try tmuxControl.run(arguments: newWindowArgs)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return .failure(error)   // tmux daemon absent or session not yet created
    }

    // 3. Validate the captured pane id. Malformed => nothing to clean up.
    guard TmuxSession.isValidPaneId(rawOutput) else {
        return .failure(SpawnError.invalidPaneId(rawOutput))
    }
    windowTarget = rawOutput   // e.g. "%7"
}
// If any condition above is false, windowTarget stays nil and we fall through.

// 4. Build descriptor with the captured target (nil for ambient / tmux-off tiles).
let descriptor = TerminalSessionDescriptor(
    id: runtime.id,
    tileId: tile.id,
    // ... all existing fields, unchanged ...
    tmuxWindowTarget: windowTarget
)

// 5. Persist synchronously before returning. On failure, compensate iff a window exists.
do {
    try projectStore.saveSession(descriptor)
    try projectStore.saveCanvas(canvasView.canvasState)
} catch {
    // Compensating action fires ONLY when a window was actually created.
    if let target = windowTarget {
        try? tmuxControl.run(arguments: ["kill-window", "-t", target])
    }
    return .failure(error)
}
// 6. Launch ghostty surface. The attach argv is the responsibility of the
//    de-mirror ticket (D19); for now the existing per-tile session attach continues.
return .spawned(runtime)
```

> **Consistency note.** The new-tile-new-window ticket refactors this same
> `tmuxWrappedProfileIfAvailable` chokepoint (adding a `projectId: UUID?` parameter and
> returning `(profile, windowTarget)` via `TmuxControl.newSession`/`newWindow`). This ticket's
> concern is strictly *capture-and-persist* of the resulting `%pane_id`; whichever of the two
> lands second inserts its half into the single `spawnTerminal` body shown here rather than
> introducing a parallel helper. The load-bearing contract — pre-create → capture → validate →
> persist-before-launch, compensate on save-failure — is identical either way.

```swift
// In TerminalSessionDescriptor: the flush path must preserve tmuxWindowTarget.
// In flushTerminalSessionSnapshot (TileSpawner.swift:393-407), the rebuilt descriptor
// must copy existing.tmuxWindowTarget — it must NOT overwrite it with nil.
let descriptor = TerminalSessionDescriptor(
    id: existing.id,
    tileId: tileId,
    ...
    tmuxWindowTarget: existing.tmuxWindowTarget   // preserve the captured target
)
```

## How we test it

### Logic (pure Core checks)

Write these checks in `ContinuumRevivedCoreChecks` against the real `TerminalSessionDescriptor`
type and the real `TmuxSession` static functions; no daemon, no app, no ghostty:

1. **Schema round-trip.** Construct a descriptor with `tmuxWindowTarget = "%7"`, encode to
   JSON, decode, assert the field round-trips to `"%7"`. Construct a v2 JSON fixture (the
   literal JSON of a descriptor without the `tmuxWindowTarget` key at all — hand-built in
   the test), decode it, assert `tmuxWindowTarget == nil` and no decode error. This proves
   both the new path and backward compatibility in one table-driven test.

2. **Pane id validation.** Table-driven check of `TmuxSession.isValidPaneId`: `"%0"` →
   true, `"%42"` → true, `"%"` → false, `"0"` → false, `"@5"` → false, `""` → false,
   `"% 3"` → false. Every row is a `(input, expected)` pair; the check asserts all of them.

3. **newWindowArguments shape.** Call `TmuxSession.newWindowArguments(projectSessionName:
   "continuum-proj-AAAA", cwd: "/tmp/proj", innerCmd: [])` and assert the resulting array
   contains `"-d"`, `"-P"`, `"-F"`, `"#{pane_id}"`, the session name after `-t`, and the
   cwd after `-c`, in the correct positions. Repeat with a non-empty `innerCmd` and assert
   the command appears at the end. No daemon.

4. **Flush preserves target.** Build a descriptor with `tmuxWindowTarget = "%3"`, run the
   flush transformation (the pure part: rebuild the descriptor from `existing`), assert
   `tmuxWindowTarget` is still `"%3"` in the output. This catches any future flush rewrite
   that accidentally zeros the field.

### Backend (real-path / integration)

This check requires a real tmux daemon but not a running Continuum app. It uses the real
`TmuxControl` implementation (not the fake) and drives the spawn path through the injectable
seam.

The check:

1. Resolves a real tmux binary via `TmuxLocator.resolve()`. If nil, skip with a clear
   message ("tmux not available — skipping real-path check"). Do not fake the skip.
2. Creates a real project session: `tmux new-session -d -s continuum-proj-TEST` where `TEST`
   is a fresh UUID.
3. Calls `TmuxControl.real.run(arguments: TmuxSession.newWindowArguments(projectSessionName:
   "continuum-proj-TEST", cwd: "/tmp", innerCmd: []))` and captures the output.
4. Asserts `TmuxSession.isValidPaneId(output)` is true.
5. Probes liveness: `tmux display -p -t <captured_pane_id> '#{pane_id}'` — asserts it
   returns the same pane id (not an error), proving the window is alive.
6. Kills the test session: `tmux kill-session -t continuum-proj-TEST`.

The manifest records: `capturedTarget` (e.g. `"%5"`), `livenessProbeReturned` (same string),
`pass: true`. These are measured values, not `{passed: true}`.

Invariant I1 is partially proven here: a successfully captured and persisted target
corresponds to a live window. The full I1 proof (tile ↔ window bijection over the full
spawn/close/restart lifecycle) belongs to the close-tile and dead-target recovery tickets,
which build on this one.

### UX (visual gate + dogfood snippet)

There is no new visible UI in this ticket. The visual gate is therefore a **diagnostic
readout gate** rather than a rendered feature gate.

**Visual gate:** Add a temporary debug log line in the spawn path (removed before merge, or
behind a compile-time flag) that prints `[tmux] captured window target: %N for tile <uuid>`
to the Xcode console on each terminal spawn. The gate: open the app, spawn a terminal in a
project zone, observe the console. The exact string `captured window target: %` (with a
percent-prefixed number) must appear. If it does not appear, or if `tmuxWindowTarget` is
absent in the saved session JSON on disk, the ticket is not done.

**Dogfood snippet:** Open the app. Spawn two terminal tiles in the same project zone. In
the Finder, navigate to `~/Library/Application Support/Continuum/sessions/` (or wherever
`ProjectStore` writes session files — the path from `ProjectStore.sessionFile(id:)` at
`Sources/ContinuumRevivedCore/ProjectStore.swift:71`). Open the two most recently modified
`.json` files with any text editor. Each file should contain a `"tmuxWindowTarget"` key
with a distinct `"%N"` value — for example `"%4"` and `"%5"`. The two values must differ
(one window per tile). If either file lacks the key, or if both files show the same value,
the spawn path has a bug that must be fixed before this ticket is marked done.

## Execution mode

**Autonomous.** The logic checks (schema round-trip, pane-id validation, newWindowArguments
shape, flush preservation) are pure and deterministic — no daemon, no display, no human
judgment required. The real-path check drives a real tmux binary but is machine-verifiable:
it asserts the captured string is a valid pane id and that a live probe returns it. The
dogfood snippet is provided for completeness and for the implementer's own confidence, but
the autonomous check fully proves the behavioral contract without human eyes. No cloud
account, no iOS device, no approval flow is involved.

The one asterisk: the real-path check needs tmux installed on the CI host. If the CI matrix
does not have tmux, the check must skip with an explicit message rather than pass silently.
The skip-not-pass rule is non-negotiable; a bypassed real-path check does not count.

## Done when

- [ ] `TerminalSessionDescriptor.currentSchemaVersion` is 3.
- [ ] `TerminalSessionDescriptor` has a `public var tmuxWindowTarget: String?` property,
  included in the memberwise initializer with a default of `nil`, encoded/decoded under the
  key `tmuxWindowTarget` with `decodeIfPresent`.
- [ ] A v2 session JSON (no `tmuxWindowTarget` key) decodes without error with the field
  set to `nil`. Proven by the schema round-trip check.
- [ ] `TmuxSession` has a `newWindowArguments(projectSessionName:cwd:innerCmd:)` static
  function producing the correct `new-window -d -t … -c … -P -F '#{pane_id}'` argv.
- [ ] `TmuxSession` has a `isValidPaneId(_:)` static function returning true for `%N`
  strings and false for anything else.
- [ ] The private `spawnTerminal` path in `TileSpawner` pre-creates the tmux window,
  captures the pane id, validates it, and passes it into the descriptor initializer — all
  before `projectStore.saveSession` is called.
- [ ] On descriptor-save failure after window creation, the compensating `kill-window`
  fires. Proven by injecting a throwing `projectStore` in a logic test with the fake
  `TmuxControl`.
- [ ] `flushTerminalSessionSnapshot` copies `existing.tmuxWindowTarget` into the rebuilt
  descriptor rather than leaving it nil.
- [ ] All four logic checks pass (round-trip, validation table, argv shape, flush
  preservation).
- [ ] The real-path check passes against a real tmux daemon (or skips explicitly when tmux
  is absent).
- [ ] The dogfood snippet passes: two spawned tiles produce two distinct `%N` values in
  their on-disk session JSON files.
- [ ] No existing checks regress.

## Depends on / unblocks

This ticket depends on the "new tile = new-window" work having shipped the project-session
spawn path that produces a `new-window` command with `-P -F '#{pane_id}'` output. Without
that, there is no pane id to capture. That same ticket also wires the project-id source this
ticket reads (`terminalProjectContextProvider?()?.id` → `activeZoneProjectEntry()`), so the
pre-create path can tell a project zone from an ambient tile. It depends on the
**project-session-naming** work having delivered `TmuxSession.projectSessionName(projectId:)`
— this ticket calls that function to build the session name it hands to `newWindowArguments`
and never constructs a `continuum-proj-` name by hand. It also depends on the injectable
substrates work having delivered the `TmuxControl` protocol and its in-memory fake, which is
what makes the compensating-action test possible without a daemon.

It unblocks the dead-target recovery work, which needs `tmuxWindowTarget` present in the
descriptor to probe for liveness and fall back to a new window when the target is dead. It
unblocks the close-tile work, which uses the stored target to run `kill-window -t <target>`
rather than `kill-session`. It unblocks the grouped-view session (de-mirror) work, which
passes the target to `select-window` when pinning a view session. And it provides the
`tmuxWindowTarget` value that the private managed-agent session record stores in its opaque
`runtimePayload`.

## Watch out for

**The synchronous-persist requirement is the hardest thing in this ticket.** The entire
point is that the target is on disk before any teardown can occur. Any refactor that moves
the pane-id capture to a later async callback, a deferred flush, or a lazy "capture on first
use" path breaks the I8 guarantee and the whole rebind story. If the ghostty surface is
already launched before the persist completes, a crash in that window destroys the binding.
The pre-create approach (create window, capture id, persist, then launch surface) is the
only ordering that is safe. Do not invert it.

**Window index vs pane id.** tmux window indices (`@N`) renumber when other windows close.
Only `%pane_id` is stable for the pane's lifetime. The `-F '#{pane_id}'` format string is
intentional and must not be changed to `#{window_index}` or `#{window_id}`. The validation
function `isValidPaneId` enforces the `%` prefix as a guard against accidentally storing
an index.

**Compensating action scope.** The compensating `kill-window` fires only when the window was
successfully pre-created but the descriptor save failed. It must not fire when the
`new-window` command itself fails (there is no window to kill). The control flow must track
whether a window was created before deciding whether to compensate.

**The flush path must copy, not reset.** `flushTerminalSessionSnapshot` rebuilds the entire
descriptor from `existing` and calls `projectStore.saveSession`. If the new initializer adds
`tmuxWindowTarget` with a default of `nil`, a naive copy that omits the field will silently
zero it on every flush. The flush must explicitly pass `tmuxWindowTarget:
existing.tmuxWindowTarget`. Add a logic check that catches this regression.

**Ambient tiles get nil.** Project zones go through the pre-create path and get a target.
Ambient tiles on the per-tile session fallback skip the pre-create path entirely and get
nil. This is correct and intentional. Code that later reads the target must handle nil
gracefully (fall back to the legacy per-tile session name, or treat nil as "no window
topology yet"). Do not add a force-unwrap or a precondition failure on this field.

**Schema version 3 is a one-way door.** Once shipped, every session file written by this
version or later will carry `schemaVersion: 3`. The decoder must remain tolerant of missing
keys for the new field (it does, via `decodeIfPresent`), but there is no downgrade path —
an older binary reading a v3 file will decode `schemaVersion: 3` and may produce a
warning or fail if the binary checks the schema version. Confirm the existing schema-version
handling in `TerminalSessionDescriptor` (currently at line 62: decoded but not validated
against `currentSchemaVersion`) and decide whether a version-mismatch warning should be
added here or deferred.
