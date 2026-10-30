# Implementation research 09: persistence, replay and recovery

29 October 2026. Planning only. No runtime behavior was exercised and no production or project state was accessed. This memo proposes a design; names and schemas are provisional.

## Recommendation

Persist shared area content independently of any participant's laptop. Use an area-scoped durable operation log with a single commit order, versioned snapshots and a local replica/outbox. Separate that from transient cursor/presence messages and from commands addressed to an execution host. Agent files, authentication and actual processes remain host-owned.

A shared brief, discussion, captured arrangement and explicitly retained artifact revision can remain readable after its publisher goes offline. A last-known transcript can be readable if it was deliberately retained. That does not make a disconnected agent resumable or prove whether its process stopped. Do not replay a queued executable request merely because the participant reconnects.

This is feasible in the current Swift/GRDB stack. The existing sync code supplies valuable reducers, sequence/replay and durable-outbox patterns, but it is not a ready-made multiuser area database.

## What actually exists

| Evidence | Observed implementation | Reuse and limitation |
| --- | --- | --- |
| `Sources/ContinuumRevivedSync/OpLog.swift:40–152` | Per-field LWW registers, deterministic Lamport/replica order, delete-wins tombstones and canonical materialization | Good test/reducer discipline. Existing entities are local tile/zone models; not a shared-area schema. |
| `Sources/ContinuumRevivedSync/OpLog.swift:306–327` | Materialization deliberately emits no ambient tiles because project/workspace partition is absent in its op stream | Do not infer arbitrary cross-project area persistence from the old log. |
| `Sources/ContinuumRevivedSync/Compaction.swift` and `Tombstone.swift` | Snapshot plus tail; deleted IDs survive in a compaction ledger to prevent stale creates resurrecting content | Reuse invariant and fixtures, not the exact local entity types. Delete history must outlive stale writers. |
| `Sources/ContinuumRevivedSync/SpatialSync.swift:9–48` | Header explicitly says production desktop canvas mutations do not flow through the op-log; backing implementation provided is memory-only | A durable area store and mounted UI bridge are new work, not wiring already proven in the app. |
| `Sources/ContinuumRevivedRelayCore/RelayStore.swift:50–149` | GRDB migrations for persistent instance/device, event and command tables | Reuse migration/transaction infrastructure; add separate area/membership/replica tables. |
| `RelayStore.swift:254–298` | Transactional per-instance sequence; newest snapshot plus count/byte-bounded event tail; event reads capped at 500 | Existing pruning can create a gap between snapshot and tail. Snapshot replacement is instance-wide, not per shared document. New recovery protocol must explicitly detect and repair coverage gaps. |
| `RelayStore.swift:301–312` | Command receipt deduplicates on instance + idempotency key | Receipt is acceptance, not observed host execution. Existing method does not compare a payload hash for reused keys. |
| `Sources/ContinuumRevivedSync/RelayHub.swift:215–245` | In-memory relay refuses a cursor that has no bridging snapshot rather than knowingly returning a hole | Preserve this honest refusal. Do not silently use latest sequence as the delivered cursor. |
| `Sources/ContinuumRevivedSync/RelaySyncTransport.swift:183–220, 303–334` | Reconnect/backoff, cursor reset and separate latest/delivered positions; comments say caller owns cursor persistence | Good recovery precedent; new client must atomically persist applied sequence with state. |
| `Sources/ContinuumRevivedSync/TranscriptProjectionReceiver.swift` | In-memory documents; exact base-version check; rejects mutation without base | Retain exact revision validation; add durable cache and explicit resnapshot recovery. Current receiver alone does not establish offline transcript availability. |
| `Sources/ContinuumRevivedSync/TranscriptProjectionSender.swift` | Responds to requested versions with encrypted snapshots | Existing snapshot request mechanism is useful; not evidence of a durable server-owned multiuser transcript archive. |
| `Sources/ContinuumRevivedRelayCore/RelayStore+NotificationOutbox.swift` | Transactional enqueue, lease, attempt policy, live-recipient recheck, terminal outcome tombstones | Reuse design discipline. This is a notification outbox, not a general prompt outbox; do not send collaboration commands through it. |
| `Sources/ContinuumRevived/App/WorkspaceAPIService+Delegation.swift:505–522` | Message operations compare payload hashes; expired operation tombstones return unknown outcome rather than repeat delivery | Better precedent for reconnect-safe execution intent than the simpler relay command receipt. |

