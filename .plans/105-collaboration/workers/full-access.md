# Part 4: full access (array/mp-full-access)

Bench: `.worktrees/multiplayer-teammates-prompt-sha-24351f30`, base `array/collaboration-finish`
(c7131f8f). Commits: 30c641a3 (feature), cba2a710 (live view layout budget), then this
receipt.

Status: DONE. `--collaboration` gate on cba2a710: **12 legs run, all passed.**

## What changed

Whoever a share admits as an editor prompts the owner's agent. It runs on the owner's
Mac, under the owner's CLI login.

- **Policy.** `Role.allows` grants `promptAgent` and `stopAgent` to owner and editor.
  `approveProviderRequest` and `writeTerminal` stay off for everyone.
- **Service** (`CollaborationHandoff.swift`). A prompt is admitted by membership and
  capability. The handoff controller, the control revision and an agreement revision
  are no longer required. `AgentPromptRequest.contextRevision` and
  `AgentDispatchCommand.context` are optional; when a revision is sent it is still
  checked as before. Removal still deactivates the member and bumps the epoch, so their
  queued prompts are refused at the host's next poll.
- **Owner's host.**
  - `SharedAreaHandoffCoordinator`: the owner's own input no longer needs control.
    Handing over never locks the owner out.
  - `SharedAgentHostDispatcher`: prompts run in arrival order. A send-now that finds
    the agent busy stays queued on the service, unclaimed, and later prompts for that
    agent wait behind it. Nothing is dropped.
- **Who sent the last prompt.**
  - `AgentSupervisor.lastPromptAuthors` records it when a turn starts.
  - `SharedAgentProjector` publishes it as `AgentProjection.LastPrompt` (a person id
    and a time; never the prompt).
  - The owner's tile shows a "Sam sent the last prompt · 10:52" pill in its status row
    (`AgentCompactStatusRowView`). It is the first thing the row drops when narrow.
  - The teammate's view shows "You sent the last prompt" or "Dylan sent the last
    prompt · 10:52".
  - Names come from presence labels: `SharedAreaHostSession` copies them into
    `AgentSupervisor.sharedParticipantNames`.
- **Teammate's view** (`SharedAgentLiveView`).
  - The live transcript sits above.
  - Below it: the last-prompt line, the real `AgentComposerView` and a Send button.
    Sending goes through `SharedAgentHandoffController.prompt(object:text:)`. Only a
    service-queued prompt clears the draft.
  - The view follows the receipt: Queued, Starting, or Refused.
  - When the agent asks for an approval, the status reads "Waiting for Dylan to
    approve". The approval opens only on the owner's Mac.
  - A viewer gets no composer ("View only").
- **Handoff (COL-13)** stays as an explicit action, renamed "Hand over…". The dialog's
  Send no longer requires holding control.
- **Removed or revoked.** A prompt a removed person sent before removal is refused. A
  prompt sent after removal is refused at the service, and the draft stays. Their view
  says "Refused: you no longer have access to this agent."
  - When a receipt can no longer be read because access ended, `refreshReceipt()`
    reports it refused if the host had not yet admitted it. The host's admission
    rechecks membership, so such a prompt can never run.

## Witnesses

- `--collaboration-full-access-check` (new, `SharedAgentFullAccessChecks`). It runs
  per harness, for Claude Code, Codex and Pi, through the production controllers and
  the reactive fake CLIs. It covers:
  1. A teammate types into the real composer and presses Send. The prompt reaches the
     owner's runner exactly once and reads accepted.
  2. The last-prompt label on both Macs, following both a teammate's prompt and the
     owner's own.
  3. Two concurrent prompts (Sam, then Priya) sent during the owner's turn. Both wait,
     then run once each, in arrival order.
  4. An approval opens on the owner's supervisor only. The teammate reads "Waiting for
     Dylan to approve", nothing about the request crosses, and no approve route exists.
  5. Priya is removed while her prompt waits. It is refused with zero writes, and her
     view shows it refused. Her next send is refused and keeps its draft. Sam keeps
     prompting across the epoch change.

  It is registered in both the `--collaboration` block and the full matrix. The matrix
  inventory was regenerated; it also picked up collaboration legs the base inventory
  had never recorded.
- **Updated to the new rule:**
  - `CollaborationHandoffChecks` (real HTTP): an editor prompts with no handoff; two
    prompts queue in arrival order and both are admitted; the owner is not locked out;
    a control change between composing and sending does not refuse.
  - `CollaborationCapabilityChecks`: editors grant prompt and stop; nobody grants
    approve or terminal.
  - `SharedAreaHandoffSeamChecks` (COL-13, three harnesses): the owner keeps prompting
    while handed over; a reclaim or a lack of control no longer refuses.
  - `SharedAreaProviderDispatchChecks`: a busy send-now now waits and then runs in
    order, instead of being refused.
  - `scripts/check-collaboration-pair.py`: the owner's send after a handoff runs (three
    runner turns, so usage is 300 in / 60 out).
- **Approvals.** No managed runner opens a provider approval today: Claude runs with
  bypassed permissions, Codex declines, and Pi has none. The witness therefore opens the
  approval at `AgentSupervisor`'s event seam, on the live fake-CLI turn.
- **Rendered.** The teammate composer and the owner tile's pill were rendered in light
  and dark through the app's own theme switch, and checked by eye.
  - Images: `qa-runs/full-access/evidence/` in the bench (not committed).
  - The pill's fill is asserted against its token in both themes.

