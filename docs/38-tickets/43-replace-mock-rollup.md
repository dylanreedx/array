# Replace the mock zone-chrome rollup with the observer's real signal

## What this delivers

After this ticket, every zone header in the canvas draws a live agent-status rollup
derived from the `SessionObserver`'s output — not the hardcoded counts that are baked in
at construction time. A zone that contains one Claude tile in the `working` state and one
Codex tile in the `needsAttention` state will display exactly "1 needs you · 1 working"
in orange (the `needsAttention`-dominant color) from the moment the observer publishes its
first update, without any manual intervention or restart. The zone chrome makes no decisions
about which tiles are agents; it renders whatever `AgentStatusRollup` the observer has
computed. This is the seam where Phase 3 becomes visible to the user for the first time.

## How it fits

This ticket is the downstream consumer for the session observer with budgets. The observer
publishes a per-tile `[UUID: AgentStatus]` dictionary on the main queue whenever its
debounced update fires; this ticket connects that dictionary to the two rendering surfaces
that currently display hardcoded data: the zone `AgentStatusRollup` inside
`CanvasNSView.ZoneRenderModel` and the per-tile `agentStatus` property on each
`TileNSView`. The sidebar tree already has its own wiring path for `agentStatusesByTileId`
(the sidebar-tree observer feed — feeding the sidebar tree from the observer — comes
immediately after and reuses the same observer output). This ticket scopes itself to the
canvas zone chrome and the
per-tile badge, and deliberately leaves the sidebar tree feed to its successor.

It builds on the pure status-derivation function, the `agentKind` closed enum, the three
concrete readers (Claude, Pi, Codex), the reader golden fixtures, the `SessionObserver`
itself with its budget enforcement, and the FSEvents push watch. None of those need to be
perfect — they just need to exist and publish `[UUID: AgentStatus]` correctly. It unblocks
the sidebar tree feed, the dock render, and all downstream visibility work by proving the
observer-to-UI pipeline is wired and can be visually gate-tested.

## The approach

The `SessionObserver` publishes a `[UUID: AgentStatus]` snapshot to the main queue via a
Combine publisher (a `CurrentValueSubject` or a plain callback closure — whichever the
observer ticket chose; either works here). The app layer subscribes to this publisher at
canvas construction time and, on each emission, recomputes the `ZoneRenderModel` array by
folding the new statuses through `SidebarAgentStatusRollup.make` (already exists in
`SidebarTree.swift:71`) and then mapping the result into the canvas-local
`CanvasNSView.AgentStatusRollup` type. The canvas's zone chrome is then refreshed
(`setNeedsDisplay` on the zone chrome area or a full canvas redraw, whichever the existing
`ZoneChromeNSView` path takes — look at how zone chrome is currently invalidated on resize
to pick the right call).

