# 92-small-team-relay — durable full-control companion relay

Status: prepared; implementation must not start until queue 91's preserved dirty candidate is resolved and this program is committed on a clean checkout
Owner direction: one boring trusted relay for Dylan and a small office, private-network first, approximately $5/month or less when a VPS is useful
Local source plan: `plan.mdx` (context only; this document plus `_DECISIONS.md` are the implementation authority)
Umbrella program: `../../../plans/companion-catch-up/plan.mdx` governs the provider, companion, migration, verification, and release sequence around this relay-specific program

## 1. Product thesis

Continuum needs a dependable bridge between first-class Mac/iPhone clients and local or remote execution hosts. It does not need T3 Connect's public signup, Clerk identity, globally managed tunnel inventory, PlanetScale, queues, or multi-tenant control plane.

One trusted Array Relay runs on an existing always-on Mac/Linux host or an owner-approved low-cost VPS. It stores workspace membership, durable provider-neutral transcript events, semantic snapshots, command receipts, pairing/device/environment state, blob references, presence metadata, push registrations, quotas, and backup metadata. It uses SQLite WAL and a relay-owned content-addressed blob directory.

Execution hosts retain final authority over providers, tools, projects, worktrees, processes, environment variables, signing keys, and unrelated filesystem content. The relay routes and mirrors approved interactive state; it is not a generic shell and cannot force a sleeping/offline host to execute.

Target operating envelope:

- 10 teammates;
- 30 paired devices;
- 20 execution environments;
- 100 active/recent agents;
- 50–100 concurrent WebSockets;
- 5 GiB default per-workspace storage quota;
- 25 MiB default individual blob limit;
- 512 frames or 8 MiB outbound queue per connection.

These are measured release targets, not unlimited-scale claims.

## 2. Budget truth

The operating target is **approximately $5/month or less**, not a permanent promise of free infrastructure.

Supported deployment profiles:

1. Existing office Mac mini/Linux/NAS plus existing private network: potentially no incremental hosting bill, but existing hardware, power, internet, backups, and administration still cost money.
2. Owner-approved low-cost VPS: likely near the target budget, but provider pricing, tax, storage, traffic, backups, and terms can change. Record actual price/date in `_DECISIONS.md`; never encode one provider as permanently cheapest.
3. Development Mac: useful for local work but unavailable during explicit Sleep, lid close, low battery, thermal sleep, reboot, or network loss.
4. Public reverse proxy/tunnel: deferred until private-network onboarding is demonstrated to be the blocker. A managed TLS provider is a trust dependency and may see Class-B content unless later end-to-end encryption is approved.

APNs has no per-message fee, but Apple Developer membership and device distribution are outside this infrastructure budget.

## 3. Locked architecture

These rules are instructions for every packet.

1. **One trusted relay.** No public tenant signup, billing, organization directory, cross-region replication, or horizontal failover in this program.
2. **Execution hosts remain final authorities.** The relay can authorize routing but a host revalidates every command against its local catalog/policy and may refuse.
3. **Mac and iPhone are first-class clients.** Both reduce the same snapshots/events/receipts; the phone is not a metadata-only observer.
4. **Persist before broadcast.** A client never sees a cursor that the restarted relay cannot replay.
5. **No exactly-once provider claim.** Ambiguous post-dispatch crashes produce `indeterminate`; the system reconciles or asks for explicit retry instead of blind redispatch.
6. **Typed privileged protocol.** Generic `SyncMessage` stays for spatial/canvas sync. Full transcripts and commands use versioned `RelayFrame` families with declared limits/capabilities.
7. **Workspace isolation.** Every read, subscription, command, blob, device, and admin operation resolves its stored workspace and checks membership/capability.
8. **Server-generated credentials.** Pairing/device/environment credentials are 256-bit opaque values, stored only as hashes and revocable/expiring. Clients never submit raw scope bits.
9. **Private-network first.** Loopback is the default bind. Wildcard/public bind fails without explicit deployment configuration and owner review.
10. **SQLite and local blobs.** No Redis/Kafka/PlanetScale/object storage until measured need. WAL, migrations, limits, backups, and corruption behavior are first-class.
11. **Native, non-executable content.** Markdown, ANSI, links, diffs, tool JSON, and opaque blocks render through owned native semantics. No arbitrary HTML/WebView execution.
12. **Sanitized push only.** APNs receives Class-A hints and opaque IDs; clients fetch Class-B state after authentication.
13. **Honest sleep semantics.** A service can survive UI quit while the host remains awake. Actual system sleep suspends local processes/sockets. Another awake host continues independently.
14. **No secret observability.** Logs, metrics, errors, readiness, backups manifests, argv, and qa artifacts contain metadata only.
15. **TDD evidence integrity.** Capture RED behavior before implementation, keep existing acceptance expectations unless an approved decision changes them, then distinguish RED/implementation/GREEN and real-route evidence.
16. **One ticket/commit.** The queue harness is the only selector, ledger writer, stager, and committer.

