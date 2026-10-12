# 70 — Confidence pass (2026-10-11)

Dylan stopped using Array for weeks: "it generally just feels unstable", fixes
"pop up again", switching workspaces "doesn't feel confident", an agent tile
feels like "throwing it into a void", he has never liked the transcript, and the
sidebar keeps rows for tiles he deleted. Goal: make him confident using the app.

Staging branch: `array/confidence-pass` (bench `.worktrees/confidence-pass`),
based on `array/0726-agent-parity` @ 6c5c5418 — 0.7.26 is not landed yet, and
everything here builds on it. Nothing lands on `array/integration` or is pushed
without Dylan's go.

Investigation reports (session f2f82ace scratchpad, `reports/`): A history, B
workspace switch/delete, C agent tile, D sidebar vs T3 nightly, E transcript,
F1 canvas/persistence, F2 tiles/agents, G prod state (read-only copy).
Design previews: https://claude.ai/artifact/7G165TUnPoAt5AnQdZutKB

## What the investigation established

1. **"The active project" as a global** is behind most data loss: AppDelegate's
   `runtimes`, `browserRuntimes`, `noteViews`, `fileTreeViews`, `projectStore`,
   `tileSpawner` resolve to the armed zone's project, and are called from code
   that acts on a tile in another project (note edits lost or written into the
   wrong `.array/notes`, close leaves the process and the canvas entry, quit
   frees only the active project's Ghostty surfaces).
2. **Zones without a layer.** Off-screen/over-budget zones never get a
   `ZoneLayer`; spawns there fall to the retired flat model (blank "—" agent).
   The fix `201b37e9` (`array/zone-layer-on-arm`) was never merged.
3. **Tiles stranded by dead zone ids.** Zone close "Delete Tiles" on a project
   zone keeps them, workspace delete keeps them, and the next mount sets them
   aside forever. Dylan's real data: 46 of 49 tiles sit in zones no registered
   document holds (harmony shows 3 of 21; selectus an empty zone).
4. **Unreadable `canvas.json` reads as empty** and is then saved over.
5. **The sidebar is a list of agent records, not of tiles.** A busy agent's
   close is refused and never retried; subagent children are never closed and
   get promoted to top-level rows; unreachable tiles stay Active; default scope
   is "All"; every push re-reads every project's files on the main thread.
6. **Workspace switch** is one blocking main-thread operation: a sidebar reload
   per restored tile (~450 file reads), every runtime torn down and rebuilt
   (terminals marked exited, tmux spawned synchronously), file editors waited on
   for up to 5.5 s each, no feedback until done, failures logged to stderr only.
7. **The agent "void"**: four independent status signals overwrite each other
   (codex/pi show Idle with Send disabled between "ready" and turn start);
   silence is not modelled (no heartbeat, retries dropped, stderr dropped);
   failures lose their reason (Claude API errors render as "success", a crash
   reads "You stopped", repeated refusals show nothing).
8. **Composer**: the ⌥ hold-leader swallows ⌥↩ (queue) and ⌥-arrows/⌥-chars in
   every text field; force-sends dropped/replayed after Stop; stranded steers.

## Decisions taken (defaults until Dylan says otherwise)

- Sidebar stays a lifecycle inbox (that *is* T3 nightly's default), scoped to
  the current workspace, derived from tiles + records, Settled/History folded.
- Closing a busy agent's tile records the close at once; the row shows
  "Finishing" and leaves when the turn ends. The agent is not stopped.
- Subagents nest under their parent and travel with it.
- Transcript: direction C (turn cards with a live head) pending Dylan's pick;
  the presence/honesty layer underneath is direction-independent and goes first.
- Plan 67 D1–D4 keep their recommended defaults. Stranded-tile repair is
  *offered*, never silent (D3): a visible notice with Recover.

## Streams

| # | Bench / branch | Scope | Reports |
|---|---|---|---|
| S1 | `cp-project-scope` | Kill active-project accessors at every per-tile call site; quit/window-close frees every project's surfaces; restored terminals get exit handlers; restarts/placeholders on the zone path | F1 #1 #2 #6 #8, F2 #1 #2 #10 #12 |
| S2 | `cp-zone-truth` | Port `201b37e9`; layer on demand for any spawn/arm; `retireFlatCompatibilityScene` empties the flat list; membership moves read the layer; unreadable ≠ empty; zone close / workspace delete never strand; offered recovery of stranded tiles; layout commit reports missing tiles | F1 #3 #4 #5 #7, B D1 Z2–Z5, G |
| S3 | `cp-agent-presence` | One owner for turn presence from Return; refusals carry reasons and mark "Not sent"; real error text, crash ≠ Stop, stderr captured; heartbeat / retries / dead-process; status line honest during long tools | C P0-1..P1-6 |
| S4 | `cp-sidebar` | R1–R6 (closeRequestedAt, children follow parent, unreachable = closed, per-root isolation, in-memory push, workspace scope) + coalesced reloads + T3-nightly layout | D §2–§4, B #1, A #4 #5 |
| S5 | `cp-workspace` | Switch: no terminal exit-stamp on leave, tmux off main, editor wait bounded, re-entrancy guard, instant feedback + failure UI, camera restore, no lock modal mid-switch, registry disagreement tolerated; delete/create/rename D2–D5 C1 C2 | B |
| S6 | `cp-composer` | ⌥ leader dwell/scope, force-send B1/B2, stranded steers B3/B4, logged-out message, /compact MCP, Pi stderr | F2 B-items |
| S7 | `cp-tiles-misc` | Terminal copy/paste, focus grab, diff review git off main, notification title/API, Esc cancels zone rename, prod-visible debug menus, onboarding codex stderr | F2, A #13 |
| S8 | `cp-transcript` | Direction C after Dylan's pick | E |

Rules for every stream: CLAUDE.md in full; RED-then-GREEN witness per fix,
registered so the matrix prints it; no `git stash`; never touch
`/Applications/Array.app`, `~/Library/Application Support/Array`, any real
project's `.array/`, or the default tmux socket; commits as Dylan, subject
`type(area): description`, no attribution trailers.

## Status

- S1 merged (b1fd4fa0): `--tile-project-scope-check`; follow-up S1b in progress.
- S2 merged (35a5755c): zone layers on spawn, unreadable canvas never overwritten,
  zone close never strands, offered recovery, truthful layout commit; S2b
  (copies excluded from recovery, hazard 9) in progress.
- S7 merged: clipboard, focus, Cmd-W, diff review off main, notification naming,
  Esc cancels rename, prod menus, codex stderr, MCP config failure, browser
  recency, language-server release.
- Merged head verified: S1/S2/S7 legs green. Terminal legs need the display awake
  (`caffeinate -u`); a locked screen reads as "terminal surface missing".
- S3 (presence), S4 (sidebar truth), S5 (warm switch, delete/create/rename,
  registry ownership once), S1b, S2b merged; agent-status check fixed (it never
  seeded the registry the sidebar inputs now read).
- Full matrix on a5cfba13: 268 legs, 10 KNOWN-RED as before, 6 regressed:
  agent-status (fixed), zone-presentation (warm re-attach header), browser-lru
  (budget ignores warm scenes), zone-tile-detach-sweep (warm contract),
  ui-geometry (failed tool vs failed turn), agent-supervisor (branch chip).
  Sent back to S5/S3. Inventory regeneration pending a clean run.
- In progress: S4b (sidebar layout), S6 (composer), S8 (transcript C).

## Handoff (2026-10-12, session wrapped for usage)

Resume here. Staging: `array/confidence-pass` (bench `.worktrees/confidence-pass`).
Nothing is on `array/integration`; nothing is pushed; `/Applications/Array.app`
and Dylan's real state were never touched (read-only copy audit only).

Merged at wrap: S4b sidebar layout, S5b warm re-attach (headers, parked agent
tiles detach), S6 hold-⌥ leader only, S8 turn cards (switch OFF:
`AgentTranscriptPresentationStyle.current = .rows`; witness
`--transcript-turn-cards-check`).

Left, by bench (uncommitted work stays in the bench):
- `cp-agent-presence`: uncommitted ui-geometry assertion migration (failed tool
  ≠ failed turn); real leftover — an unattached agent tile can show the gyro.
- `cp-workspace`: one global browser budget across warm scenes
  (`--browser-lru-budget-check` red); eviction-cancels-once assertion.
- `cp-composer`: uncommitted, non-compiling `--agent-steering-recovery-check`;
  items 2–7 (force-send drop/replay, stranded steers, queue stall/Resume,
  /compact MCP, background claude work, quit flush, codex steer, pi bridge).
- `cp-transcript`: migrate rhythm/page-zoom legs, 14/22 answer, slimmer log
  rows, send anchoring, sticky strip, then flip the default; Phase 2 LOD.
- `cp-sidebar-fold-migration-wip`: remove `foldsSettledIntoShelf` (J3 red).
- `--nav-mode-check` (KNOWN-RED) now fails on a different assertion.
- Final matrix log: session scratchpad `matrix-final.log` (head before S8).

Gate before Dylan reviews: full `scripts/run-matrix.sh` with
`CONTINUUM_SKIP_UI_BASELINES=1`, `env -u TMUX -u TMUX_PANE`, and `caffeinate -u`
(a locked screen makes terminal legs fail with "terminal surface missing").
Then regenerate the inventory once on a clean run
(`CONTINUUM_UPDATE_MATRIX_INVENTORY=1`). Then dogfood in the preview app
(`scripts/dev-app.sh`) — switch A→B→A, delete a workspace, close a busy agent
tile and watch its sidebar row, send to claude/codex/pi and watch the strip.

Open decisions for Dylan: transcript A/B/C (previews link above; C assumed);
busy-tile close = "Finishing" vs stop; subagents nested vs hidden.
Known open items: P2 persistent codex process; Recover has no undo (backups
only); deleting a workspace leaves its tmux sessions running; boot sweep of
orphan workspace dirs; retry wire formats verified against fakes only.
Benches to return when merged: every `.worktrees/cp-*`.
