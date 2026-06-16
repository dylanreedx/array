# T03 — `ZoneHydrationOrchestrator` (pure planner, docs/23 S1)

One-line: a deterministic, total, AppKit-free function that turns
`(zones, viewport, visibleSize, focusedZone, budget)` into a per-zone
`HydrationTier` plan — the planning half of CON-51. Applying the plan is T06/T10.

Status: todo
Tag: overnight [pure]
Depends on: — · Blocks: T06, T10

## Goal (why)
The keystone needs to decide, for *every* zone at once, which controllers should be
`live` / `snapshot` / `cold` given where the user is looking and a resource ceiling — so
a workspace with many project zones doesn't try to keep every PTY/WKWebView set hot. Today
the only tier logic is `CanvasEngine.hydrationTier(...)`, which judges **one zone in
isolation** (purely visibility + pin + focus). It has no notion of a *budget*: nothing
caps how many zones may be `live` simultaneously. T03 is the pure brain that the live
`WorkspaceRuntime` (T06) and the viewport-driven reconciler (T10) will call; it composes
the existing per-zone tier rule with a global live-budget so the plan is bounded and
deterministic. This task is the **planner only** — it touches no controllers, no canvas,
no registry; it just returns a `[UUID: HydrationTier]` map (plus a stable ordering for
testability). T06/T10 apply it.

## Exact scope — files & symbols
- **NEW `Sources/ContinuumRevivedCore/ZoneHydrationOrchestrator.swift`** — a pure
  `enum ZoneHydrationOrchestrator` (namespace, mirrors `CanvasEngine`/`DragMagnetizeConfig`
  style — no stored state) with one `public static func plan(...) -> ZoneHydrationPlan`.
  Delegates the *single-zone* verdict to the existing
  `CanvasEngine.hydrationTier(zone:viewport:visibleSize:focusedTileZone:snapshotMargin:)`,
  then applies a **live budget** that demotes the lowest-priority overflow `live` zones to
  `snapshot`. No AppKit import (Core has none anyway). Define the return type
  `ZoneHydrationPlan` and the budget config in the same file (see Data / API changes).
- **NEW `Sources/ContinuumRevivedCore/ZoneHydrationBudgetConfig.swift`** — a tiny config
  namespace mirroring `DragMagnetizeConfig`/`TileGapResolver`: the persisted default +
  `UserDefaults` resolver for the **max simultaneously-live zones** threshold. (Configurable-
  first; see §Configurable-first.)
- **EXTEND `Sources/ContinuumRevivedCore/SettingsSchema.swift`** — append ONE `.text` field
  to the existing `general` section binding `ZoneHydrationBudgetConfig.maxLiveZonesKey`.
- **EXTEND `Sources/ContinuumRevivedCoreChecks/main.swift`** — add the
  `--zone-hydration-plan-check` table (a new top-level `do { … }` block) and EXTEND the
  existing "Settings schema engine" `do` block's `expectedKeys` set with the new key
  (so the schema check proves the new pref is bound).
- **Do NOT touch:**
  - `Sources/ContinuumRevived/App/ZoneRuntimeController.swift` and its
    `--zone-hydration-lifecycle-check` (that is the *applying* half — the live single
    controller; T03 must not collide with it). Do not change `setTier` / `dehydrate`.
  - `BrowserRuntimeBudget.swift` — the *tile-level* LRU budget is T07/S5's domain
    (`--browser-lru-budget-check`); T03's budget is a separate **zone-count** cap.
    Reuse none of it, rename none of it.
  - `CanvasEngine.hydrationTier(...)` — call it unchanged; do NOT alter its signature,
    margin default, or the existing "Hydration tier visibility math" Core table.
  - Any AppKit, `WorkspaceRuntime`, `ZoneRuntimeRegistry` (T04), canvas/layer code (T05),
    viewport-driven *application* (T10), `WorkspaceDocument` schema (T01).
  - Do NOT add a per-check `CommandLine.arguments` dispatch in `ContinuumApp.swift` — this
    is a Core-library table, not an app real-path check (see §The check rationale).

## Data / API changes (copy-pasteable)