## For part 2 (in-canvas zone)

`SharedAreaZoneAgentView.footerMode` is the switch.

1. Drop the read-only footer and let the embedded `SharedAgentLiveView` show its own
   composer. It already hides the composer for viewers, offline hosts and when no
   route exists.
2. Set `live.prompter` to the area's `SharedAgentHandoffController`. In the window path
   that is `host.handoff.model`, wired in `ContinuumApp` next to `onRequestHandoff`.

The view names people from its controller's presence by default.

## For part 1 (links)

`revokeShareLink` and `removeShareLinkPerson` deactivate the member and bump the epoch.
That is exactly what refuses a removed person's queued prompt here, so nothing more is
needed.

## Open, not done here

- **The attribution line names the teammate by id.** The prompt's text carries "From
  collaboration participant <uuid>". This was already COL-13's frozen, digested format.
  The owner's transcript shows that line, and an unnamed agent takes it as its derived
  title. Showing a name instead needs the host to render the attribution, not the
  command.
- **Long waits are refused.** A prompt that waits longer than the service's 15-minute
  dispatch authority window behind a long turn is refused (shown refused, never
  dropped).
- **Removal refuses everyone's waiting prompts.** Removing anyone bumps the area epoch,
  so other members' prompts waiting at that moment are refused too. This rule
  predates this change.
- **Neighbouring pill, not fixed.** `AgentCompactStatusRowView.applyTokens` does not
  re-theme the processes pill, unlike the new pill. Untouched; worth a look.

## Mutation teeth (each rebuilt, run, then restored from the commit)

| Mutation | Result |
|---|---|
| Editors lose `promptAgent` | RED: "Sam's view never offered the composer" |
| Dispatcher ignores a busy agent (no arrival order) | RED: the busy prompts read `refused`, not waiting |
| Supervisor stops recording the requester | RED: owner tile reads "You sent…", Sam's view "Dylan sent…" |
| Editors may approve provider requests | RED at the owner-only approval witness |
| `refreshReceipt` stops reporting a removed sender's prompt refused | RED: Priya's view stays "Queued…" |

The restore build was clean, and `git status` showed no changes in `Sources`.
Log: `qa-runs/full-access/mutations.log`.

## Gate

`scripts/run-matrix.sh --collaboration` was run under `.worktrees/.locks/app-build.sh` with an
isolated `TMUX_TMPDIR` and `CONTINUUM_APP_SUPPORT` and `CONTINUUM_SKIP_UI_BASELINES=1`.

- **First run, on 30c641a3: 11 of 12 passed.** The live view budget in
  `--collaboration-native-check` failed: 12 Array layout passes per projection delta,
  against a budget of 6 (the base cost 1). My view re-assigned the Send button's
  presentation on every render and carried the composer subtree even with no route.
- **Fixed in cba2a710.**
  - The composer joins the view the first time it is offered.
  - `render()` only touches what changed.
  - The budget now also measures the composer-bearing view. It is hosted in a real,
    never-shown window: a bare view tree builds a temporary Auto Layout engine per pass
    and re-lays out every constrained view, which the canvas does not pay.
  - Both variants now cost 1 layout pass per delta, flat across 10, 100 and 1,000 rows.
- **Second run, on cba2a710: 12 legs, all passed.** That includes the new full-access
  leg, the real two-process pair journey and the Linux relay. Log:
  `qa-runs/full-access/gate2.log`.

**Headroom warning.** `--collaboration-native-check` runs in about 43 s of its 45 s
deadline when the machine is loaded (load average around 5 from other benches'
builds). One of my local runs hit the deadline at the last budget measurement. The
composer pass adds about 0.5 s; the journey was already near its limit before that.

## Follow-up: the approval check race (5bbf6db7, branch array/mp-full-access-pi-approval off aa136edf)

**What failed.** The teammate's view drew the host's update first and only then fetched
its prompt receipt. For that gap it showed "Waiting for Dylan to approve" beside a stale
"Queued. It runs on its host after the prompts ahead of it." The check asserted both
lines at once, and once caught the gap (Pi on aa136edf; Codex in another run).

- The gap was sub-millisecond against the in-process service, which is why 20 clean
  runs and 10 runs under CPU stress all passed. Against a real relay it is a network
  round trip.
- The merge's `AgentSupervisor` changes (account switching, helper tile cap) do not
  touch the approval path.
- `ownerSees` was not the cause: `deliver` is synchronous.

**The fix.** `SharedAgentLiveView.poll` now refreshes the receipt before it draws, so one
render shows one moment.

**The witness, made deterministic.**
- The approval is raised as the host accepts the prompt.
- The owner's approval state is waited on with a deadline.
- For this step the scripted service answers receipt reads at a relay's pace (300 ms).
- The assertion is unchanged, and on failure it now prints each condition.

**Evidence.**
- Before the fix: RED 3 of 3, "status 'Waiting for Dylan to approve · live', controls
  'Queued. …'". Everything else was true.
- After the fix: 10 runs, each covering all three harnesses (10 per harness), all
  GREEN.

**Gate** on 5bbf6db7: 14 legs, 13 passed. The one failure is
`--collaboration-native-check` at "share entry (relay): the header Share opened no
popover". It also fails in `qa-runs/coordinator/gate-aa136edf.log` on the integrator's
bench, so it predates this change.
