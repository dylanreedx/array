# Companion catch-up and proposed roadmap

Date: 2026-10-28. Planning only; no implementation authorization inferred.
Follow-up: maintained notification inventory is now
`docs/internals/notification-paths.md`; the next proposed implementation slices
are `.plans/96-companion-trustworthy-alert-to-agent.md`.
Fourteen subagents inspected UI, chat, canvas, desktop push, APNs delivery,
notification policy, Fly operations, relay architecture, pairing/security,
sync/freshness, TestFlight, verification, notification tooling, and roadmap.

Follow-up checkpoint, 2026-10-29 UTC / Oct 28 Toronto: Dylan authorized continued
backend work. The findings below preserve the initial audit; current implementation
and deployment evidence is in `.plans/96-companion-trustworthy-alert-to-agent.md`.
Hosted decision tracing, durable source-event deduplication, revoked-recipient
exclusion and cancellation suppression were deployed as Fly v14 with passing
targeted macOS/Linux gates. Task-tree consolidation, retry/outbox and usable
phone conversation remain outstanding. Fly authentication/resource/backup status
has since been verified. TestFlight's waiting screen was traced to repeated Mac
`payloadTooLarge` errors from the old 512 KiB relay limit; a bounded server-side
compatibility fix shipped as Fly v15 at 03:24:54 UTC. The existing Mac process
then resumed successful canvas and activity publication without a restart.
Physical TestFlight screen confirmation remains pending. Server health alone
did not prove sync.

Later checkpoint, 2026-10-29 04:22 UTC: source-only durable hosted alert outbox
and retry are complete with macOS/Linux matrix proof; see /96 and its `outbox/`
validation folder. Production remains v15/schema 2; no new rollout. The original
human iOS preview prerequisite is locally committed at `efcce530`, with owner
build/install/launch and production tile evidence in /92/release-handoff.md.
Optional agent-control API work is a separate follow-up and must not be mistaken
for an unfinished original human-preview prerequisite.

## Product assessment

Dylan's 45% estimate is reasonable shorthand for a connected alpha, not a
measured completion percentage. His phone demonstrates pairing/basic activity,
canvas overview and real notification receipt. Source has substantial plumbing,
but that does not establish production end-to-end reliability.

Priority: trustworthy notifications and a useful agent view with conversation.
Wait for the separate iOS-in-Mac-canvas preview integration before implementation.
That preview is a development/QA dependency, not the technology for showing the
Mac canvas on the phone. Agent 21187CCF-7F90-452B-A4E8-E2686A074B23 was inspected
read-only: its last report proved fixture frame transport/native view/input,
with real simulator interaction and production canvas integration unverified.

## Current evidence

| Area | Implemented in current source | Remaining confidence/product gap |
| --- | --- | --- |
| Pairing | Hosted one-use expiring grants, device credentials, Keychain | Revocation must stop pushes and existing socket authority |
| Agent list/detail | Stable-ID navigation, status/summary, timeline, parent links, conditional semantic transcript | Recognizable name/project/task, grouping, transcript proof; notification tap currently selects tab rather than exact detail |
| Chat | No composer, send vocabulary or send scope | Encrypted command lifecycle and authoritative Mac execution, not just a UI field |
| Controls | Stop request/ACK plumbing and approval UI | Hosted command execution not proven; production approval responder uses UnknownRequestApprovalSeam |
| Canvas | Real installed-tile geometry/zones, simplified rectangles/title/status, pan/zoom/focus | Content previews absent, below-tier tiles may be missing; edits explicitly disabled |
| Notifications | Hosted APNs classifier for approval/input/failure/finished | No task-tree consolidation, durable dedupe, retry/outbox or delivery diagnostics |
| Freshness | Reducer and cached/offline UI | Desktop heartbeat publisher logs only; phone assigns receipt time as source time, making replay look live |
| Testing | Core/Sync/relay checks, matrix iOS build | Matrix does not run iOS XCTest; physical TestFlight product acceptance remains necessary |

Latest documented iOS upload: 0.1.0 (2026082701), Aug 27, in
docs/VERSIONING.md. Current phone version and deployed relay revision were not
verified. Source entitlements are not proof of final distribution entitlements.
Public docs still describe coming soon; old 92-small-team-relay ledger/STOP
is design history, not a trustworthy record of today's implementation.

