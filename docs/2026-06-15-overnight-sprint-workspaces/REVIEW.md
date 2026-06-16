# Morning Review — workspaces/zones sprint

**Open this first.** Single entry point for reviewing the overnight run. Changes are triaged
by ATTENTION, not by build order. Tick each `[ ]` as you review. Ask me for the **guided
walkthrough** and I'll drive it highest-risk first, carrying the context so you don't have to
reconstruct it.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing is merged to `main` — that's your call.**
Review commit-by-commit: `git log --oneline main..overnight/workspaces-zones` — each task is one commit, tagged `(Tnn)` in its subject.

## Status (updated as each task lands)
- Committed: **3** · blocked: **0** · staged-for-morning: **0** · of 17 build tasks (T01–T19; T09 last session's exemplar pending build)
- Fast matrix on branch HEAD: **green** (after T03)
- Spec foundation: 17 task specs (T02–T19) committed — 5 adversarially reviewed, 12 first-draft (each gets a reviewer pass at build time).

## 🔴 Decide / eyeball — read these (tests could not prove them)
_Design calls deferred, visual/feel gates, anything unverified. The un-missable list._
- [ ] **T01 · navKey configurable-first split** — `navKey` ships in T01 as per-zone *document data* only; its Settings entry + conflict-guard are owned by **T18**. Reviewer judged this intentional — **confirm.** · `runs/T01/review.md`
- [ ] **T02 · group-zone storage shape** — group-zone tiles live as `WorkspaceDocument.groupZoneTiles` (record array) vs a list on `ZonePlacement`. Spec-flagged design choice; build follows it. **Confirm the seam** before T05/T08/T11/T15 build on it. · `runs/T02/review.md`
- [ ] **T03 · "Max Live Zones" has no UI validation** — the hydration budget Setting is a free-text field; resolver guards `>0` but the Settings pane doesn't constrain input. Product/visual call — glance when the Settings UI is reviewed. · `runs/T03/review.md`

## 🟡 Pass with risks — review carefully
_Committed + verified, but the reviewer named a specific risk._
- [ ] **T03 · planner not yet wired (downstream)** — `ZoneHydrationOrchestrator.plan()` is correct but dead code until **T06/T10**, and the budget resolver isn't passed into `plan(maxLiveZones:)` yet. If T06/T10 don't wire it, the configurable threshold is decorative. **The T06 reviewer must confirm the wiring.** · `runs/T03/review.md`

## 🟢 Verified routine — skim or trust
_Committed, test-guarded, reviewer clean._
- [ ] **T01 — zone model** · `ZonePlacement.projectId` → optional, `name`+`navKey` added, custom `Codable` backward-compat, `schemaVersion` 1→2 · guards: CoreChecks T01 table (v2 round-trips, v1→v2 migration, mixed-doc) · `runs/T01/{build,review}.md`
- [ ] **T02 — group-zone tile storage** · `GroupZoneTiles` + `WorkspaceDocument.groupZoneTiles`, `tiles(forZone:)`/`setTiles(_:forZone:)`; isolated from project canvases · guards: CoreChecks T02 table (8 assertions, real `WorkspaceStore` save→load) · `runs/T02/{build,review}.md`
- [ ] **T03 — hydration planner** · `ZoneHydrationOrchestrator.plan()` (proximity-ranked, pin-bypassing live budget) + `ZoneHydrationBudgetConfig` (default 4 + resolver + SettingsSchema) · guards: CoreChecks `--zone-hydration-plan-check` (13 assertions; `plan()` ∘ production `CanvasEngine.hydrationTier`) · `runs/T03/{build,review}.md`
  - _bypass disproved two ways by the reviewer (base-map stub + input-order stub both go RED). zoom≠1 not pinned by a test (code-read only)._

## ⛔ Blocked / needs-human
_Couldn't reach a clean PASS in the retry budget; reason recorded._
- _(none yet)_

---
Each entry reads: `[ ] Tnn — what it does · guards: <check> · runs/Tnn/{build,review}.md`
Per-task evidence lives in `runs/<task>/` (see `runs/README.md`) — the source of truth.
