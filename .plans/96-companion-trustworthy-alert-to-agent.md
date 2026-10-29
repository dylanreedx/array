# Companion: trustworthy alert to useful agent detail

2026-10-28. Backend implementation in progress following Dylan's instruction to
continue. UI/preview work remains separately owned; this slice changes no app
or preview views. Backend rollout is recorded below.

Implemented so far: typed hosted decision IDs and redacted delivery traces,
known-envelope/identity/state validation, cancellation/old-outcome suppression,
newest selected-agent history, revoked-recipient exclusion, persistent source
event dedupe with leased concurrent claims, additive v1→v2 migration, sender
census and offline matrix mode. Authoritative host task/run membership and exclusive relay ownership are now implemented in source; targeted verification is complete. Phone detail/navigation and chat remain outstanding. A durable alert outbox is
now implemented and witnessed in source (checkpoint below); non-alert retry and
host task/run publication is now implemented in source (ownership checkpoint below). No outbox rollout has occurred.

Earlier Fly attempts lacked authentication. After Dylan logged in, read-only
inspection succeeded (2026-10-29 around 02:39 UTC / Oct 28 Toronto):

- One started x86_64 machine, `879206f11ed498`, Toronto `yyz`, shared CPU/512 MB.
- Release v13, Aug 27; image digest
  `sha256:37c76e336b32bcae488415edd9d3384e988fe99ec097eefd57dda364ac4b3fcf`.
- Public health and Fly check pass, schema 1. VM uptime 12 days 8 hours.
- Last recorded crash/restart Oct 16, exit -1, OOM flag false; cause unknown.
- Volume `vol_vgnxq0m5d1nmy514`, encrypted 1 GB: 51% used, 446 MB available.
  SQLite file about 462 MB. About 357 MiB memory available, load 0.00.
- Five daily volume snapshots, five-day retention, newest about one hour old.
  Existence is verified; an application restore has not been exercised.
- Required APNs secret names are deployed; a bounded flag check confirms
  production routing. No credential values were displayed.
- Buffered log output was not usable as JSON event history; no conclusion about
  historical APNs delivery follows from it. Image labels do not identify a
  source commit.

Linux/amd64 validation passed in the Swift 6.1 production toolchain using a
frozen 13-file relay-only context: release product, relay-core behavior and
real local HTTP integration, all using fake APNs. The initial foreground build
attempts were interrupted; the independent runner completed in 168.1 seconds.
Dockerfile now provides a checks stage and RelayPackage exposes the two checks
executables. Production rollout checkpoint follows.

Validation checkpoint: `scripts/run-matrix.sh --notifications` passed with all
4 reported legs; builds include relay-core checks, HTTP integration checks and
the actual relay executable. `git diff --check`, sender-map mutation checks and
matrix inventory checks passed. Intentional RED witnesses reproduced cancelled
completion, revoked recipient eligibility, unrelated/unknown envelope
classification, repeated source alerts and positional-renumbering duplicates
before corrections. Full matrix and physical TestFlight/APNs acceptance remain
unverified. Fly authentication was restored without requesting or reading
credentials; rollout evidence follows.

## Production rollout checkpoint

2026-10-29 02:56 UTC (Oct 28 Toronto): deployed release **v14**, using only the
frozen relay context. Deployment completed successfully in 6.5 seconds.

- Immutable image:
  `registry.fly.io/arrayapp-relay@sha256:a10a0a815a584e00def0963870043b13443143dba91fd26b46d89014e65ef96f`.
- Source manifest digest prefix `739017d4cb11`; exact manifest and artifact
  metadata are in `96-companion-relay-validation/`. Source files matched the
  frozen context before rollout; no Git commit was created.
- Pre-deployment snapshot `vs_70ZlLlNJo923f97n5PokeRAX` reached `created`,
  timestamp 02:54:29 UTC, five-day retention, before machine update.
- Same machine and encrypted volume retained; no extra machine or volume.
- Fly release complete, 1/1 health checks passing; public custom domain reports
  `{"status":"ok","schemaVersion":2}`. Running image digest matches the
  checked runtime image.
- Local runtime smoke booted schema 2 with disposable state, then stopped with
  exit 0 and no OOM. Linux matrix reported 2 legs and freshly executed both
  behavior suites after its cached build; macOS notification matrix reported
  4 legs earlier. Real loopback HTTP and fake APNs only in these checks.