Paths/line numbers are observations of the working tree, not release guarantees. Some terminal searches intentionally tried nonexistent candidate paths/globs; subsequent searches resolved the actual files above. No test executables were run.

## Synchronization choices

| Choice | Fit | Tradeoff |
| --- | --- | --- |
| Existing per-field LWW model | Scalar geometry, titles and independently set fields can converge deterministically | Concurrent edits to a whole Markdown string overwrite one another. LWW is not a suitable claim of collaborative text merging. Existing schema also contains local ownership assumptions. |
| Server-sequenced typed operations with revision preconditions | Recommended initial durable area authority: membership, object inclusion/removal, layout commits, append-only discussion and immutable agreement revisions | Offline work is a local draft until committed. Conflicting revisions must be rejected/rebased explicitly, without deleting the user's draft. |
| Text CRDT within selected documents | Candidate for simultaneous character-level brief editing if real workflows require it | Adds schema/runtime compatibility, compaction, encryption and native editor-binding work. It does not solve membership, execution order or host ownership. Run a bounded native integration spike before selecting a library. |

These are engineering judgments from the current contracts; no external CRDT library was benchmarked or chosen. Start with immutable agreement revisions and explicit edits rather than silently dropping simultaneous text. Append-only human messages can be ordered without a text CRDT. Keep current camera/hover state local; broadcast presence with expiry and coalescing rather than storing every pointer movement.

Encryption is a prerequisite decision with the identity/security tracks. A trusted relay can validate and materialize typed content directly if documented honestly. With opaque end-to-end-encrypted content, the service can order authorized envelopes but cannot pretend to validate/materialize plaintext fields. Authorized clients would need snapshot creation and version/coverage verification; server-readable membership and revocation envelopes remain distinct. Do not promise both server content validation and content opacity without a design that actually supplies both.

## Durable model and reconnect contract

Proposed records: area identity and schema version; author/person/device identity; membership/revocation epoch; immutable operation ID and payload digest; committed area sequence; snapshot-through sequence and content hash; applied client cursor; local draft/outbox state; object deletion tombstones; host-action outcome ledger. Large immutable artifacts should be referenced by authenticated content identity and retention policy, rather than copied into every event.

1. Client records its pending intent locally before upload. Each changed intent gets a new operation ID. Retries of identical intent retain ID and digest.
2. Service rechecks membership/capability and current epoch inside the commit transaction, records the dedup receipt and event atomically, then publishes the committed event.
3. Client applies committed events and updates its cursor in one local transaction. A network acknowledgment never advances the applied cursor past unconsumed pages.
4. Joining/resuming receives an authorized consistent-cut snapshot plus every later operation, paging until caught up. If any gap exists, request a valid replacement snapshot; never interpret absent events as deletion or successful synchronization.
5. Local optimistic drafts reconcile against the received authoritative state. A rejected/obsolete draft remains recoverable as a draft and is never silently presented as shared.
6. A schema version the client cannot safely apply yields an explicit upgrade/read-only refusal. Failed migrations leave the old store recoverable; use disposable migration fixtures and backups according to the store's real policy.

Keep history authorization explicit: current membership may allow full retained history, join-time onward history, or only the current snapshot. Choose one per product policy. Late joining must not accidentally expose previously excluded files or messages via historical payloads.

## Host actions and ambiguity

For an authorized prompt/stop request, the relay can durably record intent. The host must independently recheck authority/epoch and persist admission before entering the strict supervisor/runner path. Track distinct states such as requested, host accepted, provider submission observed, response observed, denied and outcome unknown.

