# T17 — ⌘K zone rows (jump-to-zone, create-zone)

Status: todo
Tag: overnight
Depends on: T01 (zone model: optional `projectId` + `name` + `navKey`) · Blocks: —

## Goal
Make the ⌘K launch palette the keyboard-fast path for zones: a **Jump to `<zone name>`**
row per zone (pans/focuses that zone, exactly like the leader's zone-jump and the ⌘K
tile-jump shipped last session) and a **Create Zone** row that adds a new group zone to the
active workspace. This is the keyboard half of the charter's "⌘K stays the keyboard-fast
path (extended with zone rows)"; the sidebar (T16) and the leader's per-zone keybind (T18)
are separate.

## Exact scope — files & symbols
- **`Sources/ContinuumRevivedCore/LaunchPaletteModel.swift`** — MIRROR the shipped
  `jumpToTile` pattern EXACTLY:
  - `LaunchPaletteAction`: add `case jumpToZone(UUID)` and `case createZone` (add their
    arms to `displayName` and `filterTokens`).
  - Add a `JumpZoneRow` struct (mirror `JumpTileRow`: `id: UUID`, `title: String`,
    public memberwise init).
  - `LaunchPaletteRow`: add `case jumpToZone(JumpZoneRow)` and add its arms to
    `displayName` (`"Jump to \(zone.title)"`), `isSelectable` (`true`), and
    `matches(query:)` (haystacks `["jump zone go", zone.title, zone.id.uuidString]`).
  - `LaunchPaletteModel.makeRows`: add a `jumpZones: [JumpZoneRow] = []` parameter and
    append `jumpZones.map(LaunchPaletteRow.jumpToZone)` and a single
    `LaunchPaletteRow.action(.createZone)` — see Data/API for the EXACT order.
- **`Sources/ContinuumRevived/App/LaunchProfilePalette.swift`** — MIRROR the `jumpToTile`
  arms (do not add new behavior, just thread the new cases through the existing
  switches):
  - `show(...)`: add `jumpZones: [JumpZoneRow] = []` param; pass it to `makeRows`.
  - `selectedDisplayNameForQA`, `tableView(_:viewFor:row:)`: add a `.jumpToZone(zone)`
    arm rendering `"Jump to \(zone.title)"`.
  - `commitSelection()`: add `case let .jumpToZone(zone): onSelectAction?(.jumpToZone(zone.id)); close(restoreFocus: true)`.
- **`Sources/ContinuumRevivedCore/WorkspaceDocument.swift`** — add a pure
  `appendGroupZone(name:zoneId:defaultSize:gap:color:)` mirroring `appendProjectZone`
  but with `projectId: nil` and the new `name`. (Pure helper; gets its own Core
  assertion. See "Data / API changes".) This is the minimum the create-zone palette
  action needs that T08's `addZone` is NOT responsible for (T08 spins the *runtime
  controller* for an existing zone; T17 only adds the *document zone* + persists it).
- **`Sources/ContinuumRevived/App/ContinuumApp.swift`**:
  - `openProfilePalette()` (~:2562): build `jumpZones` from
    `canvasView?.navZoneRenderModels` (`JumpZoneRow(id: $0.placement.zoneId, title: $0.displayName)`)
    and pass to `palette.show(...)`, exactly as `jumpTiles` is built and passed.
  - `performPaletteAction(_:)` (~:2806): add
    `case let .jumpToZone(zoneId): jumpToZoneFromPalette(zoneId)` and
    `case .createZone: createGroupZoneFromPalette()`.
  - Add `private func jumpToZoneFromPalette(_ zoneId: UUID)` (mirror
    `jumpToTileFromPalette` at :2847) and `private func createGroupZoneFromPalette()`
    (mirror the persistence body of `addProjectZone` at :2961, using `appendGroupZone`).
  - Register `--palette-zone-check` in the `CommandLine.arguments` dispatch (~:230,
    next to `--palette-jump-check`) and add `static func runPaletteZoneSelfCheck()`.
