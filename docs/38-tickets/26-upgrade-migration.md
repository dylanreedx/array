# Upgrade migration: fresh project sessions, one-time note, no silent orphans

Status: **implementation-ready.** One open decision is flagged for Dylan under "Open
decision to confirm" (the visual-gate waiver) — it does not block starting the code, but it
must be acknowledged before the ticket is marked done.

A note on vocabulary: this ticket names its dependencies and its correctness properties in
plain human terms. The only code-shaped names that appear are actual Swift symbols an
implementer will type (function names, the descriptor field, the tmux session prefixes).
The structural correctness properties this program is built on are referred to by their
human names throughout — **restart survival** (a tile that was alive before an app restart
comes back bound to the same underlying tmux window, same pid, same cwd) and the **binding
bijection** (every tile points at exactly one live window and every managed window is
pointed at by exactly one tile — no orphans on either side).

## What this delivers

When a user opens Continuum after upgrading to the project-session topology, they see a
single, clear informational note: their terminal tiles will restart once because the
session model has changed, and their running agents will need to be re-launched. The app
then brings up fresh project sessions for every project-zone terminal tile using the new
`continuum-proj-<projectId>` naming, with each window's `tmuxWindowTarget` captured and
persisted synchronously at spawn. No pre-upgrade `continuum-<tileId>` session is silently
killed; each is left orphaned in tmux and reaped later by the launch-time sweep (a
separate, subsequent piece of work — see "Depends on / unblocks"). From this point forward
every project-zone tile binding flows exclusively through the captured window target — not
through a re-derived session name — so **restart survival** and the **binding bijection**
both hold from the first post-upgrade launch.

Ambient tiles (terminal tiles living in a group zone with no project) are deliberately
**left untouched** by this migration. Under the phase-1 topology they stay on the old
per-tile `continuum-<tileId>` session model as the approved fallback, so their descriptors
must not be flagged, deleted, or restarted here.

## How it fits

This ticket is the final piece of Phase 1 session topology. It depends directly on two
prior tickets:

- **Project session naming & lifecycle ownership** — establishes the
  `continuum-proj-<projectId>` naming function and gives the per-project runtime controller
  ownership of the session lifecycle.
- **Capture tmuxWindowTarget at spawn** — adds the `%pane_id`-backed window target to
  `TerminalSessionDescriptor` (bumping the descriptor schema so a missing target field
  decodes as nil) and populates it synchronously during every spawn.

Without both of those in place there is nothing clean to migrate into. Both are named again
concretely under "Depends on / unblocks" so an implementer can resolve exactly which
tickets must land first.

The migration itself unblocks the **grouped view session** ticket (Phase 2 de-mirror),
because de-mirror depends on every project-zone tile already binding through a live window
target — if some tiles are still binding through the old `continuum-<tileId>` session name,
the view-session pinning logic has nothing stable to pin against. Migration is also a
prerequisite for the agent awareness base tier (Phase 3), which reads per-project observer
state keyed off a stable project session — a topology that cannot be observed reliably
until the old per-tile naming is fully retired for project zones.

## The approach

Detection is a single, cheap, synchronous check at boot. It needs three inputs, because a
descriptor alone cannot tell the difference between a legacy project-zone tile (which we
must migrate) and a legacy ambient tile (which we must leave alone) — both have the exact
same on-disk shape. The three inputs are:

1. the persisted `TerminalSessionDescriptor` list for the project;
2. the current `CanvasState` (so we only touch descriptors whose tile still exists on the
   canvas);
3. the current `WorkspaceDocument` zone placements (so we can tell whether a descriptor's
   tile lives in a **project zone**, which migrates, versus an **ambient/group zone**,
   which does not).

A descriptor is a **legacy project-zone descriptor** (and therefore migrates) when **all**
of the following hold:

- its `tmuxWindowTarget` is nil (no window target was ever captured — the pre-upgrade
  state); **and**
- its `args` contain a `-s` argument immediately followed by a value that begins with
  `continuum-` and is **not** one of the new prefixes (`continuum-proj-`, `continuum-ws-`,
  `continuum-view-`) — i.e. the old `continuum-<tileId>` per-tile session name; **and**
- its `tileId` still appears in the canvas tiles; **and**
- that tile lives in a **project zone** (a zone whose `projectId` is non-nil), not an
  ambient/group zone.

