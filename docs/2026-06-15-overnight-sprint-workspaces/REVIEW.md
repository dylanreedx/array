# Morning Review — workspaces/zones sprint

**Open this first.** Triaged by ATTENTION, not build order. Tick each `[ ]` as you review.
Ask me for the **guided walkthrough** and I'll drive it highest-risk first.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing merged to `main` — your call.**
Spine: `git log --oneline main..overnight/workspaces-zones` (each task = one `(Tnn)` commit).
Rebuild for visual gates: `./scripts/make-app-bundle.sh --configuration release --output ~/Applications/ContinuumRevived.app && open ~/Applications/ContinuumRevived.app`

## Status
- Committed: **8** · blocked: **0** · staged-for-morning: **0** · of 17 build tasks
- Fast matrix green · `swift build` clean
- Wave 1 (T01–T04) + Wave 2 (T05, T11, T15) + **T06 keystone** done. Next: T07–T10 (now unblocked).

## 🔴 Decide / eyeball — tests could not prove these
**T06 keystone — genuine behavioral risks (heaviest delegate touch):**
- [ ] **windowWillClose quit-flush ordering** — controller flush/persist/lock-release now runs AFTER browser+terminal force-terminate (was before; the reorder was needed — closeAll-first crashed a check). Risks a stale final-nav persist on quit; mostly covered by live snapshots + 0.2s debounce. **No check covers `windowWillClose`** — accept the documented risk or ask me to add a quit-path flush check. · `runs/T06/review.md`
- [ ] **shape-B install discrepancy → T09 must reconcile** — `install()` layers ALL zones (incl. active) as descriptor tiles with `canvasState.tiles` empty, not the "active zone in `canvasState.tiles`" the build claimed. Moot now (boot uses `boot:` init, not `install`), but **T09's real switching uses `install`** — flagged for the T09 builder/reviewer. · `runs/T06/review.md`
- [ ] **`attachUI` optional-chained** — `workspaceRuntime?.activeController?.attachUI(...)`; silent-nil if ever nil at boot (guaranteed non-nil today). · `runs/T06/review.md`
- ✓ **Resolved in T06:** budget→`plan()` wired (probe green); ZoneLayer chrome now adaptive via `CanvasEngine.zoneBounds` (probe green). The two T11/T03 carry-forwards are handled.

**Smaller design ratifications:**
- [ ] **T15** name fallback `?? ""` vs canvas `?? "Project"` (settle before T16) · **T01** navKey→T18 · **T04** closeOnZero drop-box-vs-warm-pool + is the knob warranted · **T05** per-zone focus stays out · **T03** "Max Live Zones" free-text, no UI validation.

**Visual gates — rebuild & eyeball:**
- [ ] **T06** smoke: open app, click a tile, confirm the focus border (proxy rename touches the live focus/attachUI path). · `runs/T06/`
- [ ] **T05** add/remove flicker; z-paint on upsert; cursor rects; first-responder on layer removal; empty-state overlay on layer-only canvas. · `runs/T05/`
- [ ] **T11** header title fit in the band above the tiles. · `runs/T11/`

## 🟡 Pass with risks — committed, review the named risk
- [ ] **T06 — WorkspaceRuntime shell** (PASS WITH RISKS; +2 fixer fixes: orphan removed, assertion 5 strengthened to assert placement geometry). See 🔴 for its risks. · `runs/T06/`
- [ ] **T15 — sidebar view-model** · weak `build==build` net; tiebreak RED leaned on `sorted()`; untracked baseline. · `runs/T15/`
- [ ] **T11 — adaptive zone bounds** · QA reader inverse only at zoom=1; test heights re-derived; non-active zones at empty min-size. · `runs/T11/`
- [ ] **T05 — mutable ZoneLayer canvas** · focus-border reads flat dict; `upsertZoneLayer` z-order policy undocumented. · `runs/T05/`
- [ ] **T04 — ZoneRuntimeRegistry** · misleading failure-label; per-run artifacts accumulate. · `runs/T04/`

## 🟢 Verified routine — clean PASS
- [ ] **T01** zone model · CoreChecks T01 table · `runs/T01/`
- [ ] **T02** group-zone tile storage · CoreChecks T02 (real `WorkspaceStore` save→load) · `runs/T02/`
- [ ] **T03** hydration planner · `--zone-hydration-plan-check` (bypass disproved 2 ways) · `runs/T03/`

## ⛔ Blocked / needs-human
- _(none yet)_

---
Each entry: `[ ] Tnn — what · guards: <check> · runs/Tnn/{build,review}.md`. Evidence in `runs/<task>/` is the source of truth.