- **`scripts/run-matrix.sh`** — register `--palette-zone-check` next to
  `--palette-jump-check` (line 82).
- **Do NOT touch:** the leader zone-jump (`jumpToZoneOrdinal` / `jumpToZoneByOrder` /
  `fitNavZone` — that's the T18 path); the sidebar (T16); the existing `jumpToTile`
  rows / `jumpToTileFromPalette` (mirror, don't refactor); `addProjectZone` (copy its
  persistence body into the new fn, do not generalize it); `ZoneRuntimeController` /
  `addZone` runtime spin-up (T08). Do NOT give the create-zone a runtime/controller —
  it only writes the document zone.

## Data / API changes
`LaunchPaletteModel.swift` (copy-pasteable):
```swift
// LaunchPaletteAction — add two cases + their displayName/filterTokens arms:
case jumpToZone(UUID)
case createZone
// displayName:
case .jumpToZone: return "Jump to Zone…"   // overridden per-row in LaunchPaletteRow
case .createZone: return "Create Zone…"
// filterTokens:
case .jumpToZone: return ["jump", "zone", "go"]
case .createZone: return ["create", "new", "zone"]

public struct JumpZoneRow: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public init(id: UUID, title: String) { self.id = id; self.title = title }
}

// LaunchPaletteRow — add case + arms:
case jumpToZone(JumpZoneRow)
// displayName: case let .jumpToZone(zone): return "Jump to \(zone.title)"
// isSelectable: case .jumpToZone: return true
// matches: haystacks ["jump zone go", zone.title, zone.id.uuidString], allSatisfy contains

// makeRows — new param + append order (zones AFTER jump-tiles, before workspaces):
public static func makeRows(
    profiles: [LaunchPaletteProfileRow],
    projects: [ProjectPickerRow] = [],
    workspaces: [WorkspaceEntry] = [],
    harnessRoles: [HarnessRole] = [],
    jumpTiles: [JumpTileRow] = [],
    jumpZones: [JumpZoneRow] = []
) -> [LaunchPaletteRow] {
    profiles.map(LaunchPaletteRow.profile)
        + CommandRegistry.paletteActions().map(LaunchPaletteRow.action)
        + harnessRoles.map { LaunchPaletteRow.action(.spawnHarnessRole($0)) }
        + jumpTiles.map(LaunchPaletteRow.jumpToTile)
        + jumpZones.map(LaunchPaletteRow.jumpToZone)
        + [LaunchPaletteRow.action(.createZone)]
        + workspaces.flatMap { ... }  // unchanged
        + projects.map(LaunchPaletteRow.project)
}
```
NEEDS-HUMAN, see gotchas: `CommandRegistry.paletteActions()` already drives the fixed
built-in action block (New Note … New Workspace…). Confirm whether `.createZone` should
be appended in `makeRows` (as above — keeps it adjacent to zone rows and avoids editing
`CommandRegistry`) or registered inside `CommandRegistry.paletteActions()` (where the
other built-ins live). The check below assumes the `makeRows`-append form.

`WorkspaceDocument.swift` (pure helper, mirrors `appendProjectZone`):
```swift
@discardableResult
public mutating func appendGroupZone(
    name: String,
    zoneId: UUID = UUID(),
    defaultSize: ZoneSize = ZoneSize(width: 1280, height: 720),
    gap: Double = 120,
    color: String = "mint"
) -> ZonePlacement {
    let maxX = zones.map { $0.origin.x + $0.size.width }.max() ?? 0
    let origin = zones.isEmpty ? ZonePoint(x: 0, y: 0) : ZonePoint(x: maxX + gap, y: 0)
    let placement = ZonePlacement(
        zoneId: zoneId, projectId: nil, name: name, navKey: nil,   // T01 fields
        origin: origin, size: defaultSize, color: color,
        collapsed: false, hydrationPolicy: .automatic
    )
    zones.append(placement)
    zoneZOrder.removeAll { $0 == zoneId }
    zoneZOrder.append(zoneId)
    lastActiveZoneId = zoneId
    return placement
}
```
(The exact `ZonePlacement(...)` arg list/order is whatever T01 lands — read
`WorkspaceDocument.swift` after T01 and match it. T01's planned shape:
`projectId: UUID?`, `name: String`, `navKey: String?` added to the memberwise init.)

`ContinuumApp.swift`:
```swift
// performPaletteAction arms:
case let .jumpToZone(zoneId): jumpToZoneFromPalette(zoneId)
case .createZone: createGroupZoneFromPalette()

/// ⌘K "Jump to <zone>" — mirrors jumpToTileFromPalette: reuses the leader zone-jump's
/// fit + sets navSelectedZoneId, AND focuses the zone's last-active tile with
/// `.tileSpawned` so the palette's snapshot restore on close doesn't bounce focus back.
private func jumpToZoneFromPalette(_ zoneId: UUID) {
    guard let canvasView,
          canvasView.navZoneRenderModels.contains(where: { $0.placement.zoneId == zoneId }),
          let viewport = canvasView.fitZoneToViewport(zoneId: zoneId) else { return }
    canvasView.setViewport(viewport)
    navSelectedZoneId = zoneId
    if let tileId = zoneFocusTileId(forZone: zoneId) {       // see gotchas for derivation
        focusBroker.enterScope(.tile(tileId), reason: .tileSpawned)
    } else {
        focusBroker.enterScope(.tile(zoneFocusFallback), reason: .tileSpawned) // see gotchas
    }
}
```
See "Out of scope / gotchas" — the focus-survival half is the one design subtlety:
`requestFocus(.tileSpawned)` only sets `tileSpawnedDuringModal` for a `.tile` id, so a
zone-jump that only pans (no tile to focus) cannot suppress the modal snapshot restore.
The check (assertion 4/5) pins both shapes precisely; read it before implementing.

`createGroupZoneFromPalette()` mirrors `addProjectZone`'s persistence body exactly —
resolve the active workspaceId (`activeProject` → `registry.projects[...].workspaceId`
→ `registry.lastActiveWorkspaceId`), `WorkspaceStore(...).load()`,
`document.appendGroupZone(name: defaultGroupZoneName)`, persist via
`WorkspaceDocumentSaveController.scheduleZoneLayoutSave` + `flushPendingSave()`, then
`registryStore.save(registry)`. It does NOT mutate `registry.workspaces[].projectIds`
(a group zone has no project) and does NOT spin a controller.

### Configurable-first (charter §1.3)
The create-zone default name is a NEW user-facing default and MUST ship configurable:
- New resolver `DefaultGroupZoneName` (Core), `userDefaultsKey =
  "continuum.zone.defaultGroupName"`, `fallback = "Zone"`, with a `.resolve()` reading
  `UserDefaults.standard` (model on `DefaultBrowserURL`).
- A `SettingsSchema` `.text` field in the **General** section: `key:
  DefaultGroupZoneName.userDefaultsKey, label: "Default Zone Name", default:
  DefaultGroupZoneName.fallback`.
- Conflict-guard: extend the existing settings-keys uniqueness/duplication guard that
  covers `DefaultBrowserURL`/`TileGapResolver` keys (grep `userDefaultsKey` in
  `ContinuumRevivedCoreChecks/main.swift` for the existing guard and add this key to it).
  `createGroupZoneFromPalette` reads `DefaultGroupZoneName.resolve()` for the name.

## The check, written FIRST (spec-as-test)

### Part A — Core table (extend `ContinuumRevivedPaletteChecks/main.swift`)
Add a block mirroring the jump-tile rows block (lines 72–82). Build with two zones via
`makeRows(profiles: [], jumpZones: [JumpZoneRow(id: zA, title: "API"), JumpZoneRow(id:
zB, title: "Scratch")])` and assert (every value hand-derivable from the append order
above — built-ins are exactly `["New Note","New Browser","Open File...","Open File
Tree...","New Diff Review","Fit Canvas to All","New Workspace…"]`):
1. `rows.map(\.displayName)` ==
   `[...the 7 built-ins...] + ["Jump to API", "Jump to Scratch", "Create Zone…"]`
   (jump-zone rows appended after built-ins, then the single Create Zone action,
   before any workspaces/projects).
2. `filterRows(rows, query: "jump scratch").map(\.displayName) == ["Jump to Scratch"]`
   (filters by `jump` + title).
3. `filterRows(rows, query: "api").map(\.displayName) == ["Jump to API"]`
   (filters by title alone).
4. `filterRows(rows, query: "create zone").map(\.displayName) == ["Create Zone…"]`
   (create-zone filters by its tokens).
5. The `.jumpToZone` row `isSelectable == true`; the `.createZone` action row
   `isSelectable == true`.
6. Co-existence: a `makeRows(profiles: [], jumpTiles: [JumpTileRow(...)], jumpZones:
   [JumpZoneRow(...)])` puts the tile-jump rows BEFORE the zone-jump rows BEFORE Create
   Zone (assert the exact `displayName` slice) — proves T17 didn't reorder T-prior rows.

### Part B — Real-path app check `--palette-zone-check` (`runPaletteZoneSelfCheck`)
Registered in `scripts/run-matrix.sh` (next to line 82) AND the `CommandLine.arguments`
dispatch in `ContinuumApp.swift` (~:230, mirror the `--palette-jump-check` block:
`_ = NSApplication.shared`; on success print `ContinuumRevivedPaletteZoneChecks passed:
…`; on failure `fputs`+exit 1). The check has two scenarios driven through the REAL
`performPaletteAction` inside an open `.palette` modal (mirror `runPaletteJumpSelfCheck`
at :6100 for setup style).

**Scenario 1 — Jump to zone (in-memory, mirrors palette-jump):**
Build a `CanvasNSView` with two zones via `ZoneRenderModel`s (mirror :6354): zone A at
`origin (0,0)` size `1000×700` displayName "Alpha"; zone B at `origin (1400,0)` size
`800×600` displayName "Beta". Put one tile inside each zone's world rect (tile in B so
the focus-survival arm has a target). Canvas frame `1400×900`, zoom 1. Wire `app.canvasView`,
`canvas.focusBroker = app.focusBroker`, `onAcceptedTileFocus = markActive`, install tile
views, `requestFocus(.canvas)`. Then:
1. **Precondition:** `openModal(.palette)` →
   `app.focusBroker.activeSurface == .modal(.palette)`.
