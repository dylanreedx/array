# Implementation research 02: relay, transport and service boundary

29 October 2026. Planning only. Read-only source inspection; no relay was contacted, launched, deployed or tested. No credentials or runtime state were read. Relative source links below resolve from this directory.

## Feasibility and recommendation

The repository already contains a portable, durable relay server with SQLite transactions, HTTP/WebSocket adapters, revocable device credentials, bounded replay and Linux packaging. Building multi-human workspace/zone/area collaboration is technically plausible without introducing an unrelated hosted real-time platform first.

However, the current service is **per execution-Mac instance plus paired companion devices**. It is not a multi-person workspace membership service. Reuse its storage, networking, packaging and test patterns; add an explicitly versioned collaboration service boundary rather than treating a teammate as a paired phone or exposing the whole Mac instance stream.

Recommended initial architecture: one collaboration service authority persists shared-area operations and snapshots; each execution host publishes only deliberately shared projections and remains authoritative for agent commands and code. Both developers can continue their own checkout/agents. Durable area content remains readable while a host sleeps, while live execution surfaces show their actual unavailability.

## Evidence: what is actually implemented

| Source | Observed behavior | Reuse boundary |
| --- | --- | --- |
| [RelayStore.swift](../../../Sources/ContinuumRevivedRelayCore/RelayStore.swift) | GRDB `DatabaseQueue`, migrations through schema 4, transactional per-instance sequence, token hashes, pairing grants, event retention and idempotent command receipt rows | Reuse transactional/migration patterns. Schema contains instances/devices, not people/area membership. |
| [RelayProtocol.swift](../../../Sources/ContinuumRevivedRelayProtocol/RelayProtocol.swift) | Roles `desktop`/`companion`; capabilities for publish, pairing, reading projections/transcripts, approval responses and stop | Add human/device/host distinction and collaboration-specific operations. Current command vocabulary accepts approval/stop only, not collaboration prompts/discussion. |
| [RelayServer.swift](../../../Sources/ContinuumRevivedRelayNIO/RelayServer.swift) | `/v2` HTTP routes and WebSocket authentication/replay/fanout; subscribes before replay; bounded 256-event in-memory subscriber streams | Reuse NIO lifecycle/routing, after adapting scope, backpressure and full replay completion. |
| [RelayClient.swift](../../../Sources/ContinuumRevivedRelayClient/RelayClient.swift) | Portable URLSession HTTP client | Networking reuse, not an already implemented rich collaborative WebSocket client. |
| [RelaySyncTransport.swift](../../../Sources/ContinuumRevivedSync/RelaySyncTransport.swift) | Existing Mac/iPhone polling adapter, cursor callbacks, reconnect backoff and snapshots | Reuse learned recovery behavior. Its live-only desktop `startAtHead` mode must not lose durable collaboration changes. |
| [TranscriptSyncCrypto.swift](../../../Sources/ContinuumRevivedSync/TranscriptSyncCrypto.swift) | Per-pairing transcript channels, HKDF labels, authenticated encrypted transcript envelopes | Preserve existing encryption; a multi-human area needs a separate key distribution/revocation design. |
| [CompanionRelayProvisioning.swift](../../../Sources/ContinuumRevived/App/CompanionRelayProvisioning.swift) | Channel-scoped Keychain identity, desktop invite redemption, companion pairing, compiled relay endpoint | Useful credential lifecycle, but no existing human account, collaborator invitation or area ACL. |
| [RelayPackage.swift](../../../RelayPackage.swift), [Dockerfile](../../../Dockerfile), [fly.toml](../../../fly.toml) | SwiftNIO/GRDB/Crypto Linux manifest; container build/check stages; Fly configuration with one always-on 512 MB machine and mounted SQLite volume | Existing deployment target, not proof of current service capacity, data backup or tested failover. |

The older [small-team relay design](../../../docs/38-tickets/92-small-team-relay/_DESIGN.md) already discusses workspace membership, durable transcripts, blobs and presence. It explicitly describes a stopped/locked program. Its target model is richer than the actual current schema. Treat it as historical design work to reconcile, not shipped capability and not a reason to stop this newly authorized planning exercise.

## Separate three traffic lanes

1. **Durable shared work:** area membership, explicitly shared object references, committed layout changes, discussion, agreement revisions and artifact manifests. Commit before acknowledgment/broadcast, stable operation IDs, area-local sequence and deterministic reducers. Return the same accepted result on identical retry; reject mismatched payload reuse.
2. **Ephemeral presence:** cursor/selection/camera, availability, composing and freshest usage observations. Coalesce, bound frequency and payload size, expire by lease, and drop stale updates rather than replaying pointer history. Presence loss must not imply agent termination. Hover consumes cached observations; it does not create a model call.
3. **Execution requests and host events:** attributed prompt/suggestion/stop/approval requests, host acceptance receipts, durable outcomes and shared agent/artifact projections. Revalidate at both service and actual host; relay acceptance is not provider completion. Never redispatch an ambiguous accepted request as if it were new.

A shared workspace can contain several area streams or an umbrella manifest. Start with one ordered authority per area rather than building multi-region replication or a general peer-to-peer mesh. Represent source host/session identities as opaque references, not absolute paths or serialized host records.

## Gaps that require behavioral witnesses

