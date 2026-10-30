# COL-13 / COL-17 provider seams — receipt

30 October 2026, bench `.worktrees/col-provider-seams` (branch
`array/col-provider-seams`, from `cc168bed`). Offline only: scripted
collaboration authority, reactive fake CLIs, isolated app support and tmux
namespaces. No real CLI, login, relay, Keychain or app activation.

## Commits

- `26184a85` fix(collaboration): count forks, resets and subagents once in usage
- `bd868ddd` fix(collaboration): refuse unsent dispatches and isolate refused claims

## COL-17 — exact usage totals

Witness: `ContinuumRevivedCoreChecks --collaboration-usage-telemetry-check`
(`CollaborationProviderUsageChecks.swift`). Every case runs the production
translator, the new `SharedAreaUsageNormalizer` (which the production
collector also uses) and the durable ledger over the committed CLI captures.

| Case | Capture | Exact total (in / out) |
| --- | --- | --- |
| Claude subagent overlap: child frames, task_progress, task_notification and Task usage beside the result | claude-subagent-turn | 79,036 / 500 (result `usage` alone: 51,671 / 330) |
| Claude result re-reported outside its run (same uuid, new turn) | claude-async-subagent | 79,036 / 500, once |
| Claude process-cumulative `modelUsage`, with and without the share field | claude-background-result-turn | 137,919 / 1,093 |
| Claude request vs run: repeated assistant frames and the result | claude-2.1.291-opus-turn | 21,936 / 124 |
| Codex cached input is a subset of input | codex-exec-single-agent-parity | 64,925 / 286 |
| Codex app-server cumulative totals | codex-appserver-single-agent | 64,996 / 313 |
| Codex parent and delegated child threads | codex-appserver-delegating-turn | 64,781 / 262 |
| Codex fork that inherits its parent's total | app-server frame shape, `forkedFromId` | 97,300 / 400 (fork counted in full would be 162,296) |
| Replacement thread below its parent | same | baseline only, partial |
| Codex counter reset, then late frames | same | 68,996 / 333, partial |
| Pi `message_end` + `turn_end` + relaunch replay; identity-less message | Pi usage shape | 1,664 / 48; unattributable stays uncounted |
| Ledger order: late reports before and after a reset | — | 190 / 23, partial |

The production collector's own check (`--collaboration-native-check`) adds a
Codex reset through `SharedAreaUsageCollector`: 180 / 44, partial.

## COL-13 — dispatch through each real runner

Witness: `--collaboration-native-check`, `SharedAreaProviderDispatchChecks`
(called from `SharedAreaHostSessionChecks`). These run for each of Claude Code,
Codex (app-server) and Pi:
`AgentSupervisor.productionRunner` starts the real runner against
`AgentSteeringQAFakes`, driven by the production `SharedAreaHandoffCoordinator`.

- The prompt on the CLI's stdin equals `promptText` (frozen context +
  attribution) exactly once. It is text only, no attachment parts, and context
  naming `@/private/etc/hosts` and `file:///…` stays literal text.
- A stale host generation is refused at the claim with zero writes, and the
  next command still goes through.
- Membership removed after the claim is `refused` with zero writes.
- A send-now on a busy turn is refused with zero writes.
- Distinct states: requested (queued receipt, nothing on the wire), host
  accepted (receipt accepted), queued (accepted, held in Array's queue, nothing
  on the wire, then drained once), provider observed (frame on stdin), outcome
  unknown (crash after the write: the relaunched host reports `uncertain`, one
  write in total).
- A lost outcome report is recovered as accepted with no second write.

## Teeth

Each was a compile-valid mutation: RED on the intended assertion, exact bytes
restored (`git diff` clean), rebuilt, GREEN. See [teeth.txt](teeth.txt).

1. Relaunched host executes an ambiguous attempt again → 2 writes.
2. Pre-execute admission failure reported as uncertain → not refused.
3. Refused claim aborts the pending loop → next command never written.
4. Fork lineage dropped → 162,296 / 713.
5. Reset counted from zero → 70,196 / 343.
6. Claude result identity dropped → 51,671 / 330.
7. Late-report guard removed → 128,792 / 616.

## Gate

`scripts/run-matrix.sh --collaboration`: **10 leg(s) run, Collaboration
matrix (targeted) passed.** See [matrix-summary.txt](matrix-summary.txt).

## Limits, plainly

- "Provider observed" has no receipt phase in the protocol. The requester cannot
  see it, so the check tells the states apart by their evidence.
- The App witness's service is scripted, refusing the way `CollaborationStore`
  does. The service's own refusals are witnessed over real HTTP in the service
  suite.
- In production a Codex fork is inferred from the agent's thread changing.
  `forkedFromId` on `thread/started` is not consumed yet. A fresh thread after a
  failed resume therefore only sets a baseline for its first report (partial).
- That `modelUsage` without `result_index` is per run comes from the
  committed captures. It is not confirmed for every Claude CLI version.
- The ledger's partial flag stays set once a reset or unknown baseline occurs
  (existing behaviour).
