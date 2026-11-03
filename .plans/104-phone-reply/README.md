# Phone reply: commands that reach the Mac, a shared pairing secret, then reply

Handoff, 2026-10-29; updated 2026-11-01. Bench `.worktrees/phone-reply`, branch
`array/phone-reply`, rebased onto 0.7.37 (`2af6fdd8`). `array_notify` shipped
in 0.7.35. Steps 1, 2 and 3 are built (local commits, not deployed).

## Decision (Dylan, 2026-10-29)

**Option A:** the Mac puts a random secret in the pairing QR/link. Only the
phone reads it, the relay never sees it, and both sides derive keys from it.
That fixes transcript reading on the phone and encrypts replies. Cost: Dylan
re-pairs the phone once after the update. Option B, relay-readable plaintext,
was rejected.

## Finding: hosted phone commands are broken in production

Verified in source on the bench:

- The phone sends Stop and Approve as `sync.message` events over
  `POST /v2/events` (`RelaySyncTransport.swift:140-178`). `RelayStore.publish`
  requires `.publishState` (`RelayStore.swift` publish guard), and the companion
  credential has `RelayWire.companionCapabilities` (read×4, respondToApprovals,
  stopAgents), so the relay answers **403**. Nothing reaches the Mac.
- `POST /v2/commands` (`RelayServer.swift:170`, `RelayStore.acceptCommand`)
  checks capability and stores a `commands` row with an idempotency key. But no
  client calls it and nothing delivers the rows to the Mac (write-only table).
  `RelayCommandRequest` has no payload field.
- On the Mac, approval goes through `UnknownRequestApprovalSeam` →
  `unknownRequest` in every case (IOS-04). Stop uses `supervisor.stop` (teardown
  kill), not `accept(.stop)`. Authority is the static hosted scope, not a
  per-message sender, and stop has no dedupe.
- The Mac's transport uses `startAtHead: true`, so anything sent while the Mac
  was offline is skipped.
- Transcript keys: the phone derives
  `TranscriptSyncCrypto.derivePairedSessionChannel` from its hosted credential
  and hosted instance id. The Mac derives from local `companionAuthService`
  session tokens. The relay keeps only a hash of the hosted credential, so the
  keys never match and the phone stays activity-only.
- To fix: map row IOS-04 should also say that hosted publish is refused (403)
  before the Mac. Stop is not in the map.

## Plan

1. **Command delivery (needed whatever the key choice).**
   - Payload-bearing `RelayCommandRequest` (opaque sealed bytes) with a
     per-device sender.
   - The desktop reads pending commands by cursor (a new endpoint, desktop
     credential). Durable across the Mac being offline: no `startAtHead` skip
     for commands.
   - The desktop posts a result (accepted, rejected with a reason, executed).
     The phone reads results by idempotency key.
   - Move phone Stop and Approve onto it; Stop goes through `accept(.stop)`.
     Approval still needs a real execution seam; until then report
     unsupported honestly.
   - Witnesses: RelayCore, RelayIntegration (HTTP), Sync and app legs, RED
     first. Map rows for each outcome.
2. **Shared pairing secret (Option A).**
   - The Mac generates a secret at pairing-grant time and puts it in the QR/link
     (never sent to the relay). The phone stores it in the Keychain. Both derive
     the transcript channel key and the command seal key from it, plus the
     instance and device ids.
   - Old pairings keep working as today (activity-only) until re-paired.
3. **Reply.**
   - New capability on both sides (relay `RelayCapability` and app `Scope`).
   - The phone composer on agent detail; text sealed; idempotency key per
     draft; the draft is kept until the Mac accepts.
   - States: pending, accepted, rejected (reason), unknown.
   - The Mac executes through `AgentSupervisor.accept(.send(text), for:)`
     (refusals: `IntentRefusal`), never `sendAgentMessage`. Start with idle
     agents; queue/steer only once witnessed.
   - Prove a duplicate or reconnect appends exactly one prompt, and that the
     agent's answer reaches the phone (needs step 2).

Every relay change waits on the schema-4 rollout (`.plans/103`). Deploys,
TestFlight and re-pairing need Dylan's go.

## Built: step 1, command delivery (2026-11-01)

- Relay schema 6 (`relay-command-delivery`, additive: `payload`, `outcome`,
  `detail`, `completed_at` on `commands`). Routes `GET /v2/commands/pending`
  (Mac), `POST /v2/commands/{key}/result` (Mac), `GET /v2/commands/{key}`
  (sending phone only). Commands live 10 minutes; a revoked phone's queued
  commands are dropped.
- `RelayCommandChannel` + `CompanionCommandReceiver` in Sync. The Mac collects
  "everything unanswered" every 2 s (backs off to 60 s against a relay without
  the queue), so a command sent while the Mac was offline still runs.