2. **Jump:** `app.performPaletteAction(.jumpToZone(zoneB.zoneId))`.
3. **Viewport asserted == hand-derived `fitZoneToViewport(B)`:**
   `canvas.viewport` ≈ `CanvasEngine.fit(worldRect: CGRect(x:1400,y:0,width:800,height:600),
   viewportSize: CGSize(width:1400,height:900))`. (Re-derive: `availW = 1400 − 80 =
   1320`; `availH = 900 − 80 = 820`; `zX = 1320/800 = 1.65`; `zY = 820/600 ≈ 1.3667`;
   `zoom = min = 1.3667…` clamped to `defaultZoomRange`; `centerX = 1800`, `centerY =
   300`; `originX = 1800 − 700/zoom`, `originY = 300 − 450/zoom`. Assert with the same
   `CanvasEngine.fit` call so the value is identical, tolerance < 0.001.)
4. **`navSelectedZoneId == zoneB.zoneId`** after the jump (observable: the leader's
   selected-zone state moved to B — drive via a small accessor or assert the next
   `jumpToZoneByOrder`-equivalent; if `navSelectedZoneId` is private with no QA hook,
   add a `var navSelectedZoneIdForQA: UUID?` accessor — see gotchas).
5. **Focus survives `closeModal`:** `app.focusBroker.closeModal(.palette)` →
   `app.focusBroker.activeSurface == .tile(tileInB.id)` (NOT the pre-palette `.canvas`).
   This is the load-bearing assertion: it FAILS if the jump didn't enter the zone's
   tile with `.tileSpawned` (the snapshot restore would bounce focus to `.canvas`).