- Current events are scoped to `instanceID`; `events` admits desktop/companion roles but does not perform per-area/per-object membership filtering. Arbitrary new event kinds do not supply permission safety.
- A new snapshot currently deletes all earlier instance snapshots regardless of kind. Multi-area/multi-object snapshots need explicit boundaries and complete snapshot semantics.
- Stored non-snapshot tail is limited by count and bytes; a shared discussion cannot rely on that transient tail as permanent history. Design retention, compaction and reconstruction together.
- `events` returns at most 500 rows with an overall latest sequence. The socket bootstrap sends that page and then filters live events after the reported latest. Before reuse, witness backlogs larger than one page and snapshot-to-live races; do not assume a complete history from the presence of a cursor.
- WebSocket authorization is cached after authenticate; revocation currently disconnects device subscribers. Multi-human removal must prevent subsequent reads/writes and queued fanout, including an already-open socket and cached principal.
- Current `acceptCommand` records a relay receipt for approval/stop. It is not a full prompt delivery/outcome ledger. Do not advertise exactly-once provider execution.
- In-memory fanout ends a subscriber on overflow, but there is no durable presence lease model. Reconnect must resnapshot/replay explicitly after lag or eviction.

These are source-derived reuse risks, not newly reproduced bug claims about the installed app.

## Identity and encryption decisions

Separate a human principal, that human's devices, and an execution host. Accepting an invitation grants a defined area membership, not the publisher's instance credential. Persist server-minted membership and capability versions; a removed participant's old token cannot expand access by rejoining a socket.

The current server stores event payload bytes and encrypts push tokens at rest with a master-derived key. That is not blanket end-to-end encryption for every relay event. Existing transcript channels encrypt content before transport and are paired-device-shaped. Do not reuse a shared pairing token as a team key or silently decrypt existing channels.

Before shipping, choose and document either a trusted-relay content model for new shared objects, or reviewed per-area encrypted envelopes with authenticated device key distribution and key epochs on membership change. The latter adds multi-device recovery and invitation-key work. In either model, host-only provider credentials remain local and membership never becomes arbitrary shell authority. Final cryptographic policy is a planning dependency, not a reason to withhold the rest of this plan.

## Hosting, availability and cost

Reuse the existing Linux service and Fly deployment shape for an isolated collaboration staging namespace. Do not migrate or deploy the live companion service as part of planning. A single SQLite-backed authority is a reasonable small-team starting hypothesis; measure it before setting a supported envelope.

Required operating work: migration/rollback compatibility, restore rehearsal in a replacement directory, durable volume/backup ownership, bounded uploads/egress, tenant/area quotas, frame limits, slow-client behavior, health and redacted metrics, host leases and orderly shutdown. If an endpoint or notification behavior changes, update the appropriate maintained contracts.

Cost depends on always-on machine memory/CPU, persistent storage, backup retention, attachment size, transcript retention and fanout/egress. Cursor traffic scales approximately with update frequency times participants times observing peers. Do not write an unverified fixed monthly price into this new feature; the old design's low-cost target is not current provider pricing evidence. For early work, use local loopback fixtures and disposable service databases.

## Proposed ticket candidates

### Transport A — Add collaboration-scoped durable service protocol and store

Depends on domain, human identity and authorization contracts. Implement isolated area/membership/operation/snapshot storage with area sequence, atomic effects and stable request outcomes. Preserve companion v2 behavior behind its existing routes.

Acceptance: two humans with separate execution hosts can publish authorized area operations, reopen the same shared arrangement and discussion after service restart, and never receive an unrelated instance's objects. Identical retry returns the same outcome; changed payload with reused operation ID refuses. Typed snapshots recover all included streams without deleting another area's bootstrap.

Witness: offline RelayCore checks over disposable databases, including commit/crash boundaries, concurrent writes and over-500-operation replay; integration checks through actual routes and sockets, registered/reported by the matrix. No production credentials or network required.

### Transport B — Add bounded collaboration subscriptions, presence and reconnect

Depends on Transport A and presence schema. Implement authenticated area subscriptions with complete replay-to-live handoff, bounded queues, coalesced ephemeral presence and honest host liveness.

Acceptance: no lost durable operation across handshake races or multi-page backlog; lagged clients recover; presence expires after partition; removed participant loses reads/writes/fanout on an already-open socket; hovering usage never requires a provider call. A sleeping execution host leaves cached discussion readable and execution accurately unavailable.

Witness: real localhost multi-client integration with injected clocks, slow subscribers, partitions, service restart and midstream revocation. Measure configurable message/payload budgets, with expected drops confined to presence.

### Transport C — Prove isolated deployment, restore and operational budgets

Depends on A/B and explicit content-encryption decision. Package staging service/client compatibility, migrations, backups, restore validation, quotas and redacted operational diagnostics.

Acceptance: recover a disposable multi-area dataset on a replacement instance; stale/removed credentials and old key epochs stay invalid; retained operations/artifacts remain consistent; concurrent presence does not starve commits; published limits match measured evidence. Existing companion routes retain regression coverage.

Witness: Linux container build plus offline integration/restart/restore harness and bounded soak. Any real staging deployment is a separate concrete reviewable action, not part of this planning task. No service capacity, failover or hosting-cost claim is verified by this memo.