- Mac actions (`CompanionCommandActions`): Stop = `accept(.stop)` with
  `notRunning` when there is nothing to stop; Approve = `respondToRequest`
  → `sent` / `unknownRequest`. Also used by the local-relay/CloudKit path.
- Phone: on an https relay, Stop and Approve use the channel and wait 5 s.
  Pending, expired and old-relay states have their own sentences.
- Map: IOS-04 corrected, CMD-01…07 added.
- Witnesses: RelayCoreChecks `runRelayCommandChecks`, RelayChecks
  `runCompanionCommandDeliveryChecks` (real server over HTTP + production
  `DesktopCompanionSyncService`), app `--companion-command-check`. Mutations
  (old teardown Stop, no receiver, no revocation filter, no expiry) each RED.

Not covered: the one-line composition in `makeDesktopCompanionSyncService`
(app actions → service) has no leg of its own; nothing has run against a
deployed relay or a real phone.

Finding (corrected): the Mac does put the request id on needsAttention
events (`ManagedAgentActivityBridge.swift:60-63`), but managed agents never
open approval requests: Claude runs with `bypassPermissions`
(`ClaudeAgentRunner.swift:304`), Codex with `approval_policy=never`, and no
production runner implements `AgentRequestResponding`. So phone Approve is
deliverable but unreachable by design until permission prompts are turned
on. Latent bug to fix then: after r1 closes with r2 still open, the event
carries r1; the published id should be the oldest open `.approval` request
(excluding `toolUserInput`).

Rollout: relay first (schema 6 rides the same additive/rollback reasoning as
`.plans/103`; an older relay inserts commands by column name), then the Mac,
then a phone build. Either half alone is inert: a new Mac backs off quietly on
an old relay; a new phone on an old relay says the relay needs an update.

## Built: step 2, the pairing secret and hosted transcripts (2026-11-01)

Found while building: matching keys alone would not have shown a transcript.
The phone asked for transcripts with a `transcriptSubscribe` sync event, and
the hosted relay refuses every phone-published event (the same 403 as Stop).
So the request now rides the step 1 command queue.

- Link: `PairingURL.hostedIssue(…, secret:)` adds 32 random bytes (base64url)
  to the fragment. The arrayapp.dev `/pair` page forwards the fragment
  byte-for-byte, and fragments never reach Vercel or the relay.
- Mac: `createCompanionPairingInvitation` saves the secret in the Keychain
  (`CompanionRelayProvisioning`, account `pairing-secrets`, newest 16) before
  showing the code, and drops it only when the relay confirms the link was
  cancelled unredeemed. The Mac cannot tell which phone redeemed which link,
  so it keeps one key per link; an unused key costs nothing.
- Keys: `TranscriptSyncCrypto.derivePairingSecretChannel(secret, instanceID)`
  (HKDF; the key id is derived too, so it does not reveal the secret).
- Request: `transcript.request` (relay capability `readTranscripts`), payload
  `CompanionTranscriptRequest {keyID, knownVersion}`. The Mac's
  `TranscriptProjectionSender.publish` answers with an encrypted event:
  `published`, `unchanged`, `unavailable`, `unknownKey`.
- Phone: stores the secret in its Keychain session (`pairingSecret`, optional,
  so old records still load). The agent detail asks every 5 s while open and
  shows the Mac's answer when there is nothing to show (no transcript yet,
  Mac or relay needs an update, waiting for the Mac). A hosted phone paired
  before this says "Pair this iPhone again". The old
  all-agents subscribe stays for the local relay only.
- Relay: command rows are deleted a day after they were sent (they were never
  deleted before; polling made that matter). Witnessed in RelayCoreChecks;
  removing the delete goes RED.
- Map: CMD-08; CMD-04 notes the deletion.
- Witness: RelayChecks `runCompanionTranscriptDeliveryChecks`. It uses the real
  relay over HTTP, the production Mac service, and the phone's real transport
  and receiver, and asserts that the relay's files hold neither the text nor
  the secret. Mutations each went RED: relay without the kind (400), Mac
  without the handler, a key ignoring the secret, a link dropping the secret.

Not covered by a witness: the Mac's Keychain store and its composition into
`transcriptChannels`, and the phone's `transcriptChannel(for:)` /
`requestTranscript` (no iOS test target; the iOS build passes). Size: a
transcript is published whole and the relay's non-snapshot tail is 16 MiB,
so a very long transcript can push older activity events out of the tail.

Rollout is unchanged (relay, Mac, phone). Dylan re-pairs once after the new
Mac and phone builds.

## Built: step 3, replying from the phone (2026-11-01)