## Fly status

Live checks:

- https://arrayapp-relay.fly.dev/health: HTTP/2 200 at 16:52:05 UTC.
- https://relay.arrayapp.dev/health: HTTP/2 200, response Date 16:53:34 UTC.
- Both returned {"schemaVersion":1,"status":"ok"}.

The health route reads SQLite metadata; it does not establish database writes,
disk space, Mac presence, current device registration, APNs health or phone
delivery. flyctl status/checks/machines/volume queries failed: normal invocation
could not write protected ~/.fly config; isolated temporary config had no access
token. No secrets were read and no server mutations were performed.

Repository configuration (not verified deployed inventory): arrayapp-relay,
Toronto yyz, shared CPU/512 MB, minimum one always-on machine, 1 GB persistent
volume at /data, public HTTPS 8080, private admin listener 9090. SQLite persistence
and persist-before-broadcast event sequences provide a useful single-node alpha
base. No production replication or off-machine backup/restore was established.
Actual uptime, restarts/OOMs, resource usage, deployed revision, backup state and
cost remain unknown.

## Findings to resolve before claiming confidence

1. Hosted RelayAPNSService recursively chooses the first status/agentId object
   in a sync.message, including a full snapshot. It has no previous-state gate
   or parent/run identity. Repeated snapshots can re-alert old terminal state,
   while other agents can be overlooked. Ordinary progress is already quiet.
2. Terminal collapse ID is per Mac instance, not per task. It is neither a
   completion barrier nor a guarantee against already-delivered banners.
3. The hosted sender is separate from the older Core APNSPushService with its
   stronger preference/transition tests. Do not count those tests as hosted
   confidence. Cancelled/interrupted done fallbacks can say completed.
4. Hosted push is best effort: untracked task, swallowed failures, no durable
   outbox/backoff; only 410 invalidates a registration. Foreground presentation
   also always enables banners/sound, even when viewing an agent.
5. Credential revocation does not revoke push-registration rows; recipient
   lookup does not join active credentials. Source indicates revoked phones
   can remain push-eligible. Existing WebSocket auth also needs revalidation.
   These are source findings requiring behavioral reproductions.
6. Hosted transcript key continuity appears broken: phone derives from hosted
   credential/instance, desktop derives from local auth sessions/local instance.
   Prove actual paired-device transcript delivery before promising conversation.
7. Desktop freshness heartbeats/power hints are logged rather than transmitted;
   incoming replay receives fresh timestamps on iOS. Quiet Mac versus sleeping
   Mac and disconnected transport are therefore not reliably distinguished.
8. Relay v2 command receipts currently recognize approval.respond/agent.stop
   but do not constitute a payload-bearing execution queue. There is no chat
   command. Verify the actual hosted production transport path for every control.
9. Rich activity originates at tile event ingestion; headless-agent coverage
   is incomplete. Notification truth must come from app-owned lifecycle state.

Key source anchors:

- iOS/Continuum/Sources/ContinuumApp.swift:219,509,1007,1105,1156,1279,2251
- Sources/ContinuumRevived/App/ContinuumApp.swift:14,7948,11300,11366,11389
- Sources/ContinuumRevivedSync/DesktopCompanionSyncService.swift:374,445
- Sources/ContinuumRevivedRelayCore/RelayAPNSService.swift:76,112,175,226
- Sources/ContinuumRevivedRelayCore/RelayStore.swift:95,225,238,279
- Sources/ContinuumRevivedRelayNIO/RelayServer.swift:132,228
- Sources/ContinuumRevivedAgentUI/AgentLifecycle.swift:193
- Sources/ContinuumRevivedCore/AgentsBoardProjection.swift:14

## Notification policy proposal

The host decides notification intent from authoritative lifecycle facts; the
relay delivers it. Use a user-task/run identity as well as parent ancestry:
agents are reused, and old children must not block an unrelated new turn.
Reuse existing descendant-blocker semantics, including queued turns. Unknown
or disconnected state cannot establish completion. A run finishing is not
proof that the user's objective was achieved.

