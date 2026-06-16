# Morning Review — workspaces/zones sprint

**Open this first.** Triaged by ATTENTION, not build order. Tick each `[ ]` as you review.
Ask me for the **guided walkthrough** and I'll drive it highest-risk first.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing merged to `main` — your call.**
Spine: `git log --oneline main..overnight/workspaces-zones` (each task = one `(Tnn)` commit).
Rebuild for visual gates: `./scripts/make-app-bundle.sh --configuration release --output ~/Applications/ContinuumRevived.app && open ~/Applications/ContinuumRevived.app`

## ⛔ HEADLINE — read first
**The keystone (T06–T10) is BUILT + headlessly VERIFIED but INERT in the live app** — the boot
`WorkspaceRuntime` has a **throwing placeholder registry factory**, so add-zone / switch / tier-reconcile
throw on the first project acquire; ⌘K switch is a silent no-op live. → **`T20`** (needs your design
decision: per-project controller construction at boot). Until T20, the keystone's live behavior +
visual gates can't run. **#1 morning decision.**

## Status
- Committed: **14** · blocked: **0** · staged-for-morning: **0** · needs-human: **1 (T20)** · of 17 build tasks
- Fast matrix green · `swift build` clean
- Done: T01–T13 + T15. **Remaining: T14 → T17/T18 → morning T16/T19.** Then MORNING-REPORT.

## 🔴 Decide / eyeball — tests could not prove these
**Decisions / regressions / real-world deps:**
- [ ] **T20 / boot registry (HIGH)** — wire the real per-project factory at boot, or accept switch/add-zone inert. **Keystone isn't live without it.** `T20-…md`
- [ ] **T13 · OSC-7 shell dependency** — terminal cwd resume relies on the shell emitting OSC 7 on `cd`. If default zsh/bash don't auto-emit it, `capturedCwd` falls back to the launch cwd (live cwd not captured). May need a shell-integration snippet. · `runs/T13/`
- [ ] **T13 · scrollback replay deferred (A6)** — scrollback is persisted but never re-displayed (replay is a no-op) → dead weight on disk until a replay mechanism is chosen. Cold-reboot WebKit blob durability also unverified. · `runs/T13/`
- [ ] **T12 · persistence wiring (NH1/NH2)** — fsync now in *shared* `AtomicWriter` (regressions green — confirm intended); no live autosave caller wired yet (mechanism only). · `runs/T12/`
- [ ] **T09 · shape-B model** · **T07 · focus-mode eviction regression** · **T08 · group zone writes `$HOME`** (dormant) · **T06 · windowWillClose ordering / `attachUI` optional-chain**.
- [ ] Ratifications: **T15** name fallback · **T01** navKey→T18 · **T04** closeOnZero · **T05** per-zone focus · **T03** "Max Live Zones" validation.

**Visual gates — rebuild & eyeball** (keystone live-switch ones **blocked-pending-T20**):
- [ ] **T10/T09/T06** live ⌘K switch + pan/zoom (after T20) · **T08** group-zone layer chrome · **T05** flicker/z-paint/cursor/first-responder/empty-state · **T11** header title fit.

## 🟡 Pass with risks — committed, review the named risk
- [ ] **T13 — live-session resume** (2 iters +fixer: A7 bypass closed → real-path gate; A2 bound now real, both RED-confirmed; fixed a restart non-determinism). A10 blob-round-trip weaker than canGoBack; A12 store-vs-runtime.url. · `runs/T13/`
- [ ] **T12** bulletproof restore · **T10** tier transitions (+fixer) · **T09** switchWorkspace · **T08** addZone (+fixer) · **T07** browser budget · **T06** WorkspaceRuntime shell (+fixer) · **T15/T11/T05/T04** — see each `runs/Tnn/`. Keystone risks in 🔴.

## 🟢 Verified routine — clean PASS
- [ ] **T01** zone model · **T02** group-zone tile storage · **T03** hydration planner.

## ⛔ Blocked / needs-human
- **T20** — boot registry factory (design decision; see HEADLINE). The only thing between "built+verified" and "live."

---
Each entry: `[ ] Tnn — what · guards: <check> · runs/Tnn/{build,review}.md`. Evidence in `runs/<task>/` is the source of truth.
