# Project session naming & lifecycle ownership

> **RULING (C-20260702-010, 2026-07-02, Fable orchestrator) — resolves an internal contradiction.**
> The "Done when" item requiring the controller backend check to pass via the existing
> self-check-suite pattern conflicts with the "No change to `ContinuumApp.swift`" fence: every
> sibling self-check (`runHydrationLifecycleSelfCheck`, `runSaveIsolationSelfCheck`) is gated by a
> `CommandLine` flag handler in `ContinuumApp.swift` plus a `run_app_check` line in
> `scripts/run-matrix.sh`, and an unwired check gates nothing. The fence is to be read as guarding
> the spawn/attach/kill paths and descriptor types only. **Check-only wiring is REQUIRED, not
> forbidden:** add an `--zone-project-session-naming-check` flag handler in `ContinuumApp.swift`
> mirroring the two siblings, and a matching `run_app_check .build/debug/continuum-revived
> --zone-project-session-naming-check` line in `scripts/run-matrix.sh` next to the other zone
> self-checks. No other `ContinuumApp.swift` change is permitted by this ruling.

## What this delivers

After this ticket lands, every new tmux session created for a project zone carries the
name `continuum-proj-<projectId>` instead of `continuum-<tileId>`. The `ZoneRuntimeController`
becomes the unambiguous authority for that session's lifecycle — it is the only code allowed
to name, create, or issue lifecycle commands against a project session. Nothing yet changes
how tiles spawn (that is the window-creation work that follows this one), but the vocabulary
and the ownership model are locked, the old single-tile naming function is retired, and a
suite of pure Core checks proves the invariants hold before any tmux daemon is touched.

The system outcome is that future topology work has exactly one place to look for "what is
this project's session called?" and one controller to call for "detach/kill this session." The
chaotic `continuum-<uuid>` names that today conflate tile identity with session identity are
replaced by a stable, human-readable, project-scoped scheme whose semantics match what the
architecture document settled.

## How it fits

This ticket is the first step of Phase 1 (session topology) and rests directly on the
store-protocol seam established in the Phase 0 foundations work. The store seam is what makes
`projectId` a first-class, stable, addressable value at the layer where session names are
minted — without it, a session name would have to be derived from something mutable. No other
Phase 0 foundations work is a direct prerequisite. This ticket's checks need **no** injectable
substrate: the Logic checks call pure functions on fixed UUIDs, and the controller backend
check uses a real `ProjectStore` over a temporary directory (there is no in-memory
`ProjectStore` to inject — see "How we test it").

This ticket unblocks the two that immediately follow it: the new-window spawn work (which
needs `projectSessionName(projectId:)` to exist before it can form its `new-window -t` target)
and the grouped view-session de-mirror work (which needs the project naming settled before it
can produce `continuum-view-<tileId>` grouped onto the right base name). It also unblocks the
ambient-tile per-workspace session work, which needs `ambientSessionName(workspaceId:)` for
exactly the same reason.

## The approach

Two new static functions are added to `TmuxSession` in Core: `projectSessionName(projectId:)`
returning `"continuum-proj-<projectId.uuidString>"`, and `ambientSessionName(workspaceId:)`
returning `"continuum-ws-<workspaceId.uuidString>"`. The existing `sessionName(tileId:)`
function is **not deleted yet** — ambient tiles in phase 1 still fall through to the per-tile
path (option c from the topology spike), and the current kill path in `ContinuumApp` still
calls it. Deleting it would be a premature cleanup that breaks the ambient fallback before its
replacement exists. The naming change is surgical: a new function for a new concept alongside
the old one.

On the `ZoneRuntimeController` side, a single new method — `projectSessionName() -> String?`
— is added that returns the project session name for this controller's project. It reads
`self.project.id` and delegates to `TmuxSession.projectSessionName(projectId:)`. This method
is the authoritative one-stop call for any code that needs to know what a project's session is
called; no other code should construct a `continuum-proj-` name by hand. A companion
`killProjectSessionCommand(tmuxPath:)` method wraps the kill-session argv for the project
session in the same way that `TmuxSession.killSessionCommand(tileId:tmuxPath:)` does today for
tile sessions.

The lifecycle rule is encoded in documentation on the controller and in a Core check: on
`close()`, the project session is **detached, never killed**. Projects span workspaces;
`ZoneRuntimeRegistry.release(projectId:)` decrements the refcount and calls `close()` only at
zero — which means "no workspace currently shows this project," not "the project is being
deleted." A kill here would silently reap live agents during a workspace switch. The existing
`close()` body already issues no kill; this ticket adds a clear doc comment stating the policy
and a Core check asserting that the session name produced for a given `projectId` is stable and
deterministic.

