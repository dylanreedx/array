# Lazy resume on tile focus — adopt, resume, fail honestly

## What this delivers

When a user focuses a tile that was previously live but whose process or tmux window has since
gone cold (after an app relaunch, a workspace switch, or natural idleness), the system silently
tries to recover that session on the spot — in the right order, without inventing state.
If recovery succeeds, the tile picks up exactly where it left off. If recovery fails because
there is genuinely nothing to resume, the tile surface shows an honest failure state and stops
there. Under no circumstances does the system eagerly pre-warm sessions at app launch, nor does
it silently spawn a fresh session as a fallback when a resume fails. The outcome is deterministic
and observable: the tile either becomes live again or reports the specific reason it could not.

From the system's perspective: the private managed-agent session record is the only authority
consulted. Focus events drive the three-branch recovery path lazily; nothing else does.

## How it fits

This ticket is the consumer of the private managed-agent session record established in the
preceding work. That record (keyed by tile id, carrying an opaque resume cursor and an opaque
runtime payload containing the captured tmux window target) is exactly what makes "adopt" and
"resume" possible without guessing: the record is the binding that connect a tile id to a
live or resumable process.

The foundation underneath is the `TmuxControl` protocol and its in-memory fake from the
injectable substrates work, which lets the adopt and resume branches be proven in a pure core
check with no real daemon.

This ticket unblocks the reattach-by-target acceptance contract (the next step in the topology
phase), which is the first real-tmux proof that I1 and I8 hold end-to-end. It also unblocks
the idle reaper, which needs the same `routableSession` entry point to confirm a session is
idle before reaping it. Nothing in Phase 2 or beyond depends on this ticket directly, but
it is the capstone of Phase 1's lifecycle story — without it, the private record is written
but never used.

## The approach

