# T16 — Sidebar `NSOutlineView` (name / color / navKey / switch / jump)

Status: todo
Tag: morning [appkit]
Depends on: T15 (pure sidebar view-model), T09 (`switchWorkspace(to:)` in-process) · Blocks: —

⚠ **`[morning]` task.** Implement + write the headless `--sidebar-check` + self-review
overnight, but **do NOT auto-mark Done and do NOT commit as Done**. The check can prove the
data-source/click/rename/persistence wiring headlessly; it **cannot** see flicker, z-paint,
cursor-rects, divider-drag feel, or rename-field focus behavior. Land the diff staged with the
"What Dylan must eyeball" list below; Done only after Dylan confirms the visual/feel gate on a
rebuilt bundle (§ Conventions 1.8 / 6).

## Goal
Give the workspace/zone model a **visible, clickable home**: a two-level source list on the
left of the main window. Top level = workspaces; each workspace's children = its zones. Each
row shows name + color swatch, supports inline rename and (for zones) a per-zone nav-key edit,
and collapses/expands. **Clicking a workspace row switches to it in-process** (the T09
keystone — no relaunch); **clicking a zone row pans/focuses that zone**. This is the UX surface
that makes the whole sprint's model legible and operable without ⌘K. ⌘K (T17) stays the
keyboard-fast path; this is the pointer path.

## Exact scope — files & symbols
- **`Sources/ContinuumRevived/App/WorkspaceSidebar.swift`** (NEW file) — the entire AppKit
  shell, `@MainActor final class WorkspaceSidebar: NSObject, NSOutlineViewDataSource,
  NSOutlineViewDelegate, NSTextFieldDelegate`. Owns:
  - `private let outlineView: NSOutlineView` inside an `NSScrollView` (model the construction
    on `SettingsPanel`'s `NSTableView` source-list at `SettingsPanel.swift:103`).
  - `private var tree: SidebarTree` (the **T15** view-model, set verbatim — never re-derived
    here).
  - `func reload(tree: SidebarTree)` — store the tree and `outlineView.reloadData()`.
  - **Callback seams** the AppDelegate wires to production behavior (so the check can spy them
    and the class stays free of `switchWorkspace`/canvas internals):
    - `var onSwitchWorkspace: ((UUID) -> Void)?`
    - `var onJumpToZone: ((UUID) -> Void)?`
    - `var onRenameWorkspace: ((UUID, String) -> Void)?`
    - `var onRenameZone: ((UUID, String) -> Void)?`
    - `var onEditZoneNavKey: ((UUID, String?) -> Void)?`
  - The `NSOutlineViewDataSource` methods (`child(_:ofItem:)`, `isItemExpandable`,
    `numberOfChildrenOfItem`, `objectValue…`), an `outlineViewSelectionDidChange(_:)` /
    explicit click action that fires `onSwitchWorkspace` / `onJumpToZone` by **row kind**, and
    `NSTextFieldDelegate.controlTextDidEndEditing` that routes a committed rename to
    `onRenameWorkspace` / `onRenameZone` and a committed nav-key edit to `onEditZoneNavKey`.
  - A private row-item enum `SidebarItem { case workspace(SidebarWorkspaceRow); case
    zone(SidebarZoneRow) }` used as the outline-view item objects (kept off `SidebarTree` so
    Core stays AppKit-free).
- **`Sources/ContinuumRevived/App/ContinuumApp.swift`**:
  - Window content wiring (~:1219–1228, where `window.contentView = canvasView`): wrap the
    canvas in an **inset `NSSplitView`** (`isVertical = true`, `dividerStyle = .thin`) with the
    sidebar's scroll view as the leading pane and `canvasView` as the trailing pane; set
    `splitView` as the window content view. **Inset split, not an overlay** (charter §1 sidebar).
  - A `private var workspaceSidebar: WorkspaceSidebar?` field next to the other UI fields.
  - A `private func buildSidebarTree() -> SidebarTree` helper that loads each
    `registry.workspaces` document via `WorkspaceStore(workspaceId:applicationSupportDirectory:)`
    into `[UUID: WorkspaceDocument]` and returns `SidebarTreeBuilder.build(registry:documents:)`
    (T15). Call it to seed/reload the sidebar after switch / rename / nav-key edit / add-zone.
  - Wire the five callbacks: `onSwitchWorkspace` → `workspaceRuntime.switchWorkspace(to:)`
    (T09); `onJumpToZone` → the zone pan/focus helper (below); `onRenameWorkspace` → the
    existing `renameWorkspace(workspaceId:name:)` (:2911); `onRenameZone` /`onEditZoneNavKey` →
    a new persistence helper that mutates the zone's `ZonePlacement` in its `WorkspaceDocument`
    and `WorkspaceStore.save`s it (model the load→mutate→save on `addProjectZone`, :2961+).
  - `private func jumpToZone(_ zoneId: UUID)` — pan/focus the active canvas to a zone:
    `canvasView?.fitZoneToViewport(zoneId:)` → `setViewport(_:)` (the existing zone-fit path at
    `CanvasNSView.swift:460/446`); if the zone belongs to a *different* workspace, switch first
    (call `onSwitchWorkspace` equivalent) then fit. (See gotcha G3 on cross-workspace jump.)
  - A NEW static check `runSidebarSelfCheck()` (see § The check) + its dispatch in the
    `CommandLine.arguments` ladder (model on the `--add-zone-check` block, ~:566).
- **`Sources/ContinuumRevivedCore/SidebarChromeConfig.swift`** (NEW file) — the
  configurable-first home for this task's two NEW display preferences (see § Data/API changes,
  configurable-first). Mirrors the `DragMagnetizeConfig` shape
  (`DragMagnetizeConfig.swift:9-20`): static `…Key` strings, static defaults, a `resolve…`
  that reads `UserDefaults` with the default fallback.