Per-tile badges are updated in the same callback: for each `(tileId, status)` pair in the
new snapshot, call `canvasView?.tileView(for: tileId)?.agentStatus = status` — the same
line already used at `ContinuumApp.swift:3827` in `updateAgentStatus`. Non-agent tiles
(those not present in the observer's snapshot) must have their `agentStatus` set to `nil`
so stale badges from a previous state do not linger.

Non-terminal status handling (`configuring`, `idle`, `unknown`). The real `AgentStatus`
enum has six cases, not four: alongside `working`, `needsAttention`, `done`, `stale` it also
has `configuring` and `idle` (`TerminalSessionDescriptor.swift:85`), and
`SidebarAgentStatusRollup` folds both of those into an `unknown` bucket via
`SidebarAgentStatusKind.kind(for:)` (`SidebarTree.swift:10` maps `.configuring`/`.idle` →
`.unknown`). This ticket resolves those cases explicitly, so no implementer has to guess:

- **Per-tile badge.** A tile whose observer status is `configuring` or `idle` shows **no
  badge** (treat it like a non-agent tile for badge purposes): set `agentStatus = nil` for
  those cases rather than passing the raw status through. Rationale: a badge signals an
  active/attention/finished agent; a configuring or idle tile is neither, and painting a
  glyph for it is noise. Only `working`/`needsAttention`/`done`/`stale` produce a badge.
- **Zone rollup.** `configuring`/`idle` (and therefore the `unknown` bucket they land in)
  **count in no visible bucket** of the canvas rollup. Accumulate through
  `SidebarAgentStatusRollup.add` as normal — they will pile into `unknown` — but the bridge
  to `CanvasNSView.AgentStatusRollup` drops `unknown` (that type has no `unknown` field), so
  they contribute zero to the zone header text. A zone containing only configuring/idle tiles
  therefore renders an **empty** header, identical to a zone with no agents. This is the
  intended behavior, not a lossy copy — it is why the bridge deliberately omits `unknown`.

The consequence for the cold-start `.configuring` state (see the Backend check below) is that
a freshly constructed canvas whose tiles are all `.configuring` shows **no badges and empty
zone headers** until the first observer emission promotes tiles to a terminal/active state.

The static `agentStatusRollup(for:)` method at `ContinuumApp.swift:7492` reads sessions
from disk at render time and feeds the zone chrome. That method becomes the cold-start
initializer only — it populates the rollup on first canvas construction so the chrome is
not blank before the observer fires. After the first observer emission, the observer's
output is the sole truth. Do not delete the static method; just stop calling it on every
canvas rebuild. The lifecycle is: construct canvas with the disk-derived rollup → observer
fires first update → replace with live rollup → stay on live rollup.

The `zoneRenderModels` static method at `ContinuumApp.swift:7337` currently calls
`agentStatusRollup(for:)` on every invocation (including on zone add/remove/rename events
that are not status changes). After this ticket, `zoneRenderModels` no longer computes the
rollup itself. It builds the `ZoneRenderModel` array with `agentStatusRollup: .empty` (or
with the last-known observer snapshot if one is available), and the live update path
overwrites the rollup on each observer emission. This avoids a double-read where zone
structural events trigger a disk read and the observer simultaneously fires a file-watch
update.

The observer subscription must be torn down when the canvas is replaced (workspace switch,
project switch). Store the cancellable on the app delegate or the relevant owner alongside
`canvasView`, and cancel it before assigning a new canvas. Missing this teardown is the
most likely source of a status update landing on a deallocated canvas.

## Where it lives

Primary seam — rollup computation and observer subscription:
`Sources/ContinuumRevived/App/ContinuumApp.swift:7337` — `zoneRenderModels(from:registry:)`:
strip the `agentStatusRollup(for:)` call from the map; add an `observerStatuses` parameter
(defaulting to the current cold-start disk read) so callers can pass the latest snapshot.

Primary seam — per-tile badge update:
`Sources/ContinuumRevived/App/ContinuumApp.swift:3826` — `updateAgentStatus(tileId:status:now:)`:
already correct as a single-tile writer; the observer callback calls it for each tile in the
new snapshot, and clears `agentStatus = nil` for tiles absent from the snapshot.

Primary seam — zone chrome drawing and rollup text:
`Sources/ContinuumRevived/Canvas/CanvasNSView.swift:41` — `ZoneRenderModel.agentStatusRollup`:
this field is already the source of truth for the zone chrome at `CanvasNSView.swift:5260`.
Updating the `ZoneRenderModel` and triggering a redraw is all that is needed.

Supporting seam — rollup type bridge:
`Sources/ContinuumRevivedCore/SidebarTree.swift:71` — `SidebarAgentStatusRollup.make(statuses:)`:
use this as the canonical accumulator. Note the two types are **not** field-identical:
`SidebarAgentStatusRollup` has five buckets (`working`, `needsAttention`, `done`, `stale`,
`unknown`), while `CanvasNSView.AgentStatusRollup` (`CanvasNSView.swift:45`) has only four
(`working`, `needsAttention`, `done`, `stale`) — no `unknown`. Map the four shared fields
one-to-one and **drop the `unknown` count on the canvas side** (see the non-terminal-status
rule below for why that is the intended behavior, not a lossy accident).

Supporting seam — subscription owner:
Wherever the app delegate currently owns `canvasView` (search for `var canvasView` in
`ContinuumApp.swift`), add a `var observerStatusCancellable: AnyCancellable?` (or a
closure reference if the observer uses a callback rather than Combine) immediately adjacent.

New test file:
`Tests/ContinuumRevivedCoreTests/` — no new test file in Core. The real-path check lives
in the existing `ContinuumApp.swift` self-check harness, alongside `runAgentStatusBadgeSelfCheck`.

## Implementation breadcrumbs

```swift
// --- In the app delegate, near the canvasView property ---

var observerStatusCancellable: AnyCancellable?   // or a closure token if the observer uses callbacks

// --- When constructing or replacing the canvas ---

observerStatusCancellable?.cancel()
observerStatusCancellable = sessionObserver.statusPublisher  // [UUID: AgentStatus] on MainActor
    .sink { [weak self] statuses in
        self?.applyObserverStatuses(statuses)
    }

// --- New method ---

@MainActor
private func applyObserverStatuses(_ statuses: [UUID: AgentStatus]) {
    guard let canvasView else { return }

    // 1. Update per-tile badges. Tiles in the snapshot get the live status;
    //    tiles absent from the snapshot lose any previous badge. configuring/idle
    //    also show NO badge (collapse them to nil) — only working/needsAttention/
    //    done/stale paint a glyph.
    let knownTileIds = Set(canvasView.canvasState.tiles.map(\.id))
    for tileId in knownTileIds {
        canvasView.tileView(for: tileId)?.agentStatus = badgeStatus(statuses[tileId])
    }

    // Helper: only terminal/active statuses produce a badge; configuring/idle and
    // absent-from-snapshot all render as no badge.
    func badgeStatus(_ status: AgentStatus?) -> AgentStatus? {
        switch status {
        case .working, .needsAttention, .done, .stale: return status
        case .configuring, .idle, nil: return nil
        }
    }

    // 2. Recompute zone rollups from the observer snapshot.
    //    One pass: accumulate per-zone, then stamp each ZoneRenderModel.
    var rollupByZoneId: [UUID: SidebarAgentStatusRollup] = [:]
    // tileZoneMap is a [tileId: zoneId] dict. TODAY, build it from
    // WorkspaceDocument.groupZoneTiles — a [GroupZoneTiles] where each entry is
    // (zoneId, [tileId]). Invert it: for each group, for each tileId in group.tiles,
    // set tileZoneMap[tileId] = group.zoneId. This is the only membership source that
    // exists in production (WorkspaceDocument.swift:21). Do NOT wait for the tile-level
    // LWW membership register (D3/D15) — it is a future re-model and is not built yet.
    // Migrate this lookup to the register when that ticket lands; the shape ([tileId: zoneId])
    // is unchanged, so this is a one-function swap behind the same call site.
    for (tileId, status) in statuses {
        guard let zoneId = tileZoneMap[tileId] else { continue }
        rollupByZoneId[zoneId, default: .empty].add(status)
    }

    // 3. Convert SidebarAgentStatusRollup → CanvasNSView.AgentStatusRollup and
    //    push the updated models into the canvas. The canvas type has no `unknown`
    //    field, so sidebar.unknown (where configuring/idle land) is intentionally
    //    dropped — configuring/idle count toward no visible bucket.
    let updatedModels = canvasView.zoneRenderModels.map { model in
        let sidebar = rollupByZoneId[model.placement.zoneId] ?? .empty
        let canvas = CanvasNSView.AgentStatusRollup(
            working: sidebar.working,
            needsAttention: sidebar.needsAttention,
            done: sidebar.done,
            stale: sidebar.stale
            // sidebar.unknown deliberately omitted (no canvas field; not shown)
        )
        var updated = model
        updated.agentStatusRollup = canvas
        return updated
    }
    canvasView.updateZoneRenderModels(updatedModels)  // triggers setNeedsDisplay on chrome areas

    // 4. Refresh the attention surface (dock badge, system notification).
    refreshAgentAttentionSurface()
}
```

The `tileZoneMap` is either read from the active workspace document directly or cached on
the app delegate and refreshed on zone structural changes (tile add/remove, zone add/remove).
Read the membership from `WorkspaceDocument.groupZoneTiles` (`WorkspaceDocument.swift:21`) —
a `[GroupZoneTiles]` list of `(zoneId, [tileId])`. Invert that list into `[tileId: zoneId]`;
the inversion plus the per-status lookup is an `O(tiles)` scan at most. Note explicitly: the
tile-level LWW membership register that D3 and D15 describe does **not** exist in production
today — it is a future re-model, not a dependency of this ticket. Do not block on it and do
not assume `document.zones` carries per-tile membership. Use `groupZoneTiles` now; when the
register lands (its own ticket), swap this one inversion for a register read behind the same
`[tileId: zoneId]` shape.

The `canvasView.updateZoneRenderModels(_:)` method needs to exist or be added:

```swift
// In CanvasNSView, near the existing zoneRenderModels storage ---

func updateZoneRenderModels(_ models: [ZoneRenderModel]) {
    // Replace the stored models and invalidate only the zone chrome areas.
    // Pattern: find each ZoneChromeNSView by zoneId and call setNeedsDisplay,
    // or if the chrome is drawn directly in CanvasNSView's draw(_:), call
    // setNeedsDisplay(in: chromeRect(for: zoneId)) for each changed model.
    // Avoid a full canvas redraw — only chrome areas changed.
    for (index, model) in models.enumerated() {
        // update stored array entry; trigger only the affected chrome rect
    }
}
```

If the `ZoneChromeNSView` path already has an `update(model:)` method (look at how zone
rename or color change currently propagates), use that exact path — do not invent a second
invalidation route.

## How we test it

### Logic (pure Core checks)

The rollup bridge from `SidebarAgentStatusRollup` to `CanvasNSView.AgentStatusRollup` is
pure math, so test it with a table-driven Core check:

- Build a `[UUID: AgentStatus]` fixture with two tiles in `.working`, one in
  `.needsAttention`, and one non-agent tile (absent from the map). Run the accumulation
  and bridge logic. Assert the resulting `CanvasNSView.AgentStatusRollup` has
  `working == 2`, `needsAttention == 1`, `done == 0`, `stale == 0`. Assert the zone that
  contains only the non-agent tile has `agentStatusRollup == .empty`.
- Assert the non-terminal-status rule for the rollup: build a fixture with one `.working`
  tile, one `.configuring` tile, and one `.idle` tile in the same zone. Run the accumulation
  and bridge. Assert the `SidebarAgentStatusRollup` has `working == 1` and `unknown == 2`
  (both configuring and idle land in `unknown` via `SidebarAgentStatusKind.kind(for:)`), and
  assert the bridged `CanvasNSView.AgentStatusRollup` has `working == 1, needsAttention == 0,
  done == 0, stale == 0` — the two `unknown` entries contribute to no canvas bucket. Assert
  `canvas.displayText == "1 working"` (never "… · 2 unknown", which the canvas type cannot
  render). A zone containing only `.configuring`/`.idle` tiles bridges to `.empty`.
- Assert the non-terminal-status rule for the per-tile badge: the `badgeStatus` helper
  returns the raw status for `.working`/`.needsAttention`/`.done`/`.stale`, and returns `nil`
  for `.configuring`, `.idle`, and absent (`nil`). This proves configuring/idle tiles paint
  no glyph.
- Assert the priority ladder is honored by `SidebarAgentStatusRollup.dominantKind`: a
  rollup with `needsAttention == 1, working == 2` returns `.needsAttention`, not `.working`.
  This is already proven by the sidebar tree ticket; run the same assertion here to confirm
  the same type is used.
- Assert the subscription teardown: construct a mock canvas, subscribe, replace the canvas,
  cancel the subscription, fire another status update, and assert the old canvas's tile views
  were not mutated.

### Backend (real-path integration)

Extend the existing `runAgentStatusBadgeSelfCheck` at `ContinuumApp.swift:7516` to cover
the observer-driven path, not just the construction-time path. The check today constructs a
canvas with hardcoded fixture statuses; add a second phase that simulates an observer
emission:

1. Construct the canvas with all tiles showing `.configuring` (the cold-start state).
2. Call `applyObserverStatuses` directly with a fixture `[UUID: AgentStatus]` mapping the
   working tile to `.working` and the needs-attention tile to `.needsAttention`.
3. Assert `canvasView.agentStatus(for: workingTileId) == .working` (reads the `TileNSView`
   property, not a model field — this proves the per-tile path updated the view object).
4. Assert `canvasView.zoneChromeSnapshot(for: zoneId)?.agentRollupText == "1 working · 1 needs you"`.
5. Assert the non-agent tile (the plain shell tile from the existing fixture) has
   `canvasView.agentStatus(for: plainTileId) == nil` after the observer emission (no badge).
6. Write a manifest to `qa-runs/<ts>/observer-rollup-wiring/manifest.json` carrying
   `observedWorkingStatus`, `observedNeedsAttentionStatus`, `zoneRollupText`,
   `plainTileHasBadge`, and `coldStartRollupText` (before the observer call) so the
   before/after delta is measurable.

This is a real-path check: `applyObserverStatuses` exercises the same code path the live
observer callback fires. It does not call the model directly and assert a model field
changed — it reads back through `canvasView.agentStatus(for:)` and `zoneChromeSnapshot`,
the same accessors the rendering path uses.

### UX (visual gate + dogfood snippet)

Add a Component Lab entry to `ComponentLab.swift` under the "Agent Status" category titled
"Observer rollup — live feed simulation." The entry is a `staticCard` that:

1. Constructs a `CanvasNSView` with one zone containing three tiles (one `.working`,
   one `.needsAttention`, one non-agent) using the fixture tiles from `LabFixtures`.
2. Sets `agentStatus` on each tile view explicitly to the three states above, then
   calls `updateZoneRenderModels` with a rollup that matches: `working: 1, needsAttention: 1`.
3. Returns the canvas view sized at 640×340.

The `runSelfCheck` will snapshot this card and assert it is non-blank (Tier-1 visual gate).
The snapshot must show both the blue `●` badge on the working tile, the orange `◆` badge
on the needs-attention tile, and the zone header text "1 needs you · 1 working" to pass a
non-blank pixel check. Because the tile badges and zone header text are AppKit-drawn (not
ghostty GPU content), they composite through `cacheDisplay` cleanly.

Dogfood snippet (concrete and navigable in under 30 seconds):

Open the app with a workspace that has at least one active Claude Code session running in
a tile. Navigate to View → Component Lab (or press `⌃Space` and then open the Lab from the
launcher). Select "Agent Status > Observer rollup — live feed simulation" in the left nav.
The right pane should show a zone with three tiles. The working tile should display a blue
`●` glyph in its title bar and the zone header should read "1 working" in blue. Switch back
to the main canvas. Observe a tile that Continuum has detected as an active Claude session:
the tile's title bar should show a blue `●` "working" badge (or orange `◆` "needs you" if
Claude is waiting). The zone header above that tile should read "1 working" (or "1 needs
you") rather than being empty. If the tile finishes its run and Claude exits, within one
observer debounce window (at most 250 ms after the FSEvents notification) the badge should
change to `✓` "done" in green and the zone header should update to "1 done". The zone
header should never show the hardcoded "1 working · 1 needs you" that was present before
this ticket — confirm by creating a new zone with no agent tiles and verifying the zone
header is empty.

## Execution mode

Supervised. The Logic check and Backend check are machine-verifiable and will run in the
matrix. But the core claim of this ticket — that the zone chrome updates live when the
observer fires, that the badge color is visually correct, that the rollup text is accurate
and non-stale — requires a human eye on the actual running app. The dogfood snippet above
is the gate: open the app, observe a real Claude session, and confirm the badge and zone
header reflect the live signal rather than a cached or hardcoded value. No matrix check
can substitute for this because the observer's file-watch event path (FSEvents → debounce
→ reader → derivation → publish) runs through the live OS and cannot be fully exercised
headlessly.