6. **Unknown zone id is a no-op:** record viewport+activeSurface, then
   `app.performPaletteAction(.jumpToZone(UUID()))` → viewport and `activeSurface`
   unchanged (guard rejects a zone not in `navZoneRenderModels`).

**Scenario 2 — Create zone (on-disk, real persistence path):**
In a temp `CONTINUUM_APP_SUPPORT` dir: write a `Registry` with one workspace W (one
project P, `P.workspaceId = W`, `lastActiveWorkspaceId = W`) via `RegistryStore`; write
an initial `WorkspaceDocument` for W with ONE project zone (so the new group zone gets a
non-zero origin) via `WorkspaceStore`. Wire `app.registryStore = RegistryStore(...)` and
`app.zoneRuntimeController` so `activeProject?.id == P` (mirror the wiring at :3635 —
construct a `ZoneRuntimeController` for P's root, or set the minimal fields the active-
workspace resolution reads; read :2961 `addProjectZone` for the exact resolution chain).
Then:
7. **Precondition:** the reloaded W document has `zones.count == 1`, that zone's
   `projectId == P`.
8. **Create:** `openModal(.palette)`; `app.performPaletteAction(.createZone)`;
   `closeModal(.palette)`.
9. **On-disk group zone:** re-`load()` W's `WorkspaceDocument` from disk →
   `zones.count == 2`; the new zone has `projectId == nil`, `name ==
   DefaultGroupZoneName.resolve()` (default "Zone"), `origin.x == firstZone.size.width +
   120` (gap), and `zoneZOrder.last == newZone.zoneId`, `lastActiveZoneId ==
   newZone.zoneId`.
