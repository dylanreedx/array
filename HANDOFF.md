# Transcript retention gate — 2026-11-16

**Not gated. Keep the release card in Doing; do not ship this branch.**

The guarded-save draft prevents overwriting unverified archives but currently blocks
new persistence for all valid archives inherited from a previous process. It warns
and retains new history only in memory. This is a release-blocking regression; a
verified archive must be resumed without losing provider-only display history.
Checkout: `.worktrees/transcript-retention`, branch `array/transcript-retention`.
Base: `4c9d7495`. Retention commit: `f573ac7f`. Recovery and tile fence commit:
`474de68e` (`fix(agents): preserve transcripts through recovery and reattachment`).
Nothing was pushed.

## Uncommitted draft — not built or run

The working tree contains a deterministic stale-tail witness and draft strict
released-archive recovery. Do not treat these changes as verified or safe to
ship. `git diff --check` and Swift frontend parsing passed. The draft:

- Suspends a real buffered tile event across detach/reattach and checks exact
  once application plus continued delivery. The RED control removes both
  cancellation and generation checks from the stream guard. Build and run RED,
  restore the guard, build and run GREEN `--transcript-retention-check`.
- Saves a unique generation with each archive and requires the exact generation,
  version and intact snapshot/journal on reload. Invalidates cached proof before
  save attempts. Added checks for a corrupt snapshot with intact journal, a
  same-version replacement, and a journal write failure after snapshot replace.
  Build, exercise RED controls and GREEN, and independently review the final
  patch, including backward compatibility and concurrent persistence. The new
  witness is registered within `--transcript-retention-check`.

The strict read does not solve the following blockers:

1. Provider restore-only histories remain resident. Provider restore is bounded
   and mints new prompt IDs, so merging it with an existing canonical archive
   cannot safely infer overlap. Companion sync reads that canonical archive;
   making display-only provider history canonical may change what is synced.
   Design a durable local-only representation with explicit reconciliation,
   preserving unreadable and existing archives. Witness bounded restore, existing
   and corrupt archives, headless writes, release/reload/relaunch and the real
   companion callback. The first write with an existing archive also needs care.
2. When a released archive cannot be read, writes/events currently queue as
   in-memory closures and the agent can continue. A quit before successful read
   can lose new Array-only transcript content. A durable recovery or fail-closed
   policy covering prompts, notices, outside turns and unsolicited events needs
   a behavioral witness.

## Evidence

- Guard RED with temporary bypass: `--transcript-retention-check` failed as
  intended on write after restart. GREEN build passed and the check passed:
  3 held, 2,197 released, heap delta -15.2 MB. Strict-recovery and stale-tail
  witnesses passed in that GREEN run, but their own RED controls remain unrun.

- Earlier post-rebase build and retention witness passed: 3 transcripts held,
  2,197 released, 2,269 events, heap delta -15.4 MB. Previous RED controls
  covered unreadable file, tile retry, and restore-only history. The previously
  green stream-fence check did not deterministically force the race; the new
  draft witness above has not been run.
- `--share-under-load-check` passed on the existing branch binary with the real
  sibling `continuum-relay`, isolated app support and unique `TMUX_TMPDIR`,
  with `TMUX` and `TMUX_PANE` unset. Exit 0: upload backoff, 5,719,455-byte
  lead transcript, 32 helpers, guest tail, slow lane, local copy, 413 recovery.
- Render A/B completed against clean base `4c9d7495`. Base build passed
  (debug, 1,414.60 s); base render failed aqua 1.7548%, dark 0.8304%, tolerance
  0.0300%. Both base PNGs have the same SHA-256 as an earlier branch repeat.
  An adjacent branch repeat failed aqua 0.6882%, dark 0.8304%, with the dark
  image identical; light varies across runs. The baseline failure is present on
  base, and this branch did not introduce the identical mismatch. No baselines
  changed. Artifacts: `/tmp/array-render-ab.Sd8AsMB9-base` and
  `/tmp/array-render-ab.Sd8AsMB9-branch[-paired]`. The base build's SwiftPM
  attempted package update checks; use `--skip-update` for subsequent builds.

- The base build was briefly started with two other builds running due to an
  unsupported macOS `pgrep -c` preflight; it was immediately interrupted.
  No successful base build or A/B result was obtained. Subsequent builds were
  not started because the resource limit was occupied.

## Constraints and next steps

Before **each** build check `memory_pressure` for at least 25% free and use
`ps` to confirm fewer than two other `swift-build` processes. Coordinate
parallel builds; an observation is not a reservation. Debug builds only. No
full matrix; never hold `/tmp/array-matrix.lock`. Never touch the production or
Desktop preview apps or the default tmux server. Use a unique disposable tmux
namespace for any checks that require it. Do not update visual baselines.

Once capacity permits, finish base A/B, build and run RED/GREEN draft witnesses,
resolve the two blockers above, run relevant neighboring checks with a rebuilt
binary and relay, and obtain review. Only move card
`2AEBD979-B295-4E19-BCD2-C7D6BB8BCC7A` on board
`2535EAF9-BC96-49FA-9148-C99B169586E3` to Done when actually gated.