- **`Sources/ContinuumRevivedCore/SettingsSchema.swift`** — append two `SettingsField`s for the
  two new keys (see § Data/API changes).
- **`scripts/run-matrix.sh`** — register `run_app_check .build/debug/continuum-revived
  --sidebar-check` after the `--add-zone-check` line (:108).
- **Do NOT touch:**
  - `switchWorkspace` **internals** (T09 — `WorkspaceRuntime.swift`). T16 only *calls*
    `workspaceRuntime.switchWorkspace(to:)` and spies it in the check via the `onSwitchWorkspace`
    seam.
  - The **view-model** (`SidebarTree`/`SidebarWorkspaceRow`/`SidebarZoneRow`/
    `SidebarTreeBuilder`, T15) — consume verbatim; do NOT re-sort, re-backfill, or add fields.
  - **⌘K / palette** (`LaunchPaletteModel`, the palette dispatch at :2824–2840) — T17 owns the
    keyboard zone-row path. Do not add/alter palette rows here.
  - `ZonePlacement` / `WorkspaceDocument` **shape** (T01 owns the model; here you only read the
    fields and write back `name`/`navKey` via the existing `WorkspaceStore.save`).
  - The 4 window-scoped NSEvent monitors (ADR-0024), `CanvasEngine` transforms, `FocusBroker`
    internals.
  - `ZoneRuntimeController`, `CanvasNSView` zone-layer internals (T05/T06).