10. **Registry untouched re: projects:** the W workspace entry's `projectIds` is
    unchanged (still `[P]`) — a group zone adds NO project. (Re-load registry, assert.)

Emit a manifest (mirror palette-jump): `{check: "palette-zone", path:
"performPaletteAction(.jumpToZone)/(.createZone) inside an open .palette modal →
closeModal (real action + modal lifecycle + on-disk WorkspaceDocument)", fitViewport:
{...}, createdZoneOrigin: {...}}`. Clean up the temp dir.

Run both → RED (no `.jumpToZone`/`.createZone` cases; won't compile, then fails on the
assertions once stubbed). Implement to GREEN.

## Implementation steps
1. **RED — Core table:** add Part A assertions to `ContinuumRevivedPaletteChecks`;
   `swift run ContinuumRevivedPaletteChecks` → fails to compile (missing cases).
2. **RED — app check:** write `runPaletteZoneSelfCheck` (both scenarios) + register
   `--palette-zone-check` in the arg dispatch and `scripts/run-matrix.sh`; `swift build`
   → fails to compile (missing cases/fns). Add minimal compiling stubs
   (`jumpToZoneFromPalette`/`createGroupZoneFromPalette` empty, `appendGroupZone` real,
   the enum cases) → run the check → it fails on the **assertions** (viewport unchanged
   / focus not surviving / zone not on disk). This is the behavioral RED.
3. **GREEN — model:** add `LaunchPaletteAction.jumpToZone`/`.createZone` + arms,
   `JumpZoneRow`, `LaunchPaletteRow.jumpToZone` + arms, `makeRows` param/append. Thread
   the new cases through `LaunchProfilePalette` switches. Core table → GREEN.