## 4. Information boundary replacing current I5

Queue 91 was written while I5 prohibited all transcript/prompt/path/tool content from phone sync. This relay program deliberately supersedes that blanket rule only after P0 contract work records the change in repository decisions.

### Class A — sanitized notification projection

May cross the relay and APNs:

- completion/needs-input category;
- safe configured title;
- opaque workspace/agent/request identifiers;
- collapse/thread identifiers with no body data.

Never includes transcript, prompt, response, tool arguments/results, path, environment values, or credentials.

### Class B — authenticated interactive content

May cross the relay only for authorized workspace principals:

- user/assistant messages and provider-supported reasoning summaries;
- semantic Markdown/structured transcript mutations;
- tool call/result display content and diffs;
- explicit provider request prompt/options and response;
- prompt/follow-up/stop/create command payloads;
- safe opaque project/provider/model catalog IDs and display labels;
- content-hash attachment references.

Class-B allowance comes from type + operation policy + authenticated workspace authorization + limits. It does not come from passing a key-name scanner.

### Class C — host-only secrets/runtime

Never enters RelayFrame, SQLite transcript rows, APNs, or relay logs:

- provider credentials/tokens;
- environment variable values;
- APNs `.p8` outside the relay's protected secret source;
- signing/recovery keys;
- raw process handles/PIDs/tmux targets;
- arbitrary command/shell execution;
- private absolute project/worktree paths;
- unrelated filesystem content;
- unconfigured provider endpoints.

`SyncPayloadTaintScanner` remains defense-in-depth for legacy/Class-A paths. It is not authorization for Class B.

## 5. Target module graph

```text
ContinuumRevivedAgentContent
        ▲
        │ optional semantic values only
ContinuumRevivedRelayProtocol          Foundation-only wire/domain vocabulary
        ▲                 ▲
        │                 └──────── Mac/iPhone/execution-host clients
ContinuumRevivedRelayCore              GRDB + swift-crypto store, auth, policy, durable hub
        ▲
ContinuumRevivedRelayNIO               HTTP/WebSocket server adapter and limits
        ▲
continuum-relay                        config, secrets, signals, admin CLI

ContinuumRevivedRelayProtocol
        ▲
ContinuumRevivedRelayClient            portable NIO WebSocket client + host connector
        ▲                    ▲
ContinuumRevivedCore adapter    future Linux host gateway
```

Rules:

- RelayProtocol cannot depend on Core, Sync, GRDB, NIO, CloudKit, UI, or host runtime.
- RelayCore depends on RelayProtocol + GRDB + reviewed portable crypto, not ContinuumRevivedCore/Sync/UI/NIO.
- RelayNIO owns server-side NIO imports and sockets.
- RelayClient depends on RelayProtocol and client-side NIO only; it cannot depend on RelayCore/GRDB/server implementation.
- ContinuumRevivedCore supplies the Mac agent gateway adapter without making the portable connector depend on app/provider types.
- The existing ContinuumRevivedSync relay remains a compatibility path until final supervised acceptance, then is retired deliberately.

Check targets:

- `ContinuumRevivedRelayProtocolChecks`: fast Codable/schema/limit/capability contracts.
- `ContinuumRevivedRelayChecks`: real temporary SQLite plus pure auth/store/hub/fault checks.
- `ContinuumRevivedRelayIntegrationChecks`: actual relay subprocess, HTTP/WebSocket, network faults, service/config/CLI checks.

## 6. Durable model

Core tables include:

- `relay_metadata` and relay identity fingerprint;
- `workspaces`;
- `devices` and hashed credentials;
- `workspace_memberships` with canonical capability sets;
- one-use `pairing_grants`;
- `environments` and hashed environment credentials;
- sanitized environment catalogs;
- `agents` with `(generation,last_sequence,status)`;
- `agent_events` unique on `(agent,generation,sequence)` plus stable host event identity;
- `agent_snapshots` with schema version and through-sequence;
- `commands` unique on `(device,idempotency_key)`;
- outstanding provider requests/resolutions;
- `blobs` and workspace/event references;
- encrypted `push_tokens` metadata;
- rate-limit buckets and quota accounting;
- backup/maintenance metadata.

Persistence rules:

- SQLite foreign keys enabled; WAL/busy/synchronous policy measured after open.
- Generation/sequence assignment and event insert happen in one transaction.
- An identical host-event retry returns the committed row; conflicting bytes are rejected.
- Snapshot+tail must reduce to the same semantic document as complete replay.
- Command states only advance through the approved transition table.
- Quota reservation and payload commit are one recoverable operation.
- Blob paths derive only from verified content hashes under a relay-owned root.
- Online backup produces a consistent database plus referenced-blob manifest in a restricted staging directory before encryption.

## 7. Command contract

```text
received (authorized + committed)
  → forwarded (sent once to current host session)
  → hostAccepted (host owns reconciliation)
      → resolved
      → failed
      → indeterminate
```

- Uniqueness: `(deviceID,idempotencyKey)`.
- Identical retry returns the original command/receipt.
- Conflicting payload under the same key is rejected.
- Mutating commands serialize per agent.
- Offline environments refuse prompt, follow-up, approval, stop, abort, and creation; stale execution is not queued silently.
- `stop` is graceful; `abort` is a distinct stronger capability.
- Phone creation accepts only opaque IDs from the host's current catalog revision.
- Receipt errors are sanitized metadata; transcript/tool bodies remain canonical events.

## 8. Protocol and transport

Every `RelayFrame` contains protocol version, message ID, optional workspace/environment/agent IDs, and one tagged payload. Credentials ride approved transport authentication, never the JSON hello or URL.

Families:

- hello/welcome/version/error;
- event publish/batch and snapshot request/response;
- command submit/host acknowledgement/receipt/reconcile;
- subscription/resume;
- presence heartbeat/state;
- blob offer/fetch/reference;
- ping/pong.

Default limits:

- 16 KiB handshake;
- 64 KiB command;
- 256 KiB normal event/frame;
- 25 MiB blob;
- bounded JSON depth/string/collection counts;
- 512 frames or 8 MiB queued per connection;
- heartbeat every 15 seconds, stale after 45 seconds.

A slow consumer is closed with its last successfully written committed cursor and resumes through snapshot+tail. Socket writes never block database transactions.

## 9. Pairing, identity, recovery

Device pairing:

1. Relay administrator creates a five-minute one-use grant with fixed workspace/capabilities.
2. QR contains a 256-bit random secret. A manual fallback must preserve effective entropy or have separate strong rate limits.
3. The first successful exchange atomically consumes the grant and creates the device.
4. Relay returns one 256-bit opaque credential exactly once; the client stores it in Keychain.
5. Relay stores only a SHA-256 digest plus metadata, expiry, last-used, and revocation.
6. Revocation/expiry immediately evicts active sessions after durable commit.

Execution hosts use a distinct credential/principal kind scoped to one environment. Device and environment credentials are not interchangeable.

Recovery authority consists of relay identity, administrator recovery material, database, blob set, configuration manifest, and protected secret sources in an encrypted off-host backup. Restore validates in isolation and never activates a second live copy of the same identity.

## 10. Power and availability truth

| State | Relay/host truth | Client behavior |
|---|---|---|
| UI closed, service host awake | service continues | connected |
| display off/screen locked | processes continue if system awake | connected |
| idle sleep approaching | optional active-turn assertion may prevent idle sleep | visible keep-awake status |
| explicit Sleep/lid close/thermal/low battery | processes and sockets suspend | host sleeping/offline; cached read-only state |
| relay awake, execution Mac asleep | durable transcript remains readable; commands refused | read-only history |
| independent office/VPS host awake | its agents continue | normal control |
| wake/network return | reconnect, authorize, snapshot/tail replay | duplicate-free refresh |

