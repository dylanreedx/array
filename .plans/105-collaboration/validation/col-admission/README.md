# Admission refusals, freshness hook, codex fork lineage — receipt

30 October 2026, bench `.worktrees/col-provider-seams`, branch
`array/col-admission` from `e17d0a52`. Offline only: real localhost service,
scripted transports, fake CLIs, isolated app support and tmux. App build and
gate ran under `.worktrees/.locks/app-build.sh` with
`CONTINUUM_SKIP_UI_BASELINES=1`.

## Commits

- `80422994` test(collaboration): pin pre-execute refusals as refused in journal and receipt
- `5579b7cf` feat(collaboration): record handoff prompts in the freshness ledger
- `336d8fda` fix(collaboration): read codex forkedFromId to baseline a forked thread

## 1. Refused admission reported as uncertain (w9 finding 1, w3 lapse note)

Both reports describe code from before `4ecae390` (wave 1, already on this
base). Since then `dispatch` records `refused` in the journal and the receipt
for **any** failure before `execute` starts, and `uncertain` only once
`execute` has begun. No production change was needed. The checks now pin it in
`SharedAgentRevocationRaceChecks`, which runs in the default
`ContinuumRevivedCollaborationChecks` leg, over real HTTP:

- **R3, tightened.** The device is revoked between claim and admission. The
  receipt is `.refused` and the host journal is `.refused`, no longer just "final".
- **R4, new.** An injected service clock jumps past `dispatchAuthorityWindow`
  between claim and admission. The service expires the claim and the host
  journal agrees: `.refused` in both, no execution. This closes worker 3's note.

A lost admission reply (transport error) also records `refused`, not
`uncertain` as the audit suggested. `execute` runs only after a successful
admission, in the same call, so a failed admit proves the provider was never
called. "Uncertain" would claim the prompt may have run, which is false. A
replacement process that finds an interrupted attempt still reports
`uncertain`.

## 2. Freshness ledger in the production controller

`SharedAgentHandoffController.freshness`:

- records each prompt receipt on delivery;
- records the refreshed recent receipt;
- on refresh, settles every other unsettled command. A receipt that cannot be
  read stays unsettled instead of failing the refresh.

Witness: `SharedAgentHostDispatchChecks`, a real handoff over HTTP through the
production controller:

- the delivered prompt is frozen and awaiting the host;
- a relaunched controller's refresh settles the acceptance (`.current`,
  `lastAccepted` equals the command);
- a later refresh settles the older interrupted prompt.

## 3. Codex `forkedFromId`

The app-server translator keeps `thread.forkedFromId` per thread and puts it on
each usage report (`TokenUsageSnapshot.accountingForkedFrom`). The normalizer
prefers it over inferring a fork from a thread change. Witness: a forked copy
agent whose only thread was forked from another agent's, sharing one ledger.
Its frames are derived from the real `codex-appserver-single-agent` capture,
with `forkedFromId` set and the parent's total added. Exact total
129,992 / 626, against 194,988 counted in full.

## Teeth

Each was a compile-valid mutation: RED on the intended assertion, exact bytes
restored, rebuilt GREEN. See [teeth.txt](teeth.txt).

| Mutation | RED |
| --- | --- |
| pre-execute failures journaled `uncertain` | R4 claim lapse |
| delivery hook dropped | prompt not frozen in the ledger |
| refresh record dropped | relaunched refresh does not settle |
| settle loop dropped | older prompt still awaiting |
| `forkedFromId` ignored | 194,988 / 939 |

## Gate

`scripts/run-matrix.sh --collaboration` (lock acquired after 481 s):
**10 leg(s) run, FAILED (1): `ContinuumRevivedCollaborationServiceChecks`**, at
`CollaborationBackupRestoreChecks` "verification refuses a backup with damaged
pages". Every leg that covers this work passed: collaboration contracts,
native (all three runners), usage telemetry, pair, relay.

This failure is not from this branch. The branch changes nothing in the service,
its checks or the relay, and the same binary passed 1 of 3 reruns. The check
XORs 512 bytes at the file's midpoint. The backup's size varies with the
concurrent writes it races, so the midpoint can fall on a free page that SQLite
never reads. Verification then correctly passes, and the check fails. It needs
to damage a page in use, for example a b-tree page found from
`dbstat`/`sqlite_master`, or the header. Owner: the backup/restore check
(`ef89135e`, `25ed79fe`). See [matrix-summary.txt](matrix-summary.txt).