4. **GREEN — config:** add `DefaultGroupZoneName` resolver + `SettingsSchema` General
   field + extend the settings-key conflict guard.
5. **GREEN — wiring:** build `jumpZones` in `openProfilePalette`; implement
   `jumpToZoneFromPalette` (fit + `navSelectedZoneId` + `.tileSpawned` focus) and
   `createGroupZoneFromPalette` (copy `addProjectZone`'s persistence body, swap
   `appendProjectZone` → `appendGroupZone(name:)`, drop the projectIds mutation). App
   check → GREEN.
6. `swift build` → `swift run ContinuumRevivedPaletteChecks` → single `--palette-zone-check`
   → `./scripts/run-matrix.sh --fast`.
7. Self-review against Acceptance + Review rubric; commit
   `feat(palette): ⌘K jump-to-zone + create-zone rows`.

## Acceptance criteria
- [ ] `LaunchPaletteAction.jumpToZone(UUID)` + `.createZone` exist with displayName +
      filterTokens; `JumpZoneRow` + `LaunchPaletteRow.jumpToZone` mirror the tile-jump.
- [ ] `makeRows(jumpZones:)` appends zone-jump rows then a Create Zone action, AFTER
      tile-jump rows, BEFORE workspaces/projects (Core table assertions 1 + 6 green).
- [ ] `--palette-zone-check` drives the REAL `performPaletteAction` inside an open
      `.palette` modal for BOTH jump and create; jump viewport == hand-derived
      `fitZoneToViewport`, focus survives `closeModal`, unknown-zone is a no-op.
- [ ] Create-zone writes a group zone (`projectId == nil`, configured name, gap origin)
      to the active workspace's `WorkspaceDocument` on disk; registry `projectIds`
      unchanged; no controller spun.
- [ ] `DefaultGroupZoneName` default + Settings field + conflict-guard coverage shipped.
- [ ] No leader zone-jump / sidebar / tile-jump-row refactor; `addProjectZone` left
      intact.
- [ ] `swift run ContinuumRevivedPaletteChecks` + `--palette-zone-check` +
      `./scripts/run-matrix.sh --fast` all green.

## Verification commands
```
swift build
swift run ContinuumRevivedPaletteChecks
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --palette-zone-check; rm -rf "$P" "$A"
./scripts/run-matrix.sh --fast
```

## Review rubric
- **Bypass audit (critical):** the app check must call `app.performPaletteAction(.jumpToZone(...))`
  and `app.performPaletteAction(.createZone)` — the REAL handler the palette's
  `onSelectAction` fires — NOT `canvasView.fitZoneToViewport` or `document.appendGroupZone`
  directly. Trace: would the check still pass if `jumpToZoneFromPalette` /
  `createGroupZoneFromPalette` were stubbed empty? It must go RED. If it asserts on a
  value the production fn never produced, REWORK.
- **Focus-survival is the bug-magnet:** assertion 5 must be after a real `closeModal`,
  and the asserted surface must be the zone's tile (`.tile(...)`), not `.canvas`. If the
  zone-jump only pans (no `.tileSpawned` tile focus), `tileSpawnedDuringModal` stays
  false and the snapshot restores `.canvas` — the check must catch that. Re-derive: open
  modal snapshots `.canvas`; only a `.tile` `.tileSpawned` request flips the suppress
  flag (FocusBroker :62).
- **Viewport re-derivation:** assertion 3's expected value is computed by the SAME
  `CanvasEngine.fit` the production path uses — confirm the check isn't asserting a stale
  hardcoded number, and that B's world rect (`origin (1400,0)`, `800×600`) is what
  `fitZoneToViewport` reads from the `ZoneRenderModel` (via `CanvasEngine.zoneWorldFrame`).
