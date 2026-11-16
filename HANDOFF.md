# Transcript retention gate — 2026-11-16

**Not gated. Keep the card in Doing; do not ship this branch.** Checkout:
`.worktrees/transcript-retention`, branch `array/transcript-retention`, base
`4c9d7495`. No push. Committed through `b8a94c7b`: retention/recovery, render
A/B evidence, archive guard, restore-only witness and deterministic tail fence.

The uncommitted valid-restart reconciliation, migration/retry, bounded replay,
performance witness and related checks are a draft. The latest bounded-replay
and migration-failure changes have not been built or run. Release lead has
prioritized the release preview build; do not start a transcript build until it
is complete. Then wait in 120-second loops for the build preflight below.

## Evidence

- Clean base render A/B: base aqua 1.7548%, dark 0.8304% (0.0300% tolerance),
  byte-identical PNGs to an earlier branch repeat. Adjacent branch light varied.
  The same failure exists on base; no baseline was changed. Artifacts remain at
  `/tmp/array-render-ab.Sd8AsMB9-base` and `...-branch[-paired]`.
- Retention GREEN on the last built draft passed in 115.6 s: 3 transcripts
  held, 2,197 released, 2,269 events, heap -14.3 MB. All witnesses are invoked
  from the existing matrix retention leg; no full matrix was run. That build
  predates the latest uncommitted changes.
- Save guard, restore-only, strict reload and stale buffered tail all failed
  their specific RED controls and passed GREEN. Reconciliation RED omitted the
  canonical model and failed as expected; six combined RED controls detected
  notice loss, early quarantine, incorrect census, dropped saved turn, rejected
  flush and ambiguous compaction. Open-history and historical-card/high-water
  controls also failed as intended. Migration barrier, retry FIFO, and absence
  after failed read each failed their corresponding RED controls. The bounded
  replay and latest migration-failure witness still need RED/GREEN runs.
- Resumed-stream COW witness RED moved the entries buffer on 240/240 appends;
  GREEN moved it on 0/240. GREEN large-archive streaming median 0.096 ms,
  p95 0.125 ms; the complete targeted leg took 49.7 s in that run. Timing
  samples are not a complete frame-uptime benchmark. The 1,026-entry resume
  initializer measured 5.8–11.8 ms main-thread CPU; no end-to-end frame budget
  was asserted for it.
- Final neighboring checks on the prior binary: shared transcript parity,
  publisher performance, turn cards, tile detach and relay-backed share under
  load passed. The relay check used isolated app support and tmux namespaces.
- Corrected transcript-save performance remains red on the prior binary:
  5.351 ms and 13.125 ms worst post-burst frames against 4 ms, and an adjacent
  branch sample 4.422 ms. Saved documents/journals matched in those runs.
  Corrected clean-base samples were 4.045 ms (fail) and 3.298 ms (pass); this
  shows baseline variance but neither proves nor excludes a branch regression.
  Earlier branch GREEN samples were 3.149 ms and 2.729 ms. Do not relax the
  budget; rerun against final source and investigate any failure. Logs:
  `/tmp/array-transcript-final-neighbors.log`, `/tmp/array-perf-base-run1.log`,
  `/tmp/array-perf-base-run2.log`, `/tmp/array-perf-branch-paired.log`.
- A mistaken macOS process-count preflight briefly started a third Swift build;
  it was immediately interrupted. The base build subsequently passed under
  the requested limit. SwiftPM attempted update checks in that build; all later
  builds used `--skip-update`.

## Remaining work and limits

1. Rebuild the latest draft and run the targeted retention leg. Exercise
   RED/GREEN for bounded FIFO replay and migration-failure recovery; verify all
   individual failures, not just the combined exit status. Then rerun save perf,
   transcript/shared/tile neighbors and relay load with the final binary.
2. Complete independent review of archive/reload, cancellation and shutdown,
   including user-visible behavior. Explicit archive remains destructive;
   the proposed broad archive refusals were reverted. Quarantine waits for any
   already-started save before moving the archive. Its witness uses a 500 ms
   negative observation. Migration witness uses a 300 ms negative observation;
   it injects the task provider and does not drive AppDelegate startup wiring.
3. A persistent preflight fault can accumulate queued mutations in memory;
   quitting during a blocked save/replay can lose new unsaved content. A failed
   startup migration can leave an absent/legacy-only agent blocked until a new
   migration or restart. Partial writes remain fail-closed. Do not claim these
   cases are crash-durable or automatically repaired.
4. The inherited legacy migrator can use a snapshot fallback and delete a
   legacy directory even if its journal is unreadable. Companion's inherited
   forgiving read can yield incomplete history during corruption; the new
   callback witness covers intact archives, not that failure or transport.
   Canonical-only entries were already absent in fresh restored local/shared
   views on base; the draft preserves them on disk but does not add a UI merge.
   The general store guard does not prove content monotonicity for arbitrary
   live open entries; the specifically reloaded disk prefix is frozen.
5. SharedAgentProjector `.assistantOutput` has a released-reload gap, but the
   current production host uses `.excluded` and a separate transcript publisher.
   Do not claim that supported alternate mode is fixed.

Before **each** build: at least 25% free in `memory_pressure`, and fewer than
2 other `swift-build` processes counted with `ps`; wait in 120-second loops.
Debug only, `--skip-update`. No full matrix; never hold `/tmp/array-matrix.lock`.
Never touch either `/Applications/Array.app` or `~/Desktop/Array Dev.app`, or
the default tmux server. Isolate any checks' app support and tmux namespace,
unset inherited `TMUX`/`TMUX_PANE`, and do not update visual baselines.

Move card `2AEBD979-B295-4E19-BCD2-C7D6BB8BCC7A` on board
`2535EAF9-BC96-49FA-9148-C99B169586E3` to Done only after the final draft is
actually gated. Otherwise leave Doing and keep this file and the card current.