No behavior change is introduced that affects a running app. All existing `continuum-<tileId>`
spawn and kill paths continue to work exactly as before.

## Where it lives

**`Sources/ContinuumRevivedCore/TmuxSession.swift`** — the entire file is 96 lines
(`TmuxSession.swift:1-96`). The existing `sessionName(tileId:)` lives at lines 8-10 and
`wrap(profile:tileId:tmuxPath:)` at lines 12-25. The two new static functions,
`projectSessionName(projectId:)` and `ambientSessionName(workspaceId:)`, are added to the
`TmuxSession` enum alongside the existing ones. A new static
`killProjectSessionCommand(projectId:tmuxPath:)` is added as the project-scoped counterpart of
the existing `killSessionCommand(tileId:tmuxPath:)` at lines 27-29.

**`Sources/ContinuumRevived/App/ZoneRuntimeController.swift`** — the class declaration and
`project` property are at lines 6-9; `close()` runs lines 78-94. A new instance method
`projectSessionName() -> String` and a new `killProjectSessionCommand(tmuxPath: String) ->
(command: String, arguments: [String])` are added to the class, reading `self.project.id` and
delegating to `TmuxSession`. A `// LIFECYCLE: detach, never kill — see docs/38-locked-decisions.md D16` comment is added above the `close()` body to permanently anchor the policy in the code.

No changes to `TileSpawner.swift`, `ContinuumApp.swift`, or any descriptor type in this
ticket. Those are touched by the window-creation work that follows.

## Implementation breadcrumbs

In `TmuxSession` (Core, pure, no imports needed beyond Foundation):

```swift
// New — project session name (phase 1+)
public static func projectSessionName(projectId: UUID) -> String {
    "continuum-proj-\(projectId.uuidString)"
}

// New — ambient/workspace session name (phase 1 fallback promotion)
public static func ambientSessionName(workspaceId: UUID) -> String {
    "continuum-ws-\(workspaceId.uuidString)"
}

// New — project-scoped kill-session argv (mirrors the existing tileId variant)
public static func killProjectSessionCommand(projectId: UUID, tmuxPath: String)
    -> (command: String, arguments: [String])
{
    (command: tmuxPath,
     arguments: ["kill-session", "-t", projectSessionName(projectId: projectId)])
}
```

In `ZoneRuntimeController`:

```swift
// New convenience — the single authoritative call site for the project session name
func projectSessionName() -> String {
    TmuxSession.projectSessionName(projectId: project.id)
}

// New convenience — the project-scoped kill argv; callers must never issue this
// on a mere release — only on deliberate project deletion (see D16)
func killProjectSessionCommand(tmuxPath: String) -> (command: String, arguments: [String]) {
    TmuxSession.killProjectSessionCommand(projectId: project.id, tmuxPath: tmuxPath)
}
```

Above `close()` in `ZoneRuntimeController`, add exactly this comment block and leave the body
unchanged:

```swift
// LIFECYCLE POLICY (D16 — locked):
//   project release (refcount → 0): DETACH, never kill.
//   Projects span workspaces; killing here would reap live agents on workspace switch.
//   kill-session is reserved for explicit project deletion only.
func close() {
    // ... existing body unchanged ...
}
```

The Core check for naming lives in `ContinuumRevivedCoreChecks` (or the nearest existing
check target — mirror the pattern used by the store-protocol seam work). It is table-driven:
a fixed set of UUID pairs, each asserting that `projectSessionName(projectId:)` produces the
exact expected string, that two distinct UUIDs never produce the same name, and that the
ambient variant produces a distinct prefix. No tmux daemon, no disk I/O, no `TmuxControl`
injection needed — the functions are pure.

## How we test it

### Logic (pure Core checks)

A table-driven check in `ContinuumRevivedCoreChecks` asserts:

1. `TmuxSession.projectSessionName(projectId: id)` returns exactly
   `"continuum-proj-\(id.uuidString)"` for three fixed UUIDs. The string is compared
   character-for-character — no substring matching.
2. Two distinct project IDs produce two distinct session names (no collision).
3. `TmuxSession.ambientSessionName(workspaceId: id)` returns exactly
   `"continuum-ws-\(id.uuidString)"` and is distinct from the project name for the same UUID
   value — the prefix difference is load-bearing.
4. `TmuxSession.killProjectSessionCommand(projectId: id, tmuxPath: "/usr/bin/tmux").arguments`
   equals `["kill-session", "-t", "continuum-proj-\(id.uuidString)"]` exactly.
5. The existing `sessionName(tileId:)` still returns `"continuum-\(id.uuidString)"` — the
   per-tile path has not been broken.

All five checks produce measured-value manifests (the actual string vs the expected string),
never `{passed: true}`.

### Backend (real-path / integration)

