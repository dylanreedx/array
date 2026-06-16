# Morning Report — workspaces/zones overnight sprint

Branch: **`overnight/workspaces-zones`** (off `main`, 25 commits, pushed). **Nothing merged to `main` — your call.**
Fast matrix **green** · `swift build` **clean**. Per-task evidence in `runs/Tnn/{launch,build,review,result}`.
Triaged checklist: **`REVIEW.md`** (open that to review). Commit spine: `git log --oneline main..overnight/workspaces-zones`.
Rebuild for visual gates: `./scripts/make-app-bundle.sh --configuration release --output ~/Applications/ContinuumRevived.app && open ~/Applications/ContinuumRevived.app`

## 0. The two-line summary
The entire workspaces/zones model + keystone runtime + persistence + palette/nav is **built and headlessly verified** (16 committed, 1 staged). **Two things gate it from being live**, both deliberately left for you: **T20** (wire the boot registry factory → makes ⌘K-switch/add-zone/tier actually work) and a **session-bundle bridge** (→ makes profile snapshots meaningful). One task is **blocked** (T16 sidebar — its check hangs headlessly; code preserved).

## 1. DONE — committed + verified (16 + 1 staged)
| Task | sha | Guarding check |
|---|---|---|
| T01 zone model (optional projectId+name+navKey) | `6aa283d` | CoreChecks T01 (v2 round-trips + v1→v2 migration) |
| T02 group-zone tile storage | `390079a` | CoreChecks T02 (8 assertions, real WorkspaceStore save→load) |
| T03 ZoneHydrationOrchestrator | `0b39c8c` | `--zone-hydration-plan-check` (13; bypass disproved 2 ways) |
| T04 ZoneRuntimeRegistry (ref-counted) | `974c2fa` | `--zone-registry-refcount-check` (=== identity, close via throw) |
| T05 mutable ZoneLayer canvas | `70a77e1` | `--multi-zone-render-check` + compat/zindex/world-bounds |
| T06 WorkspaceRuntime shell | `93c68f4` | `--workspace-runtime-install-check` (10 + budget/chrome probes) ＋fixer |
| T07 browser budget over live union | `4ba7eac` | `--browser-lru-budget-check` multi-zone phase |
| T08 addZone (project + ambient group) | `a18b1ac` | `--add-zone-check` ＋fixer (lock + tile-routing) |
| T09 switchWorkspace in-process | `1818510` | `--workspace-switch-check` (8 swap invariants) |
| T10 viewport tier transitions | `1d7924a` | `--zone-tier-transition-check` ＋fixer (coalescing + planner-pin) |
| T11 adaptive zone bounds | `16806b1` | `--zone-adaptive-bounds-check` (remove hook → RED) |
| T12 bulletproof restore (atomic+crash-safe) | `ddd0795` | `--persistence-crash-safe-check` (14) |
| T13 live-session resume | `87de37f` | `--session-resume-check` (14) ＋fixer (bypass + bound) |
| T14 profiles/snapshots | `192e44e` | `--workspace-profile-check` (store + restore-over/instantiate) |
| T15 sidebar view-model (pure) | `b3728fc` | CoreChecks sidebar-tree (11; bypass disproved 3 ways) |
| T17 ⌘K zone rows | `4872bac` | `--palette-zone-check` ＋fixer (re-tightened nav-mode + config) |
| T18 per-zone leader nav-key jump | `564244d` | `--leader-zone-jump-check` (8) ＋fixer (precedence + validator) |
| **T19 drag-to-create/move-zone** | `b11085d` | `--zone-create-gesture-check` — **STAGED 🌅 (visual gate, not Done)** |

## 2. ⛔ HEADLINE — what's between "verified" and "live"
1. **T20 — boot registry factory (HIGH).** The keystone (T06–T10) is built + verified, but the live `WorkspaceRuntime` is constructed at boot with a **throwing placeholder registry factory** (immutable `let`, no swap-in seam). So in the running app, `addProjectZone` / `switchWorkspace` / tier-reconcile throw on the first project acquire → **⌘K-switch and add-zone silently no-op live** (T09 removed the relaunch fallback). Every T06–T10 check passes because each **injects a real registry**. Spec stub + 3 design questions: **`T20-wire-boot-registry-factory.md`**. *This is the #1 thing to decide/wire.*
2. **`WorkspaceDocument` is layout-only.** Session-state (terminal scrollback, browser `interactionState`) lives in ProjectStore sibling stores, not the document — so **profiles (T14) are layout-only**; snapshot-vs-template is inert without a **session-bundle bridge** (decide if/where it lands).

