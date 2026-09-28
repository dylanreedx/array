# History of prior fix attempts — A/B/C/D

Sources: `git log array/integration` since 2026-07-15, `.plans/*`, `docs/38-tickets/*`,
`docs/VERSIONING.md`, `scripts/run-matrix.sh`, `AGENTS.md`/`CLAUDE.md` (symlinked, same file).

## A. Zone names / zone project-home bindings revert after workspace switch or relaunch

### Commits (integration branch unless noted)
| hash | date | subject |
|---|---|---|
| cf4dcaf6 | 2026-06-21 | feat(workspace): add top bar identity |
| e04ecde4 | 2026-06-21 | Implement workspace management polish |
| 541f8c26 | 2026-06-28 | fix(workspace): polish shell chrome and workspace restore |
| ecf3bf3e | 2026-08-22 | Fix workspace switching and linked document focus |
| 06cde5dd | 2026-08-22 | Witness that a workspace switch corrupts the arriving project's canvas |
| d5561c20 | 2026-08-22 | Witness that a workspace switch leaves dead placeholder tiles |
| 0bcf01d7 | 2026-08-22 | Persist each project's own tiles, merged over what is on disk |
| 5a75fb41 | 2026-08-23 | Extract the boot scene mount, and give zones one owner |
| 4b459179 | 2026-08-23 | Create tiles in the zone you are working in (`.plans/47`) |
| 9f45eebe | 2026-08-26 | Allow launch with legacy workspace memberships |
| 6f9eecca | 2026-08-26 | Fix workspace persistence and transcript recovery |
| dfd0600a | 2026-08-26 | Persist the selected workspace on switch |
| 24517e16 | 2026-08-26 | Prevent hidden foreign workspace zones |
| c1451051 | 2026-08-31 | Persist mounted workspace before close |
| c1ba9b96 | 2026-08-31 | Drive workspace persistence through production lifecycle |
| e9dc7143 | 2026-09-01 | Integrate WS2: workspace persistence and backup identity |
| 360bd2e2 | 2026-09-01 | Integrate WS1: zone rebase safety, drift, and undo-stack survival |
| 1d2cd409 | 2026-09-01 | Persist committed layouts in world space (WS2 F2) |

