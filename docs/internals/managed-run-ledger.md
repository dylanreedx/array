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
