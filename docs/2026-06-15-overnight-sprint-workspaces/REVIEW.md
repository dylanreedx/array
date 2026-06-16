# Morning Review — workspaces/zones sprint

**Open this first.** Triaged by ATTENTION, not build order. Tick each `[ ]` as you review.
Ask me for the **guided walkthrough** and I'll drive it highest-risk first.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing merged to `main` — your call.**
Spine: `git log --oneline main..overnight/workspaces-zones` (each task = one `(Tnn)` commit).
Rebuild for visual gates: `./scripts/make-app-bundle.sh --configuration release --output ~/Applications/ContinuumRevived.app && open ~/Applications/ContinuumRevived.app`

## ⛔ HEADLINE
**Keystone (T06–T10) is BUILT + VERIFIED but INERT in the live app** — boot `WorkspaceRuntime` has a
throwing placeholder registry factory; ⌘K-switch / add-zone / tier-reconcile no-op live. → **`T20`**
(your design call: per-project controller construction at boot). #1 decision. **Also:** `WorkspaceDocument`
is **layout-only** → profiles (T14) are layout-only; snapshot-vs-template needs a session-bundle bridge.

## Status
- Committed: **17** · blocked: **0** · staged-for-morning: **0 (T16/T19 next)** · needs-human: **2 (T20, session-bundle)** · of 17 build tasks
- Fast matrix green · `swift build` clean
- **All 17 overnight build tasks done (T01–T15, T17, T18).** Remaining: **stage T16 + T19** (visual gate) → MORNING-REPORT.

## 🔴 Decide / eyeball — tests could not prove these
**Decisions:**
- [ ] **T20 / boot registry (HIGH)** — wire the real per-project factory at boot, or keep switch/add-zone inert. **Keystone isn't live without it.** `T20-…md`
- [ ] **T14 · profiles layout-only** (snapshot==template inert; session-bundle bridge?) — carry-forward: **T16 "Save as profile" must not assume session-state on the document.**
- [ ] **T17 · nav-z default action shifted** (now default-highlights a zone-jump / Create-Zone row, not the matching project; Enter changed meaning). Check pins it; confirm desired or adjust ordering.
- [ ] **T18 · zone-jump target = zone-fit, not last-active-tile** (no per-zone lastActiveTile in model — confirm or T01 follow-on) · **precedence** zone-navKey beats colliding tile-label (confirm) · **zone-jump HUD badge not drawn** (visual polish).
- [ ] **T13** OSC-7 shell dep / scrollback replay deferred · **T12** shared-fsync / no live autosave caller · **T09** shape-B · **T07** focus-mode eviction regression · **T08** group-zone `$HOME` write (dormant) · **T06** windowWillClose / attachUI.
- [ ] Ratifications: **T15** name fallback · **T01** navKey · **T04** closeOnZero · **T05** per-zone focus · **T03** Max-Live-Zones validation.

**Visual gates — rebuild & eyeball** (keystone live-switch ones **blocked-pending-T20**):
- [ ] **T16** sidebar (staging next) · **T19** drag-to-create-zone (staging next) · **T10/T09/T06** live ⌘K switch + pan/zoom (after T20) · **T17** ⌘K zone rows · **T08** group-zone chrome · **T05** flicker/z-paint/cursor · **T11** header title fit · **T18** zone-jump HUD.

## 🟡 Pass with risks — committed, review the named risk
- [ ] **T18** per-zone leader nav-key jump (+fixer: precedence bug + validator test + assertion hardening) · **T17** ⌘K zone rows (+fixer) · **T14** profiles · **T13** session resume (+fixer) · **T12** restore · **T10** tier transitions (+fixer) · **T09** switchWorkspace · **T08** addZone (+fixer) · **T07** budget · **T06** runtime shell (+fixer) · **T15/T11/T05/T04** — see each `runs/Tnn/`.

## 🟢 Verified routine — clean PASS
- [ ] **T01** zone model · **T02** group-zone tile storage · **T03** hydration planner.

## ⛔ Blocked / needs-human
- **T20** — boot registry factory (HEADLINE). Between "built+verified" and "live."
- **Session-bundle bridge** (T14) — to make profile snapshots meaningful.

---
Each entry: `[ ] Tnn — what · guards: <check> · runs/Tnn/{build,review}.md`. Evidence in `runs/<task>/` is the source of truth.