### Docs/claims table
| doc | claim | cited commit | witness named | in matrix? |
|---|---|---|---|---|
| AGENTS.md hazard 9 (pre-08-22 text) | terminal/note/browser/agent spawns install into stale flat model on workspace switch (bug, not fix) | (bug report, `.plans/15` fixed file-opening only) | — | — |
| AGENTS.md hazard 9, corrected 2026-08-22 (`.plans/46`) | "All four [spawns] are migrated" (verified `09de0b0`) | `09de0b0` | `--zone-tile-hydration-check`, `--zone-spawner-coverage-check` | Y (both in run-matrix.sh) |
| AGENTS.md hazard 9, same 08-22 entry | discloses a **bigger, still-open** hazard: after the first in-process workspace switch every ZoneLayer tile is a `DescriptorTileNSView` placeholder, and `persistProjectCanvas` can erase unhydrated zones' tiles — "has no witness" | none (named as unfixed) | none | N |
| AGENTS.md hazard 9, "Corrected again 2026-08-23 (M1.10)" (`961ba1d3`) | **retracts** yesterday's "FIXED" claim: "They were not fixed — they were *unreachable*, which is worse... made a whole milestone look green." Root cause: `WorkspaceRuntime.canvasView` had one writer (`install(into:appRegistry:)`) that **no production code ever called**; all six M1 scene witnesses were green only because each called `install(into:)` itself | — | `--workspace-scene-owner-check` (must drive `mountWorkspaceSceneAtBoot`, not `install(into:)`) | Y |
| docs/VERSIONING.md 0.5.10 (build 35, 2026-08-22) | "Workspaces switch their real canvases again..." | (matches `ecf3bf3e`/`06cde5dd`/`d5561c20` era) | 175-leg matrix, 9 KNOWN-RED | Y (gate-level) |
| docs/VERSIONING.md 0.5.11 (build 36, 2026-08-23) | "Switching a workspace switches the canvas, and new tiles land in the zone you are working in" — cites the exact `install(into:)`-never-called defect, `WorkspaceRuntime.setActiveZone` as sole writer of "armed zone" | `4b459179`-era | `--zone-arming-check`, `--relationship-geometry-check` | Y |
| docs/VERSIONING.md 0.5.13 (build 38, 2026-08-26) | "zones retain their custom names, geometry, color, collapse state, viewport and focus across round trips and relaunch" | — | "focused production-path checks, full CoreChecks... workspace switching" (not a specific flag) | partially — no single named `--zone-name-persistence-check` |
| docs/VERSIONING.md 0.5.14 (build 39) | Hotfix: legacy duplicate workspace membership no longer prevents Array from opening | — | named regression + CoreChecks | Y |
| docs/VERSIONING.md 0.5.15 (build 40) | Workspace creation escapes legacy ownership conflicts | — | CoreChecks + "real add-zone/AppDelegate route" | Y |
| docs/VERSIONING.md 0.5.16 (build 41) | "Workspaces mount completely separate canvases" — witness proving zero zones/tiles leak across switch | — | note: "the broader supervisor gate reaches a pre-existing injected **Home-persistence assertion** before its timer section" (i.e. a Home-persistence check was blocked/unreached at this point too) | partial — flagged as blocked |
| docs/VERSIONING.md 0.5.17 (build 42) | "A workspace switch now durably records the selected workspace before mounting" | — | none named | **superseded by 0.5.18 in the very next row** ("startup still let the boot project overwrite this saved selection") |
| docs/VERSIONING.md 0.5.18 (build 43) | "Startup honors the selected workspace" | — | none named | **superseded by 0.5.19** ("compatibility boot controller could still inject its foreign project zone") |
| docs/VERSIONING.md 0.5.19 (build 44) | "An empty workspace stays truly empty across launch and relaunch" | — | boot gate assertion, CoreChecks workspace-scoped project resolution | Y |
| docs/VERSIONING.md 0.5.20 (build 45) | "A saved workspace canvas no longer disappears after switching away and back" — Home picker committed a zone before checking workspace ownership | — | CoreChecks, production workspace switching | Y |

### Retracted or unlanded claims (A)
- **08-22 → 08-23 retraction** (`961ba1d3`, AGENTS.md hazard 9): "FIXED — M1 of `.plans/46`" was walked back the next day to "unreachable, not fixed" — the real defect (`install(into:)` never called in production) was still live when the "FIXED" note was written; all passing witnesses at that point were checks-only.
- **0.5.17 → 0.5.18 → 0.5.19 chain**: three consecutive point releases each claimed to have fixed workspace-selection persistence across relaunch, each superseded within the same day (2026-08-26) by the next because the previous fix only closed one of three overlapping code paths (switch transaction ordering, boot override, compatibility-controller injection).
- Net effect: **A has been "fixed" at least 6 times** (0.5.10, 0.5.11, 0.5.13, 0.5.17, 0.5.18, 0.5.19/0.5.20) across five days, with two explicit in-repo retractions. Any new claim that "workspace switch now preserves zone names/home" must be checked against this chain rather than taken as first-time.

---

## B. Agent tile created in a zone born with blank ("---") project home; home selector inert until restart

### Commits
| hash | date | subject |
|---|---|---|
| 85e678c0 | 2026-08-06 | feat(agents): project live Home Where What status |
| 307015e8 | 2026-08-06 | fix(agents): preserve Home action integration contracts |
| 34d0e1fa / e27a908f | 2026-08-06 | Queue 91 Lane A home path actions |
| 1db393f (per PAUSED-HANDOFF log) | 2026-08-06 | fix(agents): refuse implicit process cwd Home |
| 1016b2b | 2026-08-06 | docs(queue91): record Home and spatial foundations |
| ab14feb | 2026-08-06 | fix(agents): gate Home actions across platforms |
| 565b423 | 2026-08-06 | fix(agents): secure Home selection and core gates |
| 7a2f571b | 2026-08-06 | fix(core): harden agent Home path relations |
| 4b459179 | 2026-08-23 | Create tiles in the zone you are working in — "Choosing a zone's Home is one click" |

