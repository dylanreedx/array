# Morning Review — workspaces/zones sprint

**Open this first.** Triaged by ATTENTION, not build order. Tick each `[ ]` as you review.
Ask me for the **guided walkthrough** and I'll drive it highest-risk first.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing merged to `main` — your call.**
Spine: `git log --oneline main..overnight/workspaces-zones` (each task = one `(Tnn)` commit).
Rebuild for visual gates: `./scripts/make-app-bundle.sh --configuration release --output ~/Applications/ContinuumRevived.app && open ~/Applications/ContinuumRevived.app`

## Status
- Committed: **7** · blocked: **0** · staged-for-morning: **0** · of 17 build tasks
- Fast matrix green · `swift build` clean
- Wave 1 (T01–T04) + Wave 2 (T05, T11, T15) done; next: **T06** (keystone), then T07–T10.

## 🔴 Decide / eyeball — tests could not prove these
**Cross-task integration (settle before / during T06 — all recorded in T06's STATE row):**
- [ ] **T11×T05 · ZoneLayer chrome not adaptive** — T11 hugged only the *legacy* zone chrome; T05's `ZoneLayer` chrome still uses the stored frame. Dormant now; **T06 makes it live** and must wire `zoneBounds` in + add a guard check. · `runs/T11/review.md`
- [ ] **T03 · budget not wired** — `plan(maxLiveZones:)` isn't fed the resolver; **T06 must wire it**. · `runs/T03/`
- [ ] **T02/T05 · storage shape B** — group-zone tiles in `WorkspaceDocument.groupZoneTiles`, additive `ZoneLayer`s; **T06 ripples 71 `canvasState.tiles` read-sites** — confirm B. · `runs/T02/`, `runs/T05/`

**Smaller design ratifications:**
- [ ] **T15 · name fallback** — `?? ""` for an unresolved project-zone name vs the live canvas's `?? "Project"`. Unify or keep before **T16** consumes the tree (one line). · `runs/T15/`
- [ ] **T01** navKey→T18 · **T04** closeOnZero drop-box-vs-warm-pool + is the knob warranted · **T05** per-zone focus stays out · **T03** "Max Live Zones" free-text, no UI validation.

**Visual gates — rebuild & eyeball:**
- [ ] **T05** — add/remove flicker; z-paint on upsert; cursor rects for multiple headers; first-responder on layer removal; empty-state overlay may persist on layer-only canvas. · `runs/T05/`
- [ ] **T11** — header title fit in the band above the tiles. · `runs/T11/`

## 🟡 Pass with risks — committed, review the named risk
- [ ] **T15 — sidebar view-model** · weak `build==build` determinism net (acknowledged); tiebreak RED leaned on `sorted()` for the broken variant; untracked-file baseline. All minor. · `runs/T15/`
- [ ] **T11 — adaptive zone bounds** · QA reader inverse only tested at zoom=1; test heights re-derived; non-active zones draw at empty min-size. · `runs/T11/`
- [ ] **T05 — mutable ZoneLayer canvas** · focus-border reads flat dict not `layer.tileViews`; undocumented `upsertZoneLayer` z-order policy. · `runs/T05/`
- [ ] **T04 — ZoneRuntimeRegistry** · misleading failure-label on wrong-state; per-run artifacts accumulate. · `runs/T04/`

## 🟢 Verified routine — clean PASS
- [ ] **T01** zone model · CoreChecks T01 table · `runs/T01/`
- [ ] **T02** group-zone tile storage · CoreChecks T02 (real `WorkspaceStore` save→load) · `runs/T02/`
- [ ] **T03** hydration planner · `--zone-hydration-plan-check` (bypass disproved 2 ways) · `runs/T03/`

## ⛔ Blocked / needs-human
- _(none yet)_

---
Each entry: `[ ] Tnn — what · guards: <check> · runs/Tnn/{build,review}.md`. Evidence in `runs/<task>/` is the source of truth.
