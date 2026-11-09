# Stream 2: tidy latency and feel

Branch `array/aln-tidy-latency`, worktree `.worktrees/aln-tidy-latency`.
Measured 2026-11-08/09 on a shared, loaded Mac (load average 7–28 from other
helpers' builds), debug build.

## In short

Tidy and the drag release waited on two things we own before the tiles could
start moving:

1. **The disk write ran first.** A tidy or drag release wrote the layout to
   disk synchronously: each project's `canvas.json` read, verified and
   rewritten, plus the workspace document. Only after that could the run-loop
   turn end and the CA commit start the animation. Now the canvas commits the
   geometry and its animations to the screen first, then writes. The write's
   rollback-on-failure behaviour is unchanged (a refused write snaps back).
2. **Every moved tile redrew itself inside that commit.** The title bar
   compared the whole `Tile` record, frame included, so moving a tile
   re-typeset its title. The changed-tiles layout pass also called
   `invalidateForCanvasLayout` on every moved tile. A pure move draws nothing
   new; both now skip it. On an 89-tile tidy, sampled, title re-typesetting
   was the largest single cost of the commit.

The movement now starts 2–6 ms after the trigger at 4–30 tiles, and its
animations are committed before the disk is touched.

## Before / after (trigger → movement start)

"Movement start" is measured from the trigger to the `beginTime` CA stamps on
the first committed position animation: the moment the tiles start moving.
OLD is the fixes reverted with the instrumentation kept (the witness's teeth
run). NEW is the same session minutes later, same load. A second NEW run under
heavier load is included so the noise is visible. Medians of 5.

| scenario | tiles | OLD start ms | NEW start ms | NEW start ms (loaded run) |
|---|---|---|---|---|
| Tidy Zone Now | 4 | 8.3 | 2.0 | 2.6 |
| Tidy Zone Now | 12 | 12.1 | 4.6 | 5.1 |
| Tidy Zone Now | 30 | 33.9 | 12.4 | 27.4 |
| Tidy Zone Now | 89 | 144.8 | 75.9 | 104.4 |
| drag release | 4 | 5.9 | 1.9 | 2.2 |
| drag release | 12 | 7.7 | 3.9 | 3.3 |
| drag release | 30 | 25.9 | 6.3 | 8.4 |
| drag release | 89 | 37.1 | 13.9 | 15.3 |

Counted (deterministic), OLD → NEW:

| per tidy, n moved tiles | OLD | NEW |
|---|---|---|
| animations already committed when the durable write runs | 0 of n | n of n |
| title-bar invalidations on moved tiles | n (3n on the first run) | 0 |
| `invalidateForCanvasLayout` on moved tiles | n | 0 |

## Where the time goes (stages, ms, medians)

The first baseline, before any change (`qa-runs/aln-tidy-latency/before.json`).
Stages are the canvas's own clocks; layout/display/flush are the end of the
run-loop turn, which is where the animation's commit happened.

| scenario | n | solve | apply+animate | persist (disk) | notify | end-of-turn layout | CA flush |
|---|---|---|---|---|---|---|---|
| tidy | 4 | 0.1 | 0.6 | 3.8 | 1.5 | 0.8 | 2.1 |
| tidy | 12 | 0.4 | 1.5 | 4.3 | 1.9 | 1.9 | 3.8 |
| tidy | 30 | 2.4 | 2.9 | 4.9 | 1.6 | 5.0 | 12.9 |
| tidy | 89 | 60.2 | 10.6 | 6.9 | 2.0 | 13.1 | 27.1 |
| drag release | 4 | 0.1 | 0.7 | 3.7 | 0.0 | 0.5 | 1.1 |
| drag release | 30 | 0.6 | 1.5 | 4.9 | 0.0 | 1.0 | 3.7 |
| drag release | 89 | 2.8 | 2.9 | 6.6 | 0.0 | 1.3 | 5.1 |

After (NEW, `after.json`): persist and notify run after the movement has
started. The 89-tile commit's redraw share fell from 34% to 18% of solve time
(sampled), and `TitleBarView.draw` is gone from the commit.

### What still dominates, and whose it is

- **The solve at 89 tiles: 50–64 ms.** That's stream 1's packer
  (`CanvasAutoLayoutEngine.solve`, tidy branch / `compactMembers`); I did not
  touch it. At 4–30 tiles it costs 0.1–2.4 ms.
- **AppKit reacting to tiles moving: about 8 ms layout + 13–20 ms commit at
  89 tiles.** A view whose redraw policy is `.duringViewResize`, and every
  `NSTextView`, is redisplayed when an *ancestor* moves, and `NSScrollView`
  re-tiles. A control stack with no Array code shows the same thing
  (plain scroll view + text view + policy-2 view moved in the world plane: all
  three invalidated). This is per moved tile, once per tidy. Not changed; see
  "rejected".
- **Persist: 3–9 ms in the fixture (2 projects in the workspace).**
  `persistLayoutTransaction` reads the registry, then loads every project
  canvas in the workspace to find the moved tiles' owners, so it grows with
  project count and canvas size. It no longer delays the movement, but it still
  holds the main thread right after the movement starts. Next lever: load the
  projects that own the changed tiles first (from `tileZoneIds`), and fall back
  to the rest only for unplaced tiles.
- **The context menu itself: 26–35 ms** in `NSMenu.performActionForItem`
  before our action is sent. That's AppKit: `menu.update()` costs 0.03 ms and a
  bare `sendAction` costs exactly the tidy call. Whether real menu tracking
  pays the same is unverified.

### Things that turned out not to be causes

- **The 120 ms dwell timer** is not on the release path. A release re-solves at
  rest immediately (`settleAutoLayoutAfterMove`). The dwell only latches swaps
  mid-drag after a fast pass (.plans/107 design), untouched.
- **The debounced canvas save (0.2 s)** holds the main thread at most 2 ms
  in the 400 ms after a trigger (longest run-loop busy stretch, measured).
- **Per drag event:** 0.2–2.2 ms at 4–89 tiles, solve included.

## Animation

Kept at 110 ms ease-out. That's the duration the snap landing already uses
(`animateSnapLanding`), so tidy, push and landing move as one family, and it's
short enough to read as a response rather than a transition. The witness
asserts every animation's `beginTime` equals its commit (no added delay) and
that the commit precedes the write.

## Commits (local, not pushed)

- `a506289a` test(auto-layout): measure tidy and drag-release latency on the real path
- `4779794b` perf(auto-layout): start the movement before the layout write
- `0847a36c` perf(auto-layout): stop redrawing tiles that only moved
- `7e972a04` test(auto-layout): gate tidy latency on counts and the fastest run

What changed:
- `CanvasNSView.commitGeometryEdit` calls `presentGeometryBeforePersisting()`
  (window layout + display + `CATransaction.flush()`) before
  `persistGeometrySnapshot`. Only when a persistence callback exists and the
  canvas has a window.
- `TileNSView.mouseUp`: the snap-landing animation is set up before the
  commit. Set up after it, the tile would show at its destination for one frame
  first.
- `TitleBarView.tile` redraws on a `title` or `kind` change only.
- `layoutAllTiles(onlyChangedTiles:)` skips `invalidateForCanvasLayout` for a
  tile whose only change is its origin.
- `qaAutoLayoutStageTimes`: two clock reads per stage per pass, never per frame.

## The witness: `--auto-layout-tidy-latency-check`

Mounts the production scene (`WorkspaceInvariantsFixture` →
`mountWorkspaceSceneAtBoot`, launch's callbacks, so commits reach
`persistLayoutTransaction` and real stores) in an offscreen key window, with 4,
12, 30 and 89 untidy note tiles in one zone.

- **Tidy:** the zone header's context menu item, dispatched exactly as the
  menu dispatches it. `performActionForItem`'s own overhead is published.
- **Drag release:** a title-bar drag via `NSApp.sendEvent` with the production
  focus monitor (the `--canvas-pointer-path-check` pattern).

It asserts, per repetition:
- the moved tiles' animations are committed when the durable write runs;
- the animation begins at its commit;
- no title-bar or tile-surface invalidation on moved tiles;
- a wall-clock budget on the app-side stages (begin, apply, finish, capture,
  present layout and display), fastest of 5, budgets 6/10/20/50 ms. The solve
  and the CA flush are published, never gated.

Teeth: with the three fixes reverted it fails 78 times (39 "write before
movement", 39 "title bars redrawn"). Writes `qa-runs/aln-tidy-latency/<label>.json`.
Not added to `run-matrix.sh` (36 s, wall-clock half); the lead can decide.

## Tried and rejected

- **Changing redraw policies** (`.duringViewResize` → `.onSetNeedsDisplay`) on
  the title bar or on every policy-2 view in the tile. Measured as a runtime
  arm: no change to movement start within noise, because the title bar was
  being invalidated by the model write, not by the move. With that fixed, the
  remaining redraw is AppKit's text stack, and changing `NSTextView`'s policy
  risks stale or stretched content during a real resize. Not shipped.
- **Deferring the write to a later run-loop turn.** That would change
  `commitGeometryEdit`'s contract (a synchronous rollback that
  `--layout-commit-truth-check` and the jelly self-check assert), and needs
  ordering and quit-flush handling. Presenting first gets the same movement
  start and keeps the contract.
- **My first theory, that the CA flush was redraw from `invalidateForCanvasLayout`:**
  that fix alone left the flush unchanged. The sample named the title bar.

## Checks run (exit codes)

App legs, each with a disposable `CONTINUUM_APP_SUPPORT` and isolated
`TMUX_TMPDIR`, on the final code:

| leg | exit |
|---|---|
| `--auto-layout-tidy-latency-check` (twice) | 0, 0 |
| `--jelly-auto-layout-check` | 0 |
| `--layout-commit-truth-check` | 0 |
| `--canvas-pointer-path-check` | 0 |
| `--auto-layout-fanout-app-check` | 0 |
| `--spawn-arrange-commit-check` | 0 |
| `--canvas-undo-check` | 0 |
| `--tile-insert-slide-check` | 0 |
| `--camera-chrome-redraw-check` | 0 |
| `--drag-magnetize-check` | 0 |
| `--zone-arming-check` | 0 |
| `--zone-layer-move-check` | 0 |
| `--zone-move-unified-check` | 0 |
| `--ambient-tile-frame-space-check` | 0 |
| `--canvas-visibility-index-check` | 0 |
| `--perf-budget-check` | 1, pre-existing |
| `--perf-budget-gesture-transition-check` | 1, pre-existing |

The two perf legs fail identically on the base commit `0bb5fb19` (built and
run in this worktree): `canvas.zoom` tileLayoutPasses 96 over a budget of 12,
`canvas.magnify-slope`, and `gesture-transition.worstStepDuration` about 16 ms
over 8.3 ms. The last is wall-clock on a loaded machine. Neither touches the
code changed here.

Not run: the full matrix (team rule), and the change has not been seen in the
preview app.
