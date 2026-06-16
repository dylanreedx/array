# Morning Review — workspaces/zones sprint

**Open this first.** Single entry point for reviewing the overnight run. Triaged by ATTENTION,
not build order. Tick each `[ ]` as you review. Ask me for the **guided walkthrough** and I'll
drive it highest-risk first, carrying the context.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing merged to `main` — your call.**
Commit-by-commit spine: `git log --oneline main..overnight/workspaces-zones` (each task = one commit, tagged `(Tnn)`).
Rebuild for visual gates: `./scripts/make-app-bundle.sh --configuration release --output ~/Applications/ContinuumRevived.app && open ~/Applications/ContinuumRevived.app`

## Status
- Committed: **5** · blocked: **0** · staged-for-morning: **0** · of 17 build tasks
- Fast matrix on branch HEAD: **green** · `swift build` clean
- Wave 1 (T01–T04) done; Wave 2 in progress (T05 done).

## 🔴 Decide / eyeball — tests could not prove these
**Design confirmations** (settle before later tasks ripple them):
- [ ] **T02/T05 · storage shape B** — group-zone tiles live in `WorkspaceDocument.groupZoneTiles` and the canvas keeps `ZoneLayer`s *additively* over single-zone storage. **T06 will ripple 71 `canvasState.tiles` read-sites** — confirm B before then, or escalate to a uniform per-layer store. · `runs/T02/review.md`, `runs/T05/review.md`
- [ ] **T01 · navKey config split** — ships as document data only; Settings + conflict-guard owned by **T18**. Confirm. · `runs/T01/`
- [ ] **T04 · closeOnZero semantics** — registry drops the controller box at refcount 0 (rebuild on re-acquire), not a warm pool. Confirm option (a), and whether the knob is warranted. · `runs/T04/`
- [ ] **T05 · per-zone focus surface** — none today; only tile adapters unregister, `.canvas` stays. Confirm zone-level focus stays out of T05 (would be new `FocusSurfaceID` work for T06/T18). · `runs/T05/`
- [ ] **T03 · "Max Live Zones"** free-text Setting, no numeric UI validation. Glance with the Settings UI. · `runs/T03/`

**Visual gates — rebuild the bundle and eyeball** (headless checks prove correctness, not pixels):
- [ ] **T05 · mutable canvas** — (1) flicker on live zone add/remove; (2) z-paint when a layer upserts on top; (3) cursor rects for multiple zone-chrome headers; (4) no lost first-responder when a focused tile's layer is removed. Also the empty-state overlay may wrongly persist on a layer-only canvas (R2). · `runs/T05/review.md`

## 🟡 Pass with risks — committed, review the named risk
- [ ] **T05 — mutable ZoneLayer canvas** (PASS WITH RISKS) · forward risks for T06/T09: focus-border tracks only the flat `tileViews` dict not `layer.tileViews` (R1); `upsertZoneLayer` z-order policy is undocumented (R4); manifest literal cosmetic (R3). · `runs/T05/`
- [ ] **T04 — ZoneRuntimeRegistry** (PASS WITH RISKS) · misleading failure-label on wrong-state assertions (still exits non-zero); per-run `qa-runs/<ts>/` artifacts accumulate. · `runs/T04/`
- [ ] **T03 → watch at T06** — `plan()` is dead code until T06/T10 and the budget resolver isn't passed to `plan(maxLiveZones:)` yet. **The T06 reviewer must confirm the wiring** or the threshold is decorative. · `runs/T03/`

## 🟢 Verified routine — clean PASS, skim or trust
- [ ] **T01 — zone model** · optional `projectId` + `name`/`navKey`, custom `Codable`, `schemaVersion` 1→2 · CoreChecks T01 table · `runs/T01/`
- [ ] **T02 — group-zone tile storage** · `WorkspaceDocument.groupZoneTiles`, isolated from project canvases · CoreChecks T02 (8 assertions, real `WorkspaceStore` save→load) · `runs/T02/`
- [ ] **T03 — hydration planner** · `ZoneHydrationOrchestrator.plan()` + budget config · `--zone-hydration-plan-check` (13 assertions; bypass disproved 2 ways) · `runs/T03/`

## ⛔ Blocked / needs-human
- _(none yet)_

---
Each entry: `[ ] Tnn — what · guards: <check> · runs/Tnn/{build,review}.md`. Evidence in `runs/<task>/` is the source of truth.