- Deployed startup is observed. No notification trace appeared in the sampled
  live log buffer yet, so real publisher reconnect, Apple acceptance and phone
  display are not claimed. Dylan was asked to confirm TestFlight reconnects
  without pairing again. No synthetic push was sent to his phone.
- Previous image digest is retained in the artifact metadata. Snapshot restore
  and production rollback were not exercised.

Source changes remain uncommitted. The full app release matrix, physical phone
acceptance, root-task consolidation and durable retry/outbox remain outstanding.

## TestFlight waiting screen: observed publication failure

2026-10-29 around 03:15 UTC (Oct 28 Toronto): Dylan reported TestFlight stuck at
“Waiting for your Mac to publish.” Read-only Mac unified logs show repeated
`sendFailed(reason: "payloadTooLarge")` for canvas/status publications from the
installed Mac app. The relay is healthy; the installed Mac remains running and
paired. Successful-publication diagnostics stopped at 21:54 UTC, before v14.
The immediate observed cause is the relay's original 512 KiB decoded event
ceiling, not evidence of an unpaired phone or a missing startup hook.

Recovery slice: accept decoded events up to 8 MiB, cap HTTP accumulation at
24 MiB (including escaped-base64 overhead), and cap each instance's ordinary
event tail at 16 MiB while preserving its latest spatial bootstrap. Existing
desktop activity snapshots are ordinary relay events, so increasing only the
per-event ceiling would create unbounded storage pressure under the old
2,000-event count limit. Rejections log only byte bounds/reason and PUB-05.
The new HTTP witness reproduced RED on a 1 MiB publication before the fix.

Deployed Fly **v15** at **2026-10-29 03:24:54 UTC** (Oct 28 Toronto). Same
machine and volume, 1/1 checks passing, public health schema 2. Immutable image
`sha256:7002553c65e6c68b0bb74b39742a8a6231dd5110005dda4f5a45a66e65b4817f`;
source-manifest prefix `5f54045dd34a`. Pre-deployment snapshot
`vs_qwxBYB8OaeV6h78A9x6bQeAK` was created at 03:20:09 UTC. Frozen source archive,
hashes, macOS/Linux matrix logs and runtime smoke are under
`96-companion-relay-validation/payload-recovery/`.

Witnesses: macOS notification matrix **4/4** legs; Linux/amd64 Swift 6.1
notification matrix **2/2** legs, with freshly run release suites; isolated
runtime schema-2 startup and graceful exit 0/no OOM. HTTP behavior covers a
1 MiB publish and active paired-phone replay, exactly 8 MiB decoded payloads
with worst-case escaped base64, 8 MiB+1 rejection without cursor advancement,
16 MiB retained tail with preserved spatial bootstrap, and early 413 for both
oversized Content-Length and chunked ingress. Full app matrix not run.

Live Mac evidence: the same installed process resumed successful spatial and
activity publications by **03:25:08 UTC**, including nine managed sessions;
diagnostics show paired=true, pairedDevices=1, current publish timestamps and
lastError=nil. No Mac restart or native-app update was used. The sampled relay
logs show no size rejection after rollout. Working-state alert banners were
suppressed (H-05); Apple accepted liveactivity-start requests, and an expired
liveActivity token was invalidated on 410. This does not prove phone display.
Repeated working snapshots currently resend push-to-start (SUR-03), an explicit
remaining consolidation risk. Disk remains 51% used, 446 MB available; pruning
reuses SQLite pages rather than shrinking the database file. Physical TestFlight
screen confirmation is pending; no synthetic phone push was sent.

The remaining 55% is a product estimate, not a task count or schedule. Optimize
for complete useful phone workflows. The first milestone is: leave the Mac,
receive one truthful alert, tap it, identify what happened and what is still
running. The second is replying reliably. Rich canvas imagery follows.

## Continued implementation: explicit task policy

After Dylan's continued instruction, added `RelayTaskState` and the hosted
`task.state.v1` publication path. Task identity, participating run identity and
parent-run edges are explicit; lifetime agent ancestry is not used as task
membership. The policy rejects malformed/disconnected/cyclic graphs, treats
incomplete membership and unknown runs as nonterminal, suppresses successful
children and parents with running/queued descendants, targets the actual human
blocker, and permits completion only when every participant succeeded. Root
cancellation is quiet. Failure remains quiet while a parent/descendant can work;
settled task failure alerts at the root. Terminal claims/collapse are per task.