- Capability: relay `sendMessages`, app `Scope.agentMessage` (1 << 7). The
  relay grants it only when the phone asks at pairing (`RelayPairingExchange.
  wantsMessages`; the phone asks only when the link carried a secret).
  Reason: installed phone builds refuse any credential whose capabilities
  differ from the exact set they know, so granting it to everyone would stop
  them pairing. The phone's `HostedPairingPolicy` accepts either set.
- Seal: `TranscriptSyncCrypto.sealMessage/openMessage`, key derived from the
  transcript channel (so from the pairing secret), AAD binds the key id, the
  command's idempotency key and the agent. The relay cannot replay the text as
  another command or to another agent.
- Mac: `perform` opens it and calls `CompanionCommandActions.send`, which is
  `accept(.send)`: `accepted`, `busy` (a turn running; no queue or steer yet),
  `notReady`, `notFound`, `empty`, `refused`. The Mac's hosted profile is now
  `companionControl + agentMessage`; the relay decides per phone.
- Phone: `PhoneMessageComposer` on agent detail when `canMessageAgents`. The
  draft is kept until `accepted`; a retry after a network failure resends the
  same sealed bytes (a new seal has a new nonce, which the relay would refuse
  as a conflict); editing after a failure starts a new message; while the Mac
  has not answered, the field is locked and the status polled.
- Witnesses: RelayChecks `runCompanionReplyDeliveryChecks` (opt-in grant,
  older set kept, 403 without it, one prompt across retries, busy, replay to
  another command or agent does not open, unknown key, relay files hold no
  text); app `--companion-command-check` (real supervisor: the phone's words
  start the turn exactly once; a second message while running is `busy`).
  Mutations RED: phone message sent as `.queue`, relay granting messaging to
  every phone, a seal not bound to its command.
- Map: CMD-09.

A Mac crash between running the message and posting its result no longer
re-runs it. The receiver journals each `agent.message` on disk
(`CompanionCommandJournal`, `companion-command-journal.json` in the Mac's
channel-split app support): marked started before the hand-off, result
recorded after, entries pruned after the relay's 1-day retention. On restart
a journaled result is re-posted without running; a message started with no
result is not run and answers `interrupted` ("Your Mac restarted while
sending this. Check the agent before sending it again."), which the phone
treats as refused (draft kept, a retry is a new seal). If the started mark
cannot be written the message is held until it can. Other kinds are safe to
repeat and are not journaled. Witness: RelayChecks
`runCompanionMessageJournalChecks` (real relay, production service, the
crashed process's journal written before start); mutations RED: drain
ignoring the journal, started mark written after the hand-off.

Not covered: the app's journal composition in
`makeDesktopCompanionSyncService` has no leg of its own.
No iOS test target; the iOS build passes.

The composer's draft and its sealed request live in the app model
(`PhoneMessageDrafts` in RelayClient, one `PhoneMessageDraft` per agent,
in memory for the app's lifetime), not in the view. Leaving agent detail
while the Mac has not answered and coming back restores the text, the locked
waiting state and the same idempotency key, and the status poll resumes; a
resend cannot become a second message. Witness: RelayChecks
`runPhoneMessageDraftChecks`; mutations RED: the store forgetting drafts (the
old view-local behaviour), every send minting a new seal. A draft does not
survive the app being killed. The
agent's answer reaches the phone through step 2's transcript request.

Rollout adds one point: a relay rolled back past this drops `sendMessages`
when it reads the credential (unknown capabilities are skipped), so messaging
stops and nothing else breaks.

## Pointers

- Phone: `ios/Continuum/Sources/ContinuumApp.swift`. `respondToApproval`
  :772-809, `stopAgent` :811-837, ack wait 5 s :280, `TranscriptAvailabilityCard`
  :1399, hosted key derivation :585-596, pairing scope :891-904.
- Wire: `Sources/ContinuumRevivedRelayProtocol/RelayProtocol.swift`.
  Capabilities :11-22; `RelayCommandRequest`/`Receipt` :93-97.
- Mac: `DesktopCompanionSyncService.start` :377-433 (responders),
  `ApprovalResponder.swift`, `AgentStopResponder` in
  `TranscriptProjectionSender.swift:90-132`, `ContinuumApp.swift`
  `ensureDesktopCompanionSyncService` ~11625, stop closure ~11771, transcript
  key ~11748.
- Scopes: `Sources/ContinuumRevivedCore/Scope.swift` (`companionControl` :26;
  `agentStop` does not imply send).
- Supervisor: `accept(_:for:)` `AgentSupervisor.swift` ~6711;
  `AgentComposerIntent` / `IntentRefusal`.
- Existing witnesses to mirror: SyncChecks
  `checkApprovalResponderOverFakeSyncTransportRealPath`,
  `checkDesktopCompanionFakeTransportFetchAndApprovalAck`; RelayCore
  phone-cannot-publish (main.swift :30,38); app `--agent-stop-outcome-check`.