### Docs/claims table
| doc | claim | cited commit | witness named | in matrix? |
|---|---|---|---|---|
| docs/38-tickets/91-agent-tile-ux/PAUSED-HANDOFF-2026-08-06.md | "The original Home / Where / What owner workflow is substantially implemented" (94/291 Queue-91 acceptance checks done at pause) | commit list above | `AgentLocationChecks.swift` (CoreChecks section) | Y — `runAgentLocationContractChecks()` / `runAgentLocationPresentationChecks()` registered in `Sources/ContinuumRevivedCoreChecks/main.swift` and run as part of `swift run ContinuumRevivedCoreChecks` (part of the matrix) |
| docs/VERSIONING.md 0.3.0 (build 5) | "custom-folder Home updates the header" | — | none named specifically | N (no dedicated flag) |
| docs/VERSIONING.md 0.4.5 (build 11) | "A new managed agent inherits the Home you are working in": precedence explicit action → selected agent → context gravity → active project; "an unusable Home still refuses rather than falling back" | — | none named | N |
| docs/VERSIONING.md 0.5.8 (build 33) | "The Home/project chooser has clearer hierarchy, keyboard navigation and screen-aware placement; creation follows the active project/Home context" | — | "175 matrix legs... 10 known-red" (gate-level only) | partial |
| docs/VERSIONING.md 0.5.11 (build 36) | "choosing a zone's Home is one click" (part of the zone-arming fix) | 4b459179-era | `--zone-arming-check` | Y |
| docs/VERSIONING.md 0.5.16 (build 41) | admits: "the broader supervisor gate reaches a **pre-existing injected Home-persistence assertion** before its timer section" — i.e., at 0.5.16 a Home-persistence check exists but is gated/blocked from running to completion | — | named as blocked, not a pass | **N — blocked assertion, not a running witness** |

### Retracted or unlanded claims (B)
- No explicit "was not fixed" retraction found in-repo specifically naming the blank-("---")-home-on-agent-spawn symptom described in the complaint. The closest matches are the general zone/spawn-targeting defects under hazard 9 (`.plans/47`) and the Queue-91 Home/Where/What work, none of which name the literal "---" placeholder or "selector does nothing until restart" symptom verbatim — **this exact bug (B) has no prior commit or doc that names it directly; treat it as likely unaddressed/undocumented rather than re-litigated.**
- No `--*-check` flag containing "home" exists in `Sources/ContinuumRevived/App/ContinuumApp.swift` today (`grep -oE '\-\-[a-z0-9-]+-check' ... | grep -i home` → empty). The only Home-related witnesses live in CoreChecks (`AgentLocationChecks.swift`, `AgentLocationPresentationChecks.swift`), which test Home/Where/What *presentation*, not specifically "selector inert until restart."

---

## C. Tiles inside zones shift position after workspace switch/over time; zones overlap; tiles sit outside their zone's rect while still members

