# T15 — Sidebar view-model (pure tree from Registry + WorkspaceDocuments)

Status: todo
Tag: overnight [pure]
Depends on: T01 (zone model: optional `projectId` + `name` + `navKey`) · Blocks: T16 (sidebar `NSOutlineView`)

## Goal
Give the sidebar (T16) a **pure, fully testable two-level tree** to render: the top level is
the ordered list of workspaces, and each workspace's children are its ordered zones. Each
zone row carries the display fields the outline view needs — name, color, nav key,
collapsed state, and `projectId?` — with one piece of derivation done here so the AppKit
layer stays dumb: a **project zone's** display name is **backfilled from the registry**
(`ProjectEntry.name`), because the model (post-T01) stores `name == ""` for project zones
(charter §1, T01 Data/API). A **group zone** (`projectId == nil`) uses its own stored
`name`. No AppKit, no I/O — `(Registry, [UUID: WorkspaceDocument]) -> tree`.

## Exact scope — files & symbols
- **`Sources/ContinuumRevivedCore/SidebarTree.swift`** (NEW file) — the only production
  file. Add:
  - `public struct SidebarTree: Equatable, Sendable` — `public var workspaces:
    [SidebarWorkspaceRow]`.
  - `public struct SidebarWorkspaceRow: Equatable, Sendable` — `public let workspaceId:
    UUID`, `public let name: String`, `public var zones: [SidebarZoneRow]`.
  - `public struct SidebarZoneRow: Equatable, Sendable` — `public let zoneId: UUID`,
    `public let name: String`, `public let color: String`, `public let navKey: String?`,
    `public let collapsed: Bool`, `public let projectId: UUID?`.
  - `public enum SidebarTreeBuilder` with one static pure func:
    `public static func build(registry: Registry, documents: [UUID: WorkspaceDocument]) ->
    SidebarTree`.
- **`Sources/ContinuumRevivedCoreChecks/main.swift`** — append ONE new `do { … }` block
  (the "Sidebar view-model" Core table) before the final `print("ContinuumRevivedCoreChecks
  passed")`. Reuse the file-scope `expect(_:_:)` helper already defined at the top.
- **Do NOT touch:**
  - `WorkspaceDocument.swift`, `Registry.swift`, `RegistryStore.swift`, `WorkspaceStore`
    (T01 owns the model deltas; this task only *reads* them).
  - Any AppKit / `NSOutlineView` / `Sources/ContinuumRevived/**` — that is **T16**.
  - `switchWorkspace` / `ContinuumApp.swift` (T09).
  - `scripts/run-matrix.sh` and the `CommandLine.arguments` dispatch in `ContinuumApp.swift`
    — **no new app check is registered** for this task (the guarding check is a Core table
    inside the already-registered `ContinuumRevivedCoreChecks` run; the matrix already runs
    `swift run ContinuumRevivedCoreChecks` at line 62).
  - `Package.swift` — `ContinuumRevivedCoreChecks` already depends on `ContinuumRevivedCore`;
    no manifest change.

## Data / API changes
New types in `Sources/ContinuumRevivedCore/SidebarTree.swift` (copy-pasteable shape):

```swift
public struct SidebarZoneRow: Equatable, Sendable {
    public let zoneId: UUID
    public let name: String       // backfilled for project zones; stored name for group zones
    public let color: String
    public let navKey: String?
    public let collapsed: Bool
    public let projectId: UUID?   // nil == group zone
    public init(zoneId: UUID, name: String, color: String, navKey: String?, collapsed: Bool, projectId: UUID?)
}

public struct SidebarWorkspaceRow: Equatable, Sendable {
    public let workspaceId: UUID
    public let name: String
    public var zones: [SidebarZoneRow]
    public init(workspaceId: UUID, name: String, zones: [SidebarZoneRow])
}

public struct SidebarTree: Equatable, Sendable {
    public var workspaces: [SidebarWorkspaceRow]
    public init(workspaces: [SidebarWorkspaceRow])
}

public enum SidebarTreeBuilder {
    public static func build(registry: Registry, documents: [UUID: WorkspaceDocument]) -> SidebarTree
}
```

**Builder semantics (the spec the check pins down):**
1. **Top-level order = `registry.workspaces` array order, verbatim.** One
   `SidebarWorkspaceRow` per `WorkspaceEntry`, in the same order. `row.name =
   entry.name`; `row.workspaceId = entry.id`.