A phone/VPS external witness is required for actual sleep testing because a test runner on the sleeping Mac also stops.

## 11. Testing doctrine

Every autonomous packet has:

1. exact pre-change RED evidence;
2. focused deterministic checks against the production seam;
3. at least one final-code mutation witness that goes red;
4. restored source hash and green focused check;
5. `swift build`;
6. independent opposite-model read-only review;
7. one final harness-owned headless matrix;
8. one harness-owned local commit and ledger update.

Tests use executable check targets, not XCTest. Prefer injected clock, entropy, filesystem, store faults, and deterministic barriers over sleeps. Real sockets use loopback port 0 and bounded subprocess readiness rather than fixed ports or timing guesses.

Required layers:

- pure protocol/capability/cursor/receipt contracts;
- real temporary SQLite migrations, transactions, restart, corruption, backup/restore;
- real relay subprocess HTTP/WebSocket routes;
- deterministic slow consumer, disconnect, malformed frame, oversized body, and crash-boundary faults;
- two-workspace/device/environment isolation matrix;
- physical iPhone foreground/background/APNs/Keychain/Data Protection;
- external-witness Mac sleep/wake;
- target-host capacity/soak;
- real Linux build/process/systemd when Linux is supported.

A source scan is not a substitute for a behavior test. A unit test is not end-to-end proof. A test changed in the same patch is not independent proof; the RED artifact and final negative mutation witness are both required.

## 12. Autonomous versus supervised gates

Autonomous tickets may use local temporary files, loopback sockets, fake APNs, subprocesses, injected clocks/faults, and bounded capacity samples.

The loop stops at:

- **P3.10:** deployment route, trust, budget, endpoint, and real-process transport/security review;
- **P4.9:** physical iPhone, signed app, APNs, background/foreground, full commands, revoke/cache review;
- **P5.7:** deployed office/VPS acceptance, external sleep witness, restore drill, full soak, real Linux evidence when applicable, and legacy removal.

Later tickets may not skip an unresolved supervised gate.

## 13. Migration sequence

1. Establish program guard and portable protocol/core targets.
2. Capture executable legacy debt before changing behavior.
3. Build durable store, replay, commands, blobs, quotas, backup, and fault fuzz behind new types.
4. Replace broad scopes with server-derived pairing/capability authorization.
5. Define typed content/command frames and production NIO transport.
6. Supervise endpoint/trust decisions.
7. Connect execution hosts and first-class phone/Mac clients.
8. Supervise physical phone/APNs.
9. Add config, operations, launchd/systemd, capacity, and backup automation.
10. Deploy, sleep/restore/soak/security test, then retire the legacy relay only after explicit approval.

At no stage may two independent transcript authorities both mutate the visible client state.

## 14. Explicit non-goals

- Public signup, billing, arbitrary organizations, or untrusted tenants.
- Globally replicated relay state or automatic failover.
- Clerk/OAuth/PKCE/DPoP or a distributed owner certificate hierarchy in v1.
- Redis, Kafka, PlanetScale, Kubernetes, service mesh, or per-environment managed tunnels.
- Generic remote shell/tool execution.
- Sending provider credentials or environment variables through relay.
- Executing transcript HTML/JavaScript/WebViews.
- Hidden reasoning extraction beyond provider-supported summaries/events.
- Claiming agents continue on a sleeping local Mac.
- Guaranteed permanent $0/$5 vendor pricing.

## 15. Release acceptance

The program is complete only when:

- pairings, grants, events, snapshots, cursors, commands, requests, blobs, quotas, push registrations, and backups survive restart;
- full two-workspace isolation and live revocation pass;
- physical iPhone transcript/prompt/request/stop/create/reconnect/cache/push flows are observed;
- ambiguous dispatch produces honest `indeterminate` and no blind replay;
- target hardware meets measured capacity with bounded queues/WAL/storage;
- encrypted backup restores on replacement storage and identity collision is refused;
- actual forced sleep is externally observed with honest client state and duplicate-free wake;
- Linux is actually built/run if advertised;
- actual monthly cost and operational owner are recorded;
- legacy `/v1/tokens`, plaintext in-memory registry, raw BSD production server, seq-only volatile authority, and absolute Class-B taint prohibition are no longer reachable;
- Dylan explicitly approves the final supervised ticket.
