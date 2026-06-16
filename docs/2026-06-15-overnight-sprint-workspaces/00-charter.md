# Overnight Sprint — Workspaces & Zones (Charter)

Status: planning, 2026-06-15. This folder is the **execution spec** for one combined
workspace/zone sprint, decomposed into self-contained task files an autonomous agent
can run without further context. **Read `01-conventions-and-review.md` first** — it is
the non-negotiable working method + the review protocol every task agent and reviewer
follows.

Supersedes for *execution*: `docs/23` (multi-controller keystone — the backend half,
folded in here as tasks T03–T10), `docs/31` (the UX-vs-backend sequencing fork — now
resolved: one combined sprint), and `docs/33` (the shipped nav/snapping baseline this
builds on).

---

## 1. The settled conceptual model

**Workspace → Zones → Tiles.** A *workspace* is the top-level context you switch
between (sidebar top level). It owns *zones*. A *zone* is a named, colored, positioned
boundary that owns tiles. A *tile* is a terminal/browser/note/diff/etc.

**A zone is unopinionated; a project is an *optional* attachment.**
- **Project zone** — `ZonePlacement.projectId != nil`. Gives the zone a cwd, a lock,
  and a live runtime (`ZoneRuntimeController`). Its **tiles stay project-owned**: they
  live in that project's `ProjectStore` canvas (zone-local frames, exactly as today).
- **Group zone** — `projectId == nil`. Pure organization: a named/colored boundary
  around tiles. Its **tiles live in the workspace store** (new, T02). Tiles default to
  an *ambient* rootless runtime (cwd = `$HOME`/configurable).

### Why project-owned tiles (the load-bearing decision)
The keystone shares **one `ZoneRuntimeController` per `projectId`** (one lock / one PTY
set / one WKWebView set, ref-counted across workspaces — CON-58). If tiles were
workspace-owned, the same project shown in two workspaces would have two tile sets over
*one* shared runtime — the PTY↔tile mapping breaks. Project-owned keeps one project =
one canvas = one runtime = consistent everywhere. Cost: a project looks the same in
every workspace (acceptable; a project appears in one workspace in the common case).
A nice consequence: **membership needs no global `tile.zoneId`** — a project zone's
members are that project's canvas; a group zone's members are its own stored tile list;
docs/23 D1 caps one zone per project per workspace, so there's no ambiguity.

### Zones adapt their size to their tiles
A zone's drawn bounds = `union(member tile frames) + padding`, recomputed live as tiles
move/grow/shrink; an empty group zone uses a default min size; the header sits above the
union. **v1 allows zones to overlap** (no neighbor auto-reflow — deferred). Dragging the
zone chrome moves the whole zone (tiles ride along).

### Zones are named, colored, and individually keybindable
`ZonePlacement` gains `name: String` and `navKey: String?` (color already exists). The
nav-key is the zone's jump key in the leader (nil = auto ordinal). Editable inline in the
sidebar and via ⌘K.

### Persistence — three nested layers
1. **Bulletproof restore** (baseline): live tile/zone/size/viewport state auto-persists
   (debounced, atomic, restore-from-backup on corruption). Survives quit/reboot/crash.
   **Session-resume is part of this**, and *resumable ≠ live process*: terminals persist
   cwd + a scrollback snapshot (reuse the existing terminal-snapshot infra) and re-open a
   fresh shell in cwd; browsers persist WKWebView `interactionState` (full
   back/forward/scroll/form). No PID survives a quit — that is the honest ceiling, and
   it is still "unlike tmux" because it survives a cold reboot from disk.
2. **Profiles / snapshots**: a *named saved workspace layout*, applied two ways —
   **restore-over** (a backup/restore-point of this workspace) or **instantiate-as-new**
   (a template). Captures session-state for a snapshot; layout-only for a template. A
   thin layer over the same serialized document, not a separate system.

### Sidebar — two-level source list
An `NSOutlineView` left source list: **workspaces (top) → zones (nested)**. Each row:
name, color swatch, inline rename, per-zone nav-key editor, collapse/expand. Click a
workspace = **in-process switch** (the keystone, no relaunch); click a zone = pan/focus
to it. ⌘K stays the keyboard-fast path (extended with zone rows). Collapsible inset
split (not an overlay).

### Deferred to v2 (explicitly out of scope here)
Dragging a tile **between a project zone and a group zone** (content migration + cwd
loss — the one genuinely hard membership case); neighbor auto-reflow on zone overlap;
cross-zone `⌥`+arrow dock; multi-window; the docs/23 S9 lock-degradation merge (stretch).

---

## 2. Execution model — combined sprint, *staged*

This is a program, not a single night. The overnight Workflow run lands the **checkable
foundation**; the **AppKit feel layer** is a short co-verified morning pass. The split is
by *verifiability*, not by feature:

- **Overnight (autonomous):** anything whose correctness a real-path/Core check proves
  headlessly — the model change, the keystone S1–S9 (each with a swap-invariant check
  that asserts focus scope, adapter registration, installed layers, and viewport after a
  synthesized switch), persistence layers, profiles store, the sidebar's *pure
  view-model*, and the *pure gesture math*. Built TDD, adversarially reviewed, committed
  per task with the fast matrix green.