New file `ZoneHydrationOrchestrator.swift`:
```swift
import Foundation

/// The pure result of planning hydration across every zone in a workspace at once:
/// each known zone mapped to the tier its controller SHOULD hold. Total over the input
/// zones (every input zoneId appears exactly once); deterministic for a given input.
public struct ZoneHydrationPlan: Equatable, Sendable {
    /// zoneId -> assigned tier. Total over the input zone set.
    public let tiers: [UUID: HydrationTier]
    /// The input zones in the same order they were supplied, for stable iteration in
    /// callers/tests. (A dictionary has no order; this preserves the caller's.)
    public let order: [UUID]

    public init(tiers: [UUID: HydrationTier], order: [UUID]) {
        self.tiers = tiers
        self.order = order
    }

    public func tier(for zoneId: UUID) -> HydrationTier? { tiers[zoneId] }
}

/// Pure cross-zone hydration planner (docs/23 S1, CON-51). Composes the per-zone
/// visibility/pin/focus verdict (`CanvasEngine.hydrationTier`) with a global cap on how
/// many zones may be `.live` at once, demoting overflow to `.snapshot`. No AppKit, no
/// state — applying the plan (spinning/teardown of controllers) is T06/T10.
public enum ZoneHydrationOrchestrator {
    /// Compute the tier for every zone.
    ///
    /// - zones: the workspace's placements (order is preserved into the plan).
    /// - viewport / visibleSize: the live canvas view, forwarded verbatim to
    ///   `CanvasEngine.hydrationTier` (Y-down world coords; visibleSize is screen px,
    ///   converted to world by that fn via `/ viewport.zoom`).
    /// - focusedTileZone: the zone whose focused tile forces `.live` (forwarded).
    /// - maxLiveZones: the live budget; when more zones than this resolve to `.live`,
    ///   the lowest-priority overflow zones demote to `.snapshot`. `<= 0` is clamped to
    ///   1 (at least the highest-priority zone stays live).
    /// - snapshotMargin: forwarded to `CanvasEngine.hydrationTier` (default matches it).
    public static func plan(
        zones: [ZonePlacement],
        viewport: CanvasViewport,
        visibleSize: CGSize,
        focusedTileZone: UUID?,
        maxLiveZones: Int,
        snapshotMargin: Double = CanvasEngine.defaultHydrationSnapshotMargin
    ) -> ZoneHydrationPlan
}
```
Import `CoreGraphics` (for `CGSize`) — `CanvasEngine.swift` already does; match it.

New file `ZoneHydrationBudgetConfig.swift`:
```swift
import Foundation

/// Resolves the max number of zones that may be `.live` simultaneously, from
/// UserDefaults. Mirrors `TileGapResolver` / `DragMagnetizeConfig`. This is the
/// ZONE-count budget the pure `ZoneHydrationOrchestrator` enforces — distinct from the
/// tile-level `BrowserRuntimeBudget` (WKWebView LRU, T07).
public enum ZoneHydrationBudgetConfig {
    public static let maxLiveZonesKey = "continuum.zoneHydration.maxLiveZones"
    public static let defaultMaxLiveZones = 4

    public static func maxLiveZones(defaults: UserDefaults = .standard) -> Int {
        if let value = defaults.object(forKey: maxLiveZonesKey) as? Int, value > 0 {
            return value
        }
        if let s = defaults.string(forKey: maxLiveZonesKey), let value = Int(s), value > 0 {
            return value
        }
        return defaultMaxLiveZones
    }
}
```

SettingsSchema delta (append inside the existing `general` section's `fields:` array, after
the Drag Snapping toggle):
```swift
.text(
    key: ZoneHydrationBudgetConfig.maxLiveZonesKey,
    label: "Max Live Zones",
    default: String(ZoneHydrationBudgetConfig.defaultMaxLiveZones)
),
```

### The budget + priority rule (the load-bearing spec, hand-derivable)
1. **Per-zone base verdict.** For each input zone, `base = CanvasEngine.hydrationTier(zone:
   viewport: visibleSize: focusedTileZone: snapshotMargin:)`. (Unchanged single-zone rule:
   `pinnedLive` OR `focusedTileZone == zoneId` ⇒ `.live`; else visible-rect intersection ⇒
   `.live`; else within snapshot band ⇒ `.snapshot`; else `.cold`.)
