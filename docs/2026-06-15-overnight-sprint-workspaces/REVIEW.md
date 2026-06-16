# Morning Review — workspaces/zones sprint

**Open this first.** Triaged by ATTENTION, not build order. Tick each `[ ]` as you review.
Ask me for the **guided walkthrough** and I'll drive it highest-risk first.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing merged to `main` — your call.**
Spine: `git log --oneline main..overnight/workspaces-zones` (each task = one `(Tnn)` commit).
Rebuild for visual gates: `./scripts/make-app-bundle.sh --configuration release --output ~/Applications/ContinuumRevived.app && open ~/Applications/ContinuumRevived.app`

## ⛔ HEADLINE — read first
**The keystone (T06–T10) is BUILT + headlessly VERIFIED but INERT in the live app.** The boot
`WorkspaceRuntime` has a **throwing placeholder registry factory** (immutable `let`, no swap-in seam),
so add-zone / switch / tier-reconcile throw on the first project acquire; T09 removed the relaunch
fallback → **⌘K switch is a silent no-op live.** Checks pass by **injecting a real registry**.
→ **`T20`** captures the fix; it needs a small **design decision from you** (per-project controller
construction at boot). Until T20, the keystone's live behavior + visual gates can't run. **#1 decision.**

## Status
- Committed: **13** · blocked: **0** · staged-for-morning: **0** · needs-human: **1 (T20)** · of 17 build tasks
- Fast matrix green · `swift build` clean · keystone (T06–T10) + persistence (T12) landed
- Done: T01–T12 + T15. Next: T13/T14 → T17/T18 → morning T16/T19.

## 🔴 Decide / eyeball — tests could not prove these
**Decisions:**
- [ ] **T20 / boot registry (HIGH)** — wire the real per-project factory at boot, or accept switch/add-zone inert. **Keystone isn't live without it.** `T20-…md`
- [ ] **T12 · persistence wiring (NH1/NH2)** — fsync now in the *shared* `AtomicWriter` (all JSON gets durable writes; regressions green — confirm the wider blast radius is intended); and **no live autosave caller is wired yet** (the crash-safe *mechanism* exists + is checked, but nothing fires a debounced autosave on drag/resize — deferred to T05/T11/T19). Confirm both tracked. · `runs/T12/`
- [ ] **T09 · shape-B model** (descriptor-only active tiles vs live `canvasState.tiles`) · **T07 · focus-mode eviction regression** · **T08 · group zone writes `$HOME`** (dormant). · **T06 · windowWillClose ordering / `attachUI` optional-chain**.
- [ ] Ratifications: **T15** name fallback · **T01** navKey→T18 · **T04** closeOnZero · **T05** per-zone focus · **T03** "Max Live Zones" validation.

**Visual gates — rebuild & eyeball** (keystone live-switch ones **blocked-pending-T20**):
- [ ] **T10/T09/T06** live ⌘K switch + pan/zoom demote/promote (after T20). · **T08** group-zone layer chrome. · **T05** flicker/z-paint/cursor/first-responder/empty-state. · **T11** header title fit.

## 🟡 Pass with risks — committed, review the named risk
- [ ] **T12 — bulletproof restore** · R1 fsync durability code-reviewed only (power-loss not headless-simulable; corrupt-primary recovery IS asserted); R2 temp cleaned only on rename-fail not write/fsync-throw (low impact, optional follow-up); R3 runloop spin widened (documented). · `runs/T12/`
- [ ] **T10** tier transitions (+fixer) · **T09** switchWorkspace (1 iter) · **T08** addZone (+fixer) · **T07** browser budget union · **T06** WorkspaceRuntime shell (+fixer) · **T15 / T11 / T05 / T04** — see each `runs/Tnn/`. Keystone risks in 🔴.

## 🟢 Verified routine — clean PASS
- [ ] **T01** zone model · **T02** group-zone tile storage · **T03** hydration planner (`--zone-hydration-plan-check`).

## ⛔ Blocked / needs-human
- **T20** — boot registry factory (design decision; see HEADLINE). The only thing between "built+verified" and "live."

---
Each entry: `[ ] Tnn — what · guards: <check> · runs/Tnn/{build,review}.md`. Evidence in `runs/<task>/` is the source of truth.
