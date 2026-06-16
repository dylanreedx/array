# T07 — `BrowserRuntimeBudget` over the union of live browser tiles across all live zones (docs/23 S5)

One global WKWebView LRU budget that spans the **union** of live browser tiles across
every live zone the `WorkspaceRuntime` owns — not one zone in isolation.

Status: todo
Tag: overnight
Depends on: T06 (`WorkspaceRuntime` shell + `ZoneRuntimeRegistry`) · Blocks: —

## Goal (why)
Today the WKWebView LRU budget is enforced per the **single** live controller
(`AppDelegate.enforceBrowserRuntimeBudget()` reads `browserRuntimes`, a proxy over the
*one* `zoneRuntimeController.browserRuntimes`). Once a workspace runs **N** live zones
(T06), opening browsers in several zones at once could blow past the WKWebView ceiling and
exhaust the GPU/process budget the cap exists to protect (docs/23 D3 — budget caps
WKWebViews only in v1). This task moves budget enforcement into `WorkspaceRuntime` so the
cap is the **total live WKWebViews across all live zones**, evicting the global
least-recently-used browser regardless of which zone owns it, while protecting the focused
browser. The user-facing capability: a multi-zone workspace never holds more than the
configured number of live web views, and eviction picks the genuinely oldest one
everywhere — recency is global, not per-zone.

## Exact scope — files & symbols
- **`Sources/ContinuumRevived/App/WorkspaceRuntime.swift`** (created in T06) — own the
  single `BrowserRuntimeBudget` instance and add the cross-zone enforcement method. Move
  ownership of the budget here from `AppDelegate` (it currently lives at
  `ContinuumApp.swift:1008` as `private lazy var browserRuntimeBudget`). Add:
  - `private var browserRuntimeBudget = BrowserRuntimeBudget(maxLive: BrowserRuntimeBudget.resolveMaxLive())`
  - `func registerLiveBrowser(tileId: UUID)` — calls `browserRuntimeBudget.registerLive`.
  - `func enforceBrowserRuntimeBudget()` — gathers the **union** of live browser tile ids
    across **all** controllers the registry holds, computes `evictionCandidates`, and for
    each evicted tile id finds its owning controller and calls that controller's spawner
    `installBrowserSnapshotTile(...)`, then removes the runtime from *that* controller's
    `browserRuntimes` and `browserRuntimeBudget.unregister(tileId:)`.
- **`Sources/ContinuumRevived/App/ContinuumApp.swift`** — repoint the existing call sites
  (`:1154`, `:1576`, `:1626`, `:2533`, `:2701`, `:2717`) from the AppDelegate-private
  `enforceBrowserRuntimeBudget()` / `registerBrowserRuntimeForBudget(_:)` to the
  `WorkspaceRuntime` methods. Delete the now-orphaned AppDelegate
  `browserRuntimeBudget` field (`:1008`), `registerBrowserRuntimeForBudget(_:)`
  (`:1636`), and the body of `enforceBrowserRuntimeBudget()` (`:1640`) **only if** T06 has
  already introduced the `workspaceRuntime` field to forward through; otherwise keep a
  thin forwarding shim on AppDelegate that calls `workspaceRuntime.enforceBrowserRuntimeBudget()`
  (so the diff stays mechanical — docs/23 "Risk" guidance). `browserBudgetSnapshotImage()`
  (`:1660`) may move to `WorkspaceRuntime` or stay static on `AppDelegate` and be passed in;
  prefer staying put and being referenced, to minimize churn. **Access note:** it is
  currently `private static` (`:1660`); the new enforcer lives in a *different file*
  (`WorkspaceRuntime.swift`, same module), so referencing `AppDelegate.browserBudgetSnapshotImage()`
  from there requires relaxing it from `private` to **`internal`** (`static func`). The
  existing single-controller check at `:5318` already calls it as
  `AppDelegate.browserBudgetSnapshotImage()`, so it is already reachable in-file; the only
  delta is the `private` → `internal` visibility change. That one-keyword relaxation is the
  sole permitted edit to this function — do not change its body. (Alternative: pass a
  snapshot-image closure into `WorkspaceRuntime` at init; the visibility relaxation is
  simpler and is the default choice unless T06 already wires such a closure.)