2. **Hard-pinned zones bypass the budget.** A zone whose base verdict is `.live` because
   it is `pinnedLive` OR it is the `focusedTileZone` is **never demoted** — it stays
   `.live` regardless of how many such zones exist. (Rationale: a pinned zone is an
   explicit user contract; the focused zone is where they are typing. Demoting either
   would be a behavior regression vs. today's single-zone rule.)
3. **Budgeted live demotion.** Let `B = max(1, maxLiveZones)`. Count the hard-pinned-live
   zones as `P`. Among the **budget-eligible** zones whose base is `.live` (i.e. live by
   visibility only, not pinned/focused), keep the top `max(0, B - P)` by priority and
   demote the rest to `.snapshot`. (If `P >= B`, all visibility-live zones demote to
   `.snapshot`; pinned/focused still win — the budget is a *soft* cap that pins override,
   matching the single-zone rule that pin/focus always force live.)
4. **Priority ordering for the keep/demote cut (deterministic, total):** budget-eligible
   live zones are ranked by, in order:
   a. **input order ascending** is the tiebreak of LAST resort only; the PRIMARY rank is
      visual proximity. Define `proximity` = the squared distance from the zone's world
      center to the viewport's visible-rect center (smaller = higher priority). The
      visible-rect center in world coords is
      `(viewport.x + (visibleSize.width / zoom)/2, viewport.y + (visibleSize.height /
      zoom)/2)`; the zone center is `(origin.x + size.width/2, origin.y + size.height/2)`.
   b. ties in `proximity` broken by **input order ascending** (the zone's index in the
      `zones` array). This makes the cut fully deterministic and hand-derivable.
   So: sort budget-eligible live zones by `(proximity asc, inputIndex asc)`; the first
   `max(0, B - P)` stay `.live`, the remainder become `.snapshot`.
5. **`.snapshot` and `.cold` base verdicts are never *promoted*** by the budget — the
   budget only demotes `live → snapshot`. (A zone the visibility rule judged off-screen
   stays off-screen-tier.)
6. **Totality:** every input `zoneId` appears in `plan.tiers` exactly once and in
   `plan.order` in input order; an empty `zones` ⇒ empty plan. Duplicate zoneIds in the
   input are not expected (D1 caps one zone per project per workspace; T01 keeps zoneId
   unique) — if two share an id, last-write-wins in the dict and both appear in `order`
   (documented edge, not asserted).

## The check, written FIRST (spec-as-test) — `--zone-hydration-plan-check`

**Where it lives / why Core, not an app dispatch.** This is a PURE planner over pure
Core types (`ZonePlacement`, `CanvasViewport`, `HydrationTier`). Per 01 §2, *for a pure-
model task a Core round-trip/derivation table IS the real path*. The real path here is
`ZoneHydrationOrchestrator.plan(...)` composed with the production
`CanvasEngine.hydrationTier(...)` — there is no NSEvent/lifecycle to synthesize because
the planner has no side effects and no AppKit surface. Calling `plan(...)` IS calling the
function the live runtime (T06/T10) will call; it is not a bypass. The check is therefore
a new top-level `do { … }` block in **`Sources/ContinuumRevivedCoreChecks/main.swift`**,
run by the `ContinuumRevivedCoreChecks` binary (already in the matrix at run-matrix.sh:62).

**Naming.** The charter names the guard `--zone-hydration-plan-check`. Because Core checks
run as one binary (no per-flag dispatch inside `main.swift`), there is no actual CLI flag
to register; the "check" is this `do` block tagged with a leading comment
`// MARK: - zone-hydration-plan-check (T03)` and each `expect` message prefixed
`zone hydration plan:`. Do NOT add a `--zone-hydration-plan-check` entry to
`scripts/run-matrix.sh` or to `ContinuumApp.swift` — the CoreChecks line already covers it.
(NEEDS-HUMAN note in §Out of scope confirms this is the intended interpretation of the
charter's flag name for a pure table.) The existing app-target `--zone-hydration-lifecycle-
check` is the *applying* half and is untouched — no collision.

The block builds zones with hand-chosen origins so every base verdict and every budget cut
is computable by hand against the `CanvasEngine.hydrationTier` rule. Use
`viewport = CanvasViewport(x: 0, y: 0, zoom: 1)`, `visibleSize = CGSize(width: 800,
height: 600)`, `snapshotMargin` default (256), and a zone size of `200×120` (matching the
existing hydration-tier table so the derived tiers reuse known-good geometry). With
`zoom = 1`, visible world rect = `(0,0,800,600)`; its center = `(400, 300)`.

Zone fixtures (zoneId suffixes Z1..Z6; all `projectId` arbitrary fixed UUIDs; size 200×120;
policy/origin as noted). Base verdict derived from the existing tier rule:
- **Z1** origin `(100,100)` automatic → intersects visible rect → base `.live`.
  center `(200,160)`; dist² to `(400,300)` = `200²+140²` = `40000+19600` = `59600`.
- **Z2** origin `(300,100)` automatic → intersects → base `.live`.
  center `(400,160)`; dist² = `0²+140²` = `19600`. (closest to center)
- **Z3** origin `(550,100)` automatic → intersects → base `.live`.
  center `(650,160)`; dist² = `250²+140²` = `62500+19600` = `82100`.
- **Z4** origin `(100,300)` automatic → intersects → base `.live`.
  center `(200,360)`; dist² = `200²+60²` = `40000+3600` = `43600`.
- **Z5** origin `(1200,100)` automatic → outside snapshot band → base `.cold`. (Snapshot
  band right edge is x ≤ 1056 per the existing tier table — `("right margin boundary
  touches snapshot band", originX: 1056, .snapshot)` / `originX: 1057, .cold` at
  main.swift:618; 1200 is well past it.) (never live, budget-irrelevant)
- **Z6** origin `(1200,100)` **pinnedLive** → base `.live` by pin (hard-pinned).

Assertions (each hand-derivable):

1. **Empty input is total-empty.** `plan(zones: [], …, maxLiveZones: 4).tiers.isEmpty` and
   `.order.isEmpty`.
2. **Totality.** For the 6-zone fixture, `plan(...).tiers.count == 6`, `plan(...).order ==
   [Z1,Z2,Z3,Z4,Z5,Z6]` (input order), and every zoneId is a key in `tiers`.
3. **Budget non-binding passthrough.** With `maxLiveZones: 6` (≥ number of live zones),
   every base verdict survives unchanged: `tiers[Z1..Z4] == .live`, `tiers[Z5] == .cold`,
   `tiers[Z6] == .live`. (Proves the planner is a faithful passthrough of
   `CanvasEngine.hydrationTier` when the budget doesn't bite — and that it matches the
   existing single-zone table.)
4. **Budget demotes the FARTHEST visibility-live zones first.** With `maxLiveZones: 2`:
   budget-eligible live zones are Z1(59600), Z2(19600), Z3(82100), Z4(43600); Z6 is
   hard-pinned (P=1), Z5 is cold. Budget for eligible = `max(0, 2-1) = 1`. Ranked by
   proximity asc: Z2(19600), Z4(43600), Z1(59600), Z3(82100). Keep the top 1 → **Z2
   stays `.live`**; Z4, Z1, Z3 demote to `.snapshot`. Assert: `tiers[Z2] == .live`,
   `tiers[Z4] == .snapshot`, `tiers[Z1] == .snapshot`, `tiers[Z3] == .snapshot`,
   `tiers[Z6] == .live` (pin survives), `tiers[Z5] == .cold` (unchanged).
5. **Pinned/focused are NEVER demoted, even when over budget.** With `maxLiveZones: 1`:
   `B=1`, P (Z6 pinned) = 1, eligible budget = `max(0, 1-1) = 0` → ALL of Z1..Z4 demote to
   `.snapshot`; Z6 stays `.live`; Z5 `.cold`. Assert all four `.snapshot`, `tiers[Z6] ==
   .live`, `tiers[Z5] == .cold`. (Proves a soft cap that pins override — assertion 5
   would FAIL if the planner naively kept the first B live zones regardless of pin.)
6. **Focused zone is hard-pinned too (not just `pinnedLive`).** Re-plan the fixture with
   `focusedTileZone: Z1` and `maxLiveZones: 1`. Z1 is now hard-pinned (focused). P = 2
   (Z1 focused + Z6 pinned), eligible budget = `max(0, 1-2) = 0`. Assert `tiers[Z1] ==
   .live` (focus survives budget), `tiers[Z6] == .live`, and Z2,Z3,Z4 all `.snapshot`.
7. **Tiebreak is input order on equal proximity.** Build TWO zones Za, Zb with origins
   symmetric about the visible-rect center so their centers are equidistant: Za origin
   `(300,240)` center `(400,300)` dist²=0; Zb origin `(300,240)` center `(400,300)`
   dist²=0 — identical proximity, both `.live` base. With `maxLiveZones: 1` and no pins:
   `B=1`, P=0, eligible budget=1; tie on proximity → input order ascending wins → keep the
   FIRST in input order. Assert `plan(zones: [Za, Zb], …).tiers[Za] == .live` and
   `tiers[Zb] == .snapshot`; then swap input order (`[Zb, Za]`) and assert the keep flips
   to `Zb`. (Proves determinism + the documented tiebreak.)
8. **`maxLiveZones <= 0` clamps to 1.** `plan(zones: [Z2], …, maxLiveZones: 0).tiers[Z2]
   == .live` (Z2 base live, B clamped to 1, P=0, eligible budget 1 → kept). And with the
   explicit two-zone fixture `[Z1, Z2]` (both visibility-live, no pins) + `maxLiveZones:
   0`: B clamps to 1, P=0, eligible budget 1; ranked by proximity Z2(19600) < Z1(59600) →
   **`tiers[Z2] == .live`, `tiers[Z1] == .snapshot`** — exactly one live, never zero when
   at least one zone is visibility-live. (Also `maxLiveZones: -3` on `[Z1, Z2]` clamps
   identically — same result — to prove the clamp covers negatives, not just 0.)
9. **Budget never promotes.** With Z5 (base `.cold`) and a huge `maxLiveZones: 99`,
   `tiers[Z5] == .cold` (not promoted to live). Already implied by 3 but assert standalone
   so a future "promote to fill budget" bug is caught.

Plus the **config resolver** assertions (same `do` block or a sibling block tagged
`zone hydration budget config:`), in an isolated suite mirroring the DragMagnetize check
at main.swift:3963:
10. `ZoneHydrationBudgetConfig.maxLiveZones(defaults:)` on a scrubbed suite returns
    `defaultMaxLiveZones` (4).
11. After `defaults.set(2, forKey: maxLiveZonesKey)`, the resolver returns 2.
12. A bogus value (`set(0)` or `set(-3)`) falls back to the default (4) — the
    `> 0` guard.
13. A string override (`set("3", forKey:)`) resolves to 3 (defaults-as-string path).

Plus EXTEND the existing **"Settings schema engine"** block (main.swift:3949) — add
`ZoneHydrationBudgetConfig.maxLiveZonesKey` to `expectedKeys`. (No new block; this proves
the new pref is actually bound in the schema, satisfying configurable-first.)

**RED expectation:** the check fails to *compile* until `ZoneHydrationOrchestrator`,
`ZoneHydrationPlan`, and `ZoneHydrationBudgetConfig` exist (acceptable RED for a pure type,
per 01 §1 and the T01 precedent). The *behavioral* RED is assertions 4–8 (budget +
priority + tiebreak): they fail with a naive "keep first B live zones" or "demote by input
order" stub, and only pass once the proximity-ranked, pin-bypassing budget is implemented.
Write the block, add minimal compiling stubs (`plan` returning the un-budgeted base map),
run `swift run ContinuumRevivedCoreChecks` → watch 4–8 FAIL on the assertion, then GREEN.

## Implementation steps
1. Add the `--zone-hydration-plan-check` `do` block (+ config + schema assertions) to
   `ContinuumRevivedCoreChecks/main.swift`. Add a minimal compiling stub: create
   `ZoneHydrationOrchestrator.swift` with `plan(...)` returning
   `ZoneHydrationPlan(tiers: <base per-zone via CanvasEngine.hydrationTier>, order:
   zones.map(\.zoneId))` (NO budget yet), and `ZoneHydrationBudgetConfig.swift` with the
   real resolver. Append the SettingsSchema field. `swift build` → `swift run
   ContinuumRevivedCoreChecks` → confirm assertions 1–3, 9, 10–13, and the schema key pass
   but **4–8 FAIL on the assertion** (RED boundary — budget/priority not yet applied).
2. Implement the budget in `plan(...)`: (a) compute `base` per zone; (b) partition the
   `.live` zones into hard-pinned (`zone.hydrationPolicy == .pinnedLive ||
   zone.zoneId == focusedTileZone`) vs. budget-eligible; (c) `B = max(1, maxLiveZones)`,
   `P = hardPinned.count`, `keep = max(0, B - P)`; (d) sort eligible-live by
   `(proximityToVisibleCenter asc, inputIndex asc)`; (e) demote eligible-live beyond the
   first `keep` to `.snapshot`; (f) assemble `tiers` (pinned-live + kept-live stay `.live`,
   demoted → `.snapshot`, non-live keep base), preserve `order = zones.map(\.zoneId)`.
3. `swift build` → `swift run ContinuumRevivedCoreChecks` → all GREEN (RED→GREEN boundary
   crossed at this commit). Re-derive at least assertion 4 by hand to confirm intent.
4. `./scripts/run-matrix.sh --fast` green (the existing Settings-schema block now also
   asserts the new key; the existing hydration-tier table is untouched and still green).
5. Self-review against Acceptance + Review rubric; commit
   `feat(zones): pure ZoneHydrationOrchestrator + live-zone budget (S1)` (plain message,
   no co-author footer).

## Acceptance criteria
- [ ] `ZoneHydrationOrchestrator.plan(...)` exists in Core, pure, no AppKit, no stored
      state, returns a `ZoneHydrationPlan` total over the input zones.
- [ ] Single-zone verdict is delegated to the *unchanged* `CanvasEngine.hydrationTier`
      (passthrough proven by assertion 3 matching the existing tier table geometry).
- [ ] Budget demotes the farthest visibility-live zones first; pinned/focused zones are
      never demoted (assertions 4–6).
- [ ] Tiebreak on equal proximity is input order; clamping `maxLiveZones <= 0 → 1`
      (assertions 7–8). Budget never promotes (9).
- [ ] `ZoneHydrationBudgetConfig` has a persisted default (4), a `UserDefaults` resolver
      with a `> 0` guard, a SettingsSchema entry, and the schema check asserts its key.
- [ ] `--zone-hydration-plan-check` table green; fast matrix green; nothing in the App
      target / `ZoneRuntimeController` / `--zone-hydration-lifecycle-check` /
      `BrowserRuntimeBudget` / `CanvasEngine` touched.

## Verification commands
```
swift build
swift run ContinuumRevivedCoreChecks          # the --zone-hydration-plan-check table + config + schema key
./scripts/run-matrix.sh --fast
```
(No `CONTINUUM_PROJECT_ROOT`/`CONTINUUM_APP_SUPPORT` temp dirs needed — this is a pure Core
binary with no on-disk state, run directly by the matrix. The temp-dir pattern is only for
the App-target `.build/debug/continuum-revived --…-check` real-path checks.)

## Review rubric (task-specific adversarial angles)
- **Bypass audit (the framing question):** is the Core table the real path? YES — the
  planner is a pure function with no AppKit/lifecycle surface, so calling `plan(...)` IS
  the production path T06/T10 will call; per 01 §2 a Core derivation table is the real path
  for a pure-model task. REWORK only if the check were to assert against a *re-implemented*
  budget in the test instead of the real `plan(...)`, or if it called
  `CanvasEngine.hydrationTier` directly and asserted on that (that would skip the budget —
  the actual new behavior).
- **Would it go RED without the change?** Revert step 2 (return base map only): assertions
  4–8 must fail. Confirm the reviewer can mentally see that a "keep first B live by input
  order" stub fails assertion 4 (it would keep Z1,Z2 — but Z1 is farther than Z4, so the
  correct keep at B-eligible=1 is Z2 only). If 4–8 pass on the naive stub, the priority
  rule isn't actually exercised — REWORK.
- **Pin/focus override is the bug-magnet:** assertion 5 (`maxLiveZones: 1`, pinned Z6) must
  keep Z6 `.live` even though the budget is "full" — a planner that counts pinned zones
  *against* the eligible budget but then *demotes* them would fail; one that double-counts
  would let an extra eligible zone through. Re-derive `P`, `keep`, and the kept set by hand.
- **Determinism:** assertion 7 must show the keep flips when input order is swapped on a
  proximity tie — proving the tiebreak is real, not incidental dictionary ordering.
- **Totality / no promotion:** confirm `tiers.count == zones.count` and that a `.cold`/
  `.snapshot` base is never upgraded (assertion 9), so the budget is demote-only.
- **Configurable-first:** the new threshold has default + resolver (`> 0` guard, string
  fallback) + SettingsSchema field, and the schema check's `expectedKeys` now contains the
  key. Confirm the default value used in the schema (`String(defaultMaxLiveZones)`) matches
  the resolver default — a mismatch is a silent config bug.
- **Scope/orphans:** diff touches only the two new Core files, `SettingsSchema.swift` (one
  appended field), and `CoreChecks/main.swift` (one new block + one `expectedKeys` line).
  No App-target file, no `run-matrix.sh` line, no `ContinuumApp.swift` dispatch. No
  co-author footer.

## Out of scope / gotchas
- **Applying the plan is T06 (install/teardown on switch) and T10 (debounced
  viewport-driven reconcile).** T03 returns the map and stops. Do not call
  `ZoneRuntimeController.setTier` from here; do not touch any controller.
- **Tile-level WKWebView LRU = T07 (`BrowserRuntimeBudget`, S5).** T03's budget is a
  *zone-count* cap, deliberately separate. Do not unify them here (docs/23 D3 keeps the
  WebView budget tile-level in v1; a cross-zone PTY budget is a follow-up). If a reviewer
  asks "why two budgets," the answer is: zones gate which controllers are hot; the browser
  budget gates which WKWebViews within live zones stay resident — orthogonal layers, T07
  composes them.
- **No `--zone-hydration-plan-check` CLI flag is registered (NEEDS-HUMAN sanity-check, low
  risk).** The charter/docs-23 name the guard `--zone-hydration-plan-check`, but Core
  checks run as a single binary with no per-flag dispatch inside `main.swift` (verified:
  `run-matrix.sh:62` runs `swift run ContinuumRevivedCoreChecks` whole; the only `--…-check`
  flags are App-target real-path checks dispatched in `ContinuumApp.swift`). Keeping this
  as a Core table is the right call for a *pure* planner (01 §2: pure-model ⇒ Core table)
  and matches the existing "Hydration tier visibility math" table. The named flag therefore
  resolves to a tagged `do`-block + `zone hydration plan:` message prefix, not a CLI arg.
  **If the orchestrator decides the guard MUST be a discrete invokable flag**, the planner
  would have to move/duplicate into the App target purely to gain a dispatch seam — which
  would violate "keep Core pure" and add no real-path coverage. Flagging for a human design
  call; the spec is written for the Core-table interpretation.
- **`HydrationTier` has no `.warm`.** The brief mentions "Live/Warm/Snapshot/Cold or the
  existing tier enum" — the REAL enum is `live`/`snapshot`/`cold` only
  (`WorkspaceDocument.swift:118`). Use those three; do NOT invent a `.warm` case (that
  would be a model change owned by T01, not T03). docs/23 D4's "demote to Snapshot" is the
  only demotion target, consistent with this.
- **Coordinate trap:** `visibleSize` is screen px; the visible-rect width/height in WORLD
  units is `Double(visibleSize.width)/viewport.zoom` (Y-down, top-left origin) — exactly as
  `CanvasEngine.hydrationTier` already computes it. The proximity center derivation in the
  budget MUST use the same `/ zoom` conversion or the cut diverges from the base verdict at
  non-1 zoom. The check uses `zoom: 1` so the derivation is trivial, but the implementation
  must not hardcode zoom 1.
- **Determinism over `Dictionary`:** never iterate `tiers` for the keep/demote decision —
  iterate the input `zones` array (ordered) so the result is reproducible; `Dictionary`
  iteration order is unspecified and would make assertion 7 flaky.
