# Worker 7: COL-15 live agent views

30 October 2026. Bench `.worktrees/mp-w7-live`, branch `array/mp-w7-live`,
rebased onto `array/collaboration-finish` at fe041913. Not pushed. The
integrator (42F5389C) merges this branch.

## What a teammate sees

Selecting a published agent in a shared workspace replaces the inspector's
reader with a live view of that agent:

- a status line, for example "Working · live";
- what its host can do right now, and that steer, interrupt and approvals stay
  with its owner while prompts go through a handoff;
- its assistant text and tool steps ("• Command · done"), newest last.

The agent keeps running on its owner's machine. Nothing runs on the teammate's.
When the area reports the host offline, the view reads "· host offline, last
confirmed" and offers nothing. A stale host stays live, since it may still be
running. History from before the agent was shared is excluded unless the owner
chooses to share assistant output.

Renders, light and dark, offscreen:
[light](../validation/live-agent-view/live-agent-light.png),
[dark](../validation/live-agent-view/live-agent-dark.png).

## How it works

- **Host.** `SharedAreaHostSession` owns a `SharedAreaAgentProjectionHost`,
  which owns one `SharedAgentProjector` per published local agent.
  - Each projector attaches through the supervisor's atomic
    `transcriptAttachment`.
  - It refuses to attach without a semantic snapshot boundary.
  - An allowlist on the host drops prompts, reasoning, tool titles and output,
    requests, usage, error text, provider ids and control characters.
- **Wire.** Every frame carries host, object, a per-object host generation
  (persisted, so a relaunch always supersedes) and a sequence.
  - One portable reducer (`Collaboration.AgentProjection`) runs on the host, in
    the service log and in every viewer's replica.
  - A gap, an older generation or a cursor older than the 512 retained frames
    gets an explicit resnapshot.
- **Service.** `collaboration_agent_projection` holds one sealed log per agent.
  - Only the publishing device, as owner, may write.
  - Any current member may read.
  - Unpublishing deletes it, and backups authenticate it.
- **Controls.** Read from the bound runner via `turnSnapshot`.
  - Interrupt is advertised only with a bound steering runner; teardown never.
  - Remotely only send and queue exist, and only for the control holder.
- **Excerpts (COL-14).** `ResultExcerpt.Source` now cites a `Position`
  (generation and sequence) instead of a bare sequence, and each row records
  the frame that last changed it. Worker 8's view and checks were moved over;
  the displayed "event 42" wording is unchanged.

## Criteria and witnesses

| Criterion | Witness |
| --- | --- |
| Late join gets the snapshot plus every allowed event, or an explicit resnapshot | Service checks: late join, paged cursor reads (120 events, 18 pages, duplicates ignored), retention resnapshot, HTTP late join and cursor. Native: B's mounted scene reads a snapshot first, then frames |
| Snapshot/tail race | Native: events delivered in the attach turn and after it each arrive once |
| Gaps | Service: replica stays contiguous; host gap refused over HTTP. Native: lost frame after acknowledgement forces one host resnapshot; B's scene repairs a transit gap with exactly one resnapshot |
| Private history and raw side channels never cross | Native: delivered bytes hold no pre-publication history, reasoning, tool title or output, request, usage, error text, provider id or escape; included history is assistant output only; real fake-CLI turns never carry the prompt or provider item ids |
| Background turns | Native: an unsolicited turn updates status and text with zero executors |
| Stale generation | Service: stale frames and snapshot refused; viewer ignores the old session. Native: relaunched generation supersedes and the old projector stops |
| Attach and remount create no executor | Native: three recipient remounts, zero executors; per harness, two attached projections and one turn start exactly one CLI process |
| All three harnesses | Native: Claude, Codex and Pi through `AgentSteeringQAFakes` on PATH with the production runners. Each turn projects its tool step; Codex and Pi also project assistant text from a real steer |
| Controls from the bound runner | Native: bound production runner types advertise steer and interrupt only while bound; remotely only queue; a binding change arrives as a sequenced capability frame |
| QA-only capability false positive | Native: a QA `RespondingRunner` that the supervisor would let answer requests publishes no approval or steer |
| Watched sessions and unwired approvals unavailable | Native: a watched session publishes no controls; `RemoteControls` never offers steer, interrupt or approval |
| Live view lifecycle | Native: deselect hides it and stops reading, reselect resumes, unmount stops the read loop, offline host from the area's liveness turns it into history |

## Teeth (RED, then restored, then GREEN)

1. Reducer gap guard removed: "a dropped frame is detected as a gap" went RED.
2. Log accepts any generation: "a stale host generation's late frames and
   snapshot cannot update the log" went RED.
3. Projector attaches through the replaying `events(for:)`: "events delivered
   in the attach turn and after it each arrive once" went RED.
4. Capabilities from `record.harness`: "Claude: a bound production runner
   advertises steer/interrupt…" went RED.
5. Scene unmount without `livePanel.stop()`: "unmounting stops the read loop"
   went RED.

The included-history witness also caught a real leak on its first run. Message
cards include reasoning entries and notices, so history now admits assistant
cards only.

## Findings for others

- The Claude fake sends whole assistant messages, never `text_delta`, and the
  translator rightly drops those for the main thread. A Claude turn through the
  fake therefore shows a tool step and no text.
- The Codex fake omits `exitCode`, so the translator reports its command as
  failed.
- Earlier, `verification refuses a backup with damaged pages` was red on
  e17d0a52 with every projection hook disabled. cdc244a4 on the base fixed it.

## Lead-owned hunks

All are small and kept on this branch:

- `AgentSupervisor` adds `hasTranscriptSnapshotBoundary` and the QA-only
  `qaBindRunnerForCapabilities`.
- `SharedAreaController` adds projection publish/read on the transport.
- `SharedAreaHostSession` creates, syncs and stops the projection host.
- `CollaborationStore` registers the migration and calls the access refresh.
- `CollaborationRoutes` adds one line for the route.
- The service checks' `main.swift` gets one call.
- `--collaboration-native-check` gets one stage.
- `SharedAreaSceneView` adds the panel, its frame and one visibility rule in
  `refreshReader`, beside the artifact rule.

## Left

- The live view polls once a second while an agent is selected. Waking on the
  presence lane instead would need a client session hunk.
- Handoff's Send now does not yet read the projected `canSend`. It still relies
  on the host refusing at dispatch.
- No real-provider run, deploy or push was made.

## Gate

One run under `.worktrees/.locks/app-build.sh`, isolated `CONTINUUM_APP_SUPPORT`
and `TMUX_TMPDIR`, `CONTINUUM_SKIP_UI_BASELINES=1`:

    scripts/run-matrix.sh --collaboration
    ---- Collaboration matrix (targeted): 11 leg(s) run ----
    Collaboration matrix (targeted) passed.

The log shows 37 native live-projection assertions in the
`--collaboration-native-check` leg. It also shows the 26 service projection
assertions three times: once on the Mac, then twice in the Linux container
(normal, and with networking disabled except localhost). The one note is the
display-dependent theme witness that baselines-off skips.
