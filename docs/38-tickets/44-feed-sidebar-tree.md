# Feed the sidebar tree from the observer

## What this delivers

The workspace sidebar goes from showing statuses assembled from persisted session files and
live canvas views — a polling snapshot that goes cold the moment an agent changes state — to
showing statuses pushed in real time by the `SessionObserver`. Every tile row and zone
rollup in the left dock reflects the observer's live `[UUID: AgentStatus]` output as soon
as the observer publishes a new snapshot, with no polling and no manual nudge required.

From the user's perspective, the sidebar becomes a trustworthy fleet monitor. When a Claude
agent transitions from `working` to `needsAttention`, the tile row flips from a blue filled
circle to an orange diamond and the zone rollup text changes — all within the observer's
250-millisecond debounce window (D13) — without anyone reloading the sidebar manually or
toggling a tile.

From the system's perspective, the last mock-shaped gap in the status pipeline closes.
`SidebarTreeBuilder.build(agentStatusesByTileId:)` already accepts a live map;
`WorkspaceSidebarView.reload(tree:)` already renders it; the observer already produces
per-tile `AgentStatus` outputs. This ticket wires the three pieces together and proves the
wiring with a real-path check and a visual gate.

Rests on **D21** (activity surface = live-fed left dock) and **D13** (observer budgets +
250 ms debounce, which set the update cadence this ticket consumes).

## How it fits

This ticket is the downstream consumer of the `SessionObserver` with budgets (D13). The
observer emits a `[UUID: AgentStatus]` map whenever any watched tile's status changes; this
ticket subscribes to that emission and routes it into the tree builder that already exists in
`buildWorkspaceSidebarTree()` inside `AppDelegate`.

The existing `workspaceSidebarAgentStatuses(registry:projectCanvases:)` method reads
persisted session descriptors and the live canvas view as a one-shot snapshot. That method
remains as a cold-start fallback — used on first load before the observer has produced any
output — but is superseded for subsequent updates by the observer's pushed values.

This ticket directly unblocks rendering the left dock (the ticket that follows), because a
rendered dock is only meaningful when it's fed real signal. The jump-to-tile wiring and the
dock toggle/width persistence can also land in parallel once the tree is live.

## The subscription seam this ticket defines

This ticket owns the consumer half of the observer-to-sidebar seam and **states the exact
contract here** rather than deferring it — the observer must expose the emission this
consumer subscribes to. Do not leave the callback shape open; it is fixed below.

**The `SessionObserver` MUST expose this callback property** (this is the contract the
observer ticket delivers; it is stated here so this ticket is self-contained):

```swift
// On SessionObserver (delivered by the observer ticket per D13):
//   The observer stores the caller's closure and invokes it — on the observer's own
//   publication queue — with the full debounced [UUID: AgentStatus] snapshot each time any
//   watched tile's status changes, subject to the D13 budgets (250 ms debounce,
//   10 status-changes/min/tile).
var onStatusesChanged: (([UUID: AgentStatus]) -> Void)? { get set }
```

**The installation point in `AppDelegate` is exactly where the active `SessionObserver`
handle is set.** In this codebase, `AppDelegate` acquires and swaps the per-project observer
through the same lifecycle path that swaps `workspaceRuntime` / `projectStore` on project
activation and teardown. Register `onStatusesChanged` immediately after the observer handle
is assigned, and clear the stored snapshot immediately after the handle is torn down. If the
observer ticket's landed API differs in *name* (e.g. it exposes `addStatusesObserver { … }`
or an `AsyncStream` instead of a settable closure property), adapt the two registration
call-sites below to that exact API — the *behavior* (store snapshot on main, reload; clear on
teardown) does not change. Everything else in this ticket is unaffected.

There is exactly one open coordination point with the observer ticket: whether the emission
is a settable closure property (`onStatusesChanged`) or an add-observer/stream API. Both are
handled by the two call-sites below; pick the matching form when the observer lands. No other
question about the seam remains.

## The approach

The observer publishes a `[UUID: AgentStatus]` snapshot each time any watched tile's status
in the observed project changes, subject to its 250-millisecond debounce and its 10
status-changes-per-minute-per-tile budget (D13). On each observer publication, `AppDelegate`
stores the latest snapshot into a private `var observedAgentStatuses: [UUID: AgentStatus]`
property and immediately calls `reloadWorkspaceSidebar()`.

