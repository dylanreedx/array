# Morning Review — workspaces/zones sprint

**Open this first.** Triaged by ATTENTION, not build order. Tick each `[ ]` as you review.
Ask me for the **guided walkthrough** and I'll drive it highest-risk first. See `MORNING-REPORT.md` for the full wrap-up.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing merged to `main` — your call.**
Spine: `git log --oneline main..overnight/workspaces-zones`. Rebuild for visual gates:
`./scripts/make-app-bundle.sh --configuration release --output ~/Applications/ContinuumRevived.app && open ~/Applications/ContinuumRevived.app`

## ⛔ HEADLINE
**Keystone (T06–T10) is BUILT + VERIFIED but INERT in the live app** — boot `WorkspaceRuntime` has a
throwing placeholder registry factory → ⌘K-switch / add-zone / tier-reconcile no-op live. → **`T20`** (your
design call). **#1 decision.** Also: `WorkspaceDocument` is **layout-only** → profiles layout-only. **T16
(sidebar) BLOCKED** — `--sidebar-check` hangs headlessly; code preserved, needs a check rewrite.

## Status — SPRINT COMPLETE (overnight)
- Committed: **18** (T01–T15, T17, T18 done · T19 staged) · **blocked: 1 (T16)** · needs-human: **3 (T20, session-bundle, T16-check)**
- Fast matrix green · `swift build` clean · branch pushed
- **Done building. Remaining is YOUR review** + the 3 needs-human decisions + visual gates.

## 🔴 Decide / eyeball — tests could not prove these
**Decisions:**
- [ ] **T20 / boot registry (HIGH)** — wire the real per-project factory at boot, or keep switch/add-zone inert. **Keystone isn't live without it.** `T20-…md`
- [ ] **T16 / sidebar BLOCKED — check hangs** — needs a headless-safe `--sidebar-check` (model on `runNavModeSelfCheck`'s synchronous drive; `timeout`-wrap). Code preserved `runs/T16/*.reference`. Recommend pairing — it's your top remaining piece. · `runs/T16/`
- [ ] **T14 · profiles layout-only** (session-bundle bridge?) · **T17 · nav-z default shift** · **T18 · zone-jump target/precedence/HUD** · **T13** OSC-7 shell dep · **T12** shared-fsync / no live autosave caller · **T09** shape-B · **T07** focus-mode eviction regression · **T08** $HOME write (dormant) · **T06** windowWillClose / attachUI.
- [ ] Ratifications: **T15** name fallback · **T01** navKey · **T04** closeOnZero · **T05** per-zone focus · **T03** Max-Live-Zones validation.

**Visual gates — rebuild & eyeball:**
- [ ] **T19** create-marquee feel + landing pop (marquee→480×320 empty-min); move = rigid group; **render-model move snap-back** (move then pan/zoom — chrome must not revert); z-paint; cursor rects; 24px threshold; overlap; pan/zoom-anchored. · `runs/T19/`
- [ ] **T10/T09/T06** live ⌘K switch + pan/zoom demote/promote (**blocked-pending-T20**) · **T08** group-zone chrome · **T05** flicker/z-paint/cursor/first-responder · **T11** header title fit · **T18** zone-jump HUD (not drawn) · **T16** sidebar (after check rewrite).

## 🟡 Pass with risks — committed, review the named risk
- [ ] **T19** drag-to-create/move-zone (2 iters; gesture check real) — render-model-stale + empty-min-pop (visual). · **T18** leader nav-key jump (+fixer) · **T17** ⌘K zone rows (+fixer) · **T14** profiles · **T13** session resume (+fixer) · **T12** restore · **T10** tier transitions (+fixer) · **T09** switchWorkspace · **T08** addZone (+fixer) · **T07** budget · **T06** runtime shell (+fixer) · **T15/T11/T05/T04** — see each `runs/Tnn/`.

## 🟢 Verified routine — clean PASS
- [ ] **T01** zone model · **T02** group-zone tile storage · **T03** hydration planner.

## ⛔ Blocked / needs-human
- **T20** boot registry factory (HEADLINE) · **Session-bundle bridge** (T14) · **T16** sidebar check hangs (code preserved).

---
Each entry: `[ ] Tnn — what · guards: <check> · runs/Tnn/{build,review}.md`. Evidence in `runs/<task>/` is the source of truth.