- **`Sources/ContinuumRevivedCore/SettingsSchema.swift`** — append ONE `.text` field to the
  `general` section binding `BrowserRuntimeBudget.defaultsKey` with default
  `String(BrowserRuntimeBudget.defaultMaxLive)` (configurable-first; the key + resolver
  already exist in `BrowserRuntimeBudget.swift`, but it has **no Settings entry** today —
  this closes that gap).
- **`Sources/ContinuumRevivedCoreChecks/main.swift`** — add `BrowserRuntimeBudget.defaultsKey`
  to the `expectedKeys` set in the existing "Settings schema engine" block (`~:3949`) so the
  schema-coverage assertion guards it (conflict-guard: the same block already asserts
  `Set(fieldKeys).count == fieldKeys.count`, i.e. no duplicate keys).
- **`Sources/ContinuumRevived/App/ContinuumApp.swift`** — EXTEND `runBrowserLRUBudgetSelfCheck()`
  (`:5242`) with a multi-zone integration phase (see check section). The arg dispatch at
  `:577` already routes `--browser-lru-budget-check`; do not add a new flag.
- **`scripts/run-matrix.sh`** — already runs `--browser-lru-budget-check` (`:109`). No new
  registration needed (the check is EXTENDED, not new).

### Do NOT touch
- **Tier transitions on pan/zoom** (`onViewportChanged` / `reconcileHydration`) — that is
  T10. This task enforces the budget at hydration/register time only, exactly where the
  current code calls `enforceBrowserRuntimeBudget()`.
- **Non-browser tiles** — terminals/notes/diff/file-tree. PTYs stay live while their zone is
  Live (docs/23 D3). Do not add a PTY budget.
- **AppKit chrome** — zone headers, title bars, cursor rects, z-paint.
- **`BrowserRuntimeBudget`'s LRU primitives** (`registerLive`, `unregister`,
  `evictionCandidates`, `resolveMaxLive`). They are already controller-agnostic (a flat
  `[UUID]` recency list keyed by tile id) — do **not** rewrite them; the cross-zone change
  is in the *orchestration* that feeds them the union and routes evictions. The only Core
  edit is the `SettingsSchema` field + the check's `expectedKeys`.
- `ZoneRuntimeRegistry` ref-count semantics (T04), `switchWorkspace` (T09), `addZone` (T08).
- The 4 window-scoped NSEvent monitors (ADR-0024), `CanvasEngine` transforms, leader nav.

## Data / API changes
On `WorkspaceRuntime` (the exact host type from T06; see NEEDS-HUMAN gotcha for the
registry-iteration accessor name):
```swift
// Owned here, moved from AppDelegate:
private var browserRuntimeBudget = BrowserRuntimeBudget(maxLive: BrowserRuntimeBudget.resolveMaxLive())

func registerLiveBrowser(tileId: UUID) {
    browserRuntimeBudget.registerLive(tileId: tileId)
}

/// Enforce the WKWebView cap across the UNION of live browser tiles in ALL live zones.
/// `protectedTileIds` = the focused browser (canvas.lastActiveTileId) + any focus-mode
/// protected set, matching the current single-zone enforcer.
func enforceBrowserRuntimeBudget() {
    // 1. union live browser tile ids across every live controller in the registry
    let liveControllers: [ZoneRuntimeController] = registry.liveControllers  // T06/T04 accessor — see gotcha
    let liveTileIds: [UUID] = liveControllers.flatMap { $0.browserRuntimes.map(\.tileId) }
    let protected = currentProtectedBrowserTileIds()  // focused tile + focus-mode set
    // 2. global LRU decision over the union (existing Core math, unchanged)
    let evictIds = browserRuntimeBudget.evictionCandidates(liveTileIds: liveTileIds, protectedTileIds: protected)
    // 3. route each eviction to its OWNING controller's spawner
    for tileId in evictIds {
        guard let controller = liveControllers.first(where: { $0.browserRuntimes.contains { $0.tileId == tileId } }),
              let runtime = controller.browserRuntimes.first(where: { $0.tileId == tileId }),
              let spawner = controller.tileSpawner else { continue }
        do {
            try spawner.installBrowserSnapshotTile(runtime: runtime, snapshotImage: AppDelegate.browserBudgetSnapshotImage())
            controller.browserRuntimes.removeAll { $0.id == runtime.id }
            browserRuntimeBudget.unregister(tileId: tileId)
        } catch { fputs("Browser budget eviction failed for tile \(tileId): \(error)\n", stderr) }
    }
}
```
On `SettingsSchema.sections()`, in the `general` section's `fields` array, append:
```swift
.text(
    key: BrowserRuntimeBudget.defaultsKey,          // "continuum.browserLiveBudget"
    label: "Max Live Web Views",
    default: String(BrowserRuntimeBudget.defaultMaxLive)  // "6"
),
```
`BrowserRuntimeBudget` itself is unchanged. `resolveMaxLive()` already reads
`defaultsKey` from standard + bundled + legacy domains (`BrowserRuntimeBudget.swift:17`),
so the new Settings field drives the live cap with no resolver change.