`buildWorkspaceSidebarTree()` is updated to merge `observedAgentStatuses` on top of the
cold-start snapshot from `workspaceSidebarAgentStatuses`. The observer-supplied values win
for any tile the observer is watching; the cold-start values fill in for tiles not yet in
the observer's coverage. `SidebarTreeBuilder.build(agentStatusesByTileId:)` receives the
merged map and produces the tree exactly as it does today — no changes to the builder or
the view.

The observer's callback is dispatched on the main queue before calling
`reloadWorkspaceSidebar()`, matching the existing pattern in `updateAgentStatus(tileId:status:now:)`,
which calls `reloadWorkspaceSidebar()` synchronously on the main thread. There are no new
threading primitives and no new actor boundaries.

## Where it lives

**Primary seam — `Sources/ContinuumRevived/App/ContinuumApp.swift`**

Method *names* are the stable anchors; the line numbers below were verified against the
current file but treat the name as authoritative if the file has drifted.

- `AppDelegate.workspaceSidebarAgentStatuses(registry:projectCanvases:)` (`func` at line
  4451) — the existing cold-start snapshot method; unchanged in behavior, used as the base
  layer.
- `AppDelegate.buildWorkspaceSidebarTree()` (`func` at line 4412) — updated to merge
  `observedAgentStatuses` on top of the cold-start values before passing the map to the
  builder.
- `AppDelegate.reloadWorkspaceSidebar()` (`func` at line 4476) — called by the observer
  callback; already calls `buildWorkspaceSidebarTree()`, so no structural change is needed here.
- `AppDelegate.updateAgentStatus(tileId:status:now:)` (`func` at line 3826) — the existing
  per-tile update path; stays as-is; continues to call `reloadWorkspaceSidebar()` and update
  persisted sessions. The observer path does not replace this for the cases it already
  handles; the two paths coexist. This is also the reference for main-thread dispatch.

**New property on `AppDelegate`:**
- `private var observedAgentStatuses: [UUID: AgentStatus] = [:]` — stores the latest
  snapshot from the observer, replacing its own value on each observer publication. Place it
  in the private-var cluster that holds `canvasView` / `workspaceSidebarView` /
  `workspaceSplitView` (the `private var workspaceSidebarView: WorkspaceSidebarView?`
  declaration, verified near line 2217) — i.e. alongside the other sidebar-adjacent UI state.

**Observer subscription (two call-sites):**
- **On observer install** (where the active `SessionObserver` handle is assigned, the same
  lifecycle path that assigns `workspaceRuntime` on project activation): set
  `onStatusesChanged` per the pseudo-code below.
- **On observer teardown** (project close / observer replacement): clear
  `observedAgentStatuses` and call `reloadWorkspaceSidebar()` once, so the sidebar reverts to
  cold-start values instead of showing stale observer output. This must be symmetric with the
  install call-site.

**Not touched:**
- `SidebarTreeBuilder` (`Sources/ContinuumRevivedCore/SidebarTree.swift`) — already accepts
  `agentStatusesByTileId: [UUID: AgentStatus]` (`build(...)` at line 135); no changes.
- `WorkspaceSidebarView` (`Sources/ContinuumRevived/App/WorkspaceSidebarView.swift`) — already
  renders the map it receives; no changes.
- The observer itself — this ticket is a consumer, not a modifier of the observer.

## Implementation breadcrumbs

These snippets are the authoritative shape for this ticket. Use them directly; adapt only the
*registration form* if the observer's landed API is an add-observer/stream instead of a
settable closure property (see "The subscription seam this ticket defines").