This is backend implementation in source, **not deployed and not produced by the
installed Mac**. Existing legacy activity notifications remain subject to the
limitations documented above. T-01 through T-07 enter the maintained map in the
same change. The initial task witness reproduced RED through the public policy
entry point; existing matrix legs run the new graph and HTTP delivery witnesses.
Validation results follow when completed. No native UI/preview edits were made.

Validation: initial macOS notification matrix passed **4/4** legs, including
task-policy cases and real HTTP parent-blocked/settled/replayed delivery. After
splitting the HTTP task fixture into a separate function, the final Linux/amd64
Swift 6.1 matrix passed **2/2** legs with freshly executed release suites. The
first Linux attempt was stopped during prolonged integration compilation; it
reported no behavioral result. Final source hashes (16 source/config files),
archive, RED witness and Linux proof are saved under
`96-companion-relay-validation/task-policy/`. The repeated macOS gate initially
waited for other agents' shared builds; those builds were left undisturbed.
Both final macOS checks products rebuilt successfully and passed fresh direct
runs. The repeated gate's third build (relay executable, unchanged by the fixture
split) was cancelled while waiting for the shared build lock; only this task's
waiting process was stopped. That repeated gate has no completed summary. The
initial macOS 4-leg summary and final Linux 2-leg summary are reported matrix
evidence; final macOS direct-run logs are retained separately.
Full app matrix and physical phone acceptance were not run. Production remains
v15; no task-policy rollout or native app restart was performed.

Next host work: persist task/run membership at supervisor user-turn/delegation
seams, include queued work, publish policy facts independently of tile visibility,
and prove exactly one hosted source of notification intent. Do not publish the
new contract alongside legacy activity alerts without a mutually exclusive
notification-ownership/version switch. Prove restart continuity, old-child/new-
task isolation and removal/recovery semantics before migrating live users.

Preview dependency checked read-only at 03:32 UTC: referenced preview agent is
still working on its implementation; recent tool activity is observed, completion
is not established by the retained older terminal outcome. No messages or
interruptions were sent to that agent.

## Slice 1: notification contract and observability

### Alert outbox source checkpoint — 2026-10-29 04:22 UTC

Completed the independent hosted alert outbox/retry slice, following continued
instruction. No native UI, iOS agent-control/session code, prod app/state, Git
mutation, remote deployment or real phone push was performed in this slice.

- Schema 3 adds an alert outbox, per-registration cooldown and terminal identity
  disposition. Event, sequence and eligible recipient intents commit atomically;
  a failure rolls back all three. Existing v1/v2 authority, encrypted tokens and
  accepted source identities survive upgrade; no historical notification replay.
- Encrypted alert envelopes are bound to instance/recipient/decision with AEAD.
  Original summaries/transcripts, tokens and authorization headers are not queued.
  Publication fixes eligible recipients; late detached wakes cannot recreate
  superseded intents or enroll phones paired after the event.
- Startup/periodic worker recovers without republish. Leases fence concurrent
  senders; fresh authority/token lookup runs after lease acquisition. A delayed
  410 cannot revoke a newer token generation. Acceptance and queued body removal
  commit together; completion IDs remain deduplicated across restart.
- Maximum five attempts, one-hour lifetime, 256 pending per instance and 32 claims
  per drain. Transport/429/5xx retry uses persisted exponential backoff, honors
  Retry-After and observes Apple's minimum fifteen-minute 5xx delay. Cooldown is
  shared by recipient, so new source identities cannot bypass it. Permanent
  responses, expiry, exhaustion, revocation and supersession close the intent.
  Sync still commits when queue capacity rejects an additional alert.
- Quiet/working/cancelled observations withdraw obsolete pending alerts. Rejected
  new state with a valid known subject also withholds prior work; unrelated
  envelopes confer no cancellation authority. Existing task IDs stay independent.
- OUT-01…OUT-13 map every lifecycle transition. The sender census now includes
  literal header dictionaries and typed outbox IDs; behavior checks require
  every outbox transition to have an actual witness.

Verification: final `--notifications` matrix **4/4**, final
`--notifications-linux` **2/2**, both rebuilt/freshly executed. Both Linux suites
also passed at 512 MiB memory with swap disabled. Witnesses include atomic
rollback, v2 credential/token/accepted-identity preservation, no-sender commit
followed by restarted worker delivery, real worker 503→shutdown→virtual +900s
recovery, bounded attempts/age/capacity, fresh-identity throttle bypass rejection,
authority revoked before/after claim, token rotation, concurrent/stale leases,
cross-context ciphertext rejection and database failure before/after Apple
acceptance. No exactly-once phone-display claim: uncertain acceptance can repeat
with the same persisted apns-id after lease recovery. Initial HTTP restart
witness was RED before the outbox. One intermediate retry-worker fixture timed
out because its frozen clock preceded commit; corrected by advancing it past
commit, and final gates passed. Full app/release matrix and real phone/APNs
acceptance remain unrun. Frozen 20-file source archive, pins and logs are under
`96-companion-relay-validation/outbox/`.

