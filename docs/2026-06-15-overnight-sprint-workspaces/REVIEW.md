# Morning Review — workspaces/zones sprint

**Open this first.** Triaged by ATTENTION, not build order. Tick each `[ ]` as you review.
Ask me for the **guided walkthrough** and I'll drive it highest-risk first.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing merged to `main` — your call.**
Spine: `git log --oneline main..overnight/workspaces-zones` (each task = one `(Tnn)` commit).
Rebuild for visual gates: `./scripts/make-app-bundle.sh --configuration release --output ~/Applications/ContinuumRevived.app && open ~/Applications/ContinuumRevived.app`

## ⛔ HEADLINE — read first
**The keystone (T06–T10) is BUILT + headlessly VERIFIED but INERT in the live app.** The boot
`WorkspaceRuntime` is wired with a **throwing placeholder registry factory** (immutable `let`, no
swap-in seam), so `addProjectZone` / `switchWorkspace` / tier-reconcile all throw on the first project
acquire in the running app. T09 removed the relaunch fallback → **⌘K switch is a silent no-op live.**
Every T07–T10 check passes by **injecting a real registry**. → Captured as **`T20`** (a required
follow-up needing a small **design decision from you** — per-project controller construction at boot).
Until T20, the keystone's live behavior + its visual gates can't be exercised. **#1 morning decision.**

## Status
- Committed: **12** · blocked: **0** · staged-for-morning: **0** · needs-human: **1 (T20)** · of 17 build tasks
- Fast matrix green · `swift build` clean
- **Keystone chain T06–T10 complete.** W1 + W2 + T06–T10 done. Next: T12 → T13/T14 → T17/T18 → morning T16/T19.

## 🔴 Decide / eyeball — tests could not prove these
**Decisions:**
- [ ] **T20 / boot registry (HIGH)** — wire the real per-project controller factory at boot, or accept switch/add-zone inert. **Keystone isn't live without it.** `T20-…md`
- [ ] **T09 · shape-B model** — accept descriptor-only active-zone tiles, or reconcile to live `canvasState.tiles`? · `runs/T09/`
- [ ] **T07 · focus-mode eviction protection dropped (regression)** — wire `focusModeSession` in or accept. · `runs/T07/`
- [ ] **T08 · group zone writes `$HOME/.continuum-revived/project.json`** by default (dormant) — intended+document or sandbox. · `runs/T08/`
- [ ] **T06 · windowWillClose ordering** (after force-terminate) · **T06 `attachUI` optional-chain** · **T09 MED ref-count leak** (T10 fixed the related demote-leak; verify) · ratifications: **T15** name fallback · **T01** navKey→T18 · **T04** closeOnZero · **T05** per-zone focus · **T03** "Max Live Zones" validation.

**Visual gates — rebuild & eyeball** (keystone live-switch ones **blocked-pending-T20**):
- [ ] **T10/T09/T06** live ⌘K switch + pan/zoom demote/promote: flicker, z-paint, cursor rects, focus-border clearing, debounce Timer on real pan _(after T20)_. · **T08** group-zone layer chrome. · **T05** flicker/z-paint/cursor/first-responder/empty-state. · **T11** header title fit.

## 🟡 Pass with risks — committed, review the named risk
- [ ] **T10 — viewport tier transitions** (+fixer: debounce-coalescing + planner-pin checks RED-confirmed; T09 ref-count leak fixed). Live gated on T20; real-pan Timer unverified headless. · `runs/T10/`
- [ ] **T09 — switchWorkspace** (1 iter) · **T08 — addZone** (+fixer) · **T07 — browser budget union** · **T06 — WorkspaceRuntime shell** (+fixer) · **T15 / T11 / T05 / T04** — see each `runs/Tnn/`. Keystone risks in 🔴.

## 🟢 Verified routine — clean PASS
- [ ] **T01** zone model · **T02** group-zone tile storage · **T03** hydration planner (`--zone-hydration-plan-check`).

## ⛔ Blocked / needs-human
- **T20** — boot registry factory (design decision; see HEADLINE). The only thing between "built+verified" and "live."

---
Each entry: `[ ] Tnn — what · guards: <check> · runs/Tnn/{build,review}.md`. Evidence in `runs/<task>/` is the source of truth.