If a host dies between provider submission and recording the result, exactly-once execution cannot be assumed unless the actual provider supports a durable compatible request identity. Recover by querying the original operation and reconciling observed runner/session history; show unknown outcome when that cannot be established. Do not repeat the prompt with a new ID as an automatic repair.

Default executable commands should expire or require renewed confirmation after an offline interval; decide the specific policy with the runner/control track. Revocation invalidates queued not-yet-admitted commands even if their original author was once authorized. Merely remaining in a local outbox is not permission to execute later.

## Compaction, revocation and retention

Choose bounded payload/tail storage without sacrificing a complete reconstructible state. Compaction must atomically commit a snapshot and its through-sequence before retiring covered events. Retain delete/retired-ID knowledge across snapshots or require a new replica generation that cannot replay pre-compaction creates. Very old clients should resnapshot, not resurrect content.

Revocation needs a monotonic membership epoch/deny record that survives content compaction. A formerly authorized replica must not merge stale object operations or queued prompts back into the area. Do not use object deletion alone as access revocation.

Define retention separately for current area state, message history, artifact bytes, dedup receipts, unknown command outcomes and deleted-object IDs. Do not copy notification outbox's one-hour age or five-attempt defaults into collaboration. Removing access can prevent future fetches, but cannot erase content a person already read or exported; cache-clear behavior and encrypted key rotation require honest separate promises.

## Ticket candidates

### PERSIST-1 — Durable shared-area log, replica cache and compatible migrations

**Outcome:** accepted area layout/context/discussion survives both desktop shutdown and relay restart, independently of host agent execution.

**Scope:** area-scoped schema and typed operations; payload-bound idempotency; local replica/outbox transactions; schema negotiation; durable snapshots, tail coverage and revocation-aware apply. Depend on domain/identity/transport contracts and encryption decision. Do not bind to local project canvas files.

**Acceptance/witness:** two temporary client stores and a disposable relay DB commit mixed operations; crash/restart at each transaction boundary; apply duplicated/reordered deliveries; inject unsupported schema and failed migration. Assert identical committed state, recoverable drafts, no double apply and unchanged old store after failed migration. Register a behavioral leg in the real matrix; no source-string assertions.

### PERSIST-2 — Late join, long reconnect and compaction without gaps or resurrection

**Outcome:** a late/old participant receives all authorized current content and a valid continued event stream, with explicit recovery when history is no longer covered.

**Scope:** snapshot consistent cuts, multi-page replay (>500 entries), cursor durability, byte/count-pruning coverage, tombstone/revocation survival, artifact retention and user-visible stale/offline state. Depend on PERSIST-1 and membership history policy.

**Acceptance/witness:** create more than one replay page, disconnect before/after snapshot cuts, prune by bytes and count, compact with deletes, restart the service, reconnect an old replica with stale creates and unauthorized historical payload requests. Assert no missing committed operations, no cursor jump over undelivered pages, no object resurrection, denied history remains absent, and snapshot+tail matches full-log materialization. Include a production-mounted area restore witness in addition to pure reducer checks.

### PERSIST-3 — Durable host-action outcomes with revocation-safe recovery

**Outcome:** a dropped reply or host restart does not silently submit a teammate's prompt twice, and a revoked/offline request does not execute later by accident.

**Scope:** command intent digest/idempotency, separate relay receipt and host outcome, host admission authority check, durable dedup/outcome tombstones, expired/unknown handling and recovery query. Depend on identity/runner routing; do not claim provider exactly-once delivery.

**Acceptance/witness:** fake runners and durable host journals inject failure before admission, after admission, at provider invocation and before outcome persistence; repeat exact ID, reuse ID with changed payload, revoke membership while command waits, and reconnect after expiry. Assert zero or one provider invocation only where the recorded admission state establishes it; ambiguous submission returns unknown and never retries itself. Expose proposer/operator/host attribution. Matrix must report the behavioral leg.

All witnesses must use temporary state and fake processes/transports unless a dedicated isolated bundle harness is necessary. No live tmux/default project store or real provider authentication is needed for these failure cases.
