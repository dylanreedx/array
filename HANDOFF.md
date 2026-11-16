# Transcript retention gate — 2026-11-16

**Not gated. Keep the card in Doing; do not ship this branch.** Checkout:
`.worktrees/transcript-retention`, branch `array/transcript-retention`, base
`4c9d7495`. No push. Committed through `36b21050`: retention/recovery, render
A/B evidence, archive guard, restore-only witness and deterministic tail fence.

The valid-restart, bounded reload, provider-read pins and related witnesses
in local draft commit `253730e8` are unfinished and must not ship. The latest
targeted retention leg failed: a provider history seeded during a yielding reload was missing or duplicated in the
reattached tile. That test calls the seed API directly; a slow Copy-here read
plus notice-only work is source-reachable but has not been witnessed through the
production entry. Pins under development aim to prevent current production
callers from entering that state, but do not fix arbitrary direct mid-drain
seeding. The latest draft and strengthened witnesses built successfully with
71% free memory and zero other Swift builds. The latest retention run failed
(108.0 s): the late-restore check above and a separate inherited `/status`
notice-only reattachment case both lost or duplicated provider history. Isolated
pin checks and the new isolated production Copy-here handoff witness reported
no failures in that run. The latter proves combined adoption/read retention,
not each guard independently; their RED controls have not been run. The
prioritized release preview build reported complete with exit 0; use the 120-second resource loop below.

## Evidence

- Clean base render A/B: base aqua 1.7548%, dark 0.8304% (0.0300% tolerance),
  byte-identical PNGs to an earlier branch repeat. Adjacent branch light varied.
  The same failure exists on base; no baseline was changed. Artifacts remain at
  `/tmp/array-render-ab.Sd8AsMB9-base` and `...-branch[-paired]`.
- Retention GREEN on an earlier built draft passed in 115.6 s: 3 transcripts
  held, 2,197 released, 2,269 events, heap -14.3 MB. The latest RED run measured
  3 held, 2,197 released and heap -12.9 MB. All witnesses are invoked
  from the existing matrix retention leg; no full matrix was run. That earlier
  GREEN predates the latest witnesses and changes.
- Save guard, restore-only, strict reload and stale buffered tail all failed
  their specific RED controls and passed GREEN. Reconciliation RED omitted the
  canonical model and failed as expected; six combined RED controls detected
  notice loss, early quarantine, incorrect census, dropped saved turn, rejected
  flush and ambiguous compaction. Open-history and historical-card/high-water
  controls also failed as intended. Migration barrier, retry FIFO, and absence
  after failed read each failed their corresponding RED controls. The bounded
  replay and migration-failure controls have also failed RED as intended;
  provider-pin changes built and their isolated checks reported no failures;
  they still need RED controls. The new Copy-here witness reported no failure
  for the combined adoption/read guards.
- Resumed-stream COW witness RED moved the entries buffer on 240/240 appends;
  GREEN moved it on 0/240. GREEN large-archive streaming median 0.096 ms,
  p95 0.125 ms; the complete targeted leg took 49.7 s in that run. Timing
  samples are not a complete frame-uptime benchmark. The 1,026-entry resume
  initializer measured 5.8–11.8 ms main-thread CPU; no end-to-end frame budget
  was asserted for it.
- Final neighboring checks on the prior binary: shared transcript parity,
  publisher performance, turn cards, tile detach and relay-backed share under
  load passed. The relay check used isolated app support and tmux namespaces.
- Corrected transcript-save performance was variable on the prior binary:
  5.351 ms and 13.125 ms worst post-burst frames against 4 ms, and an adjacent
  branch sample 4.422 ms. Saved documents/journals matched in those runs.
  Corrected clean-base samples were 4.045 ms (fail) and 3.298 ms (pass); this
  shows baseline variance but neither proves nor excludes a branch regression.
  Earlier branch GREEN samples were 3.149 ms and 2.729 ms; a later normal
  run passed at 3.843 ms and an opt-in attribution run passed at 2.994 ms.
  Do not relax the budget; rerun against final source and investigate any failure. Logs:
  `/tmp/array-transcript-final-neighbors.log`, `/tmp/array-perf-base-run1.log`,
  `/tmp/array-perf-base-run2.log`, `/tmp/array-perf-branch-paired.log`.
- A mistaken macOS process-count preflight briefly started a third Swift build;
  it was immediately interrupted. The base build subsequently passed under
  the requested limit. SwiftPM attempted update checks in that build; all later
  builds used `--skip-update`.

## Remaining work and limits

1. Resolve both latest retention failures before shipping. Mid-drain provider
   insertion over an existing archive needs explicit provenance and overlap
   semantics: a model-only insertion can break open-stream identity, tool detail
   bindings and sharing. The direct-seed witness exercises that broad case; a
   slow Copy-here callback is now witnessed at the production handoff boundary
   with synthetic files; the test covers combined adoption/read protection,
   not the individual pin. Watch/move currently appear to link fresh or existing
   agents before idle release, while the public adoption API permits an already
   released agent. Waiting for reload alone does not resolve archive/provider
   overlap or colliding live identities. Separately, the inherited `/status`
   notice-only case needs safe local-only composition with the canonical
   companion boundary preserved. Document-only reconstruction freezes active
   state and loses replay tool details; appending provider history after later
   live turns changes ordering. Do not claim pins fix the direct-seed case.
2. Add pin RED controls. Verify each relevant
   RED/GREEN result, then rerun the targeted retention leg, save perf,
   transcript/shared/tile neighbors and relay load on the final binary.
3. Complete independent review of archive/reload, cancellation and shutdown,
   including user-visible behavior. Explicit archive remains destructive;
   the proposed broad archive refusals were reverted. Quarantine waits for any
   already-started save before moving the archive. Its witness uses a 500 ms
   negative observation. Migration witness uses a 300 ms negative observation;
   it injects the task provider and does not drive AppDelegate startup wiring.
4. A persistent preflight fault can accumulate queued mutations in memory;
   quitting during a blocked save/replay can lose new unsaved content. A failed
   startup migration can leave an absent/legacy-only agent blocked until a new
   migration or restart. Partial writes remain fail-closed. Do not claim these
   cases are crash-durable or automatically repaired.
5. The inherited legacy migrator can use a snapshot fallback and delete a
   legacy directory even if its journal is unreadable. Companion's inherited
   forgiving read can yield incomplete history during corruption; the new
   callback witness covers intact archives, not that failure or transport.
   Canonical-only entries were already absent in fresh restored local/shared
   views on base; the draft preserves them on disk but does not add a UI merge.
   The general store guard does not prove content monotonicity for arbitrary
   live open entries; the specifically reloaded disk prefix is frozen.
6. SharedAgentProjector `.assistantOutput` has a released-reload gap, but the
   current production host uses `.excluded` and a separate transcript publisher.
   Do not claim that supported alternate mode is fixed.

Before **each** build: at least 25% free in `memory_pressure`, and zero other
`swift-build` processes (`pgrep -f swift-build`); wait in 120-second loops.
Debug only, `--skip-update`. No full matrix; never hold `/tmp/array-matrix.lock`.
Never touch either `/Applications/Array.app` or `~/Desktop/Array Dev.app`, or
the default tmux server. Isolate any checks' app support and tmux namespace,
unset inherited `TMUX`/`TMUX_PANE`, and do not update visual baselines.

Move card `2AEBD979-B295-4E19-BCD2-C7D6BB8BCC7A` on board
`2535EAF9-BC96-49FA-9148-C99B169586E3` to Done only after the final draft is
actually gated. Otherwise leave Doing and keep this file and the card current.