```swift
// In AppDelegate, in the private-var cluster next to `workspaceSidebarView` (~line 2217):
private var observedAgentStatuses: [UUID: AgentStatus] = [:]

// INSTALL call-site: immediately after the active SessionObserver handle is assigned
// (same lifecycle path that assigns workspaceRuntime on project activation).
observer.onStatusesChanged = { [weak self] statuses in
    DispatchQueue.main.async {
        self?.observedAgentStatuses = statuses
        self?.reloadWorkspaceSidebar()
    }
}

// TEARDOWN call-site: immediately after the observer handle is cleared/replaced
// (project close or observer swap). Symmetric with INSTALL.
observedAgentStatuses = [:]
reloadWorkspaceSidebar()

// In buildWorkspaceSidebarTree(), after assembling the cold-start map:
private func buildWorkspaceSidebarTree() throws -> SidebarTree {
    // ... existing registry/documents/projectCanvases assembly ...

    // Cold-start base: persisted sessions + live canvas views
    var agentStatuses = workspaceSidebarAgentStatuses(registry: registry, projectCanvases: projectCanvases)

    // Observer layer wins for any tile it has watched; fills in the rest
    for (tileId, status) in observedAgentStatuses {
        agentStatuses[tileId] = status
    }

    return SidebarTreeBuilder.build(
        registry: registry,
        documents: documents,
        projectCanvases: projectCanvases,
        agentStatusesByTileId: agentStatuses
    )
}
```

The `onStatusesChanged` closure must be re-registered whenever the active `SessionObserver`
is replaced (e.g., on project switch) — that is what the INSTALL call-site guarantees, since
it runs on every observer assignment. The TEARDOWN call-site guarantees the map never carries
a previous project's values into the next.

## How we test it

### Logic (pure Core checks)

This project has **no `swift test` / XCTest target**. Pure-Core logic checks are executable
assertions in `Sources/ContinuumRevivedCoreChecks/main.swift` (an `expect(...)`-based
executable), run via `swift run ContinuumRevivedCoreChecks`. A sidebar-tree check block
already exists there (search for `SidebarTreeBuilder.build` — the block is around line 5347).

`SidebarTreeBuilder.build(agentStatusesByTileId:)` is already pure and already covered by
that block. Add **one new `do { … }` block in `Sources/ContinuumRevivedCoreChecks/main.swift`,
adjacent to the existing sidebar block**, that asserts the merge priority. This ticket does
*not* create a new test suite and does not use `swift test --filter`; there is nothing to
filter against.

Because the merge itself lives in `AppDelegate` (not in `SidebarTreeBuilder`), the pure-Core
check exercises the *builder's* behavior under the two maps the merge produces — it proves
the builder faithfully carries whichever status it is handed, which is the half of the merge
that lives in Core:

- Build a `SidebarTree` handing tile A `.stale` (the cold-start value), assert
  `SidebarTileRow.agentStatus == .stale` for tile A.
- Build again handing tile A `.working` (the observer override value), assert
  `SidebarTileRow.agentStatus == .working` for tile A.
- Also assert the reverse direction the merge must honor: hand tile B `.needsAttention` (the
  observer value) and confirm the builder carries `.needsAttention`, proving that whatever
  the merge places on top is what renders.

The merge *direction* itself (observer-wins over cold-start in the same map) is asserted in
the backend real-path check below, where the actual `buildWorkspaceSidebarTree()` merge runs.

Run via `swift run ContinuumRevivedCoreChecks` — no daemon, no process, no disk write; it
exits non-zero on the first failed `expect`.

### Backend (real-path / integration, not bypassed)

Extend the existing `--workspace-sidebar-live-status-check` shell check in
`Sources/ContinuumRevived/App/ContinuumApp.swift` (the `runWorkspaceSidebarLiveStatusSelfCheck`
static method, verified at **line 4979**). The existing check already sets
`TileNSView.agentStatus` properties and calls `reloadWorkspaceSidebar()` to prove the sidebar
renders status correctly from the canvas view layer. Add a new assertion block after the
existing ones that simulates observer output through the exact merge path this ticket adds:

```swift
// Simulate the observer publishing a new snapshot (this is what onStatusesChanged stores)
app.observedAgentStatuses = [workingTileId: .needsAttention, doneTileId: .working]
app.reloadWorkspaceSidebar()
sidebar.layoutSubtreeIfNeeded()

// The observer values must win over the previously-set canvas/session values
try expect(
    sidebar.tileStatusTextForQA(workspaceId: workspaceId, zoneId: projectZoneId, tileId: workingTileId) == "needs you",
    "observer-supplied needsAttention must override the canvas-layer working status"
)
try expect(
    sidebar.tileStatusTextForQA(workspaceId: workspaceId, zoneId: projectZoneId, tileId: doneTileId) == "working",
    "observer-supplied working must override the persisted done status"
)
try expect(
    sidebar.zoneStatusTextForQA(workspaceId: workspaceId, zoneId: projectZoneId)?.contains("1 needs you") == true,
    "zone rollup must reflect the observer-derived attention status"
)

// Observer cleared (teardown path): sidebar must fall back to cold-start values
app.observedAgentStatuses = [:]
app.reloadWorkspaceSidebar()
sidebar.layoutSubtreeIfNeeded()
try expect(
    sidebar.tileStatusTextForQA(workspaceId: workspaceId, zoneId: projectZoneId, tileId: workingTileId) == "working",
    "clearing observer output must revert to the canvas/persisted layer"
)
```