### Commits
| hash | date | subject |
|---|---|---|
| f5c94081 | 2026-08-20 | Add deterministic jelly auto layout solver |
| a18930d1 | 2026-08-20 | Integrate jelly layout with canvas gestures |
| 9e25b7a9 | 2026-08-20 | Add auto layout settings and tidy UX |
| 5d908fc7 | 2026-08-20 | Harden jelly layout interactions and validation |
| 63e007b0 | 2026-08-20 | Make layout commits durable across stores |
| 55ae5807 | 2026-08-20 | Allow direct tile drops into jelly zones |
| db9ff7ea | 2026-08-20 | Transfer in-zone resize pressure between tiles |
| f5a86a38 | 2026-08-20 | Grow zones for spawned tiles and swap occupied slots |
| 74ac7308 | 2026-08-20 | Persist zone auto layout overrides |
| b0db280d | 2026-08-20 | Document rejected jelly layout implementation |
| 5beb8258 | 2026-08-21 | Redesign jelly layout direct manipulation |
| 40c4e0cb | 2026-08-21 | Unify auto layout with canvas undo transactions |
| ecf3bf3e | 2026-08-22 | Fix workspace switching and linked document focus |
| 12178613 | 2026-08-22 | Give every live zone a spawner, so every zone's tiles hydrate |
| d4e392cf | 2026-08-22 | Hydrate a zone's tiles instead of leaving title-label placeholders |
| c0406b09 | 2026-08-25 | Keep the layout's fast-path guard from costing what it saves |
| f5c94081→…62e1365 chain | 2026-08-31 | Cover concrete duplicate zone gestures / Keep concrete zone layer through gestures / Scope layered resize frames by zone identity / Preserve layered members during zone resize |
| de341bb5 / 27b24e1e / c0ebd279 / 0f94df67 / 4c13562d / 662e1365 | 2026-08-31 | zone gesture regression coverage / duplicate zone gestures / concrete gesture routing mode / cancel gestures on topology change / rebuild zone projections on cancellation |
| ff54db6b | 2026-08-31 | Make zone rebase non-trapping and stop dropping layout frames |
| 2ba51e2f | 2026-08-31 | Witness the unvetted-origin rebase end to end |
| 9a8aea36 | 2026-08-31 | Stop an origin correction from wiping the undo stack |
| ca4c70f6 | 2026-09-01 | Compare zone chrome and its grab header in one coordinate space |
| 365d2f01 | 2026-09-01 | Disarm the same coordinate-space trap in the zone-create gesture leg |
| 360bd2e2 | 2026-09-01 | Integrate WS1: zone rebase safety, drift, and undo-stack survival |
| 1d2cd409 | 2026-09-01 | Persist committed layouts in world space (WS2 F2) |
| 24517e16 | 2026-08-26 | Prevent hidden foreign workspace zones |
| 0725e15 (0.7.13) | 2026-09-04 | Hotfix: dragging a populated zone consistently carries its tiles / stops growing the zone (see VERSIONING below; rounding-drift bug, `400.3` → `400.29999999999995`) |
| 5db4f61f | 2026-09-04 | Keep zones rigid throughout repeated drag updates |
| 41f57f3a | 2026-09-03 | Improve magnetic placement, resize pressure, and zone tidy |
| 1bb98108 | 2026-09-21 | fix(zone): delete a zone's tiles when the user asks to delete them |