The nil-target-plus-old-prefix pair is the pre-upgrade *shape*; the canvas-and-zone check
is what makes the detection *safe* — it is the only thing that distinguishes a legacy
project-zone tile (migrate) from a legacy ambient tile (leave alone), because the two are
byte-for-byte identical at the descriptor level. This is why the detection function takes
canvas and zone inputs and not descriptors alone.

We do **not** key detection on `args[1]` or on whether the argv says `new-session` versus
`new-window`. The nil-target check already captures the pre-upgrade state reliably (a
post-upgrade descriptor always has a captured target), and the argv position of
`new-session` is an implementation detail of the old wrap that we do not want to depend on.
The single detection rule is the one stated above; it is the same rule described in "The
approach", coded in "Implementation breadcrumbs", and asserted in "How we test it".

The migration path does exactly three things:

1. Show a one-time `NSAlert` ("Session model updated") with a single "OK" button, via an
   injected presenter closure (see "The alert-presentation seam" below). The alert fires
   before any tile spawning happens. A `UserDefaults` boolean key
   (`continuum.topology.migrationNoteShown`) is written to `true` **immediately before** the
   presenter is invoked, so a crash during the modal does not re-show it on the next boot.

2. Delete the migrating descriptors. They carry stale `args` that would cause
   `tmuxWrappedProfileIfAvailable` to re-produce a `continuum-<tileId>` session name,
   defeating the whole topology change. Deleting them forces the normal spawn path, which
   now produces the new `new-window` argv. The cwd for the fresh window comes from the
   persisted `descriptor.cwd` (captured via OSC-7 flush before the upgrade), preserving the
   directory the user was in.

3. Proceed with normal boot. The regular canvas-restore loop calls `restartTerminalTile`
   for each tile; because the old descriptor is gone, it falls through to a fresh
   `spawnTerminal` call that creates the new window, captures `%pane_id`, and persists the
   new descriptor. The tile keeps its canvas identity (position, size, id) — only the
   underlying tmux window is new.

The pre-upgrade `continuum-<tileId>` sessions are left running in tmux untouched. They
become unnamed orphans relative to the new project-session naming and are collected on a
later boot by the launch-time `continuum-*` sweep (a separate ticket — the no-session-leak
backstop). The release notes document this explicitly. Never issue an automatic
`kill-session` against a `continuum-<tileId>` session — a running agent could be in it.

The note is gated behind the `UserDefaults` boolean so it appears exactly once across all
future boots, including if the user force-quits during the alert. This is a write-first,
show-second pattern: write the flag, then show the alert. That way a crash between the two
is no worse than showing the note a second time (acceptable), whereas the reverse would
show the note infinitely.

## The alert-presentation seam

The modal is not called directly by the migration function. `applyTopologyMigrationIfNeeded`
takes an explicit presenter parameter — a closure `presentAlert: () -> Void` — which
defaults, at the production call site, to the closure that builds and runs the real
`NSAlert`. In the automated backend check the caller passes a **recording no-op presenter**
that does not open any window but does capture, at the moment it is invoked, the current
value of the `migrationNoteShown` flag. This is the only injection seam the ticket
introduces, and it exists for two reasons: (a) to run the backend check headlessly without
an AppKit modal, and (b) to make the write-first ordering falsifiable (the presenter
records whether the flag was already `true` when the alert would have shown).

There is no `showAlert: Bool` parameter and no protocol; a single injectable closure is the
whole seam. The production signature and the tested signature are identical — the only thing
that varies between production and test is which closure is passed.

## Where it lives

The migration detection and state belong in
`Sources/ContinuumRevivedCore/DefaultWorkspaceMigration.swift`. This file already owns the
"ensure a default workspace exists" boot-time migration logic
(`DefaultWorkspaceMigration.ensureDefaultWorkspace`, lines 10–60) and is the natural home
for "detect and record a one-time topology migration." The new entry point is a pure,
testable method that takes all three detection inputs:

```swift
// DefaultWorkspaceMigration.swift — new addition
public func detectTopologyMigration(
    descriptors: [TerminalSessionDescriptor],
    canvas: CanvasState,
    workspace: WorkspaceDocument
) -> TopologyMigrationState
```

