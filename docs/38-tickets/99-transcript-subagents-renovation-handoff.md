# 99 — Transcript and subagent renovation handoff

Written 2026-08-20 after the first macOS + iPhone relay dogfood pass.

> **0.5.7 integration closure (2026-08-21):** The lifecycle and correctness gaps
> recorded below were closed after the original handoff. macOS now persists semantic
> transcript snapshots and starts one encrypted projection sender per authorized paired
> session; iOS derives the matching transcript-only channel, starts a receiver, retries
> subscriptions, and publishes decrypted documents into the semantic renderer. Stop is
> handled by the desktop supervisor. Pairing-session keys are derived with a
> transcript-specific HKDF context and never cross the relay in plaintext. Until the
> authoritative desktop mutation/ack path exists, iPhone canvas mutation is explicitly
> disabled instead of claiming a divergent edit is Live. The historical findings below
> remain as the audit trail that motivated these release fixes.

This was the authoritative pre-integration handoff for branch
`array/transcript-subagents`. It is deliberately candid about the difference between
contracts that existed at that point, UI that could render data, and production wiring
that still had to supply that data. The closure note above records the release state.

## Executive status

The branch establishes the semantic and persistence foundation for a better desktop
transcript, durable subagent references, encrypted transcript transport contracts, and
an iPhone semantic transcript renderer. It also adds immediate visual acknowledgement
for desktop prompt submission and contextual parent-child canvas lineage.

At handoff time, it did **not** complete the original product goal yet.

- The desktop transcript received useful behavioral infrastructure, but it has not had
  the large visual-design and interaction pass the original request called for.
- The iPhone transcript renderer exists, but no app-lifecycle code negotiates transcript
  keys, starts the transcript sender/receiver, or puts decrypted documents into the
  mobile model. The companion therefore remains activity/canvas-only in production.
- Mobile canvas edits are not end-to-end authoritative. They can make the phone's mirror
  diverge from the live desktop while freshness still says `Live`.
- A severe relay echo loop discovered during dogfood was fixed and regression-tested.

The right next emphasis is the desktop agent-tile transcript. Companion work should be
limited to closing correctness gaps and then paused until the desktop experience has the
intended new feel.

## Repository state

| Item | Value |
|---|---|
| Worktree | `/Users/dylan/Documents/personal/Array/.worktrees/transcript-subagents` |
| Branch | `array/transcript-subagents` |
| Base | `array/integration` merge base `d0aef13` |
| HEAD at handoff | `6b785eb` |
| Scope | 46 files, 1,769 insertions, 45 deletions |
| Primary worktree | Never modified, cleaned, staged, or rewritten |
| QA app | `qa-runs/transcript-subagents/Array Transcript Dev.app` |
| iOS DerivedData | `qa-runs/transcript-subagents/ios-derived` |
| iPhone simulator | iPhone 17 Pro, `A5593A9C-A811-4EA4-BEEE-D5084F7CDD3C` |
| Relay | managed DevRelay on `http://127.0.0.1:8787` |

The QA bundle was manually restamped as
`dev.arrayapp.macos.transcript-subagents` after assembly. This is a QA artifact detail,
not a committed packaging change. The unique identity is necessary because many old
dev bundles use `dev.arrayapp.macos.dev`, and Launch Services otherwise routes launches
to the wrong process.

## Commits, in mergeable order

| Commit | Result |
|---|---|
| `1d9e0ff` | Provider-neutral semantic child-agent references and durable capability metadata |
| `9a0fa6d` | Versioned semantic transcript snapshots, patches, compaction, and recovery |
| `f1e9a57` | Optimistic desktop prompt insertion before awaits; agent-reference chip renderer |
| `24606c1` | Transcript scopes, message vocabulary, crypto envelope, and receiver contracts |
| `5786d23` | Contextual direct parent-child canvas lineage overlay |
| `116e422` | iPhone semantic transcript views, child navigation, breadcrumb/control UI |
| `2184052` | Encrypted transcript sender and Stop responder components, with checks |
| `b732925` | Transcript journal/compaction recovery hardening |
| `d81ca3d` | Explicit transcript/Stop scopes for debug pairing |
| `fd6c2d4` | Configurable advertised pairing host for simulator loopback |
| `99dcd02` | Deduplicate relay-echoed spatial operations and prevent an infinite loop |
| `6b785eb` | Optional isolated-QA auto-pair launch seam |

## What was implemented

### Semantic transcript and persistence

- `AgentBlockKind.agentReference` and `AgentReferencePayload` carry stable child
  `AgentID`, parent identity, relationship, spawn-time name, timestamp, provider source
  item ID, and provider.
- Spawn correlation now carries the provider source item ID through the unsafe local
  side channel and emits a safe semantic child milestone after creation.
- `AgentRecord` remains the sole durable child identity. Capability metadata describes
  transcript availability, Stop support, provider observation, and local management.