## 3. Staged / blocked morning AppKit
- **T19 (staged 🌅)** — committed + headless-checked (real mouse-event synthesis), but the *feel* needs your eye (rebuild the bundle): create-marquee tracking + landing pop (empty zone snaps to 480×320 min), move-as-rigid-group, **render-model move snap-back** (move a zone then pan/zoom — chrome must not revert to old origin), z-paint, cursor rects, 24px threshold, overlap, pan/zoom-anchored at 0.5×/2×. Full list: `runs/T19/result.json`.
- **T16 (BLOCKED ⛔)** — sidebar `--sidebar-check` **hangs headlessly** (spins an AppKit run loop, never terminates — wedged the matrix 3×). Killed + reset; **sidebar code preserved** at `runs/T16/WorkspaceSidebar.swift.reference` (+ `SidebarChromeConfig`). Needs a **headless-safe check** (model on `runNavModeSelfCheck`'s synchronous NSEvent drive, `timeout`-wrapped) + clean rebuild. **Recommend we pair** — it's your top remaining piece and ~an hour with the right pattern.
- **Visual gates blocked-pending-T20:** live ⌘K switch (T09/T06) + pan/zoom demote/promote (T10) can't be exercised until the boot registry is wired.

## 4. Decisions for you (full 🔴 list, see REVIEW.md)
- **T20** boot registry (HIGH) · **T16** sidebar check rewrite · **session-bundle bridge** (T14).
- **T17** nav-z default action shifted (now highlights a zone-jump/Create-Zone row, not the matching project — Enter changed meaning; check pins it). 
- **T18** zone-jump target = zone-fit not last-active-tile · zone-key-beats-tile-label precedence · zone-jump HUD badge not drawn.
- **T07** focus-mode eviction protection dropped (regression) · **T06** windowWillClose quit-flush ordering (after force-terminate) + optional-chained attachUI · **T09** shape-B (descriptor-only active tiles) · **T08** group zone writes `$HOME/.continuum-revived` (dormant) · **T12** fsync now in shared AtomicWriter + no live autosave caller · **T13** OSC-7 shell dependency + scrollback replay deferred.
- Ratifications: **T15** `?? ""` name fallback · **T01** navKey config split · **T03** Max-Live-Zones field validation · **T04** closeOnZero knob · **T05** per-zone focus surface.

## 5. Fixer-intervention log (the adversarial review earned its keep)
Each was **caught before commit** by the independent Opus review, fixed by a focused fixer, then re-gated:
- **T06** — strengthened install-check assertion 5 (was membership-only → now asserts placement projectId/origin/size; catches swapped placements) + orphan removed.
- **T08** — added the spec-required `acquireLock:false` lock assertion + replaced a **tautological** group-tile assertion with a real workspace-store round-trip + ProjectStore isolation (both RED-confirmed).
- **T10** — assertion that "proved" debounce was vacuous → now proves **coalescing** (pre-flush count==baseline); added the planner `focusedTileZone` pin coverage.
- **T13** — caught a **CONFIRMED BYPASS** (scrollback gate re-implemented inline) → now drives the real flush; made the `maxLines` bound actually tested. (2 builder iterations.)
- **T17** — re-tightened a **weakened existing check** (`--nav-mode-check` had been loosened to hide the nav-z UX shift) + added a config round-trip. *(Its first workflow run **stalled** on agent infra → cleaned + re-launched fresh, succeeded.)*
- **T18** — fixed a real operator-precedence bug in the key validator (non-ASCII numerals wrongly accepted) + added a reject test + hardened a fragile assertion.
- **T16** — review/orchestrator caught the **hanging check** → blocked rather than ship a CI-wedging check.

## 6. Branch + suggested merge order
Branch `overnight/workspaces-zones` (25 commits, pushed); fast matrix green, `swift build` clean.
Suggested review/merge order: **model** (T01–05, T11, T15) → **keystone** (T06–T10) → **persistence** (T12–14) → **palette/nav** (T17–18) → **T19/T16 after the visual gate**.
⚠ **Live keystone + profile behavior is gated on T20 (boot registry) + the session-bundle decision** — merging the keystone without T20 ships an inert ⌘K-switch. Recommend wiring T20 (or explicitly accepting inert-until-then) before/with the merge.
