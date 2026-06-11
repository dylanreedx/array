# Product Vision — Continuum Revived v1

Status: adopted 2026-06-10. This is the alignment document for all implementing
agents. When a ticket, plan, or instinct conflicts with this doc, this doc
wins; if this doc is wrong, change it deliberately (ADR + edit), not silently.

## North star

**Mission control for AI coding agents, native on macOS.**

One window. All of Dylan's projects live on a spatial canvas as visual zones.
Inside each zone: real terminal sessions (Ghostty), live AI coding agents with
visible status, browser tiles that behave like his real browser, notes, file
trees, and diff-review surfaces. Navigation is keyboard-first (vim/tmux
instincts). The app replaces a Desktop-per-project macOS workflow.

Reference points: Nyx (getnyx.dev — canvas density, agent tiles, focus mode,
diff review) and Ona (ona.com — background agents producing reviewable work;
our later layer). We are not cloning either; we are building the native,
local-first, harness-integrated version for a terminal-first developer.

## V1 capabilities (committed)

1. **Zoned multi-project canvas** — every registered project is a zone on one
   canvas; tiles live inside zones; zones are visually grouped (chrome,
   color, name). Multiple canvases ("workspaces": e.g. work / personal) with
   fast jumping.
2. **Keyboard-first navigation** — a leader-key "nav mode" (tmux/vim style):
   jump between zones, tiles, and agents without the mouse; ordinal jumps;
   typed pickers; Escape returns focus exactly where it was.
3. **Agent tiles** — Claude Code / Codex / any CLI agent as first-class tiles:
   live PTY with status inference (working / idle / needs-attention / done),
   zone-level status rollup.
4. **Agent harness bridge** — the canvas can spawn, watch, and review runs
   from the pi/conductor setup (`.pi/agents/` roles, `.conductor/conductor.db`
   task queue, `run.json`/`final.md`/`events.jsonl` artifacts, `qa-runs/`
   verdicts). Opinionated: we build for our harness first, generalize later.
5. **Diff review tile** — review a worktree/branch diff on-canvas like a PR;
   send feedback to an agent without copy-paste (v1: read + comment file;
   flyback via harness prompt).
6. **Real-browser tiles** — persistent credentials, cookies, localStorage via
   per-profile persistent `WKWebsiteDataStore`s; profile picker per tile;
   good-enough-to-test-your-app fidelity.
7. **Focus mode** — collapse the canvas to one tile + one agent split pane;
   Escape restores the canvas exactly.

## Explicit v1 non-goals

- No agent-to-agent cables/wiring, no rope physics, no routines.
- No cloud execution, no SSH workspaces (Ona-style background fleet is a
  POST-v1 epic that reuses the harness bridge).
- No import of actual Chrome/Safari profiles — persistent WK data stores
  only; document the boundary honestly.
- No native code editor (Neovim profile + external editor handoff stays,
  per ADR-0007). Editor tile is post-v1.
- No todo-inbox tile in v1 (the conductor queue tile covers "what's next").

## Architecture (decided 2026-06-10; ADR-0023)

### Zone model — hybrid ownership

- New Core type `Zone`/`ZonePlacement`: `{zoneId, projectId (registry UUID),
  origin (world coords), size, color, collapsed, hydrationPolicy}`.
- A central **workspace document** owns zone placements + canvas viewport:
  `~/Library/Application Support/continuum-revived/workspaces/<workspaceId>/canvas.json`
  (own schemaVersion, AtomicWriter policy).
- **Project tile state stays project-local** in `.continuum-revived/`
  (ADR-0004 preserved). Tile frames are zone-local; world = zoneOrigin +
  tileFrame. Existing project state is byte-compatible (zone origin 0,0).
- Folder moves: repair only the registry path; zone references survive.
- `TileGroup` is NOT a zone — groups remain flat visual grouping *inside* a
  zone.

### Hydration tiers (the performance contract)

Per-zone, driven by viewport intersection (pure `CanvasEngine` math):
- **Live**: real Ghostty surfaces / WKWebViews / text views installed.
- **Snapshot**: views torn down to cached bitmaps; terminal PTYs stay alive
  (spike: headless Ghostty surfaces; fallback hidden surfaces); WKWebViews
  torn down to snapshot + descriptor (the existing restart-placeholder
  pattern).
- **Cold**: descriptor-only (existing boot-restore rendering).
Global LRU budget on live WKWebViews (~6-8) across all canvases. Perf
ceilings enforced in `ContinuumRevivedPerfChecks`.

### Multi-canvas

Canvas = existing `WorkspaceEntry` in `Registry.swift` (id, name,
projectIds — already modeled, unused at runtime). One window, swap canvas
in place; switch = dehydrate → swap workspace doc → hydrate visible zones.
Window-per-canvas is explicitly deferred (focus matrix cost).

### Navigation

Nav mode = a `FocusModalKind.navMode` on the existing FocusBroker. Leader
chord enters it; a local keyDown monitor hard-captures all keys (same
machinery as the palette capture). Semantic actions: directional tile jump
(`CanvasEngine.nearestTile(from:direction:)`), zone next/prev/ordinal/typed,
workspace jump, agent cycle / jump-to-needs-attention, focus-mode toggle.
Leader-leader passes the literal chord through to terminals (tmux safety).

### Agent tiles & harness

Agent tile = terminal session descriptor + `agentDescriptor` extension
(agent kind, worktree path, status). Status via OSC/title parsing or
agent-emitted status file; rollup per zone. Harness bridge reads/writes:
conductor sqlite (task queue), `.pi/agent-runs/<id>/run.json` (status),
`final.md` (results), spawns via the documented CLI invocations. Zones may
reference git worktrees of another zone's repo (`ProjectEntry.worktreeOf`).

### Staged migration (no big bang)

0. Finish in-flight focus broker work (docs/17) and spawn experience
   (docs/19) — both remain valid.
1. docs/18 Phases A/B/D as planned; Phase C retargeted to extracting a
   per-project `ZoneRuntimeController` from the AppDelegate god object
   (stores, runtime dicts, debounce timers, broker registrations — instanced
   per project). Single-instance lock becomes per-hydrated-project; lock
   failure degrades that zone to cold with a badge.
2. Zone model with exactly one zone wrapping the current project.
   Behavior-neutral; matrix green with zero semantic changes.
3. Multi-zone + hydration tiers + zone chrome. Riskiest stage; gated by the
   LRU budget and a `--zone-hydration-check`.
4. Multi-canvas workspaces.
5. Nav mode.
6. Parallel tracks: browser profiles, agent tiles, harness bridge, diff
   tile, focus mode.

### Top risks (carry into every design review)

N live WKWebViews/PTYs (mitigation: tiers + LRU + perf ceilings) · focus
matrix growth (mitigation: everything routes through FocusBroker, no
side-channel makeFirstResponder) · AppDelegate extraction (mitigation:
behavior-neutral refactor gate) · write amplification (per-zone dirty
tracking; only hydrated zones write) · zone-local vs world coordinate bugs
(transforms only in CanvasEngine, CoreChecks tables) · headless PTY support
(spike before stage 3) · leader-key vs tmux (leader-leader passthrough).

## How work is organized

The backlog lives in **Linear, team `continuum`** — epics as projects,
tickets follow the template in `docs/21-agent-workflow.md`. The legacy
`docs/16-daily-driver-backlog.md` is superseded (absorbed into Linear).
Development is trunk-based on `main`; the check matrix
(`docs/15-repo-audit-2026-06-10.md` §5 plus every flag added since) is the
regression contract; `qa/run-autonomous.sh` is the session gate.