Because `observedAgentStatuses` is `private`, the self-check accesses it through the same
in-process path the check already uses to reach `AppDelegate` internals (the check is
declared inside the type, so it can read/write the private property directly). If the check
lives outside the type, add a `#if`-gated internal test hook mirroring the existing QA
accessors — do not widen `observedAgentStatuses` to `internal`/`public` for production.

Add the new assertion outcomes (with measured values, never `{passed:true}`) to the manifest
JSON the check writes to `qa-runs/<timestamp>/workspace-sidebar-live-status/manifest.json`,
alongside the existing fields. The check runs with
`swift run ContinuumRevived --workspace-sidebar-live-status-check` and exits 0 only if all
assertions pass. This drives `AppDelegate.reloadWorkspaceSidebar()` — and therefore the real
`buildWorkspaceSidebarTree()` merge — through the true event path, not a direct
tree-builder call, per the verification doctrine (D26).

### UX (visual gate + dogfood snippet)

The `WorkspaceSidebarView` is an AppKit view that composites through `cacheDisplay`. Add the
updated sidebar — loaded with the observer-driven status map — as a `ComponentLab` entry so
`ComponentLab.runSelfCheck()` renders it over an opaque dark backdrop and asserts the
snapshot is non-blank via `VisualSnapshot.metrics` (never `bytes>0`). The entry should seed
the sidebar with a workspace containing two zones: one with a `needsAttention` tile (orange
`◆` glyph) and one with a `working` tile (blue `●` glyph), mirroring the mixed-status
scenario the real observer produces. The check writes the PNG to `qa-runs/`.

Concrete dogfood snippet: Open the app with a project that has a running Claude agent in one
tile and an idle terminal in another. The left dock is visible. Observe the working agent's
tile row showing a blue `●` and the status text `working`. Now trigger a state change in the
observer's output — the simplest path is to run
`swift run ContinuumRevived --workspace-sidebar-live-status-check` to prove the pipeline,
then dogfood the live app: in a tile running a long-running command, let the command
complete. Within the observer's 250-millisecond debounce window (D13; you will see the change
in under a second), the tile row must flip from `● working` in blue to `✓ done` in green, and
the zone rollup text must update accordingly, without any manual reload or tile interaction.
No glyph should stutter or flicker between values.

## Execution mode

**Supervised.** The logic check (`swift run ContinuumRevivedCoreChecks`) and the real-path
backend check (`--workspace-sidebar-live-status-check`) are both automatable and run without
human eyes. However, the UX gate requires a human to confirm that the sidebar glyphs and
colors render correctly in the running app — the `cacheDisplay` snapshot proves the surface
is non-blank, but confirming that blue `●` transitions to orange `◆` and back without visual
artifacts requires the dogfood pass. The 250-millisecond debounce window and the
merge-priority behavior are mechanical, but the rendered result is the verification.

## Done when

- [ ] `AppDelegate` has a `private var observedAgentStatuses: [UUID: AgentStatus] = [:]`
  property in the sidebar-adjacent private-var cluster; it is never `internal` or `public`.
- [ ] `buildWorkspaceSidebarTree()` merges `observedAgentStatuses` on top of the cold-start
  values from `workspaceSidebarAgentStatuses`, with observer values winning for any tile
  present in both maps.
- [ ] The observer subscription is registered at the INSTALL call-site (where the active
  `SessionObserver` handle is assigned) via `onStatusesChanged` (or the observer's landed
  add-observer/stream equivalent), storing the snapshot into `observedAgentStatuses` and
  calling `reloadWorkspaceSidebar()` on the main queue.