2. **Children = that workspace's zones**, drawn from `documents[entry.id]`. A workspace with
   **no document** in the map yields `zones: []` (do NOT crash, do NOT synthesize a zone).
3. **Zone ordering is deterministic and mirrors the existing canvas ordering**
   (`ContinuumApp.loadActiveZoneRenderModels`, :3537–3543): sort `document.zones` by the
   zone's position in `document.zoneZOrder` (a zone absent from `zoneZOrder` sorts first via
   `Int.min`), tiebreaking on `zoneId.uuidString` ascending. Use the same comparator so the
   sidebar order == the canvas z-paint order.
4. **Per-zone display fields:**
   - `zoneId = placement.zoneId`, `color = placement.color`, `navKey = placement.navKey`,
     `collapsed = placement.collapsed`, `projectId = placement.projectId`.
   - **name backfill:** if `placement.projectId != nil` (project zone), `name =
     registry.projects.first(where: { $0.id == placement.projectId })?.name ?? ""`
     (mirrors the canvas backfill at :3545–3546; this task uses `""` as the
     unresolved-project fallback rather than the canvas's `"Project"` literal — see Review
     rubric note R5). If `placement.projectId == nil` (group zone), `name =
     placement.name` (the stored group-zone name, verbatim — no backfill, no trimming).

No new `UserDefaults` key, `SettingsSchema` field, threshold, or binding is introduced —
this is a pure derivation over the existing model, so the configurable-first rule adds
nothing here (explicitly confirmed in Out of scope / gotchas).

## The check, written FIRST (spec-as-test)
A **Core table** appended to `Sources/ContinuumRevivedCoreChecks/main.swift` (the table IS
the real path for a pure-model task: it constructs a synthetic `Registry` + a
`[UUID: WorkspaceDocument]` map, calls the **production** `SidebarTreeBuilder.build(...)`,
and asserts the **observable returned tree** field-by-field). No app check / matrix
registration is added — it rides the already-registered `swift run ContinuumRevivedCoreChecks`.

### Fixture (all values hand-derivable)
Construct with fixed UUID literals so every expected value is computable by hand.

**Required-but-irrelevant fields (the builder ignores these; fill them with fixed
throwaway values so the fixture compiles — none of them affects any assertion):**
- `ZonePlacement` (post-T01) still requires `origin: ZonePoint`, `size: ZoneSize`, and
  `hydrationPolicy: ZoneHydrationPolicy` — there are no defaults on its memberwise init.
  Use `origin: ZonePoint(x: 0, y: 0)`, `size: ZoneSize(width: 100, height: 100)`,
  `hydrationPolicy: .automatic` for every fixture zone. The builder does **not** read
  origin/size/hydrationPolicy, so these are pure padding.
- `WorkspaceDocument.init` requires `viewport: CanvasViewport` (no convenience
  `.zero`/`.identity` exists — its only init is `CanvasViewport(x:y:zoom:)`) and
  `lastActiveZoneId: UUID?`. Use `viewport: CanvasViewport(x: 0, y: 0, zoom: 1)` and
  `lastActiveZoneId: nil` for every fixture document. The builder does **not** read
  `viewport` or `lastActiveZoneId`.
- `WorkspaceEntry.init` requires `projectIds: [UUID]`, `createdAt: Date`,
  `updatedAt: Date`. Use `projectIds: []` and a single shared fixed date
  (`Date(timeIntervalSince1970: 0)`) for both date fields on every workspace entry — the
  builder reads only `entry.id` and `entry.name`.
- `ProjectEntry.init` requires `rootPath: String`, `workspaceId: UUID?`,
  `lastOpenedAt: Date`, `pinned: Bool` (and defaulted `missing`/`worktreeOf`/
  `linearTicketQueue`). Use `rootPath: "/tmp/x"`, `workspaceId: nil`,
  `lastOpenedAt: Date(timeIntervalSince1970: 0)`, `pinned: false` — the builder reads
  only `project.id` and `project.name`.
- `Registry.init` requires `lastActiveWorkspaceId`, `lastActiveProjectId`, `settings`.
  Use `lastActiveWorkspaceId: nil`, `lastActiveProjectId: nil`, and
  `RegistrySettings(preferredEditor: .auto, zoomModifier: .command, openLastProjectOnLaunch: true)`
  (the `browserProfiles`/`defaultBrowserProfileId` args are defaulted). The builder reads
  only `registry.workspaces` and `registry.projects`.

