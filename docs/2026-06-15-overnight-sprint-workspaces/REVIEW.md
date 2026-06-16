# Morning Review — workspaces/zones sprint

**Open this first.** Triaged by ATTENTION, not build order. Tick each `[ ]` as you review.
Ask me for the **guided walkthrough** and I'll drive it highest-risk first.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing merged to `main` — your call.**
Spine: `git log --oneline main..overnight/workspaces-zones` (each task = one `(Tnn)` commit).
Rebuild for visual gates: `./scripts/make-app-bundle.sh --configuration release --output ~/Applications/ContinuumRevived.app && open ~/Applications/ContinuumRevived.app`

## Status
- Committed: **10** · blocked: **0** · staged-for-morning: **0** · of 17 build tasks
- Fast matrix green · `swift build` clean
- W1 (T01–T04) + W2 (T05,T11,T15) + T06 keystone + T07 + T08 done. Next: T09 → T10.

## 🔴 Decide / eyeball — tests could not prove these
**Behavioral regressions / design decisions:**
- [ ] **T07 · focus-mode eviction protection dropped (regression)** — `currentProtectedBrowserTileIds()` reads only `lastActiveTileId`, not `focusModeSession.protectedTileIds`. A focus-mode companion browser that's globally oldest can be evicted while viewed. **Decide:** wire `focusModeSession` into `WorkspaceRuntime`, or accept. · `runs/T07/`
- [ ] **T08 · group zone writes to `$HOME` by default** — a group/ambient zone with no `AmbientZoneHome` override roots its controller at `$HOME` → materializes `$HOME/.continuum-revived/project.json` (a project named after you). **Dormant** until group-zone *creation* is wired (T17/sidebar/T19). **Decide:** intended+document, or sandbox the ambient root. · `runs/T08/`
- [ ] **T06 · windowWillClose quit-flush ordering** now runs AFTER force-terminate (no check covers `windowWillClose`). Accept or add a quit-path flush check. · `runs/T06/`
- [ ] **T06 · shape-B install discrepancy → T09 reconciles** — `install()` layers ALL zones as descriptor tiles, `canvasState.tiles` empty (injected into T09). · **T06 `attachUI` optional-chained** silent-nil surface.
- ✓ **Resolved in T06:** budget→`plan()` wired; ZoneLayer chrome adaptive (probe-guarded).

**Smaller ratifications:** T15 name fallback `?? ""` vs `?? "Project"` (before T16) · T01 navKey→T18 · T04 closeOnZero design · T05 per-zone focus stays out · T03 "Max Live Zones" no UI validation.

**Visual gates — rebuild & eyeball:**
- [ ] **T08** group zone's installed ZoneLayer on the live canvas (chrome, empty bounds, z-order). · **T06** focus-border smoke (click a tile). · **T05** flicker/z-paint/cursor-rects/first-responder/empty-state overlay. · **T11** header title fit.

## 🟡 Pass with risks — committed, review the named risk
- [ ] **T08 — addZone (project + ambient group)** · +fixer strengthened the check (R2 asserts no project lock for ambient; R3 real group-tile workspace-store round-trip + ProjectStore isolation, both RED-confirmed). Original RED not separately confirmed (retro-established). R4 forwarder change low-risk. · `runs/T08/`
- [ ] **T07 — browser budget over live union** · R2: cross-zone eviction fully effective once T08… (T08 now done; verify a non-active zone's browsers are actually evictable in the live app — they only are if the controller has a `tileSpawner`). · `runs/T07/`
- [ ] **T06 — WorkspaceRuntime shell** (+fixer). Risks in 🔴. · `runs/T06/`
- [ ] **T15** sidebar view-model · **T11** adaptive bounds · **T05** mutable ZoneLayer canvas · **T04** ZoneRuntimeRegistry — minor risks, see each `runs/Tnn/`.

## 🟢 Verified routine — clean PASS
- [ ] **T01** zone model · **T02** group-zone tile storage (real `WorkspaceStore` save→load) · **T03** hydration planner (`--zone-hydration-plan-check`, bypass disproved 2 ways).

## ⛔ Blocked / needs-human
- _(none yet)_

---
Each entry: `[ ] Tnn — what · guards: <check> · runs/Tnn/{build,review}.md`. Evidence in `runs/<task>/` is the source of truth.
