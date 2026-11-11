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
credentials or report bodies are accepted by the ledger interface.

Kinds: `taskOpened`, `submission`, `delegated`, `working`, `reported`,
`turnEnded`, `taskClosed`, `taskInterrupted`. The opening row identifies the lead
and project; delegation rows associate helpers and parts. A human send or queued
submission accepted for a managed top-level lead opens or joins its active task.
Only a lead turn ending with no open helper parts closes it. Helper wakes do not
open tasks. The next submission links a new task to the prior one. Restart marks
active tasks interrupted without manufacturing terminal helper events.

`ManagedRunLedger.append(_:)` is the single append path. Source event identities
suppress replayed delegation and turn facts. A serial utility queue owns reduction,
recovery and writes. Request paths enqueue metadata and never wait for disk.
Recovery retains complete rows and discards a torn trailing append. Buffered facts
may be lost on process death before their write; this is not a transactional audit
log. Unknown schema versions are not interpreted.

Later parts must extend this schema and append path for typed usage counters,
observed evidence and integration object IDs. No token totals, verified stage,
release stage or acceptance is inferred here. Export, retention, deletion,
compaction snapshots, takeover and usage UI remain later work.