## The check, written FIRST (spec-as-test) — EXTEND `--browser-lru-budget-check`
Registered: already in `scripts/run-matrix.sh:109` and dispatched at `ContinuumApp.swift:577`
(`AppDelegate.runBrowserLRUBudgetSelfCheck()`). **Keep** the existing pure-LRU assertions
(lines 5251–5261: `firstEviction == [b]`, `secondEviction == [c]`) — they still guard the
recency/protected math. **Keep** the existing single-controller integration phase (5266–5328)
so its assertions don't regress. **ADD** a new multi-zone integration phase that drives the
REAL `WorkspaceRuntime.enforceBrowserRuntimeBudget()` across **two** live controllers.

### Real path (no bypass)
The new phase must call `WorkspaceRuntime.enforceBrowserRuntimeBudget()` — the production
method the spawn/hydrate call sites invoke — **not** `budget.evictionCandidates(...)`
directly. It builds two `ZoneRuntimeController`s (one per project, each with a real
`TileSpawner` + `CanvasNSView` + real `BrowserEngineContext`), seeds browser tiles in each,
hydrates them to Live (real `restartBrowserTile` → real `WKWebViewBrowserRuntime`s), inserts
both controllers into the `WorkspaceRuntime`'s registry, then calls
`workspaceRuntime.registerLiveBrowser(tileId:)` for each in a defined recency order and
`workspaceRuntime.enforceBrowserRuntimeBudget()`. Asserts on **observable state**: the
`browserRuntimes` arrays of each controller (the live set), the on-canvas tile view types
(`BrowserSnapshotTileNSView` for evicted, `BrowserTileNSView` for live), and the
`runtimeRef` on the canvas `Tile` for the evicted tile.

### Assertions (every one hand-derivable)
Setup: `maxLive = 2`. Two live zones:
- Zone A (project A) holds browser tiles **a1, a2** (live WKWebViews).
- Zone B (project B) holds browser tiles **b1, b2** (live WKWebViews).
Recency is established by calling `registerLiveBrowser` in this exact order:
`a1, a2, b1, b2` (so a1 is oldest, b2 newest). Focused/protected = **{b2}** (the focused
browser in zone B). Union live = `[a1, a2, b1, b2]` (4 tiles), `maxLive = 2` → overflow = 2.