- **Morning (human co-verified):** the genuinely *visual* AppKit shells the night
  scaffolded against tested view-models — the sidebar `NSOutlineView`, on-canvas
  drag-to-create-zone / move-zone gestures, and visual polish (flicker, z-paint, cursor
  rects, feel). These are short because the foundation + view-models are done and tested.

**Rule:** a task tagged `[morning]` may be *implemented* overnight but **must not be
auto-committed as Done** — it lands on a branch / is left staged with its diff + a note,
for human verification. `[overnight]` tasks commit when their check + matrix are green.

---

## 3. Task index (dependency-ordered)

| # | Task | Tag | Depends on | Guarding check |
|---|------|-----|-----------|----------------|
| T01 | Zone model: optional `projectId` + `name` + `navKey` (+ doc migration) | overnight [pure] | — | Core round-trip + migration table |
| T02 | Group-zone tile storage in the workspace store | overnight [pure] | T01 | Core store round-trip |
| T03 | `ZoneHydrationOrchestrator` (pure planner, docs/23 S1) | overnight [pure] | — | `--zone-hydration-plan-check` |
| T04 | `ZoneRuntimeRegistry` per-projectId, ref-counted (S2) | overnight [pure] | — | `--zone-registry-refcount-check` |
| T05 | Mutable canvas: `ZoneLayer` set, per-layer layout+hit-test (S3) | overnight [appkit-checkable] | T01 | compat / multi-zone-render / zindex / world-bounds |
| T06 | `WorkspaceRuntime` shell + AppDelegate proxy (S4) | overnight [appkit-checkable] | T03,T04,T05 | full matrix + focus-broker + save-isolation |
| T07 | `BrowserRuntimeBudget` over union of live tiles (S5) | overnight | T06 | `--browser-lru-budget-check` |
| T08 | `addZone` spins real controller + ambient controller for group zones (S6) | overnight [appkit-checkable] | T06,T02 | extend `--add-zone-check` |
| T09 | `switchWorkspace` in-process; retire relaunch (S7) ⚠ | overnight [appkit-checkable] | T06 | `--workspace-switch-check` (swap invariants) |
| T10 | Viewport-driven tier transitions (S8) | overnight | T06 | `--zone-tier-transition-check` |
| T11 | Adaptive zone bounds (union+padding, live) | overnight [pure+wiring] | T05 | Core bounds table + real-path recompute check |
| T12 | Bulletproof restore: debounced atomic autosave + crash-safe reload | overnight | T01,T02 | `--persistence-crash-safe-check` |
| T13 | Live-session resume: terminal cwd+scrollback, browser `interactionState` | overnight | T12 | `--session-resume-check` |
| T14 | Profiles/snapshots: store + restore/instantiate modes + session toggle | overnight | T12 | `--workspace-profile-check` |
| T15 | Sidebar view-model (pure tree from Registry + WorkspaceDocument) | overnight [pure] | T01 | Core sidebar-model table |
| T16 | Sidebar `NSOutlineView` (name/color/navKey/switch/jump) | morning [appkit] | T15,T09 | `--sidebar-check` + human feel |
| T17 | ⌘K zone rows (jump-to-zone, create-zone) | overnight | T01 | extend palette Core + `--palette-zone-check` |
| T18 | Per-zone nav keybind + zone-jump in the leader | overnight | T01 | `--leader-zone-jump-check` |
| T19 | On-canvas drag-to-create-zone + move-zone gesture | morning [appkit] | T05,T11 | `--zone-create-gesture-check` + human feel |

S9 (lock-degradation merge from `wip/con-50-zone-lock-degradation`) is a **stretch**, not
in the critical path.

### Suggested overnight wave order (parallelism the Workflow can exploit)
- **Wave 1 (no deps, parallel):** T01, T03, T04.
- **Wave 2:** T02, T05, T15 (after T01) · T11 (after T05).
- **Wave 3:** T06 (after T03/T04/T05) → then T07, T08, T09, T10.
- **Wave 4:** T12 → T13, T14 · T17, T18 (after T01).
- **Morning:** T16, T19.

---

## 4. Sprint success criteria
- A workspace switch is **in-process** (no relaunch) and headless checks prove focus
  scope, runtime registration, installed zone layers, and viewport are correct after it.
- A **group zone** (no project) can be created, named, colored, holds tiles, and
  persists across quit/relaunch.
- Zone bounds **adapt** to their tiles live.
- Quit → reboot → relaunch restores the full layout **and** resumable session state
  (cwd/scrollback/browser session).
- A workspace layout can be **saved as a profile** and restored or instantiated.
- The fast matrix is green; every new behavior has a real-path check; `[morning]` AppKit
  shells are co-verified by Dylan before they count as Done.

---

## 5. How to use this folder
1. Read `01-conventions-and-review.md` (working method + task template + review protocol).
2. Pick the lowest-numbered task whose **Depends on** are all Done.
3. Execute it exactly (write its check RED first → implement → matrix green).
4. Review it against its **Review rubric** (or hand to a reviewer agent) before marking Done.
5. `[morning]` tasks stage their diff for Dylan; do not auto-mark Done.
