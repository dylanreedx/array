# Morning Review — workspaces/zones sprint

**Open this first.** Single entry point for reviewing the overnight run. Changes are triaged
by ATTENTION, not by build order. Tick each `[ ]` as you review. Ask me for the **guided
walkthrough** and I'll drive it highest-risk first, carrying the context so you don't have to
reconstruct it.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing is merged to `main` — that's your call.**
Review commit-by-commit: `git log --oneline main..overnight/workspaces-zones` — each task is one commit, tagged `(Tnn)` in its subject.

## Status (updated as each task lands)
- Committed: **4** · blocked: **0** · staged-for-morning: **0** · of 17 build tasks (T01–T19; T09 last session's exemplar pending build)
- Fast matrix on branch HEAD: **green** (after T04) · `swift build` clean
- Wave 1 (T01–T04) complete. Spec foundation: 17 specs committed (5 adversarially reviewed, 12 first-draft + reviewer pass at build time).

## 🔴 Decide / eyeball — read these (tests could not prove them)
_Design calls deferred, visual/feel gates, anything unverified. The un-missable list._
- [ ] **T01 · navKey configurable-first split** — `navKey` ships as per-zone *document data* only; Settings entry + conflict-guard owned by **T18**. Reviewer judged intentional — **confirm.** · `runs/T01/review.md`
- [ ] **T02 · group-zone storage shape** — group-zone tiles as `WorkspaceDocument.groupZoneTiles` (record array) vs a list on `ZonePlacement`. Spec-flagged choice; build follows it. **Confirm the seam** before T05/T08/T11/T15 build on it. · `runs/T02/review.md`
- [ ] **T03 · "Max Live Zones" has no UI validation** — hydration budget Setting is free-text; resolver guards `>0` but the pane doesn't constrain input. Glance when Settings UI is reviewed. · `runs/T03/review.md`
- [ ] **T04 · closeOnZero warm-keep semantics** — registry default drops the controller box at ref-count 0 (re-acquire rebuilds), NOT a warm pool. Confirm option (a) is intended (or schedule a warm-pool follow-up), and whether the `closeOnZero` knob is warranted at all (spec flagged it). · `runs/T04/review.md`

## 🟡 Pass with risks — review carefully
_Committed + verified, but the reviewer named a specific risk._
- [ ] **T03 · planner not yet wired (downstream)** — `plan()` is correct but dead code until **T06/T10**, and the budget resolver isn't passed into `plan(maxLiveZones:)` yet. **The T06 reviewer must confirm the wiring** or the threshold is decorative. · `runs/T03/review.md`
- [ ] **T04 — ZoneRuntimeRegistry** committed PASS WITH RISKS. Risks: (1) misleading failure-label when an assertion hits a wrong controller state (still exits non-zero); (2) `closeOnZero` is drop-box not warm-pool (see 🔴); (3) per-run `qa-runs/<ts>/` artifacts accumulate. · `runs/T04/review.md`

## 🟢 Verified routine — skim or trust
_Committed, test-guarded, reviewer clean._
- [ ] **T01 — zone model** · `ZonePlacement.projectId` → optional, `name`+`navKey`, custom `Codable` backward-compat, `schemaVersion` 1→2 · CoreChecks T01 table · `runs/T01/`
- [ ] **T02 — group-zone tile storage** · `GroupZoneTiles` + `WorkspaceDocument.groupZoneTiles`, isolated from project canvases · CoreChecks T02 (8 assertions, real `WorkspaceStore` save→load) · `runs/T02/`
- [ ] **T03 — hydration planner** · `ZoneHydrationOrchestrator.plan()` + `ZoneHydrationBudgetConfig` · `--zone-hydration-plan-check` (13 assertions; bypass disproved 2 ways) · `runs/T03/`
- [ ] **T04 — runtime registry** · `ZoneRuntimeRegistry` (@MainActor, per-project ref-counted, injected factory) + `ZoneRuntimeBudgetConfig` · `--zone-registry-refcount-check` (9 assertions; bypass disproved via detached worktree stubs) · `runs/T04/` _(see 🟡 for its risks)_

## ⛔ Blocked / needs-human
_Couldn't reach a clean PASS in the retry budget; reason recorded._
- _(none yet)_

---
Each entry reads: `[ ] Tnn — what it does · guards: <check> · runs/Tnn/{build,review}.md`
Per-task evidence lives in `runs/<task>/` (see `runs/README.md`) — the source of truth.