- [ ] The TEARDOWN call-site (project close / observer replacement) clears
  `observedAgentStatuses` and calls `reloadWorkspaceSidebar()` once so the sidebar falls back
  to cold-start values; it is symmetric with the INSTALL call-site.
- [ ] The new merge-priority logic block in `Sources/ContinuumRevivedCoreChecks/main.swift`
  passes with `swift run ContinuumRevivedCoreChecks`.
- [ ] The extended `--workspace-sidebar-live-status-check` passes with all new assertions
  (observer override wins; clearing reverts; zone rollup reflects observer-derived attention
  status); the manifest includes the new assertion outcomes with measured values.
- [ ] The `ComponentLab` entry for the observer-fed sidebar renders a non-blank PNG via
  `VisualSnapshot.metrics` and is included in `ComponentLab.runSelfCheck()`.
- [ ] The dogfood snippet is verified: a status change from the observer is visible in the
  sidebar within one second of the agent state change, with no manual reload.
- [ ] `swift build` passes with no new warnings.
- [ ] No existing checks (`ContinuumRevivedCoreChecks`, the sidebar live-status self-check,
  `ComponentLab.runSelfCheck()`) are broken or deleted.

## Depends on / unblocks

This ticket depends on the `SessionObserver` with budgets (D13). The observer must exist and
must expose the `[UUID: AgentStatus]` emission this ticket subscribes to. **This ticket
fixes the shape of that emission** (see "The subscription seam this ticket defines"): a
`var onStatusesChanged: (([UUID: AgentStatus]) -> Void)?` callback, or an equivalent
add-observer/stream API the two call-sites adapt to. Without the observer landed, the INSTALL
call-site has no handle to attach to — so land the observer first, then wire this. Do not stub
the observer or fabricate a fake subscription; the contract above is the real seam the
observer must satisfy.

This ticket also depends on the `AgentKind` closed enum (D14) and the pure status-derivation
function, both of which the observer itself depends on. Those prerequisites are upstream of
the observer and are satisfied before the observer ticket lands.

This ticket directly unblocks rendering the left dock as a persistent, resizable,
default-visible surface (D21). The dock render ticket consumes the live tree that this ticket
feeds; it cannot deliver a meaningful visual result without real observer data behind it. The
jump-to-tile wiring and the dock toggle / width persistence tickets can proceed in parallel
once this ticket lands, because they depend on the dock surface being present, not on the
specific status source.

## Watch out for

**The hardest thing to get right: clearing `observedAgentStatuses` on observer teardown.**
If the `observedAgentStatuses` map is not cleared when the active observer is replaced or
when the active project closes, stale observer values from the previous project persist in
the map and override the cold-start values for the new project's tiles — which may happen
to share UUID values if any fixtures use deterministic IDs, or may silently show old
statuses for tiles that no longer exist in the current workspace. The TEARDOWN call-site that
clears the map and triggers a reload must be symmetric with the INSTALL call-site. Every path
that sets a new observer must also clear the old map.

**The merge direction is observer-wins, not union.** The purpose of the merge is to let the
observer override stale persisted values. If the merge is reversed — cold-start wins for
tiles present in both maps — the entire point of this ticket is defeated, because the
persisted session descriptor is the stale value the observer is supposed to supersede.
The backend real-path check specifically asserts `observer(.needsAttention) + cold(.working)
→ needs you` and `observer(.working) + cold(.done) → working`; make sure the merge in
`buildWorkspaceSidebarTree()` writes observer values *on top of* the cold-start map, not the
reverse.

**Do not call `reloadWorkspaceSidebar()` from off the main queue.** The existing
`updateAgentStatus(tileId:status:now:)` (line 3826) calls `reloadWorkspaceSidebar()`
synchronously on the main thread. The observer callback arrives on whatever queue the
observer uses for publication; always dispatch to `DispatchQueue.main.async` before storing
`observedAgentStatuses` and calling `reloadWorkspaceSidebar()`. Calling `reload` off-main
will crash in the sidebar view's data-source path.

**Do not remove `workspaceSidebarAgentStatuses` or bypass the cold-start path.** That
method provides the fallback for tiles the observer is not yet watching — ambient tiles in
group zones, tiles in workspaces with no active observer, and tiles in projects that have
not yet been opened. Removing it or short-circuiting it means those tiles show "no agent"
even when their persisted session descriptor has valid status.