- **On-disk, not in-memory:** assertion 9 must re-`load()` the document from disk AFTER
  `createGroupZoneFromPalette` ran (proves the save flushed), not read `app`'s in-memory
  copy. `projectId == nil` asserted (proves it's a group zone, not a project zone).
- **Append order didn't regress prior rows:** Core assertion 6 (tile-jump BEFORE
  zone-jump BEFORE create-zone) guards against silently reordering T-prior palette rows.
- **Configurable bits:** `DefaultGroupZoneName` has a UserDefaults default + Settings
  field + is in the conflict guard, and `createGroupZoneFromPalette` actually reads
  `.resolve()` (not a hardcoded "Zone"). No co-author footer on the commit.

## Out of scope / gotchas
- **NEEDS-HUMAN — focus target of a zone-jump.** The brief says "use `.tileSpawned`
  semantics where focus must survive `closeModal`, as the tile-jump does." But a tile-jump
  focuses a specific tile; a zone-jump's natural action is a *viewport pan*. There is no
  shipped "zone's last-active tile" concept (`lastActiveTileId` is canvas-global, not
  per-zone, and a zone's tiles aren't tagged with `zoneId` — charter §1). Two coherent
  resolutions; the check above assumes (a):
  (a) **Focus the zone's first member tile with `.tileSpawned`** (a tile whose world
  frame falls inside the zone's world rect, derived from `navZoneRenderModels` +
  `canvasState.tiles`); if the zone is empty, the jump only pans and focus does NOT
  survive (snapshot restores the prior scope) — and assertion 5 must be written for a
  *non-empty* zone only. (b) **Pan only, no focus change** — then drop assertion 5/the
  `.tileSpawned` requirement entirely and the brief's "focus survives" is moot.
  A human must pick (a) or (b) before this task is implemented; this changes whether
  `jumpToZoneFromPalette` enters a tile scope at all and whether `zoneFocusTileId`
  needs a derivation helper. The spec is written for (a); flag if (b) is preferred.
- **NEEDS-HUMAN — `navSelectedZoneId` is `private` with no QA accessor.** Assertion 4
  needs to observe it. Either add a tiny `var navSelectedZoneIdForQA: UUID? {
  navSelectedZoneId }` (cheap, matches the `searchTextForQA` precedent) or drop
  assertion 4 and rely on viewport + focus. Prefer the accessor; confirm with Dylan
  it's acceptable to add a QA hook here.
- **`.createZone` placement** (`makeRows` append vs `CommandRegistry.paletteActions()`):
  see the NEEDS-HUMAN note under Data/API. The check assumes the `makeRows` append; if
  Dylan wants it in `CommandRegistry`, the Core table's expected `displayName` slice
  moves (Create Zone would land inside the built-in block, not after zone rows).
- **T01 dependency is hard:** `appendGroupZone` and the `ZonePlacement(projectId: nil,
  name:, navKey:)` construction only compile after T01 lands the optional `projectId` +
  `name` + `navKey`. If T01 is not Done, this task cannot start — verify first.
- **T08 boundary:** create-zone here writes ONLY the document zone + persists. It does
  NOT spin a `ZoneRuntimeController` or an ambient controller — that is T08's `addZone`.
  The created group zone will have no live runtime until T08; that is expected and the
  check does not assert any runtime.
- **Coordinate trap:** `fitZoneToViewport` reads the zone's world rect via
  `CanvasEngine.zoneWorldFrame` (`origin`+`size`), Y-down. The check's zone origins are
  world coords; don't confuse with screen px. Canvas is `isFlipped`.
- **Modal restore trap:** `openModal` snapshots `activeSurface`; the snapshot is `.canvas`
  in scenario 1, so a pan-only jump would lose focus on close. Drive the modal lifecycle
  through `openModal`/`closeModal`, never a hand-set `activeSurface`.
- Stale SourceKit "cannot find `.jumpToZone`" diagnostics are noise until `swift build`.