> **No protected-set bypass.** The protected set MUST be produced by the real enforcer's
> own derivation (`currentProtectedBrowserTileIds()` — see API block), which reads each live
> controller's `canvasView?.canvasState.lastActiveTileId` (unioned with the focus-mode set).
> The check therefore establishes `{b2}` by setting **`canvasB.canvasState.lastActiveTileId
> = b2`** (the way the real spawn/focus path would) — it must NOT hand a literal `{b2}` into
> any budget call. If the check fabricates the protected set instead of driving it through
> `lastActiveTileId`, it has bypassed the very path assertion 4 claims to verify — that is
> REWORK. (Mirror of the single-zone enforcer at `ContinuumApp.swift:1642-1645`.)
> `maxLive` is likewise set via the production constructor
> `BrowserRuntimeBudget(maxLive: BrowserRuntimeBudget.resolveMaxLive())` after writing
> `2` to `BrowserRuntimeBudget.defaultsKey` in an isolated `UserDefaults` suite — NOT by
> hardcoding `maxLive: 2` on a throwaway budget — so the new Settings field is proven to
> actually drive the live cap (configurable-first, exercised end-to-end). If T06 hardwires
> the budget's `maxLive`, note it and fall back to the constructor the same way.

After `workspaceRuntime.enforceBrowserRuntimeBudget()`:

1. **Live set never exceeds the budget.** Total live browser runtimes across BOTH
   controllers == 2. (`controllerA.browserRuntimes.count + controllerB.browserRuntimes.count == 2`.)
2. **Global LRU eviction is correct and cross-zone.** The two evicted tiles are the two
   oldest *unprotected* tiles in global recency order: **a1 then a2** (overflow=2, walk
   recency `[a1,a2,b1,b2]` skipping protected b2 → evict a1, a2). So after enforcement:
   `controllerA.browserRuntimes` is **empty** (both a1,a2 evicted) and
   `controllerB.browserRuntimes` == **[b1, b2]** (b1 kept because a1,a2 absorbed the whole
   overflow; b2 protected). This proves recency spans zones: the evictions came entirely
   from zone A because A held the oldest, even though zone B also held a live browser.