This ticket introduces no behavior change to spawn, attach, or kill paths, so no real-tmux
integration check is introduced here. The integration check for "project session is created
with the right name" belongs to the new-window spawn work that follows. What this ticket does
owe the backend tier: a check that constructs a real `ZoneRuntimeController` and calls
`controller.projectSessionName()`, asserting it matches
`TmuxSession.projectSessionName(projectId: controller.project.id)`. This exercises the
controller convenience method end-to-end without a live tmux daemon.

**The substrate is a real temporary directory — there is exactly one path and it uses only
things that exist today.** There is no injectable/in-memory `ProjectStore`: `ProjectStore` is
a plain `struct` (`Sources/ContinuumRevivedCore/ProjectStore.swift:76`), not behind a
protocol, and no fake store exists anywhere in `Sources`. So the check does **not** wait on
any Phase 0 store-protocol seam. It constructs the controller through the existing
lock-free initializer `init(projectRoot:projectStore:project:)`
(`ZoneRuntimeController.swift:71`) — the one that takes an explicit store and project and
acquires no `ProjectLock` — against a `ProjectStore(projectRoot:)` rooted at a freshly-created
`FileManager.default.temporaryDirectory` subdirectory (removed at the end of the check). The
`Project` is created with a known `UUID` so the expected session name is
`"continuum-proj-<thatUUID.uuidString>"`, computed independently and compared
character-for-character. No `ProjectLock` is taken (the initializer skips it), no tmux is
touched, no daemon is spawned. The check is added to the existing controller self-check suite
(mirroring the pattern of `runHydrationLifecycleSelfCheck` and `runSaveIsolationSelfCheck` at
`ZoneRuntimeController.swift:291` and `:415`), which already build controllers against real
temp directories the same way.

The check also asserts that two `ZoneRuntimeController` instances built against two temp
directories with two distinct `Project` UUIDs produce two different session names, confirming
that the controller never falls through to a shared default. The manifest records both
measured session-name strings alongside their expected values.

### UX (visual gate + dogfood snippet)

This ticket ships no user-visible UX change — no new tile, no new status, no new UI surface,
**and no change to how any session is spawned or named at runtime.** `wrap()` is untouched and
still calls `sessionName(tileId:)`, so anything running in the real app — and any wrap trace —
still emits `continuum-<tileId>`. The visual gate must therefore assert what this ticket
*actually produces* (the new pure functions), not a spawn-path outcome this ticket does not
create. A wrap trace can never read `continuum-proj-<uuid>` after this ticket, so it is the
wrong instrument.

**Visual gate — Component Lab "session naming" panel that invokes the new functions
directly.** Add (or extend) a small Component Lab dev panel that calls the three new pure
functions on a fixed, visible UUID and prints their exact return strings as labels on screen.
With, for example, the fixed UUID `00000000-0000-0000-0000-000000000001`, the panel must show
exactly these three lines and nothing derived from a live tmux session:

```
projectSessionName  → continuum-proj-00000000-0000-0000-0000-000000000001
ambientSessionName  → continuum-ws-00000000-0000-0000-0000-000000000001
sessionName(tileId) → continuum-00000000-0000-0000-0000-000000000001
```

The gate passes iff those three labels read exactly as above — the `-proj-` and `-ws-`
prefixes are the load-bearing thing to eyeball. This is a one-line-per-function visual
confirmation of the code this ticket ships, decidable at a glance, no judgment call, and it
does not depend on any spawn wiring that does not exist yet.

**Dogfood snippet — one observable outcome, in the same Component Lab panel (not `tmux ls`).**
Because the spawn path is deliberately unchanged, `tmux ls` in a real terminal tile would show
`continuum-<tileId>` both before and after this ticket — it can never distinguish "shipped
correctly" from "did nothing," so it is not a valid dogfood check for this ticket. Instead:
build the app, open the Component Lab, open the "session naming" panel described above, and
read the `projectSessionName` label. The single outcome that proves this ticket landed
correctly is: **that label reads exactly `continuum-proj-00000000-0000-0000-0000-000000000001`
(the `-proj-` prefix present)**. If the label is absent, or reads `continuum-` without the
`proj-` segment, the new function is missing or wrong and the ticket is not done. There is no
"both outcomes are fine" branch — exactly one string is correct.

The `tmux ls`-in-a-terminal proof — seeing a live session actually *named*
`continuum-proj-<uuid>` — belongs to the new-window spawn work that follows this ticket, which
is the ticket that rewrites the spawn path. It is intentionally **not** part of this ticket's
verification, because this ticket does not touch that path.

## Execution mode

