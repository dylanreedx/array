# Handing an agent over, per harness — receipt

30 October 2026, bench `.worktrees/col-provider-seams`, branch
`array/col-handoff-seams` from `f3a60d1b`. Offline: recording fake CLIs, a
scripted collaboration service, isolated app support and tmux. App builds and
the gate ran under `.worktrees/.locks/app-build.sh`.

## Commit

- `a7fe1f0f` test(collaboration): witness handing an agent over through each runner

## Witness

`--collaboration-native-check`, `SharedAreaHandoffSeamChecks`, run for Claude
Code, Codex (app-server) and Pi. It is called from
`SharedAreaProviderDispatchChecks`, ahead of the dispatch cases.

The owner and the teammate each drive a production
`SharedAgentHandoffController`: refresh, offer, accept, send, reclaim. The
owner's app hosts the agent through the production `SharedAreaHandoffCoordinator`,
`AgentSupervisor.productionRunner` and the real runner, against
`AgentSteeringQAFakes`, which records every stdin line.

1. **New controller's prompt reaches the runner.** After offer and accept, the
   teammate's prompt is written to the CLI's stdin exactly once, as the frozen
   context plus attribution. The teammate's controller then reads `accepted`.
2. **Old owner stops executing.** While the teammate holds control, the owner's
   own input is `refused(.sharedAgentControlRequired)` with zero writes. A
   positive control before the handoff, and again after the reclaim, shows the
   same input running.
3. **Refused handoff reads refused.** The teammate queues a prompt and the owner
   reclaims before the host polls. The host refuses it with zero writes, and the
   teammate's controller reads `refused`. A further teammate send is refused by
   the service, and the controller says "This request was not accepted"; it does
   not leave the send unresolved.

Exactly three prompts reach each runner: the owner before handoff, the
teammate, and the owner after reclaim.

The service is scripted with `CollaborationStore`'s handoff rules: one
controller, revisions, owner-only offer and reclaim, recipient-only accept, and a
queued prompt whose requester lost control resolving `refused` at the host's
poll. Refusals are the `CollaborationClientError` HTTP errors the client
handles. The real service's own rules are witnessed over HTTP in the
service suite.

## Teeth

Each was a compile-valid mutation: RED at its own assertion, exact bytes
restored, rebuilt, GREEN. See [teeth.txt](teeth.txt).

| Case | Mutation | RED |
| --- | --- | --- |
| 1 | `acceptSharedAgentPrompt` sends `command.text`, dropping context and attribution | prompt never reached the runner as sent |
| 2 | control gate stops requiring the owner to be the current controller | former owner's input accepted, 1 write |
| 3 | client treats a 403 send as unresolved | send left "Delivery is unresolved" |

## Gate

`scripts/run-matrix.sh --collaboration`, with `CONTINUUM_SKIP_UI_BASELINES=1`,
under the lock: **11 leg(s) run, Collaboration matrix (targeted) passed.** See
[matrix-summary.txt](matrix-summary.txt).

## Limits

- The service is scripted in the native check, as the app target cannot load
  the server. The two-process pair harness covers a real relay.
- Each harness runs one handoff and one reclaim. Many handoffs in a row, or
  concurrent offers, are covered by the service suite only.