- `AgentTranscriptStore` persists complete semantic documents independently of bounded
  runtime replay. It supports versioned snapshots, incremental patches, atomic
  compaction, and incomplete-journal recovery.
- Transcript persistence contains semantic/sanitized data only—no runtime handles,
  process identifiers, raw unsafe provider arguments, or host capabilities.

### Desktop transcript behavior

- Composer submission calls `onSubmissionStarted` synchronously, before draft journal,
  attachment, supervisor, or provider awaits.
- The tile immediately inserts the user prompt and shows `Sending`, then advances to
  `Starting agent` after acceptance.
- Refusal removes the pending latch, restores the existing draft flow, hides the live
  indicator, and shows an explicit not-sent notice.
- Child-agent milestones render as accessible transcript chips.
- Activating a child chip resolves the existing durable agent; it does not create a new
  agent or runner.
- Direct parent-child lineage can be drawn contextually on the canvas.

### Sync/security infrastructure

- Added explicit `transcriptRead` and `agentStop` scopes.
- Added subscribe, encrypted envelope, history, detail, child lifecycle, and Stop
  request/ack message contracts.
- Added Curve25519/HKDF/ChaChaPoly crypto primitives with authenticated agent, session,
  version, content-type, and key identity metadata.
- Added `TranscriptProjectionSender` and `TranscriptProjectionReceiver` actors.
- Added encrypted snapshot round-trip, tamper, wrong-device, AAD, scope, long-text, and
  semantic child-reference checks.
- CloudKit explicitly refuses negotiated transcript/control messages; these require the
  encrypted companion channel.

### iPhone presentation

- Agent detail can render an `AgentDocument` with user/assistant hierarchy, text,
  headings, tools, command output, and child-agent navigation.
- Child navigation and parent breadcrumbs use durable agent identity.
- Stop and approval controls are scope- and freshness-gated.
- The Canvas and Agents tabs consume the same activity/spatial relay feed.
- Missing transcript data has honest copy instead of pretending activity events are a
  full transcript.

### Dogfood and relay fixes

- Simulator pairing can advertise `127.0.0.1` while physical-phone pairing keeps its LAN
  behavior.
- Debug pairing grants explicit operator, transcript-read, and agent-stop scopes.
- `CONTINUUM_AUTO_PAIR_PHONE=1` can mint and present an isolated QA pairing credential
  at launch.
- `MemorySpatialOpLogStore` now deduplicates by CRDT `OpId`, which closes the relay
  self-echo loop described below.

## Why the transcript is not shown on iPhone

The mobile renderer is real, but the end-to-end transcript channel is not wired into
either app lifecycle.

Specifically:

1. macOS never constructs or starts `TranscriptProjectionSender`.
2. macOS has no production `DocumentProvider` joining `AgentTranscriptStore` or the live
   supervisor projection to the sender.
3. Pairing grants `transcriptRead`, but does not negotiate and persist the Curve25519
   device keys/channel key used by `TranscriptSyncCrypto`.
4. iOS never constructs or starts `TranscriptProjectionReceiver`.
5. `AgentsBoardModel.transcriptControlTask` sees transcript history responses but
   intentionally ignores encrypted envelopes; its comment says decryption will be
   installed after key negotiation.
6. Nothing assigns a decoded document to `AgentsBoardModel.transcripts`, so
   `MobileSemanticTranscriptView` has no production input.
7. History/detail/media fetch, encrypted cache, key rotation, revocation, and restart
   restoration are contracts or planned behavior, not app-level implementations.

Therefore the current card—“Full transcript is waiting for encrypted channel
negotiation”—is accurate. The protocol, crypto, sender/receiver actors, renderer, and
checks are an infrastructure slice, not completed transcript delivery.

### Minimum vertical slice to make one transcript appear

1. Extend pairing exchange with device public keys and key IDs; persist private keys in
   Keychain and derive the shared transcript channel key.
2. Give `DesktopCompanionSyncService` one shared demux that also owns a started
   `TranscriptProjectionSender`.
3. Implement a semantic document provider keyed by `AgentID`, backed by
   `AgentTranscriptStore` with a live supervisor fallback.
4. On iOS, construct `TranscriptProjectionReceiver` with the negotiated key, subscribe
   to visible/non-history agent IDs, and publish documents into `transcripts`.
5. Prove one existing agent cold-loads its full transcript after reconnect before adding
   patching, history LRU, details, media, or Stop.
6. Add key rotation/revocation and ciphertext-only relay/cloud fixtures before treating
   the channel as releasable.

## Immediate known issues

### P0 — Mobile canvas edit reports Live while desktop diverges

Reproduction observed during dogfood:

1. Pair the current simulator and wait for `Live`.
2. Move a tile in the companion Canvas.
3. The phone applies the move optimistically.
4. The live desktop canvas does not move.
5. The phone can continue to show `Live` because recent heartbeat/snapshot timestamps are
   healthy.

Cause: the phone emits a spatial CRDT op and the desktop-role `SpatialOpSender` accepts
it into `MemorySpatialOpLogStore`, but that store is not bridged to the desktop's live
`WorkspaceRuntime`/`CanvasNSView` mutation path. The source file already states that the
desktop live canvas is not wired to the op log. Freshness currently means recent
transport data, not convergence or acknowledged mutation.

Do not ship companion canvas mutation in this state.

Recommended repair:

- Bridge authorized inbound spatial ops into the canonical desktop workspace mutation
  path, on the main actor, with normal persistence and undo/interaction rules.
- Introduce an explicit mutation receipt/ack keyed by `OpId` and authoritative desktop
  revision/watermark.
- Show `Pending sync` after an optimistic edit; return to `Live` only after the
  authoritative ack/snapshot contains that operation.
- Time out/revert with an actionable error if the Mac refuses or cannot apply the op.
- Add convergence tests over the real relay, not only the fake transport (the fake does
  not echo sends back to their publisher).
- Until that lands, disable mobile canvas editing or label it experimental rather than
  using freshness as mutation permission.

### P0 — Full companion transcript channel is incomplete

The UI and protocol create an expectation the app cannot yet satisfy. Either complete
the minimum vertical slice above or make the capability metadata return unavailable so
the UI says exactly that the build is activity-only. Do not leave an endless
“negotiating” state with no negotiator running.

### P1 — Desktop transcript renovation is visually incomplete

The original request was primarily the desktop agent-tile transcript. This branch did
not yet deliver the desired visual transformation.

What exists is behavioral scaffolding: optimistic prompt paint, status copy, semantic
child chips, reveal, lineage, persistence, and provider-neutral identity.

Still owed:

- one stable, designed live-work row spanning preparing, provider wait, thinking, tool
  work, writing, input wait, failure, stop, and completion;
- a visually restrained completed-work disclosure such as
  `Worked for <duration> · <tools> · <agents>` that preserves authored commentary,
  errors, requests, diffs, and child milestones;
- clearer right-aligned user messages and calmer full-width assistant prose;
- materially better typography, spacing, hierarchy, chip treatment, tool chrome,
  attention states, and expansion animation;
- elapsed time and Stop behavior in the live row;
- intentional tail-follow and reader-anchor behavior across streaming, expansion,
  resizing, and selection;
- subagent chips with current joined status and richer hover/focus treatment;
- complete VoiceOver and keyboard traversal for the new hierarchy;
- 100 ms first-paint instrumentation and deterministic visual fixtures for every phase;
- 10,000-entry performance, selection, copy, resizing, and scroll-anchor proof.

The optimistic submission implementation is only a first slice. It uses `Sending` and
`Starting agent`; it is not the full correlated nine-phase state machine from the plan.

### P1 — QA build isolation is too manual

The generic dev bundle identity collides with many historical builds, and the dev
Application Support store can contain schemas newer than an older branch supports.
During this session that caused:

- Launch Services opening a different Array dev app;
- a pairing listener disappearing with the wrong process;
- a schema-6 canvas being opened by a schema-4 branch;
- repeated terminal initialization errors.

The repeatable QA launcher should own a unique bundle ID, unique defaults domain,
`CONTINUUM_APP_SUPPORT`, project root, relay URL/token injection, simulator loopback
host, and cleanup. Manual PlistBuddy restamping should not be the long-term workflow.

### P1 — Relay health is not connection health

`/v1/health` reports `latestSeq` and current long-poll waiters. `subscribers: 0` can be
observed while the phone is healthy between polls, so it must not be presented as a
durable connected-device count. Companion UI should use authenticated connection state
plus freshness/ack state, not this waiter count.

### P2 — Relay state is in-memory and pairing retries accumulate devices

Restarting DevRelay clears sequence history and token registrations. The Mac correctly
re-registers active tokens on reconnect, but repeated dogfood pairing created several
durable paired-device records. A QA reset command should revoke/clear only the isolated
auth store and simulator session without touching production identities.

## Severe bug found and fixed: spatial relay echo loop

Observed symptom: laptop CPU surged, the phone stayed in syncing, and relay
`latestSeq` increased by roughly 500 per second, reaching more than 159,000 events.

Mechanism:

1. phone emits `.op`;
2. desktop `SpatialOpSender` appends it and its active serve stream rebroadcasts it;
3. HTTP relay broadcasts the message back to every poller, including the desktop;
4. desktop appended the identical `OpId` again;
5. append fanned it to serve, repeating forever.

The fake transport tests did not expose this because their basic delivery contract does
not loop a sender's own message back to that sender.