## Done when

- [ ] The `zoneRenderModels(from:registry:)` static method no longer calls
  `agentStatusRollup(for:)` on each canvas rebuild; instead, the observer subscription
  drives all post-construction rollup updates.
- [ ] `applyObserverStatuses(_:)` (or equivalent) exists, is called on every observer
  emission, and updates both per-tile `agentStatus` on each `TileNSView` and the
  `agentStatusRollup` on each `ZoneRenderModel`.
- [ ] Non-agent tiles (absent from the observer's `[UUID: AgentStatus]` map) have
  `agentStatus == nil` after an observer emission — confirmed by the Backend check asserting
  `plainTileHasBadge == false` in the manifest.
- [ ] The Backend real-path check passes: `agentStatus(for: workingTileId) == .working`,
  `agentStatus(for: needsTileId) == .needsAttention`, and
  `zoneChromeSnapshot(for: zoneId)?.agentRollupText == "1 working · 1 needs you"` after
  calling `applyObserverStatuses` with the fixture map.
- [ ] The Backend manifest at `qa-runs/<ts>/observer-rollup-wiring/manifest.json` exists
  and contains `coldStartRollupText`, `observedWorkingStatus`, `observedNeedsAttentionStatus`,
  `zoneRollupText`, and `plainTileHasBadge` with correct measured values.
- [ ] The Component Lab "Observer rollup — live feed simulation" entry exists and
  `runSelfCheck` passes its Tier-1 non-blank assertion on the snapshot.
- [ ] The observer subscription cancellable is stored adjacent to `canvasView` and is
  explicitly cancelled before the canvas is replaced on any workspace or project switch
  — confirmed by the subscription-teardown Logic check.
- [ ] The dogfood snippet produces the expected badge and zone header behavior in the
  real running app: a live Claude session shows `●` working in blue, the zone header reads
  "1 working", and the badge changes to `✓` done in green when Claude exits.
- [ ] No hardcoded `AgentStatusRollup(working: 1, needsAttention: 1, ...)` literal remains
  at `CanvasNSView.swift:3128` or anywhere in the production code path (only in tests and
  Lab fixtures) — confirmed by a grep.

## Depends on / unblocks

Depends on the session observer with budgets, which must be publishing a `[UUID: AgentStatus]`
dictionary (via Combine or a callback) on the main queue. It also depends on all three
concrete readers (Claude, Pi, Codex), the FSEvents push watch, and the pure
status-derivation function, because those are what give the observer meaningful output to
publish. Without a real observer, this ticket's subscription wires to nothing and all the
visual behavior falls back to the cold-start disk read — which is acceptable for
compilation, but the dogfood gate cannot be satisfied.

The `agentKind` closed-enum ticket and the `AgentStateReader` protocol ticket are indirect
prerequisites via the observer, but this ticket does not import them directly — it only
receives the derivation output.

Directly unblocked by this ticket: feeding the sidebar tree from the observer (the next
ticket in Phase 3), which reuses the same observer publisher and the same `[UUID: AgentStatus]`
map to drive `SidebarTreeBuilder`. The sidebar feed ticket can begin once the observer
subscription pattern is established here. Also unblocked: the activity surface dock render
and the dock toggle, because those tickets need a proven observer-to-UI pipeline before they
can be trusted to show live data.

## Watch out for

**The subscription teardown is the most common source of subtle bugs here.** If the
cancellable is not stored, the subscription is released immediately and no updates ever
fire. If it is stored but not cancelled on canvas replacement, the old subscription fires
against the new canvas's tile views — emitting statuses for tile IDs that no longer exist
in the new canvas, potentially no-op or, worse, reusing a tile ID that coincidentally
exists in both canvases with different intent. Cancel before replace; always.

**The `zoneRenderModels` method is called from multiple sites** (boot, workspace switch,
zone add/remove, project add/remove). After this ticket, none of those calls should
recompute the agent rollup — they should produce models with `.empty` rollups (or the
most-recently-published observer snapshot if you cache it). If any of those call sites
still calls `agentStatusRollup(for:)`, it will do a synchronous disk read on the main
queue on every zone structural event, which will be slow and will race with the observer's
file-watch reads. Remove all production calls to `agentStatusRollup(for:)` outside the
cold-start initializer.

**The tile-zone membership map must be fresh.** The `applyObserverStatuses` method needs to
know which tile belongs to which zone to compute per-zone rollups. If this map is stale
(built at canvas construction and never refreshed), a tile that was moved to a different
zone will be counted in the wrong zone's rollup. Rebuild the map from the workspace document
on every observer emission, or subscribe to zone-membership changes and refresh it. A stale
map shows "0 working" in a zone that has a working agent — the dogfood check will catch this.

**Status for tiles not in the observer snapshot must be `nil`, not `stale`.** The observer
only emits statuses for tiles it has detected as agents. A plain shell tile (no agent
running) will not appear in the map. That tile's badge must be cleared to `nil`
(no badge) — not set to `.stale`. Setting it to `.stale` would show a gray hollow circle on
every plain terminal tile, which is misleading. The only tiles that should show `.stale` are
those the observer explicitly returns `.stale` for (tiles that previously had a reader
result and whose evidence has gone cold).

**Do not merge `CanvasNSView.AgentStatusRollup` and `SidebarAgentStatusRollup`.** Both
types carry the same four integer fields and could theoretically be unified. Do not do this
here — it is a refactor that touches the sidebar tree builder, the canvas chrome, and every
self-check that constructs either type. The bridge is two lines; the refactor is a
distraction from the ticket's goal and belongs in a separate cleanup if warranted.
