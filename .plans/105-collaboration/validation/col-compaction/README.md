# COL-19 receipt: replay, compaction, retention and host-outcome recovery

30 October 2026. Bench `.worktrees/mp-recovery`, branch `array/col-compaction`
from `array/collaboration-finish` at `cc168bed`. Disposable SQLite, injected
clocks, real localhost HTTP and real `continuum-relay` processes. No production
relay, Keychain, provider, default tmux, live app or Desktop preview touched.

## What changed

- Service compaction (`CollaborationRetention.swift`). After a commit, a separate
  transaction folds every eligible operation into an encrypted horizon snapshot.
  Eligible means older than the tail and older than the age bound. The snapshot
  and horizon are written before the covered rows are deleted.
  Tombstones and receipts stay in the snapshots. A new `operation_receipts` table
  keeps each operation ID bound to its actor after its row is retired.
- A cursor behind the horizon gets `409 snapshotRequired`; the client resnapshots.
- `backup(to:)` (online SQLite backup) and `verifyIntegrity()`: horizon plus tail
  must rebuild the head exactly, with one receipt per revision.
- Unadmitted host requests (`queued`/`claimed`) expire after an authority window
  (15 min default) to `refused`. Admitted attempts are never rewritten.
- `CollaborationSession` reports `.incompatible` for undecodable or future-schema
  data. The controller closes the view without marking the cache access-denied,
  so cache bytes, drafts and outbox stay untouched.
- Retention contract in `docs/internals/collaboration.md` → Retention.

## Witnesses (in the default runs, no new legs)

`ContinuumRevivedCollaborationServiceChecks` → `runCollaborationRetentionChecks`
(also `--retention-only`); `ContinuumRevivedCollaborationChecks` →
`runCollaborationRetentionRecoveryChecks`.

| Acceptance | Witness lines |
| --- | --- |
| >500 events + post-compaction reconnect lose nothing, resurrect nothing | 524 ops paged, compacted to horizon 516; ancient cursor → `snapshotRequired`; resnapshot client byte-equal to full-replay client; never presents a stale revision as connected; deleted artifact absent and stale re-admit refused |
| Revocation/epoch and receipts survive compaction | removed member 404, revoked device 401, old epoch 409; compacted retry returns original revision 2 (`duplicate`); another person reusing the ID → `changedIntent` |
| Unsupported schemas keep recoverable state | future command schema → 400, document unchanged; future document schema → `incompatibleState`, cache bytes identical (open path and live-session path); later build reopens cache with draft and outbox; schema-2 cache behind the horizon recovers over HTTP with its draft |
| Crash each durable boundary, restore to replacement dirs | SQLite trigger fault inside compaction rolls back snapshot+horizon, keeps the command; online backup → new relay process → full HTTP verification; SIGKILL mid-burst → cold copy → new relay → every acknowledged commit present, integrity verified |
| Offline executable actions expire/reconfirm; receipt ≠ execution | queued receipt says not accepted; after window host executes nothing, receipt `refused`; exact-ID retry returns the refusal; a new request executes once; claimed-not-admitted expires; admitted attempt stays `dispatching` → `uncertain`, no replay; removed requester refused |

## Teeth (compile-valid mutation → RED, exact bytes restored → GREEN)

Logs, diffs and restore hashes in `teeth/`.

| Mutation | RED at |
| --- | --- |
| t1 compaction strips tombstones from the head | `integrityFailure` (verifier) |
| t1b same, with the verifier blinded | resnapshot client not byte-equal to full replay |
| t2 actor binding read from the retired `operations` table | another person claims a compacted operation ID (request succeeded) |
| t2b compaction deletes `operation_receipts` | `integrityFailure` |
| t3 expiry disabled | expired request executed when the host returned |
| t4 incompatible state marks the cache denied | cache bytes changed |
| t5 horizon guard removed | cursor got `resyncRequired`, not `snapshotRequired` |

All seven GREEN after restore.

## Gate

`scripts/run-matrix.sh --collaboration` in this bench, with isolated
TMUX_TMPDIR/CONTINUUM_APP_SUPPORT and `CONTINUUM_SKIP_UI_BASELINES=1`:
**"Collaboration matrix (targeted): 10 leg(s) run … passed"**, exit 0. One note:
the display-dependent theme surface-cache witness was skipped. Both new
sections printed their pass lines inside the default legs. The full log is
`matrix-collaboration.log`; the standalone runs are `retention-only.log` and
`collaboration-checks.log`.

## Not done / honest limits

- Receipts and tombstones grow for the life of an area; pruning them needs a
  reducer schema change in `SharedAreaDocument.swift` (lead-owned).
- Expired requests report `refused` (no distinct `expired` phase; that would be
  a protocol change). The UI copy already says to refresh and review control.
- A claim that lapses between claim and admission is refused by the service
  while the host journal records `uncertain`; nothing executes, but the two
  labels differ.
- Compaction failures are counted (`compactionFailures`), not logged.
- `CollaborationHandoff.swift` got four one-line expiry hooks (enqueue time and
  expiry before pending/claim/receipt reads); no handoff logic changed.
- No deployed backup schedule, key rotation or Linux-container run of the new
  fixture.