`canvas` is needed so a descriptor whose tile no longer exists is never touched; `workspace`
is needed so an ambient-zone tile (identical descriptor shape) is never flagged. Both are
plain Codable value types already available at boot, so the function stays pure and
fully testable with in-memory fixtures — no disk, no tmux.

`TopologyMigrationState` is a new `public enum` in the same file:

```swift
public enum TopologyMigrationState: Equatable, Sendable {
    case notNeeded
    case needed(legacyDescriptorIds: [UUID])  // runtime ids of migrating descriptors
}
```

The decision to show the alert and delete the descriptors lives in
`Sources/ContinuumRevived/App/ContinuumApp.swift`, called from the project-boot path
near where `DefaultWorkspaceMigration().ensureDefaultWorkspace` is already called
(around line 7308). The check reads `UserDefaults.standard.bool(forKey:
"continuum.topology.migrationNoteShown")` before calling `detectTopologyMigration` — if
the flag is already set, the whole detection path is skipped.

The `TileSpawner.spawnTerminal` private path
(`Sources/ContinuumRevived/App/TileSpawner.swift`, lines 151–215) is unchanged by this
ticket. It already creates and persists `TerminalSessionDescriptor`; after the project
session naming and target capture work land, the argv it emits is already the new shape.
Migration only needs to remove the old descriptor, not touch the spawn path itself.

## Implementation breadcrumbs

Zone-membership helper (how to tell a project-zone tile from an ambient tile). This mirrors
the two membership mechanisms the sidebar tree already uses: an ambient/group zone owns its
tiles via the inline `groupZoneTiles` list (read with `workspace.tiles(forZone:)`), and a
project zone owns its tiles *spatially* — a tile belongs to a project zone when its center
falls inside that zone's world frame. For the migration we only need the coarse answer "is
this tile in a project zone?":

```swift
private func tileIsInProjectZone(
    tileId: UUID,
    canvas: CanvasState,
    workspace: WorkspaceDocument
) -> Bool {
    // Ambient/group zones own their tiles by explicit inline membership.
    // If a tile is in any group zone's tile list, it is NOT a project-zone tile.
    for zone in workspace.zones where zone.projectId == nil {
        if workspace.tiles(forZone: zone.zoneId).contains(where: { $0.id == tileId }) {
            return false
        }
    }
    // Otherwise: is the tile's center spatially inside a project zone frame?
    // Reuse the exact predicate the sidebar tree uses (tileCenter / isInside /
    // zoneWorldFrame from SidebarTree / CanvasEngine) so migration agrees with the
    // membership the user already sees. A tile in no zone at all is treated as
    // not-in-a-project-zone (leave it alone).
    guard let tile = canvas.tiles.first(where: { $0.id == tileId }) else { return false }
    for zone in workspace.zones where zone.projectId != nil {
        if tileCenter(tile).isInside(zone: zone /* via zoneWorldFrame */) {
            return true
        }
    }
    return false
}
```

Detection (pure, in Core):

```swift
public func detectTopologyMigration(
    descriptors: [TerminalSessionDescriptor],
    canvas: CanvasState,
    workspace: WorkspaceDocument
) -> TopologyMigrationState {
    let legacyIds = descriptors.compactMap { d -> UUID? in
        // 1. Pre-upgrade shape: no window target was ever captured.
        guard d.tmuxWindowTarget == nil else { return nil }

        // 2. Old per-tile session name: a "-s" arg followed by "continuum-<tileId>",
        //    excluding the new project / workspace / view prefixes.
        let args = d.args
        let hasLegacyName = args.indices.dropLast().contains { i in
            args[i] == "-s"
                && args[i + 1].hasPrefix("continuum-")
                && !args[i + 1].hasPrefix("continuum-proj-")
                && !args[i + 1].hasPrefix("continuum-ws-")
                && !args[i + 1].hasPrefix("continuum-view-")
        }
        guard hasLegacyName else { return nil }

        // 3. The tile must still exist on the canvas (never delete a descriptor for a
        //    tile that is already gone — it would be silently recreated by the spawn path).
        guard canvas.tiles.contains(where: { $0.id == d.tileId }) else { return nil }

        // 4. The tile must live in a PROJECT zone. Ambient tiles have an identical
        //    descriptor shape but stay on the per-tile fallback — never migrate them.
        guard tileIsInProjectZone(tileId: d.tileId, canvas: canvas, workspace: workspace)
        else { return nil }

        return d.id
    }
    return legacyIds.isEmpty ? .notNeeded : .needed(legacyDescriptorIds: legacyIds)
}
```