Autonomous. The changes in this ticket are pure naming functions (no I/O, no daemon, no
device) and a pair of convenience methods on a class whose lock-free initializer
(`ZoneRuntimeController.init(projectRoot:projectStore:project:)`, `ZoneRuntimeController.swift:71`)
lets a check build a controller against a real temp-directory `ProjectStore` with no lock and
no tmux. The Core check exercises every new function on fixed inputs and produces
deterministic, character-for-character output. The controller check constructs a real
controller over a temporary directory (there is no in-memory `ProjectStore` — see the backend
tier). The visual gate is a Component Lab panel that prints the new functions' exact return
strings, decidable at a glance. No human judgment is required: the naming invariants are fully
decidable by the check harness, the manifests carry measured values, and the existing
self-check suite patterns provide a clear template for how to wire them.

## Done when

- [ ] `TmuxSession.projectSessionName(projectId:)` exists in Core and returns
  `"continuum-proj-<uuid.uuidString>"` for any input UUID.
- [ ] `TmuxSession.ambientSessionName(workspaceId:)` exists in Core and returns
  `"continuum-ws-<uuid.uuidString>"` for any input UUID.
- [ ] `TmuxSession.killProjectSessionCommand(projectId:tmuxPath:)` exists and produces
  `["kill-session", "-t", "continuum-proj-<uuid>"]` as its `arguments`.
- [ ] `ZoneRuntimeController.projectSessionName()` exists, returns the correct string for
  `self.project.id`, and is the only place any caller should read a project session name.
- [ ] `ZoneRuntimeController.killProjectSessionCommand(tmuxPath:)` exists and delegates
  correctly to `TmuxSession`.
- [ ] The `// LIFECYCLE POLICY (D16 — locked)` comment block is present above `close()`.
- [ ] All five naming/kill-argv Logic checks pass with measured-value manifests.
- [ ] The controller backend check passes: a `ZoneRuntimeController` built via the lock-free
  `init(projectRoot:projectStore:project:)` against a real temp-directory `ProjectStore`
  asserts name agreement between the controller convenience and the static function, and name
  distinctness across two controllers with two distinct project UUIDs.
- [ ] The Component Lab "session naming" panel prints the three new/existing functions' exact
  return strings for a fixed UUID, and the `projectSessionName` label reads
  `continuum-proj-<uuid>` with the `-proj-` prefix present (visual gate + dogfood proof).
- [ ] The existing `sessionName(tileId:)` function and all callers compile and pass their
  existing checks unchanged — no ambient or per-tile behavior is broken.
- [ ] No change to `TileSpawner.swift`, `ContinuumApp.swift`, or any descriptor type.

## Depends on / unblocks

This ticket depends on the store-protocol seam (the Phase 0 work that establishes
`projectId` as a stable, reachable identity at the Core layer). It does **not** depend on any
injectable/in-memory `ProjectStore`: none exists (`ProjectStore` is a plain `struct` at
`ProjectStore.swift:76`, not behind a protocol), so the controller backend check is built the
one way that is verifiably available today — a real `ProjectStore(projectRoot:)` over a
temporary directory, constructed through the lock-free
`ZoneRuntimeController.init(projectRoot:projectStore:project:)` at
`ZoneRuntimeController.swift:71`. There is no alternative substrate and no open choice.

This ticket unblocks the new-window spawn work (which forms its `-t` target from
`projectSessionName(projectId:)`), the grouped view-session de-mirror work (which names its
grouped sessions against the project session name), and the ambient per-workspace session
work (which calls `ambientSessionName(workspaceId:)`). None of those three can be started
without a settled naming API.

## Watch out for

**The `sessionName(tileId:)` function must not be deleted in this ticket.** The per-tile kill
path in `ContinuumApp.swift:3108-3119` still calls it; the ambient fallback still produces
`continuum-<tileId>` names. Deleting it here would break compilation across multiple call
sites before their replacements exist. Leave it in place; the window-creation and de-mirror
work will migrate each call site surgically.

**The session name must embed `uuidString` verbatim, not a truncated or lowercased variant.**
tmux session names are case-sensitive and must survive a round-trip through `tmux ls` output
parsing. Any normalization (trimming, lowercasing, truncating) will cause the
dead-target-fallback liveness probe (`tmux display -p -t <name>`) in later tickets to silently
miss the session. The check must compare the full, exact string.

**`killProjectSessionCommand` must never be called from `ZoneRuntimeController.close()`.**
`close()` is triggered by a release (refcount → 0) and must only detach. If an implementer
is tempted to add a "clean up on close" kill here — because it looks tidy — that is exactly
the bug that would silently reap a long-running agent the moment its last workspace tab
switches away. The `// LIFECYCLE POLICY` comment block is there to be read before touching
`close()`. Stop condition: if the check sees a `kill-session` of a `continuum-proj-` name
issued during a simulated `close()` call, mark the implementation as failing.