### Docs/claims table
| doc | claim | cited commit | witness named | in matrix? |
|---|---|---|---|---|
| `.plans/54-prompts/01-zones-auto-layout.md` (WS1 dispatch) | Known defects going in: HUD shows during auto-layout zone move but not resize; `CanvasAutoLayoutEngine` shrinks passive neighbors before growing the zone; `.zone` resize repacks members and pushes collisions into neighbor zones; `growZoneToFitMembers` has a flat-model blind spot for hydrated layer tiles | — | `--resize-dimensions-hud-check`, `--zone-resize-check`, `--zone-adaptive-bounds-check`, `--jelly-auto-layout-check`, `--resize-snap-check` | Y (all 5 present in run-matrix.sh) |
| `.plans/54-run-ledger.md` | WS1 (zones) integrated at `360bd2e2`, 17 green legs, 3 independent reviews each finding a real defect — but **"WS1 open items, all confirmed by review and untouched"**: `updateTile` mutates the tile model before calling the solver (non-atomic rejection); noncanonical same-zone peers over-constrain the vetting set; `growZoneToFitMembers` can silently no-op | `360bd2e2` | (see above) | Y, but three named defects are explicitly **left open/unfixed** at integration time |
| `.plans/54-run-ledger.md` | "The same coordinate-space trap was found armed in `--zone-create-gesture-check` (passing only because its `vpB` is at the origin) and disarmed there too" | — | `--zone-create-gesture-check` | Y |
| docs/VERSIONING.md 0.7.11 (build 62) | "Auto layout gains magnetic placement, smooth resize pressure, and a reliable Tidy" — resizing "preserves neighbor dimensions... grows only the owning zone and restores the gesture baseline on reversal" | — | "focused pressure, magnetic drag, resize snapping and mounted-zone checks" (unnamed specifically) + 201-leg matrix, 5 KNOWN-RED | partial |
| docs/VERSIONING.md 0.7.12 (build 63) | zone chrome uses vector fills/outlines; "connected layout settling avoids redundant packing work" | — | 213-leg matrix; 3 new integration failures "repaired" | Y (gate level) |
| docs/VERSIONING.md 0.7.13 (build 64) — **hotfix** | "dragging a populated zone consistently carries its tiles and no longer grows the zone." Root cause: coordinate rebasing introduced float rounding drift (`400.3` → `400.29999999999995`), misclassified as a resize, pinning members | — | "the extended mounted-zone witness fails before the fix and passes afterward in Debug and Release" — **explicitly not the full matrix**: "the full matrix was not repeated for this focused one-file hotfix" | **N — not run through the gate, only a focused witness + manual Computer Use check** |
| CLAUDE.md non-negotiable #9 (frame-space invariant) | "canvas.json holds WORLD frames; a ZoneLayer holds ZONE-LOCAL. Convert at the model boundary only... Persisting zone-local moves every tile by its zone origin the next time the flat boot path reads the file" — this is the exact mechanism for "tiles drift/shift after workspace switch" | multiple (`4b459179`, `961ba1d3`) | none single-named; covered indirectly by `--workspace-scene-owner-check`, `--zone-arming-check` | Y (proxy coverage only) |
| CLAUDE.md non-negotiable #9 (membership invariant) | "A tile's zoneId can name another project's zone... `CanvasEngine.resolveZoneMembership` rescues those into the project's own zone by geometry" — this is the exact mechanism for "tile sits outside a zone's rect while still a member" | `4b459179` (mentions "one store found with all 89 of a project's tiles stamped to another's") | none named directly (referenced as a general invariant) | unclear — no explicit `--*-membership-check` flag found |

### Retracted or unlanded claims (C)
- `.plans/54-run-ledger.md` explicitly records **three WS1 defects that were reviewed, confirmed real, and left unfixed at integration** (`updateTile` non-atomic rejection, noncanonical-peer over-constraint, silent `growZoneToFitMembers` no-op) — these are candidate root causes for "zones overlap / tiles sit outside a zone's rect" that were never closed, not merely re-broken.
- 0.7.13 is a **narrow, unverified-by-full-matrix hotfix** for exactly the "tiles shift position" drift symptom (rounding-induced pin/no-grow bug) — a new claim of "zones drift/tiles shift" should be checked against this specific rounding mechanism before treating it as novel.
- WS2 ledger notes (`.plans/54-run-ledger.md`) that the WS2 persistence corrective (which underlies "tiles at correct position after reload") went through corrective iterations F → I → K → M → O across many rejected reviews (`review-g`, `review-h`, `review-l`, `review-n` all DO_NOT_PROMOTE/TEST_FAIL) before landing — i.e., persistence-of-position was hard to get right and had several rejected "fixes" in the same program before the one that shipped (`e9dc7143`).

---

## D. macOS window titlebar merge

### Commits
| hash | date | subject | branch |
|---|---|---|---|
| f1a60801 | 2026-06-15 | fix(tiles): keep title bar + close button a usable on-screen size across zoom | integration (tile chrome, not the window titlebar) |
| 4863d19e | 2026-08-30 | Witness titlebar drag with passive event tap | integration |
| 1aa1e5c1 | 2026-08-30 | Bind pointer witness to exact topmost titlebar point | integration |
| **61416361** | **2026-09-13** | **feat(window-chrome): merge the workspace bar into the titlebar** | **`array/topbar-merge` ONLY — never merged into `array/integration`** |

