# Morning Review — workspaces/zones sprint

**Open this first.** Triaged by ATTENTION, not build order. Tick each `[ ]` as you review.
Ask me for the **guided walkthrough** and I'll drive it highest-risk first.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing merged to `main` — your call.**
Spine: `git log --oneline main..overnight/workspaces-zones` (each task = one `(Tnn)` commit).
Rebuild for visual gates: `./scripts/make-app-bundle.sh --configuration release --output ~/Applications/ContinuumRevived.app && open ~/Applications/ContinuumRevived.app`

## ⛔ HEADLINE
**Keystone (T06–T10) is BUILT + VERIFIED but INERT in the live app** — boot `WorkspaceRuntime` has a
throwing placeholder registry factory → ⌘K-switch / add-zone / tier-reconcile no-op live. → **`T20`**
(your design call). **#1 decision.** Also: `WorkspaceDocument` is **layout-only** → profiles are layout-only.
**T16 (sidebar) is BLOCKED** — its `--sidebar-check` hangs headlessly (AppKit run-loop); code preserved, needs a check rewrite.

## Status
- Committed: **17** (T01–T15, T17, T18) · **blocked: 1 (T16)** · staged-for-morning: **0 (T19 next)** · needs-human: **3 (T20, session-bundle, T16-check)**
- Fast matrix green · `swift build` clean (T16's hanging check reverted, matrix unwedged)
- Remaining: **stage T19** → MORNING-REPORT.

## 🔴 Decide / eyeball — tests could not prove these
**Decisions:**
- [ ] **T20 / boot registry (HIGH)** — wire the real per-project factory at boot, or keep switch/add-zone inert. **Keystone isn't live without it.** `T20-…md`
- [ ] **T16 / sidebar BLOCKED — check hangs** — the `NSOutlineView` `--sidebar-check` spins a live run loop and never terminates (3 runs hung 32/22/19 min, wedged the matrix). I killed it, preserved the sidebar code (`runs/T16/WorkspaceSidebar.swift.reference` + `SidebarChromeConfig.swift.reference`), and reset to clean. **Needs a headless-safe check** (model on `runNavModeSelfCheck`'s synchronous NSEvent drive — no `NSApp.run()`; wrap in `timeout`). The sidebar is your top remaining piece — recommend we pair on the check rewrite. · `runs/T16/`
- [ ] **T14 · profiles layout-only** (session-bundle bridge?) · **T17 · nav-z default action shifted** · **T18 · zone-jump target/precedence/HUD** · **T13** OSC-7 shell dep / replay deferred · **T12** shared-fsync / no live autosave caller · **T09** shape-B · **T07** focus-mode eviction regression · **T08** $HOME write (dormant) · **T06** windowWillClose / attachUI.
- [ ] Ratifications: **T15** name fallback · **T01** navKey · **T04** closeOnZero · **T05** per-zone focus · **T03** Max-Live-Zones validation.

**Visual gates — rebuild & eyeball** (keystone live-switch ones **blocked-pending-T20**):
- [ ] **T19** drag-to-create-zone (staging next) · **T10/T09/T06** live ⌘K switch + pan/zoom (after T20) · **T17** ⌘K zone rows · **T08** group-zone chrome · **T05** flicker/z-paint/cursor · **T11** header title fit · **T18** zone-jump HUD.

## 🟡 Pass with risks — committed, review the named risk
- [ ] **T18** per-zone leader nav-key jump (+fixer) · **T17** ⌘K zone rows (+fixer) · **T14** profiles · **T13** session resume (+fixer) · **T12** restore · **T10** tier transitions (+fixer) · **T09** switchWorkspace · **T08** addZone (+fixer) · **T07** budget · **T06** runtime shell (+fixer) · **T15/T11/T05/T04** — see each `runs/Tnn/`.

## 🟢 Verified routine — clean PASS
- [ ] **T01** zone model · **T02** group-zone tile storage · **T03** hydration planner.

## ⛔ Blocked / needs-human
- **T20** — boot registry factory (HEADLINE). Between "built+verified" and "live."
- **Session-bundle bridge** (T14) — to make profile snapshots meaningful.
- **T16** — sidebar `--sidebar-check` hangs headlessly; sidebar code preserved in `runs/T16/`; needs a headless-safe check rewrite (pair).

---
Each entry: `[ ] Tnn — what · guards: <check> · runs/Tnn/{build,review}.md`. Evidence in `runs/<task>/` is the source of truth.
