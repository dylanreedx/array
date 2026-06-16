# Morning Review — workspaces/zones sprint

**Open this first.** Triaged by ATTENTION, not build order. Tick each `[ ]` as you review.
Ask me for the **guided walkthrough** and I'll drive it highest-risk first.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing merged to `main` — your call.**
Spine: `git log --oneline main..overnight/workspaces-zones` (each task = one `(Tnn)` commit).
Rebuild for visual gates: `./scripts/make-app-bundle.sh --configuration release --output ~/Applications/ContinuumRevived.app && open ~/Applications/ContinuumRevived.app`

## ⛔ HEADLINE — read this first
**The keystone (T06–T10) is BUILT + headlessly VERIFIED but INERT in the live app.** The boot
`WorkspaceRuntime` is wired with a **throwing placeholder registry factory** (`"T08 wires this"`,
immutable `let`, no swap-in seam). So in the running app, `addProjectZone` and `switchWorkspace`
throw on the first project acquire → no-op. T09 removed the relaunch fallback, so **⌘K switch is a
silent no-op regression** live. Every T07–T10 check passes because each **injects a real registry**.
→ **Captured as `T20` (`T20-wire-boot-registry-factory.md`)** — a required follow-up that needs a
small **design decision from you** (per-project controller construction at boot). Until T20, the
live-switch visual gates can't be exercised. This is the #1 thing to decide in the morning.

## Status
- Committed: **11** · blocked: **0** · staged-for-morning: **0** · needs-human follow-up: **1 (T20)** · of 17 build tasks
- Fast matrix green · `swift build` clean · `--workspace-switch-check` green
- W1 + W2 + T06 + T07 + T08 + T09 done. Next: T10 → T12 → T13/T14 → T17/T18 → morning T16/T19.

## 🔴 Decide / eyeball — tests could not prove these
**Decisions:**
- [ ] **T20 / boot registry (HIGH)** — wire the real per-project controller factory at boot (3 design Qs in `T20-…md`), or accept the switch/add-zone inert until a follow-up. **The keystone isn't live without it.**
- [ ] **T09 · shape-B model** — accept descriptor-only active-zone tiles (`canvasState.tiles` not populated; ~71 read-sites blind to switched-in tiles), or reconcile to live `canvasState.tiles`? inv2b proves hit-testable; gap documented. · `runs/T09/`
- [ ] **T07 · focus-mode eviction protection dropped (regression)** — wire `focusModeSession` into `WorkspaceRuntime` or accept. · `runs/T07/`
- [ ] **T08 · group zone writes `$HOME/.continuum-revived/project.json`** by default (dormant until creation wired) — intended+document or sandbox. · `runs/T08/`
- [ ] **T06 · windowWillClose quit-flush ordering** (after force-terminate; no check) · **T06 `attachUI` optional-chained** · **T09 MED:** ref-count leak on budget-demoted target project (T10 should address).
- [ ] Ratifications: **T15** name fallback · **T01** navKey→T18 · **T04** closeOnZero · **T05** per-zone focus · **T03** "Max Live Zones" no UI validation.

**Visual gates — rebuild & eyeball** (T06/T09 live-switch ones are **blocked-pending-T20**):
- [ ] **T09/T06** live ⌘K switch: flicker, z-paint after `setZones`, cursor rects, old-tile focus-border clearing _(after T20)_. · **T08** group-zone layer chrome. · **T05** flicker/z-paint/cursor/first-responder/empty-state. · **T11** header title fit.

## 🟡 Pass with risks — committed, review the named risk
- [ ] **T09 — switchWorkspace in-process** (1 iter; inv7→real reachability, inv2b hit-test, viewport-persist RED-confirmed). Risks in 🔴 + MED ref-count leak + LOW inv5/inv7-spy/naming. · `runs/T09/`
- [ ] **T08 — addZone** (+fixer: lock + tile-routing checks, RED-confirmed) · **T07 — browser budget union** (R2 cross-zone needs live spawner) · **T06 — WorkspaceRuntime shell** (+fixer) · **T15 / T11 / T05 / T04** minor risks — see each `runs/Tnn/`.

## 🟢 Verified routine — clean PASS
- [ ] **T01** zone model · **T02** group-zone tile storage · **T03** hydration planner (`--zone-hydration-plan-check`).

## ⛔ Blocked / needs-human
- **T20** — boot registry factory (design decision; see HEADLINE). The only thing standing between "built+verified" and "live."

---
Each entry: `[ ] Tnn — what · guards: <check> · runs/Tnn/{build,review}.md`. Evidence in `runs/<task>/` is the source of truth.