Boot-time gate (in ContinuumApp, near the `ensureDefaultWorkspace` call):

```swift
func applyTopologyMigrationIfNeeded(
    projectStore: ProjectStore,
    canvas: CanvasState,
    workspace: WorkspaceDocument,
    defaults: UserDefaults,
    presentAlert: () -> Void = { presentTopologyMigrationAlert() }
) throws {
    guard !defaults.bool(forKey: "continuum.topology.migrationNoteShown") else { return }

    let descriptors = try projectStore.listSessions()
    let migration = DefaultWorkspaceMigration()
    let state = migration.detectTopologyMigration(
        descriptors: descriptors, canvas: canvas, workspace: workspace
    )
    guard case .needed(let staleIds) = state else {
        // No migrating descriptors; still mark shown so we never run again.
        defaults.set(true, forKey: "continuum.topology.migrationNoteShown")
        return
    }

    // Write the flag BEFORE presenting the alert, so a crash between these
    // two lines results in a missed note (acceptable), not an infinite loop.
    defaults.set(true, forKey: "continuum.topology.migrationNoteShown")

    presentAlert()  // production: builds + runModal()s the NSAlert; test: recording no-op

    // Remove migrating descriptors so the normal spawn path produces new-window argv.
    for id in staleIds {
        try? projectStore.deleteSession(id)
    }
    // Canvas restore will call restartTerminalTile for each affected tile,
    // which falls through to spawnTerminal and captures a fresh tmuxWindowTarget.
}

// Production presenter, built where NSAlert is available.
func presentTopologyMigrationAlert() {
    let alert = NSAlert()
    alert.messageText = "Session model updated"
    alert.informativeText = """
        Continuum now groups terminal tiles by project, so your terminals share one \
        tmux session per project. Your terminal tiles will restart once. Any running \
        agents will need to be re-launched — they are still alive in tmux and can be \
        found with `tmux ls` if needed.
        """
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
```

No new tmux command is issued by this ticket. The orphaned `continuum-<tileId>` sessions
are not touched here; the launch-time `continuum-*` sweep ticket handles them.

## How we test it

### Logic (pure Core checks)

In `Sources/ContinuumRevivedCoreChecks/main.swift`, alongside the existing
`DefaultWorkspaceMigration` checks (around line 1741). Every check builds an in-memory
`CanvasState` and `WorkspaceDocument` alongside the descriptors so the full three-input
signature is exercised.

- **Legacy project-zone descriptor fires.** Build a `TerminalSessionDescriptor` with args
  shaped as the old wrap output (`["-A", "-s", "continuum-<uuid>", "-c", "/some/path"]`)
  and `tmuxWindowTarget == nil`, a canvas that contains a tile with the matching `tileId`,
  and a workspace whose zones include a **project zone (projectId != nil)** whose frame
  contains that tile's center. Call `detectTopologyMigration`. Assert result is
  `.needed(legacyDescriptorIds: [descriptor.id])`.

- **Ambient descriptor with the SAME legacy shape is NOT flagged.** Build a descriptor with
  the identical legacy shape (`continuum-<tileId>` name, `tmuxWindowTarget == nil`), a
  canvas containing the tile, and a workspace whose **group zone (projectId == nil)** lists
  that tile in its inline `groupZoneTiles`. Assert result is `.notNeeded`. This is the
  load-bearing safety case: an ambient tile is byte-for-byte identical to a legacy
  project-zone tile at the descriptor level, and it must not be restarted.

- **New-shape descriptor is not flagged.** Build a descriptor with `tmuxWindowTarget ==
  "%5"` and args shaped as the new `new-window` output, in a project zone. Assert result is
  `.notNeeded`.

- **Descriptor whose tile no longer exists is not flagged.** Build a legacy-shaped
  descriptor whose `tileId` is absent from the canvas tiles (tile was deleted). Assert
  result is `.notNeeded` — a descriptor with no live tile is never touched.

- **Mixed list.** Supply one legacy project-zone descriptor, one legacy ambient descriptor
  (in a group zone), and one new-shape descriptor. Assert that **only** the project-zone
  descriptor's id appears in `legacyDescriptorIds`.