`ZoneRuntimeController` gains one new method, `routableSession(forTile:allowRecovery:)`, that
implements a strict three-branch decision in order. The branches mirror t3code's
`recoverSessionForThread` (`ProviderService.ts:355–429`) exactly, adapted to Continuum's tmux
substrate. The method returns a **`RoutableSessionOutcome` enum**, not a bare `LiveSession`
struct — because two of the outcomes (a live session, and "the reaper asked me not to recover
so there is nothing live") are genuinely different shapes and both must be well-typed. The enum
has exactly two cases: `.live(LiveSession)` (a real handle to a live window) and `.inactive`
(no live window, and none was created — the idle-reaper's expected answer). The two honest
failures — no record at all, and a record with no resume cursor — are `throw`n, not returned,
so they can never be mistaken for a live outcome. This is the concrete resolution of the
return-type contract: `.live` and `.inactive` are members of `RoutableSessionOutcome`; `LiveSession`
is the plain struct carried inside `.live`; nothing returns a bare `LiveSession`.

**Branch 1 — adopt existing.** If the tile's tmux window target (stored in the record's opaque
`runtimePayload`) is still alive in tmux right now — that is, a `tmux display-message` or
`list-panes` call against `%<pane_id>` returns successfully — the controller refreshes
`lastSeenAt` on the record and returns `.live(session)` with the live session handle. No
re-spawn, no re-attach dance. This is the common case after a brief app-foreground cycle. This
branch does **not** consult `allowRecovery` — an already-live window is adopted whether or not
recovery was requested.

**Branch 2 — no cursor, fail honestly.** If the window is dead and there is no persisted resume
cursor on the record (meaning the session was never fully started or the record was written in
an incomplete state), `throw SessionError.noResumeState` immediately. Do not attempt a
new-window spawn as a fallback. The caller surfaces this to the user as a named error; the tile
shows a stale/error indicator. (When `allowRecovery` is `false` — the idle reaper's pre-reap
check — a dead window short-circuits to `return .inactive` *before* this cursor check, because
the reaper is only asking "is anything live?", not "please recover".)

**Branch 3 — resume from cursor.** If the window target is dead but a resume cursor exists,
re-bind by calling `tmux new-window` in the project session (the same path as new-tile spawn,
from the new-tile-as-window work), persist the fresh window target back into the record's
`runtimePayload`, bump `lastSeenAt`, and return the new live session handle. The cursor itself
is opaque to this layer — it is handed back to the tile/reader layer, which interprets it
per-agent-kind (Claude `sessionId`, Pi `runId`, Codex rollout path).

The trigger lives on `FocusBroker.onAcceptedTileFocusWithReason` — already fired by both
`requestFocus` and `acceptExistingFocus` for every `.tile` focus event
(`FocusBroker.swift:91–93`), carrying the real `FocusRequest` reason. `ZoneRuntimeController.attachUI`
already sets this callback (`ZoneRuntimeController.swift:104`); this ticket extends it by
dispatching an async `routableSession` call when the focused tile id has a record in the
managed-agent store — but **only for the two reasons that mean "the user is actually turning
their attention to this tile."** `allowRecovery` is always `true` on such a focus event; it is
`false` only for the idle reaper's pre-reap check.

**Which `FocusRequest` reasons trigger recovery — decided exhaustively against the real enum
(`FocusModel.swift:38–47`), no guessing.** The enum has exactly eight cases; each is assigned a
verdict here so the guard is total, not "as appropriate":

| `FocusRequest` case | Fired by (real call site) | Trigger `routableSession`? | Why |
|---|---|---|---|
| `.userClick` | user clicks/selects a tile; keyboard-nav landing also arrives as `.userClick` (there is no `keyboardNav` case) | **Yes** | genuine user attention on the tile |
| `.appActivated` | app foreground after relaunch (`ContinuumApp`) | **Yes** | the core relaunch/re-adopt case this ticket exists for |
| `.tileSpawned` | brand-new tile creation (`ContinuumApp.swift:5929`, etc.) | No | a fresh tile has no cold session to resume; the spawn path owns it, and firing here would race the spawn |
| `.tileClosed` | focus recovering to a *survivor* after a close (`ContinuumApp.swift:2943`) | No | not a user interaction with the survivor; incidental focus, would spuriously query tmux |
| `.runtimeExited` | a runtime just died (`ContinuumApp.swift:2903, 2930`) | No | the exit is being handled; resuming here would fight teardown |
| `.modalOpened` | a modal took focus | No | not a tile interaction |
| `.modalDismissed` | modal closed, focus restored to a tile | No | a restore, not a user interaction; would add tmux latency to the close animation and could race an in-progress recovery |
| `.recovery` | internal focus-restore (`FocusBroker.swift:39, 147`) | No | explicitly internal, never user-driven |

So the guard triggers on exactly `{.userClick, .appActivated}` and skips the other six. There is
no `keyboardNav` case in the enum; keyboard-driven tile focus lands as `.userClick` through the
broker's `enterScope`, so it is already covered by the `.userClick` arm.

The three-branch function is an `async throws` method on `ZoneRuntimeController` returning
`RoutableSessionOutcome`. It takes an injected `TmuxControl` rather than calling the real tmux
directly, so the core check uses the in-memory fake without touching a daemon.

## Where it lives

**`Sources/ContinuumRevived/App/ZoneRuntimeController.swift`** — the primary implementation
site. At line 96–124 the `attachUI` method installs focus callbacks; the
`onAcceptedTileFocusWithReason` hook (already declared in `FocusBroker.swift:25`) is wired
here but not yet used for session recovery. Add:

- `func routableSession(forTile tileId: UUID, allowRecovery: Bool, tmux: TmuxControl) async throws -> RoutableSessionOutcome` — the new three-branch entry point, `async throws`, injecting `TmuxControl`. Returns `.live(LiveSession)` or `.inactive`; throws `SessionError.noBinding` / `.noResumeState` for the two honest failures.
- A private `func recoverRecord(_ record: ManagedAgentSessionRecord, tmux: TmuxControl) async throws -> LiveSession` — Branch 3 logic pulled into its own function for legibility and isolated testing.
- An extension to `attachUI` that wires `focusBroker.onAcceptedTileFocusWithReason` to call `routableSession` when the focused tile has a managed record; fire-and-forget the async call with a `Task { @MainActor in … }` wrapper; surface failure as a posted `SessionError` notification on the tile.

**`Sources/ContinuumRevived/App/TileSpawner.swift`** — owns `spawnTerminal` and
`restartTerminalTile` (around line 108 and 276 respectively). These remain the spawn path
for truly new sessions; this ticket does not touch them. The seam to be aware of: `restartTerminalTile` (line 276) follows a similar adopt-or-restart pattern for the view layer but does not consult the managed-agent record and does not have the no-cursor guard. That function is not modified here; `routableSession` sits above it and calls through to it only in Branch 3.

**`Sources/ContinuumRevivedCore/`** — `ManagedAgentSessionRecord` (new type, added by the
private-record ticket that precedes this one) lives here. This ticket's core check imports
it directly. `AgentStatus` (`TerminalSessionDescriptor.swift:85`) and `AgentDescriptor`
(`TerminalSessionDescriptor.swift:94`) are the existing vocabulary; this ticket does not add
new status values.

**`Sources/ContinuumRevived/App/FocusBroker.swift:25`** — `onAcceptedTileFocusWithReason:
((UUID, FocusRequest) -> Void)?` is the hook this ticket wires into. No changes to
`FocusBroker` itself.

## Implementation breadcrumbs

The central pattern, showing the types and call flow the implementer must follow:

```swift
// In ZoneRuntimeController

enum SessionError: Error {
    case noBinding          // record never written — tile was never a managed session
    case noResumeState      // record exists, window dead, and resumeCursor is nil
    case windowRebindFailed(underlying: Error)
}

struct LiveSession {
    let tileId: UUID
    let windowTarget: String   // the %pane_id in tmux — from runtimePayload
    let resumeCursor: Data?    // opaque; passed to the reader/adapter layer
}

// The well-typed result of routableSession. `.live` and `.inactive` are the two
// SUCCESSFUL shapes; the two honest failures (no record / no cursor) are thrown, never
// returned, so a caller can never treat a failure as a live handle. This is why the
// return type is an enum and NOT a bare LiveSession: the idle-reaper's "dead window, do
// not recover" answer has no LiveSession to return, and needs a first-class home.
enum RoutableSessionOutcome {
    case live(LiveSession)   // a real, live tmux window is bound to this tile
    case inactive            // no live window, and none was created (reaper's expected answer)
}

// Three-branch entry point. `tmux` is injected; the real impl passes TmuxControl.live,
// the core check passes TmuxControl.fake(…).
func routableSession(
    forTile tileId: UUID,
    allowRecovery: Bool,
    tmux: TmuxControl
) async throws -> RoutableSessionOutcome {
    // Guard: must have a record.
    guard let record = managedSessionStore.record(forTile: tileId) else {
        throw SessionError.noBinding
    }

    // Branch 1: adopt-existing — window still alive in tmux. Does NOT consult allowRecovery.
    let target = record.runtimePayload.flatMap { WindowTarget.decode(from: $0) }
    if let target, await tmux.windowIsAlive(target) {
        managedSessionStore.upsert(record.bumping(lastSeenAt: .now))
        return .live(LiveSession(tileId: tileId, windowTarget: target.rawValue,
                                 resumeCursor: record.resumeCursor))
    }

    // Window is dead below this point.
    // Reaper path: it only asks "is anything live?" — a dead window means .inactive,
    // and we must NOT recover or throw. This short-circuits BEFORE the cursor check.
    guard allowRecovery else {
        return .inactive
    }

    // Branch 2: window dead AND no cursor — cannot recover, fail honestly.
    guard record.resumeCursor != nil else {
        throw SessionError.noResumeState
    }

    // Branch 3: resume-from-cursor — window is dead but cursor exists.
    return .live(try await recoverRecord(record, tmux: tmux))
}

private func recoverRecord(
    _ record: ManagedAgentSessionRecord,
    tmux: TmuxControl
) async throws -> LiveSession {
    // Re-bind by spawning a new window in the project session.
    // This is identical to the new-tile-as-window path; reuse that helper.
    let newTarget: WindowTarget
    do {
        newTarget = try await tmux.newWindow(
            inSession: projectSessionName,   // "continuum-proj-<projectId>"
            cwd: record.runtimePayload.flatMap { RuntimePayload.decode($0)?.cwd }
                 ?? projectRoot.path
        )
    } catch {
        throw SessionError.windowRebindFailed(underlying: error)
    }

    // Persist the fresh window target back into runtimePayload, bump lastSeenAt.
    var updated = record
    updated.runtimePayload = RuntimePayload(
        cwd: record.runtimePayload.flatMap { RuntimePayload.decode($0)?.cwd } ?? projectRoot.path,
        tmuxWindowTarget: newTarget.rawValue
    ).encoded()
    updated.lastSeenAt = .now
    managedSessionStore.upsert(updated)

    return LiveSession(tileId: record.tileId, windowTarget: newTarget.rawValue,
                       resumeCursor: record.resumeCursor)
}
```

The `onAcceptedTileFocusWithReason` wire-up in `attachUI`:

```swift
focusBroker.onAcceptedTileFocusWithReason = { [weak self] tileId, reason in
    // Only attempt recovery on real user-driven attention: a click/keyboard-nav landing
    // (.userClick) or an app-foreground after relaunch (.appActivated). Every other real
    // FocusRequest case (tileSpawned, tileClosed, runtimeExited, modalOpened,
    // modalDismissed, recovery) is deliberately skipped — see the reason table above.
    // There is NO .keyboardNav case; keyboard-nav focus arrives as .userClick.
    guard reason == .userClick || reason == .appActivated else { return }
    Task { @MainActor [weak self] in
        guard let self else { return }
        do {
            _ = try await self.routableSession(forTile: tileId, allowRecovery: true,
                                               tmux: .live)
        } catch SessionError.noBinding {
            // Not a managed session — this is normal for shell tiles with no record. Ignore.
        } catch SessionError.noResumeState {
            // Post a named tile-level error so the surface can show a stale indicator.
            self.postSessionError(.noResumeState, forTile: tileId)
        } catch {
            self.postSessionError(.windowRebindFailed(underlying: error), forTile: tileId)
        }
    }
}
```

Key discipline: `SessionError.noBinding` is silent — it is the normal case for every non-managed
tile (browser, note, file-tree). Only `.noResumeState` and `.windowRebindFailed` surface as
tile-level indicators.

The `WindowTarget` type holds a `%pane_id` string and a static `decode(from: Data?)` that
returns `nil` on missing or malformed payload, rather than throwing — callers treat missing
as "window not yet known" and proceed to Branch 2/3 cleanly.

## How we test it

### Logic (pure Core checks)

Write a table-driven core check at `ZoneRuntimeControllerLazyResumeCheck` (a static `throws`
function like the existing `runHydrationLifecycleSelfCheck`). It uses `TmuxControl.fake` from
the injectable substrates work to control which window targets are "alive". The table covers:

- Record present, window alive → returns `.live` (with the adopted `LiveSession`), `lastSeenAt`
  bumped, `tmux.newWindow` never called.
- Record present, window dead, cursor present, `allowRecovery: true` → returns `.live`,
  `tmux.newWindow` called exactly once, new target persisted in record, the carried
  `LiveSession.resumeCursor` equals the original cursor value unchanged.
- Record present, window dead, cursor absent, `allowRecovery: true` → `SessionError.noResumeState`
  thrown, `tmux.newWindow` never called.
- Record present, window alive, `allowRecovery: false` → still returns `.live` from
  Branch 1 (adopt-existing does not consult `allowRecovery`).
- Record present, window dead, cursor present, `allowRecovery: false` → returns `.inactive`,
  no throw, `tmux.newWindow` never called (reaper short-circuit before the cursor check).
- Record present, `runtimePayload` nil (pre-payload record), cursor present, `allowRecovery: true`
  → `WindowTarget.decode` returns nil, falls through to Branch 3, `tmux.newWindow` called once,
  returns `.live` (asserts a nil payload does not crash the callback — see "Watch out for").
- Record absent → `SessionError.noBinding` thrown.
- `SessionError.noBinding` fired on a `.userClick` focus → no tile-error posted (silent).
- `SessionError.noResumeState` fired on a `.userClick` focus → tile-error posted.

Each assertion emits a measured-value manifest entry, not a boolean flag. The manifest is
written to `qa-runs/<timestamp>/lazy-resume/manifest.json` following the existing pattern in
`ZoneRuntimeController.runHydrationLifecycleSelfCheck`.

### Backend (real-path / integration)

The backend check is the reattach-by-target acceptance contract (the following ticket), which
runs against a real tmux daemon and asserts I1 and I8 end-to-end. This ticket's specific
contribution to that check:

Run a sentinel process in a real tmux window, capture its `%pane_id`, write a
`ManagedAgentSessionRecord` with that target and a non-nil cursor, then call
`routableSession(forTile:allowRecovery:tmux:.live)`. Assert that Branch 1 fires (no new window
created), `lastSeenAt` advances, and the returned `windowTarget` matches the original
`%pane_id`. Then kill the window, call again with the same cursor — assert that Branch 3 fires,
a new `%pane_id` is returned, the record's `runtimePayload` now contains the new target, and
the sentinel command from the cursor payload can be re-launched in the new window.

This check runs only in the matrix gate that has `CONTINUUM_REAL_TMUX=1` set, never on CI
without that flag.

### UX (visual gate + dogfood)

Visual gate: in the Component Lab, add a scenario named "tile-lazy-resume-states" that shows
three tiles side by side using scripted fixture records: one in the "resuming" transient state
(the async call is in-flight), one that resolved to live (normal chrome, no indicator), and one
in the "resume failed / stale" state (gray hollow status indicator for `AgentStatus.stale`).

The oracle is **code, not a screenshot** — so it is runnable, not aspirational. The stale
indicator in the scenario must be produced by calling the *same* status-render functions the
real surfaces already use, so it cannot drift from them:

- Glyph and color come from `AgentStatus.stale` → the existing render helpers
  `WorkspaceSidebarView.color(for:)` / `glyph(for:)` (`WorkspaceSidebarView.swift:570–588`,
  which return `.systemGray` and `◌` for stale) and, on the tile surface itself,
  `TileNSView`'s `color(for status: AgentStatus)` (`TileNSView.swift:892`, also `.systemGray`
  for stale). The
  scenario renders the stale tile by feeding `AgentStatus.stale` through these functions — it
  does not hard-code a gray value.