## Data / API changes
**New sidebar shell (App target), copy-pasteable surface:**
```swift
@MainActor
final class WorkspaceSidebar: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    enum SidebarItem { case workspace(SidebarWorkspaceRow); case zone(SidebarZoneRow) }
    var onSwitchWorkspace: ((UUID) -> Void)?
    var onJumpToZone: ((UUID) -> Void)?
    var onRenameWorkspace: ((UUID, String) -> Void)?
    var onRenameZone: ((UUID, String) -> Void)?
    var onEditZoneNavKey: ((UUID, String?) -> Void)?   // nil clears → auto ordinal
    let scrollView: NSScrollView
    init()
    func reload(tree: SidebarTree)
    // For the headless check (no NSEvent needed for these — they are the production entry
    // points the click/rename handlers themselves call):
    func qaClickRow(at index: Int) // walks the flattened expanded rows, fires switch/jump by kind
    func qaCommitRename(itemAt index: Int, to newName: String)
    func qaCommitNavKey(zoneAt index: Int, to navKey: String?)
}
```
> The `qa*` methods are **not** a bypass: they are the *same* code the real
> `outlineViewSelectionDidChange` / `controlTextDidEndEditing` handlers run — they exist so the
> check drives the production routing logic with a deterministic row index instead of
> reconstructing an `NSOutlineView` click hit-test (which is untestable headlessly without a
> live window/run-loop). The handler bodies (`switch item { … fire callback … }`) are shared.
> A reviewer must confirm the real `NSOutlineViewDelegate` selection handler and the `qaClickRow`
> path call **one** shared private `func activate(_ item: SidebarItem)` — not two divergent
> implementations. (See Review rubric R1.)

**Configurable-first — two NEW display preferences (this task ships them in full):**
- `SidebarChromeConfig.visibleKey = "continuum.sidebar.visible"`, `defaultVisible = true` —
  whether the inset sidebar pane is shown at launch. Resolved at window build to set the split's
  initial collapsed state. (A view toggle is a binding → must be persisted + in Settings.)
- `SidebarChromeConfig.showNavKeysKey = "continuum.sidebar.showNavKeys"`, `defaultShowNavKeys =
  true` — whether zone rows render their nav-key affordance. Read by the delegate's
  `viewFor`/cell builder.
- `SidebarChromeConfig.resolveVisible(defaults:) -> Bool` and `resolveShowNavKeys(defaults:) ->
  Bool`, each `defaults.object(forKey:) != nil ? defaults.bool(forKey:) : default` (exact
  `DragMagnetizeConfig` idiom).
- `SettingsSchema.sections()` "General" section gains two `.toggle` fields:
  `.toggle(key: SidebarChromeConfig.visibleKey, label: "Show Sidebar", default:
  SidebarChromeConfig.defaultVisible)` and `.toggle(key: SidebarChromeConfig.showNavKeysKey,
  label: "Sidebar Nav Keys", default: SidebarChromeConfig.defaultShowNavKeys)`.
- **Conflict-guard for the per-zone nav-key edit:** the nav-key edit field accepts a single char
  or empty (→ nil). Before routing `onEditZoneNavKey(zoneId, key)`, the handler must reject a key
  that **collides with a reserved leader binding** — reuse `NavKeymap.resolve(...)`'s reserved
  set (`up/down/left/right/nextZone/previousZone/zonePicker/workspacePicker/agentCycle/
  agentNeedsAttention/focusMode/deleteTile` single-char tokens) and reject a duplicate of another
  zone's `navKey` **within the same workspace document**. A rejected edit leaves the stored
  `navKey` unchanged and is asserted in the check (assertion 9). The conflict predicate lives in
  Core as `SidebarChromeConfig.navKeyConflicts(_:against:reserved:) -> Bool` so it is unit-pinned
  by the check, not buried in AppKit.