The fixture values that **do** drive assertions:
- Workspaces (in this array order): `WS_A` (id `…A1`, name `"Alpha"`), `WS_B`
  (id `…B1`, name `"Beta"`), `WS_C` (id `…C1`, name `"Gamma"`) — and one **stray** workspace
  `WS_D` (id `…D1`, name `"Delta"`) that has **no entry** in the `documents` map.
- Projects: `PROJ_X` (id `…X1`, name `"continuum-revived"`), `PROJ_Y` (id `…Y1`, name
  `"docs"`). A third project id `PROJ_GHOST` (id `…G1`) is referenced by a zone but
  **absent** from `registry.projects` (tests the `?? ""` fallback).
- `documents[WS_A.id]` = a `WorkspaceDocument` with **two zones**:
  - `zoneA1` (project zone, `projectId = PROJ_X`, `name = ""`, `color = "blue"`, `navKey =
    "a"`, `collapsed = false`), and
  - `zoneA2` (group zone, `projectId = nil`, `name = "Scratch"`, `color = "mint"`, `navKey =
    nil`, `collapsed = true`).
  - `zoneZOrder = [zoneA2.zoneId, zoneA1.zoneId]` (deliberately the **reverse** of storage
    order, so the test proves z-order — not array order — drives the sort), with `zones`
    stored in `[zoneA1, zoneA2]` order.
- `documents[WS_B.id]` = a `WorkspaceDocument` with **one zone** `zoneB1` (project zone,
  `projectId = PROJ_GHOST`, `name = ""`, `color = "orange"`, `navKey = "b"`, `collapsed =
  false`).
- `documents[WS_C.id]` = a `WorkspaceDocument` with **two zones not present in
  `zoneZOrder`** — `zoneC1` (`zoneId.uuidString` = `"00000000-0000-0000-0000-0000000000C2"`)
  and `zoneC2` (`zoneId.uuidString` = `"00000000-0000-0000-0000-0000000000C1"`), both group
  zones, `zoneZOrder = []`. **Store `zones` in `[zoneC1, zoneC2]` order** (i.e. the
  uuidString-descending order `["…C2", "…C1"]`) so that a builder with a *missing* tiebreak
  (a no-op/stable sort that preserves storage order) would emit `["…C2", "…C1"]` and FAIL
  assertion 8 — proving the tiebreak runs. This forces the `Int.min` tiebreak path: both sort
  to `Int.min`, so the `zoneId.uuidString`-ascending tiebreak orders `…C1` before `…C2`,
  flipping storage order.
- `WS_D` has no document-map entry.

### Assertions (every one hand-derivable — this IS the acceptance spec)
Let `tree = SidebarTreeBuilder.build(registry: registry, documents: documents)`.

1. **Top-level count & order:** `tree.workspaces.count == 4` and
   `tree.workspaces.map(\.workspaceId) == [WS_A.id, WS_B.id, WS_C.id, WS_D.id]` (verbatim
   `registry.workspaces` order).
2. **Workspace names:** `tree.workspaces.map(\.name) == ["Alpha", "Beta", "Gamma", "Delta"]`.
3. **WS_A zone order (z-order, not storage):** `tree.workspaces[0].zones.map(\.zoneId) ==
   [zoneA2.zoneId, zoneA1.zoneId]` — proves `zoneZOrder` (`[zoneA2, zoneA1]`) drives the
   sort, overriding the `[zoneA1, zoneA2]` storage order.
4. **Project zone backfill (resolved):** the WS_A row for `zoneA1` has `projectId ==
   PROJ_X.id` and `name == "continuum-revived"` (backfilled from `registry.projects`, **not**
   the stored `""`).
5. **Group zone uses stored name:** the WS_A row for `zoneA2` has `projectId == nil` and
   `name == "Scratch"` (its stored name, no backfill).
6. **Color / navKey / collapsed pass through, per zone:**
   - `zoneA1` row: `color == "blue"`, `navKey == "a"`, `collapsed == false`.
   - `zoneA2` row: `color == "mint"`, `navKey == nil`, `collapsed == true`.