| Scenario | Default behavior |
| --- | --- |
| Child succeeds while parent works | Update activity, no push |
| Parent finishes with a task child running/queued | Keep task active, no completion push |
| Root and participating descendants settle successfully | One task completion after a short settle window |
| Child fails but parent can recover | Detail/activity update; defer standalone alert |
| Task needs human input or approval | One actionable alert naming/linking the actual blocker |
| Duplicate snapshot/reconnect/restart | No new decision for the same durable event identity |
| New independent task on the same agent | New notification eligibility |
| User views agent in foreground | Update detail; suppress redundant banner by default |
| Mac disappears during work | Stale/unknown, never infer done |

Separate task aggregation from optional cross-task digests. A settle delay alone
does not establish that descendants finished. Attention alerts need request-level
dedupe and resolution; recovery should cancel still-pending obsolete alerts.
Honor notification categories, quiet hours and user preferences centrally.

## Agent notification tool proposal

Add array_notify / notification.request through the shared workspace-tool
catalog, covering Pi, Claude and Codex. No such tool exists currently.

Inputs: reason (needs_input/milestone/completed), bounded message and stable
idempotencyKey. Host derives caller/project/task/destination, checks a distinct
notification grant and applies the same aggregation/budget/preferences policy.
Children cannot bypass the completion barrier. Milestone alerts are opt-in and
truthfully described as updates while work continues. Agent-written lock-screen
text needs an explicit privacy policy; current safe payload boundaries should
remain the default. No arbitrary recipients, device tokens or credentials.

Return recorded/coalesced/suppressed/queued with a reason and recoverable operation
ID. Do not call an APNs acceptance proof of phone display. Maintain an activity
inbox so suppressing a push does not discard useful information.

## Proposed sequence after preview integration

1. **Establish truthful state.** Resolve hosted transcript/key routing, source
   timestamps/heartbeat, task/run membership, headless lifecycle coverage and
   revocation. Record exact installed TestFlight build and relay revision.
2. **Notification confidence + agent identity.** Replace snapshot guessing with
   typed durable decisions/outbox, retries and redacted diagnostics. Named
   agent/project/task list and detail, root/children state, exact deep links.
   Attach array_notify to this same policy in this milestone.
3. **Useful mobile agent conversation.** Readable live transcript first; then
   text follow-up to existing idle managed agents with an explicit send scope.
   Use stable request ID, expected agent/session identity, encrypted content,
   persisted drafts and Mac execution ACK. Distinguish queued/accepted/rejected/
   unknown. Start with clear busy refusals; add queue/steer only per actual
   provider capability. Avoid routing human sends through agent.message.
4. **Canvas as navigation.** Improve structural coverage/focus and tap-through
   to useful detail. Add bounded semantic snippets, then optional timestamped
   on-demand tile images if a mobile use case warrants them. Full remote canvas
   streaming/control is a separate, substantially larger project.
5. **Physical TestFlight acceptance.** Validate foreground/background/terminated
   behavior, cold deep links, Mac sleep/reconnect, revoked pairing and realistic
   parallel-agent work on the exact distributed build.

## Required witnesses

- Fourteen task children complete: zero child-success alerts, one root alert.
- Root finishes while one participating child runs: no completion alert.
- Nested blocked child: one actionable alert, tap opens correct detail.
- Duplicate tool key, repeated snapshot, relay restart and replay: no new intent.
- New task on reused root: completion still eligible; old child does not block it.
- Cancelled/interrupted/unknown states never become successful completion.
- Retry 429/5xx/network failure with bounded backoff; 410 removes token;
  revocation prevents later delivery and cached-socket commands.
- Phone send double-tap/drop/reconnect: exactly one authoritative prompt append;
  draft survives uncertain delivery, wrong session/scope/instance refused.
- Freshness distinguishes old replay, awake idle Mac, asleep Mac and lost network.
- Separate policy decisions, APNs accepted requests and witnessed phone banners.
- Register behavioral checks in matrix and verify its final summary actually
  reports them. Existing source-string assertions do not establish behavior.

## Work performed and limits

Read-only source/config/history inspection, fourteen subagent reports, read-only
preview-agent inspection, public health HTTP requests, attempted read-only Fly
CLI inventory, and scripts/benches.sh inventory. This note is the only intended
workspace edit. No builds/tests/matrix/simulator/device acceptance were run;
no pushes were sent; no agents were messaged/interrupted; no Git mutation,
deployment, restart, app launch or cleanup was performed. Existing unrelated
workspace changes were left in place. All suspected defects above remain
source findings, not executed RED/GREEN witnesses.
