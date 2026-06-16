# Morning Review — workspaces/zones sprint

**Open this first.** Triaged by ATTENTION, not build order. Tick each `[ ]` as you review.
Ask me for the **guided walkthrough** and I'll drive it highest-risk first.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing merged to `main` — your call.**
Spine: `git log --oneline main..overnight/workspaces-zones` (each task = one `(Tnn)` commit).
Rebuild for visual gates: `./scripts/make-app-bundle.sh --configuration release --output ~/Applications/ContinuumRevived.app && open ~/Applications/ContinuumRevived.app`

## Status
- Committed: **9** · blocked: **0** · staged-for-morning: **0** · of 17 build tasks
- Fast matrix green · `swift build` clean
- W1 (T01–T04) + W2 (T05,T11,T15) + T06 keystone + T07 done. Next: T08 → T09 → T10.

## 🔴 Decide / eyeball — tests could not prove these
**Behavioral regressions / decisions:**
- [ ] **T07 · focus-mode eviction protection dropped (regression)** — `WorkspaceRuntime.currentProtectedBrowserTileIds()` reads only `lastActiveTileId`, not `focusModeSession.protectedTileIds` (lives on AppDelegate). A focus-mode companion browser that's globally oldest can be evicted to a snapshot while you view it. Pre-T07 protected these. **Decide:** wire `focusModeSession` into `WorkspaceRuntime` (closure), or accept. · `runs/T07/review.md`
- [ ] **T06 · windowWillClose quit-flush ordering** — controller flush/persist/lock-release now runs AFTER browser+terminal force-terminate (reorder was required). Risks stale final-nav persist on quit; no check covers `windowWillClose`. Accept or add a quit-path flush check. · `runs/T06/`
- [ ] **T06 · shape-B install discrepancy → T09 reconciles** — `install()` layers ALL zones as descriptor tiles with `canvasState.tiles` empty; T09's real switch must decide where the active zone's live tiles live (flagged into T09). · `runs/T06/`
- [ ] **T06 · `attachUI` optional-chained** silent-nil surface (non-nil at boot today). · `runs/T06/`
- ✓ **Resolved in T06:** budget→`plan()` wired; ZoneLayer chrome adaptive (both probe-guarded).

**Smaller design ratifications:**
- [ ] **T15** name fallback `?? ""` vs canvas `?? "Project"` (before T16) · **T01** navKey→T18 · **T04** closeOnZero drop-box-vs-warm-pool + is the knob warranted · **T05** per-zone focus stays out · **T03** "Max Live Zones" free-text, no UI validation.

**Visual gates — rebuild & eyeball:**
- [ ] **T06** smoke: open app, click a tile, confirm focus border. · **T05** add/remove flicker, z-paint, cursor rects, first-responder, empty-state overlay. · **T11** header title fit in band above tiles.

## 🟡 Pass with risks — committed, review the named risk
- [ ] **T07 — browser budget over live union** · R2: cross-zone eviction only fully effective once T08 attaches UI (a `tileSpawner`) to non-active controllers; mechanism proven, non-active zones skipped today. · `runs/T07/`
- [ ] **T06 — WorkspaceRuntime shell** (+fixer: orphan removed, assertion 5 strengthened to assert placement geometry). Risks in 🔴. · `runs/T06/`
- [ ] **T15 — sidebar view-model** · weak determinism net; tiebreak RED leaned on `sorted()`; untracked baseline. · `runs/T15/`
- [ ] **T11 — adaptive zone bounds** · QA reader inverse only at zoom=1; test heights re-derived; non-active zones at empty min-size. · `runs/T11/`
- [ ] **T05 — mutable ZoneLayer canvas** · focus-border reads flat dict; `upsertZoneLayer` z-order policy undocumented. · `runs/T05/`
- [ ] **T04 — ZoneRuntimeRegistry** · misleading failure-label; per-run artifacts accumulate. · `runs/T04/`

## 🟢 Verified routine — clean PASS
- [ ] **T01** zone model · CoreChecks T01 table · **T02** group-zone tile storage · CoreChecks T02 (real `WorkspaceStore` save→load) · **T03** hydration planner · `--zone-hydration-plan-check` (bypass disproved 2 ways).

## ⛔ Blocked / needs-human
- _(none yet)_

---
Each entry: `[ ] Tnn — what · guards: <check> · runs/Tnn/{build,review}.md`. Evidence in `runs/<task>/` is the source of truth.
