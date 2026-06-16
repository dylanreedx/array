# Morning Review — workspaces/zones sprint

**Open this first.** Triaged by ATTENTION, not build order. Tick each `[ ]` as you review.
Ask me for the **guided walkthrough** and I'll drive it highest-risk first.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing merged to `main` — your call.**
Spine: `git log --oneline main..overnight/workspaces-zones` (each task = one `(Tnn)` commit).
Rebuild for visual gates: `./scripts/make-app-bundle.sh --configuration release --output ~/Applications/ContinuumRevived.app && open ~/Applications/ContinuumRevived.app`

## ⛔ HEADLINE
**Keystone (T06–T10) is BUILT + VERIFIED but INERT in the live app** — boot `WorkspaceRuntime` has a
throwing placeholder registry factory; ⌘K-switch/add-zone/tier-reconcile no-op live. → **`T20`** (your
design call: per-project controller construction at boot). #1 decision. **Also:** `WorkspaceDocument`
is **layout-only**, so profiles (T14) are layout-only — snapshot-vs-template needs a session-bundle bridge.

## Status
- Committed: **16** · blocked: **0** · staged-for-morning: **0** · needs-human: **2 (T20, session-bundle)** · of 17 build tasks
- Fast matrix green · `swift build` clean
- Done: T01–T15 + T17. **Remaining: T18 → morning T16/T19 → MORNING-REPORT.**

## 🔴 Decide / eyeball — tests could not prove these
**Decisions:**
- [ ] **T20 / boot registry (HIGH)** — wire the real per-project factory at boot, or keep switch/add-zone inert. **Keystone isn't live without it.** `T20-…md`
- [ ] **T17 · nav-z default action shifted** — the zone picker now default-highlights "Jump to Alpha" (a zone-jump row) / "Create Zone…" instead of the matching project; Enter changed meaning. The check now PINS this (honest), but **confirm the new default is desired**, or adjust `makeRows` ordering. · `runs/T17/`
- [ ] **T14 · profiles layout-only** (snapshot==template inert; session-bundle bridge?) — carry-forward: **T16 "Save as profile" must not assume session-state on the document.** · `runs/T14/`
- [ ] **T13 OSC-7 shell dep / scrollback replay deferred** · **T12 shared-fsync / no live autosave caller** · **T09 shape-B** · **T07 focus-mode eviction regression** · **T08 group-zone `$HOME` write** (dormant) · **T06 windowWillClose / attachUI**.
- [ ] Ratifications: **T15** name fallback · **T01** navKey→T18 · **T04** closeOnZero · **T05** per-zone focus · **T03** "Max Live Zones" validation · **T17** createZone home / focus option.

**Visual gates — rebuild & eyeball** (keystone live-switch ones **blocked-pending-T20**):
- [ ] **T10/T09/T06** live ⌘K switch + pan/zoom (after T20) · **T17** ⌘K zone-row rendering · **T08** group-zone chrome · **T05** flicker/z-paint/cursor/first-responder · **T11** header title fit.

## 🟡 Pass with risks — committed, review the named risk
- [ ] **T17 — ⌘K zone rows** (1st run stalled→re-launched; +fixer re-tightened nav-mode check + config round-trip). create-zone runtime branch untested (T20-gated); intersects-vs-contains; empty-zone jump untested. · `runs/T17/`
- [ ] **T14** profiles · **T13** session resume (+fixer) · **T12** restore · **T10** tier transitions (+fixer) · **T09** switchWorkspace · **T08** addZone (+fixer) · **T07** budget · **T06** runtime shell (+fixer) · **T15/T11/T05/T04** — see each `runs/Tnn/`.

## 🟢 Verified routine — clean PASS
- [ ] **T01** zone model · **T02** group-zone tile storage · **T03** hydration planner.

## ⛔ Blocked / needs-human
- **T20** — boot registry factory (HEADLINE). Between "built+verified" and "live."
- **Session-bundle bridge** (T14) — to make profile snapshots meaningful.

---
Each entry: `[ ] Tnn — what · guards: <check> · runs/Tnn/{build,review}.md`. Evidence in `runs/<task>/` is the source of truth.