Remaining limits: widgets/Live Activities remain best effort, including the
previous repeated-start weakness. Legacy one-agent selection, missing host task
revisions and received-order ambiguity remain; outbox reliability does not make
legacy aggregation truthful. Compact accepted/terminal metadata is retained
indefinitely while payloads are bounded; a safe pruning horizon is not defined.
A future schema-3 rollout needs a tested compatible rollback or snapshot-restore
plan. Production was rechecked read-only after validation: v15, one passing
health check, public health schema 2. No source-outbox rollout occurred.

Preview prerequisite correction: owner commit `efcce530` exists locally, and
`.plans/92-ios-device-preview/release-handoff.md` records the completed original
human preview, actual companion build/install/launch and tile proofs. The
currently running agent is implementing optional agent-control follow-up;
its working status does not invalidate that original prerequisite. Owner proofs
were reviewed, not independently rerun here. Continue host task/run publishing
and a mutually exclusive notification-owner migration next; native UI work
should use the verified human preview rather than wait for optional API work.

Source of truth: docs/internals/notification-paths.md. Stable path IDs cover
production, diagnostic, quiet, failure and retired routes. Begin with an
executable typed decision catalog: all official triggers/senders/categories
must classify; an unknown reason must never become a guessed alert. Add a
structural census for new delivery entry points, clearly separate from tests
of behavior. Make both reported matrix legs; no source-string behavior claims.

Introduce task/run membership, distinct from lifetime agent ancestry, using
authoritative supervisor lifecycle/queued-work facts. Publish state independent
of tile visibility. Log decision IDs/reasons and source timestamp/sequence.
Prove that unknown child state cannot authorize completion. The map must change
with each new event or decision branch, never as a later documentation chore.

Acceptance: every emitted or suppressed official notification is explainable by path
ID, task, source event and policy reason; independent tasks do not collapse
into one another; a new run on a reused agent remains eligible.

## Slice 2: trustworthy notification delivery and state

Replace recursive snapshot guessing with typed policy decisions. Implement
quiet child success, root completion barrier, request-level attention dedupe,
cancelled/interrupted semantics and foreground suppression. Add durable outbox,
bounded transient retry and restart recovery, redacted APNs diagnostics and
recipient revocation. Persist intent before sending. Apple acceptance remains
distinct from phone receipt/display.

Publish real desktop timestamps/heartbeats; replay cannot appear current. Check
paired transcript key continuity and resolve it before relying on live detail.
Keep all map entries current. No capacity redesign or horizontal scaling is
required for this milestone; verify backups/restore and basic server visibility.

Done: 14 child successes → zero child alerts and one eventual root completion;
parent settles with one child running → no completion; actionable blocked child
→ one alert; replay/restart → no duplicate; revoked phone → no later push.

## Slice 3: the alert opens a useful agent

Propagate actual agent name, project, task and parent/child context. Use stable
agent IDs for foreground and cold-launch navigation to exact detail. Show
readable conversation, blocker reason, still-running children, truthful source
freshness and clear unavailable/deleted-target handling. The canvas remains
navigation context. Do not promise approval actions until runner execution is
proved; report unsupported actions honestly.

Done: on the exact TestFlight build, a push answers who needs me, what happened,
what is still running and whether the Mac is reachable. Verify foreground,
background, terminated state, Mac sleep and reconnect. Record actual banners
separately from decision counts and APNs accepted requests.

## Slice 4: agent-requested notification intent

Add array_notify through the shared Pi/MCP catalog with caller-derived task and
destination, explicit grant, idempotency, privacy, budgets and preferences.
Requests enter slices 1–2's same engine; children cannot override completion
barriers. Support needs_input/completed plus opt-in truthful milestones. Return
recorded/queued/coalesced/suppressed with reason and recoverable operation ID.
This can join slice 2 once the common policy path exists.

## Slice 5: reliable phone conversation

Add an explicit send capability and encrypted payload-bearing command lifecycle,
host execution ACK and reconciliation. Start with text to existing idle managed
agents. Preserve draft until acceptance; distinguish pending/accepted/rejected/
unknown. Prove a duplicate/reconnect causes exactly one prompt append and that
its reply reaches the phone. Add busy queue/steer and attachments only after
capability-specific behavior is witnessed. Human input uses supervisor send,
not the agent-to-agent message attribution route.