### Key finding
`61416361` is the only commit that actually implements "merge the titlebar" (full-size content view, transparent/title-less titlebar, workspace bar hoisted to sit in the titlebar strip, `--window-chrome-check` added). It sits on `array/topbar-merge`, branched off `a8d77e56` (2026-08-21). `git merge-base --is-ancestor 61416361 array/integration` → **NOT ANCESTOR**. `array/integration` instead continued past that point on its own line (`a8d77e56` → `10b3b5fe` "Restore the workspace sidebar" → ... → `547859a7` 2026-09-21), never picking up the topbar-merge work.

### Docs/claims table
| doc | claim | cited commit | witness named | in matrix? |
|---|---|---|---|---|
| `.plans/65-release-0.7.21-coordination.md` (line 20) | "Existing topbar" candidate at `.worktrees/topbar-merge` / `array/topbar-merge` / `61416361` — "Clean, one existing feature commit ahead; Sol APPROVE and fresh focused checks passed. **Not landed**; no real fullscreen/window-drag/taste QA. Preserve original ownership." | `61416361` | `--window-chrome-check`, `--workspace-top-bar-check` (both run in isolation, NOT through the real matrix) | **N — `window-chrome-check` string does not appear anywhere in `scripts/run-matrix.sh`; `workspace-top-bar-check` does appear (count 1) but corresponds to the pre-existing top bar, not the merged-titlebar feature** |
| `.plans/65-release-0.7.21-coordination.md` (line 32) | "Topbar fresh build/check logs... Both checks exit0. Fullscreen witness invokes callbacks rather than actual fullscreen; **no actual mouse-drag proof**." | `61416361` | same two flags | N |
| `.plans/65-release-0.7.21-coordination.md` (line 215) | Explicitly: "These are deterministic check passes, NOT manual titlebar/fullscreen QA or user taste approval. **No integration/landing claimed**; original owner preserved." | `61416361` | same | N |
| `docs/VERSIONING.md` | No 0.7.x or 0.8.x ledger row mentions "titlebar" or "window-chrome" at all | — | — | N/A — never shipped |

### Retracted or unlanded claims (D)
- **D was never claimed as fixed/shipped anywhere except the branch's own commit message and the 0.7.21 coordination doc, and that doc itself explicitly disclaims landing.** There is no retraction because there was never an accepted claim — the work exists, was reviewed once (Sol APPROVE per the coordination doc), and was deliberately left un-integrated pending real titlebar/fullscreen/window-drag QA. Any statement to Dylan that "the titlebar was merged" would be **unsupported by `array/integration` HEAD** — `--window-chrome-check` does not exist in `ContinuumApp.swift` on that branch and is absent from `scripts/run-matrix.sh`.

---

## Gaps: claimed-fixed with no registered matrix witness
- **D (titlebar merge)**: `--window-chrome-check` — written, run once in isolation on the unlanded branch, never registered in `scripts/run-matrix.sh`, and the branch itself was never merged.
- **B (Home selector/blank home)**: no `--*-check` flag containing "home" exists in the app at all; the only coverage is CoreChecks' `AgentLocationChecks`/`AgentLocationPresentationChecks`, which do not test the specific "selector does nothing until restart" symptom.
- **A (0.5.16-era)**: the doc itself records a "pre-existing injected Home-persistence assertion" that the supervisor gate reaches but does not clear before its timer section — i.e., a known Home-persistence check exists but was not passing/running cleanly at that point, and it's unclear from the ledger whether it was ever resolved before being folded into later releases.
- **0.7.13 zone-drift hotfix (C)**: shipped with an explicit "the full matrix was not repeated for this focused one-file hotfix" — the fix's only gate evidence is the one extended witness plus manual Computer Use, not a real `run-matrix.sh` pass.
