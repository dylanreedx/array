# Managed run ledger

Recording only: no agent snapshot, workspace operation, UI or policy reads this
store. It never gates a submission or applies a budget.

The file is `run-ledger/ledger.jsonl` under `AgentStore.layout`'s channel-specific
Application Support directory (or the explicit `CONTINUUM_APP_SUPPORT` override).
Agent identities belong to that channel. Project `.array/` is shared across
installations and must not hold these records.

Each v1 row carries `v`, `at` (Foundation reference-date seconds), `kind`, `task`,
`agent`, `source`, and `origin` (`host`). Optional fields are `part`,
`previousTask`, `project`, `outcome`, `checks`, `findings`, and `openParts`.
Task, agent, part and project identities are UUIDs. The initial part identity is
the delegated child UUID. Checks and findings contain counts by declared enum
value, never claims of host verification. No text, filesystem paths, diffs,
credentials or report bodies are serialized. Report check/finding arrays are
handed off unchanged for background aggregation; only their enum counts persist.

Kinds: `taskOpened`, `submission`, `delegated`, `working`, `reported`,
`turnEnded`, `taskClosed`, `taskInterrupted`. The opening row identifies the lead
and project; delegation rows associate helpers and parts. A human send or queued
submission accepted for a managed top-level lead opens or joins its active task.
A lead turn ending with no open helper parts closes it. Once the lead has
ended, the last helper report or terminal event also closes it without a wake. Helper wakes do not
open tasks. The next submission links a new task to the prior one. Restart marks
active tasks interrupted without manufacturing terminal helper events.

`ManagedRunLedger.append(_:)` is the single append path. Source event identities
suppress replayed delegation, report and turn facts. Typed report and turn
hand-offs defer aggregation and source formatting to the utility queue. A serial utility queue owns reduction,
recovery and writes. Request paths enqueue metadata and never wait for disk.
Recovery reads complete rows and preserves all previous bytes. If the last
append was torn, the sole append path adds a newline before the recovery fact. Buffered facts
may be lost on process death before their write; this is not a transactional audit
log. Unknown schema versions are not interpreted.

Later parts must extend this schema and append path for typed usage counters,
observed evidence and integration object IDs. No token totals, verified stage,
release stage or acceptance is inferred here. Export, retention, deletion,
compaction snapshots, takeover and usage UI remain later work.

## Review witnesses and timing

The extended `--managed-run-ledger-check` observed RED for each original defect:
restart changed earlier bytes; the last helper report did not close a task with
wakes disabled; a non-temporary storage override was accepted. All three are
GREEN after the fixes. Restart now appends exactly one interrupted fact after
preserving the original byte prefix, including a deliberately torn final row.
Runtime attribution is established only by live submission/delegation, so
transcript replay during restore cannot manufacture new historical outcomes.

Timing uses the production supervisor `accept` and `fileReport` calls over the
fake CLI fixture, with eight warm-up pairs and 100 samples per on/off condition.
Order alternates between pairs; readiness waits are outside the measured calls.
These are whole-call timings, including the pre-existing persistence work.

| Call | Recording | Median (µs) | p95 (µs) |
| --- | --- | ---: | ---: |
| Submission | off | 9493.96 | 35112.08 |
| Submission | on | 9979.21 | 39793.75 |
| Helper report | off | 2617.92 | 32237.29 |
| Helper report | on | 2621.46 | 24481.12 |

The distributions are noisy. This run does not establish zero added latency;
submission median and p95 were higher with recording enabled. Aggregation,
formatting, encoding and ledger disk access are off the request path; the caller
still pays for an asynchronous hand-off.

All twelve previously reported regression arms passed on the final build.
Cross-harness delegation initially failed its selected-mode assertion, then
passed on rerun; no adjacent policy code was changed. Full matrix was not run.

## Request-path cost, measured

`--managed-run-ledger-timing-check` is targeted only, never a matrix leg. It
prints numbers and asserts nothing about time. It refuses to run unless
`CONTINUUM_APP_SUPPORT` is already a temporary directory, then creates and owns
its own temporary support directory. Run it the way the matrix runs an app check:
temporary `CONTINUUM_APP_SUPPORT`, an isolated `TMUX_TMPDIR`, and `TMUX` unset.

What the calling (main) thread does per path:

- Submission (`AgentSupervisor.accept(_:for:)`): a bool read, an enum compare,
  `effectiveMode(for:)` (dictionary reads of `records`, `runners`,
  `helperProviderRetryErrors`, `runningModes`), two more `records` reads, then
  `ManagedRunLedger.submission`: one `queue.async` whose closure captures two
  UUIDs. That is one heap block and one enqueue, which wakes the idle utility
  queue.
- Delegation (`WorkspaceAPIService+Delegation.swift`): one `queue.async`
  capturing two UUIDs and the existing request-id string (retained, not copied),
  behind the same `qaRunLedgerRecording` switch as submission and report.
- Helper report (`fileReport`): a bool read, then one `queue.async` capturing a
  UUID, a `Date` and the report's two arrays (retained, not copied).
- Turn start/end (`working`/`ended`, on the event path): one `queue.async` each.

No path formats strings or dates, encodes, takes a lock or waits on disk on the
calling thread. Source strings, counts, encoding and file I/O all run on the queue.

Part 1 times only those statements on the production supervisor and ledger,
with recording on. It takes 5,000 samples after 200 warm-up samples, each
preceded by a 2 ms pause so the queue is idle, as it is when a person submits.
Part 2 times the whole `accept` call, on and off alternating within each of
1,000 pairs (20 warm-up pairs). Debug build, on a machine running a live Array.

| Run | Submission med / p95 / max (µs) | Delegation med / p95 | Report med / p95 | Paired whole-call on−off median (95% CI) |
| --- | --- | --- | --- | --- |
| A | 8.62 / 19.96 / 116.83 | 3.29 / 9.25 | 3.33 / 9.21 | −19.75 µs (−69.33, 31.54) |
| B | 13.50 / 25.58 / 200.75 | 5.12 / 12.12 | 5.25 / 13.29 | 4.21 µs (−60.58, 64.25) |

Each whole call takes about 21 ms. The paired differences have an interquartile
range near ±0.6–0.9 ms. Both confidence intervals contain zero.

Machine load moves these numbers about 2–3×. Under heavier load, earlier runs
reached a submission median of 27–30 µs, while the enqueue alone, which did not
change, also tripled. A sample is also inflated by whatever ran just before it.
The first statement after an idle pause pays a cold-cache cost. In an in-process
A/B with alternating order, binding a whole `AgentRecord` copy and reading single
fields differed by about 0.5 µs, so nothing on the calling thread is worth
moving. The remaining cost is the main-actor reads and the enqueue itself.

## Constant cost per fact

Each fact costs the same however long the ledger is. One `reduce` keeps the
open parts per task, each part's tasks, delegation order and the owner's last
turn boundary in memory; live appends and the load-time rebuild both run it,
and `append` stays the only writer. Before this, closure scanned every row on
each report or turn end: at 50,001 rows a fact took 5,795 µs against 36 µs on
an empty ledger (161×), and the queue fell minutes behind.

`--managed-run-ledger-check` runs two arms for it (each alone through
`CONTINUUM_LEDGER_REVIEW_CASE=replay|scale`). `replay` drives one fixed call
sequence, with a torn row and a restart, and compares a digest of the rows (times
zeroed, ids renamed by first appearance, keys sorted, since the encoder's key
order differs per process) against the digest the scanning reducer produced.
`scale` preloads 50,001 rows and fails only if a fact costs five times more
than on an empty ledger; it measured 0.99–1.03×.

## Helper evidence shadow capture

`helperEvidence` rows extend v1 with an `evidence` dictionary. The host queues
hook counters independently of the 128-receipt ring and snapshots them when a
helper files a report. Task and part ids come from the ledger's delegation row.
Only counts and fixed enum words are stored; no command, path or report text.
The report, courier, UI and agent output never read these rows.

This initial subset records pre/post tool counts and shell completion counts.
`afterCoveredEdit`, `checkFilesModified` and `exitZero` are always `unknown`;
`captureGap` is always `true`. A hook completion is not a verified check run.
Counters are process-local; report snapshots survive restart, but recovery does
not pretend it recovered unreported hook activity. Queue backlog or process death
can lose observations. This is not complete provider correlation.

The gate-owned manifest is deliberately not copied here. Exact check identity,
covered-path freshness, snapshots, call-id/stream correlation for both harnesses,
and known numeric terminal exits remain unimplemented. The provider check flag
currently exercises only this conservative subset through the production helper
report and authenticated Claude hook paths. It does not prove the full part 8
step 1 contract or the before/after-edit cases.