## Later: richer map and companion breadth

Improve structural coverage and agent tap-through, then bounded semantic tile
snippets/on-demand images with capture timestamps. Defer continuous streaming,
canvas editing, remote agent creation, broad management and widget polish until
the core attention→context→reply loop survives daily use. Revisit each deferred
area explicitly; a long feature checklist does not define product readiness.

## Acceptance gate

Every substantive change owes offline behavioral witnesses reported by the
matrix, plus relevant real-device TestFlight proof. Test nested grandchildren,
concurrent independent tasks, old children/new root run, unknown child state,
transient APNs failures, token rotation/410, revocation, stale replay and lost
ACK. Never change baselines or run checks against the live tmux namespace.
No percent-complete advancement without a demonstrated user workflow.

## Authoritative Mac task membership and exclusive notification owner — source checkpoint

2026-10-29: implementing the planned host slice without deployment, phone push,
Git mutation or native iOS UI changes. The supervisor persists accepted root
turns, explicit delegated/provider children, durable queue admissions/item IDs,
readiness holds, compaction and steer outcomes. Runner generation/provider turn
fences protect newer work; restart/imported provenance stays unknown. Publication
is independent of tile subscribers/canvas, uses bounded app coalescing and a
serialized task publisher with a 10-second periodic refresh.

Source relay schema 4 advertises task.batch.v1. First full batch atomically
establishes a persisted publisher/revision, quiet baseline and cancellation of
legacy pending intents. Legacy activity then remains inventory only on every
hosted surface. Persistent per-decision recipient cohorts prevent newly paired phones
from receiving history; baseline identities remain quiet after an interim unknown
state. Stale/conflicting/foreign publications cannot roll ownership backwards.
Task-mode widgets/existing Live Activities use one aggregate; push-to-start is
suppressed. Stable HOST-01…07 and OWN-01…07 paths are maintained in the map.

Final gates: Mac task matrix 7/7, Mac notification matrix 4/4, Linux notification matrix 2/2; both Linux suites also passed with 512 MiB/no swap. Generic iOS Simulator build succeeded. Frozen source, behavior logs and limits are recorded in qa-runs/overnight-2026-10-29/companion-task-ownership-handoff.md.
Production remains v15/schema 2, without this source ownership/outbox slice.
Original human iOS preview prerequisite is satisfied by efcce530 and the owner's
.plans/92 release proof; optional additional agent-control API is separately owned.

## Slice 3 source checkpoint: alert opens the exact agent and task

2026-10-29. Codex implemented this slice and stopped at 08:09 UTC on a usage
limit, partway through its final gates. Claude Code reran the interrupted gates
at 12:40 UTC; no source was changed in the rerun.

- A notification link carries agent/task/run/instance IDs
  (`CompanionAgentDestination`, map row IOS-03). A cold launch holds the link
  until the model and pairing have loaded. Detail shows the task from the alert,
  never whichever task the reused agent is on now, plus that task's
  finished/running/queued/blocked participants and its freshness. Legacy,
  foreign, missing and deleted targets show an explicit unavailable state.
- Gates: `--companion-tasks` matrix **8/8** (rerun, passed);
  `--notifications-linux` **2/2**; generic iOS Simulator build succeeded
  (rerun). Negative control: the real destination source, compiled in an
  isolated copy with task equality inverted, goes RED; unchanged it goes GREEN.
  An earlier attempt in the shared checkout was abandoned and restored before it
  compiled, so it proves nothing.
- Rendering: a DEBUG-only fixture (`CONTINUUM_COMPANION_DETAIL_QA=1`; no
  Keychain, network or token) on a disposable simulator, which was then deleted.
  Light and dark screenshots are in `qa-runs/overnight-2026-10-29/companion-detail/`.
  A clipped status chip in one dark screenshot did not recur after relaunch.
- Not verified: APNs delivery, the real TestFlight build, physical
  foreground/background/terminated taps. Production is still Fly v15 (schema 2),
  without the outbox, task ownership or exact-destination slices. Nothing has
  been committed.

Next: slice 5 (phone reply) needs a new authenticated command contract. Today's
relay accepts approve/stop only, and the Mac's transcript keys come from local
sessions, not hosted phone credentials. Slice 4 (`array_notify`) can reuse the
task policy path that now exists.