- The vocabulary these functions implement is defined in **`docs/38-ux-analysis.md`** (the "one
  status vocabulary" table, `:38–45`: `stale = ◌ hollow, gray .systemGray, no motion`). That
  is the human-readable spec; the two functions above are its executable form.

The gate passes when the scenario's stale indicator is rendered by those functions and its
color resolves to `.systemGray` with glyph `◌` — asserted directly against the function output,
not by pixel-diffing an external image. (There is intentionally **no** pre-existing
ComponentLab `AgentStatus` render to diff against; this scenario is the first one, and it grounds
itself in the shared render helpers rather than in a nonexistent reference image.) A human eye
still confirms the three states read as distinct, per the honest UX boundary below.

Dogfood snippet: Open the app. Open a project that has at least one terminal tile. Let it run
`sleep 9999` so the session is definitively alive. Quit the app. Relaunch. Click the terminal
tile. Within two seconds, the tile's tmux surface resumes showing the running `sleep` process —
no new window, no shell prompt, the same process tree. The tile status indicator returns to
`working` (blue pulse) if it previously showed `stale` (gray hollow) during the relaunch
interstitial. If you instead close the tmux window manually before refocusing, the tile shows
the gray hollow `stale` indicator with a non-empty error label rather than silently opening a
blank shell.

## Execution mode

Autonomous. The logic check is a pure Core function over an in-memory `TmuxControl.fake`, a
`ManagedAgentSessionRecord` fixture, and a deterministic manifest output — no human eye
required, no real daemon, no cloud. The three-branch decision is fully deterministic given the
fake's window-alive responses, and the manifest carries measured values (not booleans) that
the matrix gate asserts. The UX gate requires a human eye on the Component Lab render and a
real app dogfood pass; the UX section above is honest about that boundary and labels both
checks explicitly. Only the logic check governs the autonomous execution gate.

## Done when

- [ ] `ZoneRuntimeController.routableSession(forTile:allowRecovery:tmux:)` compiles with the
  declared signature `async throws -> RoutableSessionOutcome`, returns `.live(LiveSession)` for
  Branch 1 and Branch 3, returns `.inactive` for the `allowRecovery: false` dead-window path,
  and throws `SessionError.noBinding` / `.noResumeState` for the two honest failures — all three
  branches implemented as described.
- [ ] `recoverRecord` persists a fresh `tmuxWindowTarget` in `runtimePayload` and bumps
  `lastSeenAt` before returning.
- [ ] `attachUI` wires `onAcceptedTileFocusWithReason`; `.noBinding` is silent, `.noResumeState`
  and `.windowRebindFailed` post tile-level errors.
- [ ] The logic check (`runLazyResumeCheck`) passes all nine table rows with a
  non-degenerate manifest written to `qa-runs/`.
- [ ] `SessionError.noBinding` is not propagated to the user for non-managed tiles (verified
  by the "noBinding is silent" row in the logic check).
- [ ] No eager recovery call at app launch: `attachUI`, `init`, and `close` contain no
  `routableSession` call sites (verified by a grep in the logic check manifest).
- [ ] Branch 3 never calls `TileSpawner.spawnTerminal` (verified by the fake: `tmux.spawnCount`
  stays at zero in Branch 1 and 2 rows, equals one in the Branch 3 row).
- [ ] The Component Lab scenario "tile-lazy-resume-states" renders all three states without
  assertion failures.
- [ ] The dogfood snippet above produces the described outcome on a real relaunch.

## Depends on / unblocks

This ticket depends on the private managed-agent session record, which provides the
`ManagedAgentSessionRecord` type, its `resumeCursor` and `runtimePayload` fields, the
`managedSessionStore` on `ZoneRuntimeController`, and the `upsert` write path. Without that
record existing and being written at spawn, Branch 1 and Branch 3 have nothing to read, and
Branch 2's guard is vacuous.

It also depends on the injectable substrates work for `TmuxControl.fake` and the
new-tile-as-window work for the `tmux.newWindow` call in Branch 3, which re-uses the same
project-session window-creation path established there.

This ticket directly unblocks the reattach-by-target acceptance contract (I1/I8), which is
the first real-tmux proof of the topology. It also unblocks the idle reaper: the reaper calls
`routableSession(forTile:allowRecovery:false, tmux:.live)` as its pre-reap liveness check and
consults `lastSeenAt` for the staleness gate.

## Watch out for

**The no-re-spawn invariant is the hardest thing to hold.** Branch 3 calls `tmux.newWindow`
to get a new pane, but it must never call `TileSpawner.spawnTerminal` or create a new
`TerminalSessionDescriptor`. The `tmuxWindowTarget` in `runtimePayload` is updated; the tile's
`Tile.runtimeRef` and the `TerminalSessionDescriptor` on disk are not touched in this path.
If those are updated here, a tile that resumes will appear as a new session to the rest of the
system, which breaks I1 (binding bijection). Verify with the "spawnCount stays zero" check in
the logic manifest.

**`WindowTarget.decode` must return `nil` on missing payload, not throw.** A record written
before `runtimePayload` was introduced (or with a `nil` payload) must silently fall through to
Branch 3 (or Branch 2 if cursor is also nil), never crash the focus callback. The focus
callback is fire-and-forget inside `Task`; a thrown error that escapes the do/catch block
would be swallowed silently, so the logic check must explicitly assert that a nil-payload
record follows the correct branch rather than crashing.

**Focus reasons must be filtered by an explicit allowlist, not a denylist.** The guard triggers
on exactly `{.userClick, .appActivated}` and skips the other six real `FocusRequest` cases (see
the exhaustive reason table in "The approach"). Writing it as an allowlist — not "skip
`.modalDismissed` and `.recovery`" — is deliberate: a denylist silently starts triggering on any
case added to the enum later, whereas the allowlist stays safe by construction. Two of the
skipped cases are the ones most likely to bite if misfiled: a modal restore (`.modalDismissed`)
is not a user interaction and firing a tmux query on every modal dismiss would add latency to
the close animation and could race an in-progress recovery; a `.recovery` event is internal
focus-restore, never user-driven. The guard on `reason` must be explicit, not implicit.

**`lastSeenAt` must be bumped in Branch 1 as well as Branch 3.** A tile that is focused
repeatedly without ever going cold keeps its session alive through the reaper's idle gate only
if each focus refreshes `lastSeenAt`. If Branch 1 returns without bumping, a tile that the
user focuses every 25 minutes will be reaped after 30 minutes despite being actively used.

**Concurrency: `ZoneRuntimeController` is `@MainActor`.** The `routableSession` call site is
inside a `Task { @MainActor in … }`. The `TmuxControl` calls inside `routableSession` are
`async` and may suspend; during that suspension, other main-actor work can run, including
another focus event firing. The implementation must not assume that `managedSessionStore` is
stable across an `await`. Read the record before the first `await`, and re-read (or use a
copy) when writing back the updated record after recovery — do not hold a mutable reference
across the suspension point.