> **navKey itself is NOT a UserDefaults binding** — it persists on the `ZonePlacement` in the
> workspace document (T01 model field). The configurable-first rule is satisfied by the two
> *display* preferences above (each with default + Settings entry) plus the nav-key
> *conflict-guard* (the rule's third clause). No threshold is hardcoded.

## The check, written FIRST (spec-as-test) — `--sidebar-check`
Register in `scripts/run-matrix.sh` (after `--add-zone-check`) **and** the
`CommandLine.arguments` dispatch in `ContinuumApp.swift`. Static
`AppDelegate.runSidebarSelfCheck() throws` modeled on `runFocusBrokerActivationSelfCheck`
(:6576) — it builds a **real** `WorkspaceSidebar`, feeds it a **real** `SidebarTree` built by
the **production** `SidebarTreeBuilder.build` from a synthetic `Registry` + on-disk
`WorkspaceDocument`s in a temp `CONTINUUM_APP_SUPPORT`, then drives the sidebar's production
data-source / click / rename / nav-key handlers and asserts **observable** results: the
data-source's returned items, spied callback fires, and the **on-disk JSON after a write**.

### Fixture (every value hand-derivable, fixed UUID literals)
- Temp `appSupport = NSTemporaryDirectory()/continuum-sidebar-check-<uuid>` (deleted in
  `defer`).
- `WS_A` id `…16A1` name `"Alpha"`; `WS_B` id `…16B2` name `"Beta"`. `registry.workspaces =
  [WS_A, WS_B]` (this order). `PROJ_X` id `…16X1` name `"continuum-revived"` in
  `registry.projects`.
- `documents[WS_A]` saved to disk: two zones, `zoneZOrder = [zA2, zA1]` (reverse of storage so
  the sidebar order is provably z-order, mirroring T15 assertion 3):
  - `zA1` id `…16A1A` project zone (`projectId = PROJ_X`, stored `name = ""`, `color = "blue"`,
    `navKey = "a"`, `collapsed = false`).
  - `zA2` id `…16A2B` group zone (`projectId = nil`, `name = "Scratch"`, `color = "mint"`,
    `navKey = nil`, `collapsed = true`).
- `documents[WS_B]` saved to disk: one group zone `zB1` id `…16B1C` (`projectId = nil`, `name =
  "Notes"`, `color = "orange"`, `navKey = "n"`).
- `let tree = SidebarTreeBuilder.build(registry: registry, documents: documents)` (the PRODUCTION
  builder — the check does not hand-assemble the tree).
- `let sidebar = WorkspaceSidebar(); sidebar.reload(tree: tree)`.
- Spies: `var switched: [UUID] = []`, `var jumped: [UUID] = []`, `var renamedWS: [(UUID,
  String)] = []`, `var renamedZone: [(UUID, String)] = []`, `var navKeyed: [(UUID, String?)] =
  []`, wired to the five callbacks. **Crucially**, `onRenameZone` / `onEditZoneNavKey` are wired
  to the SAME load→mutate→save persistence helper the production AppDelegate uses (call it
  through a small closure that runs `WorkspaceStore(...).load()` → mutate the matching
  `ZonePlacement` → `.save(...)`) so the check can re-read disk (assertions 8–9).

### Assertions (the acceptance spec — every one hand-derivable)
Let the sidebar be fully expanded (both workspaces).

1. **Data source — top level reflects the tree verbatim.** `outlineView`'s
   `numberOfChildren(ofItem: nil) == 2`; the two root items are `.workspace` with ids
   `[WS_A, WS_B]` and names `["Alpha", "Beta"]` — read back through the **real**
   `child(_:ofItem:)` + `objectValue` path, equal to `tree.workspaces.map(\.workspaceId/.name)`.
2. **Data source — children reflect the tree's zone order (z-order).**
   `numberOfChildren(ofItem: WS_A item) == 2`; the child zone ids in order ==
   `[zA2, zA1]` (the tree's z-order, NOT storage order). `WS_B` has one child `zB1`.
3. **Expandable by kind.** `isItemExpandable` is `true` for both workspace items and `false`
   for every zone item.
4. **Zone display fields pass through from the tree.** The `zA1` row exposes `name ==
   "continuum-revived"` (T15 backfilled the project zone — NOT the stored `""`), `color ==
   "blue"`, `navKey == "a"`. The `zA2` row exposes `name == "Scratch"` (group zone stored name),
   `color == "mint"`, `navKey == nil`. (Proves T16 renders the T15 tree and does no re-derivation.)
5. **Click a workspace row → real switch.** `sidebar.qaClickRow(at: rowIndexOf(WS_B))` ⇒
   `switched == [WS_B]` and `jumped == []`. (The production click handler routed a workspace
   item to `onSwitchWorkspace`, which the AppDelegate wires to
   `workspaceRuntime.switchWorkspace(to:)` — spied here.)
6. **Click a zone row → jump, not switch.** With both expanded,
   `sidebar.qaClickRow(at: rowIndexOf(zA1))` ⇒ `jumped == [zA1]` and `switched` unchanged.
   (Zone item routed to `onJumpToZone`.)
7. **Inline rename of a workspace fires the rename callback with the trimmed string.**
   `sidebar.qaCommitRename(itemAt: rowIndexOf(WS_A), to: "  Alpha 2  ")` ⇒ `renamedWS == [(WS_A,
   "Alpha 2")]` (delegate trims; empty is rejected — also assert a `""` commit produces NO
   callback fire).
8. **Inline rename of a ZONE writes through to the document on disk.**
   `sidebar.qaCommitRename(itemAt: rowIndexOf(zA2), to: "Scratchpad")` then re-load
   `WorkspaceStore(workspaceId: WS_A, applicationSupportDirectory: appSupport).load()`: the zone
   `zA2`'s `ZonePlacement.name == "Scratchpad"` **on disk**, and the project zone `zA1`'s stored
   `name` is still `""` (rename of a *group* zone does not backfill/clobber the project zone).
9. **Nav-key edit persists to disk; conflict is rejected.**
   - `sidebar.qaCommitNavKey(zoneAt: rowIndexOf(zA2), to: "z")` → re-load disk: `zA2.navKey ==
     "z"`. Clearing with `qaCommitNavKey(... to: nil)` → re-load: `zA2.navKey == nil`.
   - **Conflict rejected:** `qaCommitNavKey(zoneAt: rowIndexOf(zA1), to: "a")` is a no-op for a
     reserved leader token (e.g. set the fixture so `"a"` is in the resolved reserved set, or use
     a token that is — assert via `SidebarChromeConfig.navKeyConflicts("h", against: [], reserved:
     reserved) == true` for the `left` binding and that the matching `qaCommitNavKey` leaves disk
     unchanged). Also a duplicate of another zone's navKey in the same document is rejected:
     `qaCommitNavKey(zoneAt: rowIndexOf(zA2), to: "a")` (a duplicate of `zA1`'s `"a"`) leaves
     `zA2.navKey` unchanged on disk. (Both rejection branches asserted: `navKeyed` did NOT fire a
     persisting edit, and disk is unchanged.)
10. **`reload(tree:)` after a switch swaps the rendered tree.** Build a second tree where
    `registry.workspaces = [WS_B, WS_A]` (reordered) and call `sidebar.reload(tree: tree2)`;
    assert `numberOfChildren(ofItem: nil) == 2` and the new root order is `[WS_B, WS_A]`.
    (Proves the data source has no stale cached order; switch-then-reload is the live path.)
11. **Configurable defaults resolve.** With a fresh `UserDefaults` (no keys set),
    `SidebarChromeConfig.resolveVisible(defaults:) == true` and `resolveShowNavKeys(defaults:) ==
    true`; setting `visibleKey = false` flips `resolveVisible` to `false`. (Pins the
    configurable-first defaults + override.)
12. **`buildSidebarTree()` real load path (no in-memory shortcut).** Drive the AppDelegate's
    `buildSidebarTree()` against the temp `appSupport` (set `registryStore` + `appSupport` on a
    test `AppDelegate`, as `runAddZoneSelfCheck` does) and assert the returned `SidebarTree`
    equals `tree` from the fixture — proving the map is loaded **from disk via `WorkspaceStore`**,
    not synthesized. (This is the seam where a "looks fine" check would cheat by hand-building
    the map; assertion 12 forces the real disk read.)

### RED → GREEN
Until `WorkspaceSidebar.swift` + `SidebarChromeConfig.swift` exist the check fails to compile
(missing types) — acceptable RED for the scaffold. The first compiling stub:
`WorkspaceSidebar` returning `0` children and no-op `qa*`; run `--sidebar-check` and watch it
fail on **assertion 1** (`numberOfChildren(ofItem: nil) == 0 ≠ 2`) — the behavioral RED. Then
fill the data source, click routing, rename/nav-key routing, conflict-guard, and
`buildSidebarTree` to GREEN.

## Implementation steps
1. **(RED)** Create `Sources/ContinuumRevivedCore/SidebarChromeConfig.swift` (keys + defaults +
   `resolveVisible`/`resolveShowNavKeys` + `navKeyConflicts(_:against:reserved:)`). Append the two
   `.toggle` fields to `SettingsSchema`.
2. **(RED)** Create `Sources/ContinuumRevived/App/WorkspaceSidebar.swift` as a compiling stub
   (`reload` stores tree; data source returns 0; `qa*` no-ops; one shared `activate(_:)` /
   `commitRename`/`commitNavKey` private routing the check and real handlers both call).
3. **(RED)** Write `runSidebarSelfCheck()` (all 12 assertions) + register `--sidebar-check` in the
   `ContinuumApp` dispatch and `scripts/run-matrix.sh`. `swift build`; run the single check →
   fails on assertion 1.
4. **(GREEN)** Implement the data source (`SidebarItem` items, two-level children from
   `tree.workspaces` / `row.zones`), `isItemExpandable` by kind, the click router
   (`outlineViewSelectionDidChange` → `activate(item)` → `onSwitchWorkspace` for workspace /
   `onJumpToZone` for zone), and the `NSTextFieldDelegate` rename/nav-key commit → trim → conflict
   check → `onRenameWorkspace`/`onRenameZone`/`onEditZoneNavKey`. Share the routing between `qa*`
   and the real handlers.
5. **(GREEN)** In `ContinuumApp`: add `workspaceSidebar`, wrap canvas in the inset `NSSplitView`
   at the window-build site (initial sidebar-pane collapsed state from
   `SidebarChromeConfig.resolveVisible`), wire the five callbacks (switch → `workspaceRuntime.
   switchWorkspace(to:)`; jump → `jumpToZone`; renames/navKey → `renameWorkspace` + the new
   zone-document mutate→save helper), add `buildSidebarTree()` and `jumpToZone(_:)`, and reload the
   sidebar after switch/rename/navKey/add-zone.
6. `swift build` → `--sidebar-check` GREEN → `./scripts/run-matrix.sh --fast` (then a full
   `./scripts/run-matrix.sh` since this touches the window/canvas/focus shell — confirm
   `--focus-broker-activation-check`, `--multi-zone-render-check`, `--workspace-switch-check`,
   `--settings-panel-check` all still green).
7. **STAGE (do not mark Done):** leave the diff staged, rebuild the bundle
   (`./scripts/make-app-bundle.sh --configuration release --output
   ~/Applications/ContinuumRevived.app` → `open`), and hand Dylan the "What Dylan must eyeball"
   list. Set Status `needs-review` with a note that the visual/feel gate is pending.

## Acceptance criteria
- [ ] `--sidebar-check` (all 12 assertions) drives the REAL `WorkspaceSidebar` data
      source / click / rename / nav-key handlers + the REAL `buildSidebarTree` disk load + the
      REAL `WorkspaceStore.save`; no hand-assembled tree, no bypass of the routing.
- [ ] Top level + zone children reflect the **T15 tree verbatim** (order, names, color, navKey,
      collapsed) — no re-sort/re-backfill in T16 (assertions 1–4).
- [ ] Workspace-row click → `workspaceRuntime.switchWorkspace(to:)` (spied); zone-row click →
      `jumpToZone` (assertions 5–6).
- [ ] Workspace rename → `renameWorkspace` (trim, reject empty); zone rename + nav-key edit write
      through to the workspace document **on disk** (assertions 7–9).
- [ ] Nav-key conflict-guard rejects reserved-leader and intra-document duplicate keys (assertion
      9); `SidebarChromeConfig` ships `visibleKey`/`showNavKeysKey` defaults + two Settings
      toggles + `navKeyConflicts` (assertion 11).
- [ ] Inset `NSSplitView` (not overlay); initial sidebar visibility from
      `SidebarChromeConfig.resolveVisible`.
- [ ] `swift build`, `--sidebar-check`, and full matrix green; no co-author footer.
- [ ] **STAGED, not Done.** Visual/feel gate listed for Dylan; Status `needs-review`.

## Verification commands
```
swift build
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --sidebar-check; rm -rf "$P" "$A"
swift run ContinuumRevivedCoreChecks        # SidebarChromeConfig + T15 tables still green
./scripts/run-matrix.sh --fast
./scripts/run-matrix.sh                      # full — touches window/canvas/focus shell
# Morning bundle (Dylan):
./scripts/make-app-bundle.sh --configuration release --output ~/Applications/ContinuumRevived.app
open ~/Applications/ContinuumRevived.app
```

## Review rubric (adversarial)
- **R1 — One routing path, not two.** The most likely cheat: `qaClickRow`/`qaCommitRename`/
  `qaCommitNavKey` re-implement the routing while the real `NSOutlineViewDelegate` /
  `NSTextFieldDelegate` handlers do something different (or nothing). Confirm the real selection
  handler and the `qa*` methods both call a single shared `activate(_:)` / `commitRename(_:_:)` /
  `commitNavKey(_:_:)`. If they diverge, the check proves nothing about the real click — **REWORK**.
- **R2 — Switch is the REAL T09 method.** Assertion 5's spy must be wired to
  `workspaceRuntime.switchWorkspace(to:)` in the AppDelegate, not a local stub. Trace the
  `onSwitchWorkspace` assignment to the production call. A relaunch path here is a fail (T09 retired
  it).
- **R3 — Persistence is observed on disk, not in memory.** Assertions 8–9 must re-`load()` the
  `WorkspaceStore` and read `ZonePlacement.name`/`.navKey` from the **reloaded** document. A check
  that asserts on an in-memory mutation it made itself is a bypass — it would pass even if the
  AppDelegate never saved. **REWORK** if it doesn't round-trip disk.
- **R4 — Tree is T15's, not re-derived.** Assertion 4 must show the project zone rendering the
  **backfilled** name `"continuum-revived"` while the stored `name` is `""`; if T16 re-reads the
  document and backfills itself, scope leaked into T16 (T15 owns derivation). The sidebar must
  render `tree` verbatim. Grep the diff for any sort/backfill logic in `WorkspaceSidebar` — there
  should be none.
- **R5 — Z-order, not storage order.** Assertion 2 uses the reverse-order fixture (`zoneZOrder =
  [zA2, zA1]`). A green check whose children came out in storage order would mean T16 ignored the
  tree's order — confirm `[zA2, zA1]`.
- **R6 — Conflict-guard actually rejects.** Assertion 9's rejection branches must show disk
  **unchanged** after a reserved/duplicate key edit, and `navKeyConflicts` must be the Core
  predicate (unit-pinned), not an inline `if`. A guard that silently writes the conflicting key is a
  fail.
- **R7 — Scope.** Diff = one new App file, one new Core config file, the `SettingsSchema` append,
  the `ContinuumApp` window/wiring/check edits, and the `run-matrix.sh` line. No `switchWorkspace`
  internals, no `SidebarTree`/`ZonePlacement` shape edits, no palette edits. Orphans your change
  created removed. No co-author footer.
- **R8 — Morning gate present.** The "What Dylan must eyeball" list is in the staged note; Status is
  `needs-review`, NOT `done`; nothing committed as Done.

### What Dylan must eyeball (the morning visual/feel gate — the check cannot see these)
- **Flicker / z-paint during a workspace switch:** click a workspace row, watch for a flash, a
  half-painted old canvas, or zone layers ghosting (the T09 swap's visual half).
- **Inset split feel:** divider drag is smooth, the sidebar pane has a sane min/max width, the
  canvas reflows without tile jitter; collapsing/showing the sidebar (the `visible` toggle) animates
  cleanly and the canvas reclaims the space.
- **Inline rename UX:** double-click (or the chosen affordance) enters edit, the field takes first
  responder, Return commits / Esc cancels, focus returns to the canvas — no stuck editor, no lost
  keystrokes, no rename bleeding into a switch.
- **Nav-key editor:** the per-zone nav-key affordance is legible (only shown when
  `showNavKeys`), single-char entry feels right, a rejected (reserved/duplicate) key gives visible
  feedback rather than silently snapping back.
- **Color swatch + collapse chevron:** swatch color matches the zone color token; expand/collapse
  triangles behave; collapsed group zone (`zA2`) shows collapsed.
- **Cursor rects / hit zones:** rows highlight on hover, the divider shows the resize cursor, no
  dead/overlapping click zones between sidebar and canvas.
- **Selection ↔ active workspace sync:** the selected row tracks the actually-active workspace after
  a switch (including a switch initiated from ⌘K).

## Out of scope / gotchas
- **NEEDS-HUMAN — depends on two unfinished tasks.** T16 is specified against the *planned*
  surfaces of **T09** (`workspaceRuntime.switchWorkspace(to:)`) and **T15**
  (`SidebarTreeBuilder.build(registry:documents:)` + the row structs). Neither exists in `main`
  yet (T09's current `runWorkspaceSwitchSelfCheck` is the *old relaunch/render-model* check;
  `WorkspaceRuntime` is created by T06). **Before executing T16, confirm:** (a) T09 shipped
  `WorkspaceRuntime.switchWorkspace(to:)` with the exact name/signature (sync vs async — the
  callback wiring and `jumpToZone`'s cross-workspace branch depend on it), and (b) T15 shipped the
  row structs with the field names this spec reads. If either diverges, adjust the callback/seam
  signatures and re-pin assertions 5/12 — do not invent a different switch API.
- **G2 — there is no main-window sidebar today.** The window content view is set **directly** to
  `canvasView` (ContinuumApp.swift:1227). T16 introduces the first inset `NSSplitView` on the main
  window; the only existing `NSSplitView` is `FocusModeSession`'s overlay (:8046) — a different
  surface, do not reuse it. Verify the split doesn't break the focus-mode overlay path
  (`--focus-mode-check`).
- **G3 — cross-workspace zone jump.** `jumpToZone` against a zone in the *currently active*
  workspace is a straight `fitZoneToViewport` → `setViewport`. A zone in a *different* workspace
  requires switching first (T09) then fitting — but the canvas/zone layers only exist after the
  switch completes. If T09's `switchWorkspace` is async, sequence the fit in its completion; if the
  shape is unclear, scope `onJumpToZone` to **same-workspace zones in v1** and flag cross-workspace
  jump for a follow-up (the headless check only exercises same-workspace jump, assertion 6).
- **G4 — `[morning]` staging.** Do NOT commit as Done. The check + matrix green is necessary but
  not sufficient (memory: verification-doctrine); the visual gate above is required for Done.
- **G5 — SourceKit noise.** "Cannot find `WorkspaceSidebar`/`SidebarChromeConfig` in scope" before
  the files are saved is stale-diagnostic noise; `swift build` is authoritative.
- **Deferred:** drag-to-reorder workspaces/zones in the sidebar; drag a tile onto a zone row;
  context menus (delete/duplicate workspace from the sidebar); cross-workspace zone jump if T09 is
  async-unclear (G3). These are not in T16.