- **All-new list.** Supply only new descriptors. Assert `.notNeeded`.

- **Descriptor round-trip with nil target.** Confirm a pre-upgrade session JSON (no
  `tmuxWindowTarget` key) decodes cleanly with `tmuxWindowTarget == nil` and is therefore
  correctly eligible when its tile is in a project zone. This covers the schema back-compat
  path and mirrors the existing `A3_v1_migration` pattern at `ContinuumApp.swift:14820`.

- **`continuum-proj-` prefix is not flagged.** A descriptor whose session name begins with
  `continuum-proj-` (post-migration session) is not counted as legacy even with a nil
  target. Assert `.notNeeded`.

All checks are pure value assertions over in-memory `CanvasState` / `WorkspaceDocument`
fixtures; no tmux daemon, no disk I/O.

### Backend (real-path / integration)

This check drives the true `ProjectStore` and the real `applyTopologyMigrationIfNeeded`
function against a temporary on-disk project store, using an isolated `UserDefaults` suite
so it does not touch `.standard`. It does not spawn any tmux session.

Setup:
1. Create a temporary `ProjectStore` pointing at a temp directory.
2. Write two legacy-shaped `TerminalSessionDescriptor` JSON files directly into the store's
   session directory, using the real pre-upgrade schema (the hand-written JSON literal
   pattern already established at `ContinuumApp.swift:14823`).
3. Build a `CanvasState` containing the two tiles and a `WorkspaceDocument` whose project
   zone frame contains both tiles' centers (so both descriptors are migration-eligible).
4. Create an isolated `UserDefaults` suite with the migration key absent.
5. Build a **recording presenter**: a closure that, when invoked, appends
   `defaults.bool(forKey: "continuum.topology.migrationNoteShown")` to a captured array.
   This records the flag's value at the exact moment the alert would have been shown. It
   opens no window.

Execution:
6. Call `applyTopologyMigrationIfNeeded(projectStore:, canvas:, workspace:, defaults:,
   presentAlert: recordingPresenter)`.
7. After the call, call `projectStore.listSessions()`.

Assertions (all measured values in the manifest, never `{passed: true}`):
- `presenterFlagAtPresentTime == [true]` — the presenter was invoked exactly once and the
  `migrationNoteShown` flag was **already `true`** when it ran. This is the falsifiable
  proof of the write-first ordering: if the code wrote the flag after `presentAlert()`, the
  recorded value would be `false`, and this assertion would fail. The ordering is verified
  in-process, not left to the human dogfood pass.
- `defaults.bool(forKey: "continuum.topology.migrationNoteShown") == true` — flag was set.
- `listSessions().count == 0` — migrating descriptors were deleted.
- `listSessions().filter { isLegacy($0) }.count == 0` — none of the migrating descriptors
  survive.

Ambient-safety in the real path (second scenario, same check):
8. Reset the suite (or use a fresh suite with the key absent). Write one legacy-shaped
   descriptor whose tile is placed in a **group zone** (inline `groupZoneTiles`, projectId
   nil) and one legacy-shaped descriptor in a project zone.
9. Call `applyTopologyMigrationIfNeeded` with a recording presenter.
10. Assert `listSessions().count == 1` and that the **surviving** descriptor is the ambient
    one (its `tileId` matches the group-zone tile). Assert the recorded presenter flag is
    `[true]` again. This proves the dangerous false-positive (deleting/restarting a live
    ambient agent) does not happen on the real store path, not just in the pure check.

Idempotency (third scenario):
11. With the flag now set, write two more legacy-shaped project-zone descriptors.
12. Call `applyTopologyMigrationIfNeeded` again with the same defaults instance.
13. Assert `listSessions().count == 2` and that the recording presenter was **not** invoked
    (empty recorded array) — the function exits early. This proves the gate is a true
    once-only.

### UX (visual gate + dogfood snippet)

See "Open decision to confirm" below regarding the automated visual gate. The dogfood
snippet is the required real-app check; whether it also counts as the visual gate is the
open decision.

Concrete dogfood snippet:

1. Run the app once normally so the canvas has at least one terminal tile in a project
   zone, with an old-style descriptor on disk. Simulate this by directly writing a
   legacy-shaped descriptor JSON file into
   `~/Library/Application Support/Continuum/<project-id>/sessions/<uuid>.json` before
   launch (the file format is documented in `TerminalSessionDescriptor.swift` and the
   existing JSON literal at `ContinuumApp.swift:14823` shows the exact shape), and confirm
   the tile it names sits inside a project zone on the canvas.
2. Clear the migration defaults key: `defaults delete continuum.topology.migrationNoteShown`
   in Terminal.
3. Launch the app.
4. Expected: an alert appears with the title "Session model updated" and body text
   beginning "Continuum now groups terminal tiles by project…", with a single "OK" button.
   No other buttons. The alert appears before the canvas is interactive.
5. Click "OK".
6. Expected: the canvas loads with the tile in its previous position; the tile's terminal
   shows a fresh shell (agent has restarted); the old descriptor file is gone from disk
   (confirm with `ls ~/Library/Application\ Support/Continuum/<id>/sessions/`).
7. Also place one terminal tile in a **group zone** with its own legacy descriptor before
   launch. Expected after OK: that ambient tile is **not** restarted (its descriptor file
   is still present, its terminal keeps its existing shell/agent). This is the visible
   confirmation that ambient tiles are left alone.
8. Quit and re-launch.
9. Expected: the alert does not appear again. The project-zone tile attaches normally via
   its captured `tmuxWindowTarget`.

## Open decision to confirm

**Is a Component-Lab visual gate required-and-impossible here, or genuinely waived?**

The verification doctrine (the phase-0 harness contract) requires every UX-touching ticket
to ship a non-degenerate automated visual gate. This ticket's UX surface is a stock
`NSAlert` — an AppKit modal with no snapshottable view in the Component Lab. There is
therefore no honest way to produce an automated visual snapshot of it; the only visual
confirmation is the real-app dogfood pass (step 4 above).

This ticket does **not** silently downgrade the doctrine. It surfaces the conflict for
Dylan to resolve one of two ways:

- **Waive the automated visual gate for this ticket** (accept the dogfood pass as the sole
  visual confirmation, on the grounds that a stock system modal has fixed, Apple-owned
  chrome not worth snapshotting); or
- **Require a substitute** — e.g. replace the `NSAlert` with a small custom SwiftUI/AppKit
  sheet that *is* snapshottable in the Component Lab, and add a Lab fixture for it.

Recommendation: **waive** (stock `NSAlert`, one line of body copy, no custom view worth a
snapshot). But this is Dylan's call, and the ticket must not be marked done until it is
explicitly confirmed. Do not proceed as if the requirement were quietly satisfied.

## Execution mode

**Supervised.** The logic and backend checks are fully automated and prove detection,
ambient-safety, deletion, the write-first ordering, and idempotency without human eyes.
However, the UX gate — confirming the alert appears at the right moment in the boot
sequence, with the correct text, before the canvas is interactive, and does not reappear —
requires a real app run and a human dogfood pass, because the boot sequencing of
`applyTopologyMigrationIfNeeded` relative to canvas restore is not observable from a
headless check.

## Done when

- [ ] The open decision above (visual-gate waiver) has been explicitly confirmed by Dylan.
- [ ] `DefaultWorkspaceMigration.detectTopologyMigration(descriptors:canvas:workspace:)`
  exists in `DefaultWorkspaceMigration.swift` and returns `.needed` for a descriptor that
  (a) has a nil `tmuxWindowTarget`, (b) has a `-s continuum-<tileId>` session name not
  prefixed `continuum-proj-`/`continuum-ws-`/`continuum-view-`, (c) has a `tileId` present
  in the canvas, and (d) whose tile is in a project zone — and returns `.notNeeded`
  otherwise.
- [ ] `TopologyMigrationState` is a `public enum` with `.notNeeded` and
  `.needed(legacyDescriptorIds: [UUID])` cases, in the Core target.
- [ ] All Logic checks pass with measured manifests (not `{passed: true}`), including the
  ambient-descriptor-not-flagged case and the tile-no-longer-exists case.
- [ ] The Backend integration check passes: migrating descriptors are deleted, the flag is
  set, an ambient descriptor in a group zone survives untouched, and a second call leaves
  new descriptors untouched.