3. **Eviction routed to the owning controller's spawner.** The evicted tiles a1, a2 are now
   `BrowserSnapshotTileNSView` on **zone A's** canvas (`canvasA.tileView(for: a1) is
   BrowserSnapshotTileNSView`, same for a2), and their canvas `Tile.runtimeRef == nil`
   (snapshotted). b1, b2 remain `BrowserTileNSView` on zone B's canvas with non-nil
   `runtimeRef`. (Proves the eviction touched the *correct* zone's UI, not a global blob.)
4. **Protected (focused) browser survives even when oldest-in-its-zone.** b2 is protected
   and present in `controllerB.browserRuntimes`. (Re-derive: b2 ∈ protected → skipped by
   `evictionCandidates`.)
5. **Budget recency pruned to the union.** After enforcement, register a *third* zone's
   newer browser is out of scope; instead assert the eviction is **idempotent**: calling
   `workspaceRuntime.enforceBrowserRuntimeBudget()` a second time evicts **nothing more**
   (live set still == 2, `controllerA.browserRuntimes` still empty, `controllerB` still
   `[b1, b2]`) — proving `unregister` cleaned the evicted ids out of the recency list and
   the cap is stable.
6. **Recency-touch protects across zones.** After the first enforcement
   (live = {b1, b2}), hydrate a fresh browser **a3** in zone A and call
   `registerLiveBrowser(a3)` **only** (do NOT re-register b1/b2 — re-registering would
   reorder recency and invalidate this derivation), keep protected = {b2} (still via
   `canvasB.lastActiveTileId = b2`), then `enforceBrowserRuntimeBudget()`.
   Recency after the first enforcement's `unregister(a1)`/`unregister(a2)` is `[b1, b2]`;
   registering a3 appends it → `[b1, b2, a3]`. Union live = `{b1, b2, a3}` (3), overflow =
   1. The eviction walks **recency** (`[b1, b2, a3]`), NOT the union's enumeration order, so
   the controller-iteration order of the union is irrelevant here. Walk: b1 unprotected →
   evict (overflow 0). Evict = **[b1]**. Assert: `controllerB.browserRuntimes` == **[b2]**,
   zone B's canvas `tileView(for: b1) is BrowserSnapshotTileNSView`,
   `controllerA.browserRuntimes` == **[a3]** (a3 survived: newest in recency, behind the
   single-tile overflow), total live == 2. (Proves a freshly-touched browser in one zone
   evicts an older browser in another zone — recency is global, and survives an
   `unregister`-pruned recency list.)

Plus retain the existing assertions:
7. (existing) `firstEviction == [b]` — focused-oldest skip, next LRU evicts.
8. (existing) `secondEviction == [c]` — re-touched browser protected from immediate eviction.
9. (existing single-controller phase) `liveAfterHydration.count == 2`, contains `a`,
   `snapshotTileIds.count == 1`.

And the Core `SettingsSchema` assertions (in `ContinuumRevivedCoreChecks`), which gain
coverage of the new key automatically:
10. `BrowserRuntimeBudget.defaultsKey` ∈ schema field keys (added to `expectedKeys` →
    `expectedKeys.isSubset(of: fieldKeys)` covers it).
11. (existing, now also guards the new field) field keys are unique
    (`Set(fieldKeys).count == fieldKeys.count`) — the conflict-guard.
12. (existing per-field loop) the new `.text` field round-trips:
    `currentValue` on empty defaults == `.string("6")`; `setValue(.string("6-edited"))`
    round-trips. (No new code in the check loop — it already iterates all fields.)

### RED → GREEN boundary
- **RED #1 (Settings):** add the `expectedKeys` entry in
  `ContinuumRevivedCoreChecks/main.swift` BEFORE adding the `SettingsSchema` field. Run
  `swift run ContinuumRevivedCoreChecks` → fails the `expectedKeys.isSubset` assertion
  ("settings schema must represent every existing pref key"). Then add the `.text` field →
  GREEN. (Proves the field is actually wired, not just declared.)
- **RED #2 (multi-zone budget):** add the new multi-zone integration phase to
  `runBrowserLRUBudgetSelfCheck()` BEFORE writing `WorkspaceRuntime.enforceBrowserRuntimeBudget()`.
  With T06's `WorkspaceRuntime` present but the cross-zone enforcer absent (or stubbed to a
  no-op), assertion 1 fails: live set == 4, not 2. Then implement the union enforcer → GREEN.

## Implementation steps
1. **(RED #1)** In `ContinuumRevivedCoreChecks/main.swift` add `BrowserRuntimeBudget.defaultsKey`
   to `expectedKeys` (~:3949). `swift run ContinuumRevivedCoreChecks` → RED on the
   schema-coverage assertion.
2. Append the `.text` field to `SettingsSchema.sections()`’s `general` section binding
   `BrowserRuntimeBudget.defaultsKey`, default `String(BrowserRuntimeBudget.defaultMaxLive)`.
   `swift run ContinuumRevivedCoreChecks` → GREEN (coverage + uniqueness + per-field
   round-trip all pass).
3. **(RED #2)** Extend `runBrowserLRUBudgetSelfCheck()` with the multi-zone phase
   (two controllers, two spawners, two canvases, one shared `BrowserEngineContext`; seed a1,
   a2 in A and b1, b2 in B; hydrate to Live; build/obtain a `WorkspaceRuntime` whose
   registry holds both controllers; `registerLiveBrowser` in order a1,a2,b1,b2;
   protected = {b2}). Call `workspaceRuntime.enforceBrowserRuntimeBudget()` and add
   assertions 1–6. `swift build` then run the check → RED on assertion 1 (live == 4).
4. **(GREEN)** Implement on `WorkspaceRuntime` (T06): own `browserRuntimeBudget`, add
   `registerLiveBrowser(tileId:)` + the union `enforceBrowserRuntimeBudget()` per the API
   block above. Repoint `ContinuumApp` call sites (`:1154,:1576,:1626,:2533,:2701,:2717`)
   to forward to the `WorkspaceRuntime` methods; remove the orphaned AppDelegate
   `browserRuntimeBudget` field + `registerBrowserRuntimeForBudget` + the body of the old
   `enforceBrowserRuntimeBudget` (or leave a one-line forwarding shim — see scope note).
5. `swift build` → run `--browser-lru-budget-check` → GREEN (all of 1–9).
6. `./scripts/run-matrix.sh --fast` → green (Core schema checks + the budget check + no
   regression in `--zone-hydration-lifecycle-check` / `--zone-save-isolation-check` /
   `--add-zone-check`, which share the controller harness).

## Acceptance criteria
- [ ] Budget is owned by `WorkspaceRuntime`; `AppDelegate` no longer holds its own
      `BrowserRuntimeBudget` (orphan removed or forwarded).
- [ ] `enforceBrowserRuntimeBudget()` operates over the **union** of `browserRuntimes`
      across all live controllers in the registry, not one controller.
- [ ] Eviction routes each evicted tile to its **owning** controller's spawner (snapshot
      installed on the correct zone's canvas; that controller's `browserRuntimes` trimmed).
- [ ] Live WKWebView count across all zones never exceeds `maxLive` after enforcement.
- [ ] Cross-zone recency: the globally-oldest unprotected browser is evicted regardless of
      zone; a freshly-touched browser in one zone can evict an older one in another.
- [ ] Focused/protected browser is never evicted.
- [ ] `BrowserRuntimeBudget.defaultsKey` has a `SettingsSchema` `.text` entry (default "6"),
      covered by `expectedKeys`, unique, round-tripping (conflict-guard green).
- [ ] `--browser-lru-budget-check` GREEN with all multi-zone assertions; existing
      single-controller + pure assertions retained and green.
- [ ] Fast matrix green; commit `feat(zones): browser runtime budget spans live-zone union (S5)`.

## Verification commands
```
swift build
swift run ContinuumRevivedCoreChecks
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --browser-lru-budget-check; rm -rf "$P" "$A"
./scripts/run-matrix.sh --fast
```

## Review rubric (adversarial)
- **Bypass audit (critical):** the multi-zone phase MUST call
  `WorkspaceRuntime.enforceBrowserRuntimeBudget()` — the real production method — and assert
  on the controllers' `browserRuntimes` + canvas tile-view types. If it calls
  `budget.evictionCandidates(...)` directly and asserts on the returned `[UUID]` (the bypass
  the existing pure-phase already covers), that is **NO new check** — REWORK. Ask: would the
  multi-zone assertions still pass if `enforceBrowserRuntimeBudget` were stubbed to a no-op?
  They must go RED (live set stays 4).
- **Union, not loop-over-zones:** confirm the enforcer gathers ALL live tile ids into one
  `evictionCandidates` call (one global LRU decision), not per-zone enforcement that would
  cap each zone independently. The tell: with maxLive=2 and 2 tiles in each of 2 zones, a
  per-zone enforcer would leave 2+2=4 (each zone "within budget"); the union enforcer leaves
  2 total. Assertion 1 is the discriminator — re-derive it.
- **Routing correctness:** assertion 3 must check the *owning* zone's canvas got the
  snapshot view (not just that some runtime vanished). Verify the check inspects
  `canvasA.tileView(for: a1)` specifically, and that b-tiles on canvasB are untouched.
- **Recency is global:** assertion 6 (touch a3 in zone A → evict b1 in zone B) is the proof
  recency crosses zones. If absent or it evicts within the same zone, REWORK.
- **Protected survives — and is derived, not fabricated:** confirm b2 is kept BECAUSE the
  enforcer's own `currentProtectedBrowserTileIds()` read it from `canvasB.lastActiveTileId`
  (the check set that field), NOT because the check handed a literal `{b2}` into a budget
  call. A check that protects nothing trivially passes assertion 1 by evicting any 2; a
  check that fabricates the protected set bypasses the focus-derivation path — both are
  REWORK. Verify the cap itself was driven by `resolveMaxLive()` reading the Settings key
  (not a hardcoded `maxLive: 2`).
- **Configurable-first:** the Settings field binds `BrowserRuntimeBudget.defaultsKey`
  exactly (so it drives `resolveMaxLive()`), default "6", and is in `expectedKeys`. The
  conflict-guard = the existing unique-keys assertion now covers it. No new default invented.
- **Scope:** no PTY budget, no T10 viewport wiring, no edits to the LRU primitives in
  `BrowserRuntimeBudget.swift`. Orphaned AppDelegate budget members removed (no dead field).

## Out of scope / gotchas
- **⚠ NEEDS-HUMAN — T06 API shape not yet in source.** `WorkspaceRuntime` and
  `ZoneRuntimeRegistry` (T06/T04) do **not exist yet** (`grep WorkspaceRuntime`/
  `ZoneRuntimeRegistry` over `Sources/` returns nothing; the field at `ContinuumApp.swift:995`
  is still the single `zoneRuntimeController: ZoneRuntimeController?`). This spec is written
  against the **planned** docs/23 shape ("WorkspaceRuntime owns the global
  BrowserRuntimeBudget" + "ZoneRuntimeRegistry `[projectId: ControllerBox]`"). Two binding
  points are unresolved until T06 lands and MUST be confirmed against the real T06 source
  before building, not invented:
  1. **The registry accessor that yields the live `ZoneRuntimeController`s** — assumed
     `registry.liveControllers: [ZoneRuntimeController]` here. T06/T04 may expose this as
     `registry.allControllers`, a `controllers.values` map over `ControllerBox`, or a
     filter on tier. The builder must use whatever T06 actually exposes; do not add a new
     accessor unless T06 left none (then add a minimal read-only one and note it).
  2. **How `WorkspaceRuntime` reaches each controller's focused/protected tile + spawner.**
     Assumed `controller.tileSpawner` (exists, `ZoneRuntimeController.swift:17`, but
     `weak`/optional) and a `currentProtectedBrowserTileIds()` that unions each live
     controller's `canvasView?.canvasState.lastActiveTileId` with the focus-mode set
     (mirroring the current single-zone enforcer at `ContinuumApp.swift:1642-1645`). The
     exact ownership of `focusModeSession` post-T06 (AppDelegate vs WorkspaceRuntime) must
     be confirmed; if it stays on AppDelegate, `WorkspaceRuntime` needs a closure/accessor
     to read it. **Builder: confirm both against real T06 source; if the shape differs,
     adapt the enforcer to it — the LRU contract (union → `evictionCandidates` → route to
     owner) is the invariant; the accessor names are not.**
  3. **How the *check* builds a `WorkspaceRuntime` and inserts the two controllers into
     its registry.** The new phase needs to (a) construct a `WorkspaceRuntime` and (b) place
     both `ZoneRuntimeController`s into its `ZoneRuntimeRegistry` so `liveControllers`
     enumerates them. The constructor signature and the registry-insertion API
     (e.g. `registry.acquire(projectId:)` returning a `ControllerBox`, or a test seam to
     inject pre-built controllers) are defined by T06/T04 and do **not exist yet** — the
     builder MUST use whatever insertion path T06 exposes (preferring the same
     `acquire`/`register` path production uses, so the harness exercises the real registry,
     not a back-door). Do not invent a constructor or a controller-injection API here; if
     T06 genuinely left no headless-test seam to populate the registry with two controllers,
     that is a T06 gap to raise, not something to paper over with a bespoke accessor.
- The existing single-controller integration phase (5309–5328) wires eviction via
  `controller.onBrowserRuntimeHydrated`; the production path now lives in
  `WorkspaceRuntime`. Keep the old phase's assertions (don't delete coverage), but the new
  phase is the one that exercises the cross-zone production method.
- `installBrowserSnapshotTile` is `throws` (`TileSpawner.swift:532`) — preserve the
  do/catch + stderr log shape from the current enforcer; do not let a single eviction
  failure abort the loop.
- Coordinate model is irrelevant here (no frame math) — eviction is by tile id; do not
  reach for `worldFrame`/`screenToWorld`.
- Stale SourceKit "cannot find `WorkspaceRuntime`/`registry.liveControllers`" diagnostics
  are expected until T06 is integrated; `swift build` is authoritative.
- Shared-project zones (one `projectId` in two workspaces, ref-counted — CON-58/D1) share
  ONE controller, so the union naturally counts that project's browsers once. No special
  case needed, but the reviewer should confirm the union dedupes by controller identity if
  the same controller could be enumerated twice (it should not, per T04 — one box per
  projectId).
