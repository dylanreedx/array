# Morning Review — workspaces/zones sprint

**Open this first.** Triaged by ATTENTION, not build order. Tick each `[ ]` as you review.
Ask me for the **guided walkthrough** and I'll drive it highest-risk first.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing merged to `main` — your call.**
Spine: `git log --oneline main..overnight/workspaces-zones` (each task = one `(Tnn)` commit).
Rebuild for visual gates: `./scripts/make-app-bundle.sh --configuration release --output ~/Applications/ContinuumRevived.app && open ~/Applications/ContinuumRevived.app`

## ⛔ HEADLINE — read first
**Keystone (T06–T10) is BUILT + headlessly VERIFIED but INERT in the live app** — boot
`WorkspaceRuntime` has a throwing placeholder registry factory, so add-zone/switch/tier-reconcile
no-op live. → **`T20`** (your design call: per-project controller construction at boot). #1 decision.
**Second architectural note:** `WorkspaceDocument` is **layout-only** — session-state (scrollback,
browser `interactionState`) lives in ProjectStore sibling stores, not on the document. So **profiles
(T14) are layout-only**; snapshot-vs-template is inert without a session-bundle bridge. Affects T16.

## Status
- Committed: **15** · blocked: **0** · staged-for-morning: **0** · needs-human: **1 (T20)** · of 17 build tasks
- Fast matrix green · `swift build` clean
- Done: T01–T14 + T15. **Remaining: T17/T18 → morning T16/T19.** Then MORNING-REPORT.

## 🔴 Decide / eyeball — tests could not prove these
**Architecture / design decisions:**
- [ ] **T20 / boot registry (HIGH)** — wire the real per-project factory at boot, or accept switch/add-zone inert. **Keystone isn't live without it.** `T20-…md`
- [ ] **T14 · profiles are layout-only (snapshot==template inert)** — capture-mode ships as dead config (architecturally forced: `WorkspaceDocument` is layout-only). **Accept** layout-only profiles, or **schedule a session-bundle bridge** (new capture, was forbidden in T14). Carry-forward: **T16's "Save as profile" must not re-assume session-state on the document.** · `runs/T14/`
- [ ] **T13 · OSC-7 shell dependency** (cwd resume needs the shell to emit OSC 7 on cd; else falls back) · **scrollback replay deferred / cold-reboot blob unverified**. · `runs/T13/`
- [ ] **T12 · persistence wiring** (shared `AtomicWriter` fsync; no live autosave caller yet) · **T09 shape-B** · **T07 focus-mode eviction regression** · **T08 group-zone `$HOME` write** (dormant) · **T06 windowWillClose / attachUI**.
- [ ] Ratifications: **T15** name fallback · **T01** navKey→T18 · **T04** closeOnZero · **T05** per-zone focus · **T03** "Max Live Zones" validation.

**Visual gates — rebuild & eyeball** (keystone live-switch ones **blocked-pending-T20**):
- [ ] **T10/T09/T06** live ⌘K switch + pan/zoom (after T20) · **T08** group-zone chrome · **T05** flicker/z-paint/cursor/first-responder/empty-state · **T11** header title fit.

## 🟡 Pass with risks — committed, review the named risk
- [ ] **T14 — profiles/snapshots** (store + restore-over + instantiate-as-new are REAL, RED-confirmed; capture-mode inert — see 🔴). · `runs/T14/`
- [ ] **T13** session resume (+fixer) · **T12** bulletproof restore · **T10** tier transitions (+fixer) · **T09** switchWorkspace · **T08** addZone (+fixer) · **T07** browser budget · **T06** WorkspaceRuntime shell (+fixer) · **T15/T11/T05/T04** — see each `runs/Tnn/`.

## 🟢 Verified routine — clean PASS
- [ ] **T01** zone model · **T02** group-zone tile storage · **T03** hydration planner.

## ⛔ Blocked / needs-human
- **T20** — boot registry factory (design decision; HEADLINE). Between "built+verified" and "live."
- **Session-bundle bridge** (from T14) — decide if/where it lands to make profile snapshots meaningful.

---
Each entry: `[ ] Tnn — what · guards: <check> · runs/Tnn/{build,review}.md`. Evidence in `runs/<task>/` is the source of truth.