- [ ] The write-first ordering is proven automatically: the recording presenter observes the
  `migrationNoteShown` flag already `true` at present-time (`presenterFlagAtPresentTime ==
  [true]`), and the manifest records this measured value.
- [ ] The alert has exactly one button ("OK"), the message text "Session model updated",
  and informative text that mentions tmux and the one-time restart.
- [ ] No `continuum-<tileId>` session is issued a `kill-session` command — orphaned
  sessions are left for the sweep backstop.
- [ ] Dogfood pass: alert appears once, the project-zone tile restores in its canvas
  position with a fresh shell and its old descriptor file is gone, an ambient tile is left
  untouched, and a second launch shows no alert.
- [ ] The existing `DefaultWorkspaceMigration` Core checks (lines 1741–1803 in
  `ContinuumRevivedCoreChecks/main.swift`) still pass without modification.

## Depends on / unblocks

Depends directly on:

- **Project session naming & lifecycle ownership** (ticket 14) — provides
  `TmuxSession.projectSessionName(projectId:)` and the `continuum-proj-<id>` convention the
  detection heuristic contrasts against.
- **Capture tmuxWindowTarget at spawn** (ticket 16) — introduces
  `TerminalSessionDescriptor.tmuxWindowTarget` and the schema bump, making the nil-target
  check a reliable pre-upgrade signal.

Both must land before this ticket can begin; there is nothing clean to migrate into without
them.

Unblocks:

- **Grouped view session** (ticket 27, Phase 2 de-mirror) — that work assumes every active
  project-zone tile already binds through a `tmuxWindowTarget`.
- It is also a practical prerequisite for the agent awareness base tier (Phase 3), which
  observes a per-project session; mixed legacy/new sessions in the same project would
  produce ambiguous observer state.

Related-but-separate (does **not** block this ticket, and this ticket does not implement
it):

- **Launch-time `continuum-*` sweep** (the no-session-leak backstop) — reaps the orphaned
  pre-upgrade `continuum-<tileId>` sessions on a later boot. This migration deliberately
  leaves those sessions alive; the sweep is where they are cleaned up.
- **Per-workspace ambient session** (ticket 22) — the eventual promotion of ambient tiles
  off the per-tile fallback. Until it lands, ambient tiles stay on the per-tile model and
  this migration must leave them alone.

## Watch out for

**The write-first ordering is load-bearing, and it now has an automated check.** If the
`migrationNoteShown` flag is written after the alert instead of before, a force-quit during
the alert leaves the flag unset and the alert reappears on next boot. The backend check
proves the ordering in-process via the recording presenter
(`presenterFlagAtPresentTime == [true]`); do not remove or weaken that assertion. Always
write the flag before invoking the presenter, never inside the alert's completion handler.

**Do not delete descriptors whose tile no longer exists on the canvas.** The detection
function already filters on `canvas.tiles.contains(tileId)`; a descriptor for a tile that
was already deleted on disk is left alone (it is harmless and must not be silently recreated
by the spawn path). If no canvas state is loadable, err on the side of not deleting — pass
an empty canvas and the function returns `.notNeeded`.

**Never call `kill-session` against a `continuum-<tileId>` session.** The orphaned sessions
may contain running agents. The sweep backstop is the right place to decide what to do with
them, and it does so with full context about whether a project is still live.

**Ambient per-tile tiles have the identical descriptor shape and must never be flagged.**
Under this migration, ambient tiles (those in group zones with no project) remain on the
old per-tile session model as the approved fallback. Their descriptors also have a
`continuum-<tileId>` session name and a nil `tmuxWindowTarget` — byte-for-byte identical to
a legacy project-zone descriptor. The **only** thing that distinguishes them is zone
placement, which is why `detectTopologyMigration` takes the `WorkspaceDocument` and
`CanvasState`: a tile is migrated only if it lives in a project zone. Both the pure Logic
check ("Ambient descriptor with the SAME legacy shape is NOT flagged") and the Backend
ambient-safety scenario exist specifically to make this falsifiable. Ambient-fallback tiles
must not be restarted.

**The existing self-checks in `TileSpawner.swift` assert the old per-tile session argv
shape** (at lines 3247, 3263 and `ContinuumApp.swift:11082`). These are check-only paths,
not production. They will fail once the project session naming and target capture work
lands. Budget time to update them, but that update belongs to those upstream tickets — not
here.
