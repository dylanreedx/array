# Morning Review — workspaces/zones sprint

**Open this first.** Triaged by ATTENTION, not build order. Tick each `[ ]` as you review.
Ask me for the **guided walkthrough** and I'll drive it highest-risk first.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing merged to `main` — your call.**
Spine: `git log --oneline main..overnight/workspaces-zones` (each task = one `(Tnn)` commit).
Rebuild for visual gates: `./scripts/make-app-bundle.sh --configuration release --output ~/Applications/ContinuumRevived.app && open ~/Applications/ContinuumRevived.app`

## Status
- Committed: **6** · blocked: **0** · staged-for-morning: **0** · of 17 build tasks
- Fast matrix green · `swift build` clean
- Wave 1 (T01–T04) done; Wave 2 (T05, T11) done; next T15 then **T06** (keystone).

## 🔴 Decide / eyeball — tests could not prove these
**Cross-task integration (settle before / during T06):**
- [ ] **T11×T05 · ZoneLayer chrome not adaptive** — T11 made the *legacy* zone chrome hug its tiles, but T05's new `ZoneLayer` chrome still uses the **stored** frame. Dormant now (ZoneLayer has 0 prod callers); **T06 makes it live**. T06 must wire `zoneBounds` into the ZoneLayer chrome path + add a guard check (T05's check only asserts tile frames → gap is invisible to CI). Recorded in T06's STATE row. · `runs/T11/review.md`
- [ ] **T02/T05 · storage shape B** — group-zone tiles in `WorkspaceDocument.groupZoneTiles`; canvas keeps `ZoneLayer`s additively. **T06 ripples 71 `canvasState.tiles` read-sites** — confirm B before then. · `runs/T02/`, `runs/T05/`
- [ ] **T03 · budget not wired** — `plan(maxLiveZones:)` isn't fed the resolver yet; **T06 must wire it** or the threshold is decorative (in T06's STATE row). · `runs/T03/`
- [ ] **T01 · navKey config split** → owned by T18. · **T04 · closeOnZero** drop-box vs warm-pool + is the knob warranted. · **T05 · per-zone focus surface** stays out (tile adapters only). · **T03 · "Max Live Zones"** free-text, no UI validation.

**Visual gates — rebuild & eyeball (headless proves correctness, not pixels):**
- [ ] **T05** — add/remove flicker; z-paint on layer upsert; cursor rects for multiple zone headers; no lost first-responder when a focused tile's layer is removed; empty-state overlay may persist on a layer-only canvas. · `runs/T05/`
- [ ] **T11** — header title fit in the band now sitting above the tiles. · `runs/T11/`

## 🟡 Pass with risks — committed, review the named risk
- [ ] **T11 — adaptive zone bounds** · R1 QA reader inverse only tested at zoom=1; R2 test heights re-derived (170 not spec's 120, .note min); R3 non-active zones draw at empty min-size (member source deferred). · `runs/T11/`
- [ ] **T05 — mutable ZoneLayer canvas** · focus-border reads flat dict not `layer.tileViews` (R1); undocumented `upsertZoneLayer` z-order policy (R4). · `runs/T05/`
- [ ] **T04 — ZoneRuntimeRegistry** · misleading failure-label on wrong-state; per-run artifacts accumulate. · `runs/T04/`

## 🟢 Verified routine — clean PASS
- [ ] **T01** zone model · CoreChecks T01 table · `runs/T01/`
- [ ] **T02** group-zone tile storage · CoreChecks T02 (real `WorkspaceStore` save→load) · `runs/T02/`
- [ ] **T03** hydration planner · `--zone-hydration-plan-check` (bypass disproved 2 ways) · `runs/T03/`

## ⛔ Blocked / needs-human
- _(none yet)_

---
Each entry: `[ ] Tnn — what · guards: <check> · runs/Tnn/{build,review}.md`. Evidence in `runs/<task>/` is the source of truth.