Fix `99dcd02`: `MemorySpatialOpLogStore` owns a `Set<OpId>` and ignores repeats both in
initial seeds and later appends. A regression check appends an identical relayed op twice
and requires exactly one stored/fanned operation.

Live post-fix evidence:

- relay reset to sequence 0;
- clean macOS and iOS builds installed;
- pairing succeeded on loopback;
- phone rendered `Active desktop workspace · Live` and the remote canvas;
- relay reached sequence 13 and remained 13 across five seconds;
- isolated desktop measured 0.2% CPU;
- screenshot: `qa-runs/transcript-subagents/iphone-after-loop-fix.png`.

## Pairing and dogfood failures encountered

These are worth preserving because each looked like a product bug from the UI:

1. **Stale LAN link:** simulator tried `192.168.40.54:<old-port>` while the current
   listener was elsewhere. Simulator must use Mac loopback.
2. **Bundle identity collision:** multiple apps shared `dev.arrayapp.macos.dev`; the
   requested QA app exited or the Pair command ran in another build.
3. **Shared dev store collision:** the branch read a schema-6 canvas while supporting
   schema 4. Use an explicit isolated Application Support root.
4. **Missing operator credential:** pairing exchange succeeded locally, but the Mac
   could not register the phone token with DevRelay. The phone then retried with HTTP
   401 forever while UI said it was waiting for publish.
5. **Poisoned relay history:** the spatial echo loop filled the in-memory ring and made
   catch-up useless. Stop the offending app and restart the relay before retesting.
6. **Root relay URL:** `http://127.0.0.1:8787/` is not a UI. The meaningful read-only
   diagnostic is `/v1/health`.

## Verified checks and evidence

Green in the final session:

- `swift run ContinuumRevivedSyncChecks`, including transcript crypto/projection and
  relay-echo dedupe;
- `swift build --product Array`;
- `xcodebuild` for iPhone 17 Pro simulator using the explicit isolated DerivedData path;
- clean simulator uninstall/install and binary-hash comparison;
- real loopback pairing, token registration, activity/spatial snapshot delivery;
- live simulator visual inspection of the Canvas screen;
- stable relay sequence and low desktop CPU after the fix.

Not completed after the final fix:

- the entire `scripts/run-matrix.sh` matrix;
- a fresh deterministic macOS transcript visual corpus;
- 10,000-entry transcript performance;
- physical iPhone pairing/firewall validation;
- actual encrypted transcript delivery between apps;
- mobile Stop responder end to end;
- mobile spatial mutation convergence.

Do not describe this branch as release-ready until those distinctions are resolved.

## Safe QA launch recipe

The final run used all of these isolation inputs:

```sh
CONTINUUM_APP_SUPPORT=<worktree>/qa-runs/transcript-subagents/app-support
CONTINUUM_PROJECT_ROOT=<worktree>/qa-runs/transcript-subagents/project
CONTINUUM_RELAY_URL=http://127.0.0.1:8787
CONTINUUM_RELAY_OPERATOR_TOKEN=<managed DevRelay secret>
CONTINUUM_PAIRING_ADVERTISED_HOST=127.0.0.1
CONTINUUM_AUTO_PAIR_PHONE=1
```

Never print or paste the relay operator token into documentation or logs. Read it from
the managed LaunchAgent at launch time. The simulator pairing credential is also a
secret and should not appear in captured command output.

The bundle must be assembled from this worktree, restamped with the unique QA bundle
identifier, ad-hoc signed again, and launched as a new instance. The simulator app must
be built with the explicit DerivedData path above; never glob Xcode DerivedData.

## Recommended next sequence

1. Keep mobile canvas mutation disabled or visibly experimental until authoritative ack
   and desktop application exist.
2. Make transcript capability honest: unavailable/activity-only until key negotiation
   and sender/receiver lifecycle wiring are present.
3. Return focus to the original desktop goal. Produce a visual fixture gallery for the
   full turn lifecycle and iterate on typography, density, live-work row, folding, and
   subagent chips until the tile has the intended new feel.
4. Instrument first paint and streaming cadence before polishing animation; the original
   complaint was dead air, so latency truth must remain structural.
5. After the desktop design is approved, wire the smallest encrypted transcript vertical
   slice to iPhone and prove one cold-load/reconnect path.
6. Only then add history LRU, details/media, mobile Stop, and physical-device release
   gates.

## Product direction to preserve

- Desktop agent tiles are the primary product surface.
- Subagents remain inline transcript milestones backed by durable `AgentID`, with tiles
  revealed lazily rather than created eagerly.
- Companion is a useful secondary observer/operator, not the reason to defer desktop
  transcript quality.
- `Live` must mean authoritative convergence for mutations, not merely a recent network
  heartbeat.
- Infrastructure that cannot yet deliver a user-visible feature must be labeled as
  infrastructure, not counted as the finished feature.