7. **Unresolved project zone falls back to `""`:** WS_B's `zoneB1` row has `projectId ==
   PROJ_GHOST.id` and `name == ""` (project id not in `registry.projects`).
8. **Tiebreak ordering when absent from z-order:** WS_C's `zones.map(\.zoneId.uuidString)`
   == `["00000000-0000-0000-0000-0000000000C1",
   "00000000-0000-0000-0000-0000000000C2"]` (both `Int.min`, so ascending `uuidString` wins).
9. **Missing document ⇒ empty children, no crash:** WS_D's row has `zones.isEmpty == true`.
10. **Empty registry is empty tree:** `SidebarTreeBuilder.build(registry:
    Registry.empty(), documents: [:]).workspaces.isEmpty == true`.
11. **Determinism (cheap regression net):** calling `build(...)` twice on the same inputs
    returns `Equatable`-equal trees (`SidebarTreeBuilder.build(registry:documents:) ==
    SidebarTreeBuilder.build(registry:documents:)`). Note this is a *weak* guard on its own —
    `Dictionary`/`Set` iteration order is stable **within a single process run**, so this
    assertion would NOT catch a builder that iterates `documents` (the `Set`/`Dictionary`)
    for top-level order; it only catches gross nondeterminism (e.g. a date/`Date()` or
    random value leaking into a row). The *real* order guarantees are pinned by assertion 1
    (top-level order comes from the `registry.workspaces` **array**, not the dict) and
    assertion 8 (zone order comes from the explicit `zoneZOrder`-index + `uuidString`-tiebreak
    sort, not dict/set traversal). Keep assertion 11 as a regression net, but do not rely on
    it alone to prove order-stability — the determinism *trap* is enforced structurally by
    the §Out-of-scope "Determinism trap" note (iterate the array, look up into the dict).

### RED → GREEN
Until `SidebarTree.swift` exists the check **fails to compile** (missing `SidebarTreeBuilder`
/ row types) — acceptable RED for a pure-model task. The first compiling stub should be
`build` returning `SidebarTree(workspaces: [])`; run the table and watch it fail on
**assertion 1** (count 0 ≠ 4) — that is the behavioral RED. Then fill in the builder to GREEN.

## Implementation steps
1. **(RED)** Create `Sources/ContinuumRevivedCore/SidebarTree.swift` with the three structs
   + `enum SidebarTreeBuilder { public static func build(...) -> SidebarTree {
   SidebarTree(workspaces: []) } }` (a compiling stub).
2. **(RED)** Append the "Sidebar view-model" `do {}` table (all 11 assertions) to
   `Sources/ContinuumRevivedCoreChecks/main.swift`, just above the final `print(...)`.
   `swift run ContinuumRevivedCoreChecks` → fails on assertion 1.
3. **(GREEN)** Implement `build`:
   - Build `let zOrderResolved = false`-style comparator only via the document; map each
     `registry.workspaces` entry (in order) to a `SidebarWorkspaceRow`.
   - For each workspace, look up `documents[entry.id]`; if absent, `zones = []`.
   - Sort the document's `zones` with the comparator from §Builder-semantics-3 (z-order index
     via a `Dictionary(uniqueKeysWithValues: document.zoneZOrder.enumerated().map { ($0.element,
     $0.offset) })`, `?? Int.min`, tiebreak `zoneId.uuidString`).
   - Map each sorted `ZonePlacement` to a `SidebarZoneRow` with the name-backfill rule
     (project zone → `registry.projects.first { $0.id == projectId }?.name ?? ""`; group zone
     → `placement.name`).
4. `swift build` → `swift run ContinuumRevivedCoreChecks` GREEN.
5. `./scripts/run-matrix.sh --fast` green; commit `feat(sidebar): pure two-level view-model
   from registry + workspace documents`.

## Acceptance criteria
- [ ] `SidebarTree.swift` adds `SidebarTree` / `SidebarWorkspaceRow` / `SidebarZoneRow` /
      `SidebarTreeBuilder.build(registry:documents:)`; all `Equatable, Sendable`; no AppKit
      import.
- [ ] Top-level rows mirror `registry.workspaces` order and names (assertions 1–2).
- [ ] Zone children sort by `zoneZOrder` then `zoneId.uuidString` (assertions 3, 8).
- [ ] Project zone name is backfilled from the registry; group zone uses its stored name;
      unresolved project id falls back to `""` (assertions 4, 5, 7).
- [ ] color / navKey / collapsed / projectId pass through per zone (assertion 6).
- [ ] Missing document ⇒ empty children, no crash; empty registry ⇒ empty tree; build is
      deterministic (assertions 9, 10, 11).
- [ ] No AppKit/runtime/`switchWorkspace`/`scripts` files touched; no new app check
      registered; no new `UserDefaults`/`SettingsSchema` entry.
- [ ] Core checks + fast matrix green; commit message has no co-author footer.

## Verification commands
```
swift build
# The guarding check rides the already-registered Core checks run:
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  swift run ContinuumRevivedCoreChecks; rm -rf "$P" "$A"
./scripts/run-matrix.sh --fast
```
(The temp `CONTINUUM_PROJECT_ROOT`/`CONTINUUM_APP_SUPPORT` dirs are harmless here — the Core
table touches no disk — but keep them for parity with the matrix's `run_app_check` env so the
invocation matches how the matrix runs it.)

## Review rubric (adversarial)
- **R1 — Real path, not a hidden bypass.** For a pure-model task the real path is
  `SidebarTreeBuilder.build` returning a tree the AppKit layer will render verbatim. Confirm
  the check asserts on the **returned tree** (`tree.workspaces[...]`), not on intermediate
  locals or a re-implementation of the comparator inside the test. If the check re-sorts the
  zones itself and compares to its own sort, REWORK — it must trust only `build`'s output.
- **R2 — Backfill actually happens.** Assertion 4 must use a zone whose **stored `name` is
  `""`** and a registry project whose name differs (`"continuum-revived"`), so a regression
  that returned the stored `""` would go RED. If the fixture stores a non-empty name on the
  project zone, the backfill is untested — REWORK.
- **R3 — Group vs project divergence.** Assertions 4+5 must both be present: project zone
  backfilled, group zone NOT backfilled (stored name kept). A check that only exercises one
  kind hides the branch.
- **R4 — Ordering is provably z-order, not array/dict order.** Assertion 3 reverses storage
  vs z-order; assertion 8 forces the `Int.min` + `uuidString` tiebreak. These two are the
  load-bearing order guards. Assertion 11 (`build == build`) is a *weak* net only (intra-run
  dict iteration is stable, so it would NOT catch a top-level built by iterating `documents`)
  — confirm top-level order is asserted to be `registry.workspaces`-array order via
  assertion 1, and confirm the reverse-order `zoneZOrder` fixture is used (a green check whose
  fixture has `zoneZOrder` equal to storage order would pass even with the wrong sort).
- **R5 — Fallback literal.** This task intentionally uses `?? ""` (not the canvas's
  `"Project"`) so an unresolved project zone renders blank rather than a fake label; the
  outline view (T16) decides how to present an empty name. If a reviewer prefers `"Project"`
  to match the canvas, that is a one-line change but must be agreed — flag, don't silently
  diverge. (Captured below; not a blocker.)
- **R6 — Scope.** Diff is exactly one new Core file + one appended `do {}` block. No
  `WorkspaceDocument`/`Registry`/AppKit/`scripts`/`Package.swift` edits. Orphans none (new
  file). No co-author footer.

## Out of scope / gotchas
- **The `NSOutlineView` itself is T16** — this task produces only the data it consumes. No
  inline-rename, no click-to-switch, no jump wiring here.
- **Where the `[UUID: WorkspaceDocument]` map comes from is T16's concern**, not this task's:
  T16 will load each workspace's document via `WorkspaceStore(workspaceId:…)` and pass the map
  in. Keeping `build` a pure function of `(Registry, [UUID: WorkspaceDocument])` is the whole
  point — no `WorkspaceStore`/disk access leaks into Core here.
- **Configurable-first is N/A:** no new binding/threshold/default is introduced. This is a
  pure projection of existing persisted model fields (`color`, `navKey`, `collapsed` already
  live on `ZonePlacement` post-T01; workspace order already lives in `registry.workspaces`).
  If T16 later adds a *display preference* (e.g. "show nav keys"), that setting is T16's, with
  its own default + `SettingsSchema` entry — not this task's.
- **NEEDS-HUMAN — fallback name literal (low-risk design call):** the canvas's existing
  backfill (`ContinuumApp.loadActiveZoneRenderModels`, :3546) uses `?? "Project"` for an
  unresolved project id, whereas this spec uses `?? ""` so the sidebar can render an
  unresolved/missing project zone as blank and let T16 own the empty-name presentation
  (placeholder text, "Missing Project", etc.). The two are intentionally different but a
  reviewer might want them unified. **Decision needed:** keep `""` here (assertion 7) or
  mirror the canvas `"Project"`. Pick one before T16 consumes the tree; the rest of the spec
  is unaffected either way. This is the only open question.
- **Determinism trap:** do not iterate `documents` (a `Dictionary`) to build the top level —
  iterate `registry.workspaces` (the ordered array) and *look up* into `documents`. Iterating
  the dict would make order nondeterministic and fail assertion 11.
- Stale SourceKit "cannot find `SidebarTreeBuilder`" squiggles before the file is saved are
  noise; `swift build` is authoritative.
