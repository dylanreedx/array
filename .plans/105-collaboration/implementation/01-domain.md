# Shared-area domain and operation model

29 October 2026. Implementation research only. No product code, migration, network request to Array infrastructure or behavioral check was run. Recommended names below are provisional Swift/domain vocabulary, not approved user-facing labels.

## Feasibility and recommendation

Feasible, but the shared object should be a new portable collaboration document with local bindings. Do not make collaboration synonymous with synchronizing the existing local `WorkspaceDocument`, sharing a project's `.array/` directory, or importing another participant's `AgentRecord`.

Recommend one `SharedAreaDocument` identity and operation contract behind **Share workspace**, **Share zone**, and **Capture area to share**. These entry points determine the initial explicitly reviewed selection and its arrangement. They need not create three independent collaboration protocols.

The first useful domain slice should support a shared arrangement containing both participants' own agents, revisioned shared context and human discussion. It should not require shared remote execution or automatic source-file synchronization. Session views are components of the shared area, not the central deliverable.

## Current source evidence

| Source | Observed contract | Consequence |
| --- | --- | --- |
| [WorkspaceDocument.swift](../../../Sources/ContinuumRevivedCore/WorkspaceDocument.swift), lines 3–30, 324 onward | Current schema 9 contains zones, ambient tiles, per-device viewport, creation scope and active pointers; zone scope combines project and relative Home. | The complete local document is not a portable room snapshot. Shared navigation cannot write everyone's viewport or armed creation scope. |
| [WorkspaceStore.swift](../../../Sources/ContinuumRevivedCore/WorkspaceStore.swift), lines 3–22 | Workspace canvas lives in channel-specific application support, keyed by local workspace ID. | Keep collaboration IDs separate from this local filesystem identity. |
| [Registry.swift](../../../Sources/ContinuumRevivedCore/Registry.swift), lines 124–150 | Projects are exclusively workspace-owned; duplicate membership is an error. | A shared reference must not register the same project in a second local workspace or reparent it just to display work. |
| [Project.swift](../../../Sources/ContinuumRevivedCore/Project.swift), lines 3–17 | Projects carry `rootPath` and host settings. | The repository's conceptual identity must be distinct from a participant's checkout mapping. |
| [CanvasState.swift](../../../Sources/ContinuumRevivedCore/CanvasState.swift), lines 76–94 and 214 onward | A tile has one `zoneId`, a host/runtime handle and substantial metadata. | Multi-area sharing needs references/instances, not multiple zone stamps on the original tile. |
| [AgentRecord.swift](../../../Sources/ContinuumRevivedCore/Agents/AgentRecord.swift), lines 7–27 | Agent identity outlives its tile; the record is explicitly host-bound and must not cross sync. | Publish an allowlisted session projection and opaque source binding, never the record. |
| [SpatialOp.swift](../../../Sources/ContinuumRevivedCore/SpatialOp.swift), lines 7–20, 112–159 | Lamport+replica ordering, per-field operations, atomic zone-scope write, private viewport and omitted runtime handles. | Existing operation discipline is useful; the existing closed op set is not a complete collaboration domain. |
| [OpLog.swift](../../../Sources/ContinuumRevivedSync/OpLog.swift), lines 26–57, 123–179, 306–327 | Deterministic LWW fold, delete-wins tombstones, canonical encoding; resolver deliberately leaves `ambientTiles` empty because workspace scoping is unresolved. | Convergence machinery exists, but blindly materializing it into the production workspace would omit content and bypass scope contracts. |
| [SpatialSync.swift](../../../Sources/ContinuumRevivedSync/SpatialSync.swift) | Existing sender uses a capability mapping that groups spatial mutations under companion orchestration scope. | Human/object membership and sharing authority cannot reuse this coarse mapping unchanged. |
| [SyncPayloadTaintScanner.swift](../../../Sources/ContinuumRevivedCore/SyncPayloadTaintScanner.swift) | Defensive scanner includes host paths and transcript-length content. | New legitimate shared discussion/context needs separate typed lanes, not disabling old scanner checks globally. |

These are source observations. No installed-release or deployed-service behavior was established.

## Proposed entities and boundaries

| Entity | Shared meaning | Local-only counterpart |
| --- | --- | --- |
| `SharedAreaID` | Stable collaboration document identifier, schema version, title and server revision | Local placement/window/sidebar association |
| `ParticipantID` | Authenticated person/principal; membership and capabilities | Current device login and selected local profile |
| `DeviceID` / replica | Delivery, presence and optional optimistic-operation identity | Host connection credentials and machine-specific configuration |
| `SharedObjectID` | An admitted discussion, brief, artifact, shared session projection or group | Actual local note/file/agent/terminal identity and adapter |
| `SharedPlacementID` | A view of one shared object inside an area; rect, z-order and parent group | Personal outer-container placement, viewport and focus |
| `SourceBindingID` | Opaque reference to the authorized source owner/host plus resource projection type | `AgentID`, project UUID, local tile UUID, path, runner handle and store location |
| `ArtifactRevisionID` / context revision | Immutable content version to which review and dispatch refer | Host's evolving working tree and retrieval/cache implementation |
| `MembershipEpoch` | Authority generation used to reject stale mutations/subscriptions | Server-issued credential and local authentication cache |

The server must authenticate attribution; a client-supplied `ParticipantID` is never proof. A source binding names a resource; it does not grant its holder authority. Publishing an existing local object in another area is a deliberate per-area grant decision. IDs alone must not allow cross-area lookup or correlation beyond authorized membership.

Shared placements permit an agent to appear in multiple areas without minting another executor or changing the original `Tile.zoneId`. A local deletion removes a view only unless an explicit source-object/runner action is separately requested. Area removal, shared object deletion and source execution termination need distinct operations.

### Coordinate and repository mapping

Use area-local geometry for shared arrangement. Capture converts the selected world rectangles once relative to an explicit capture origin; receiving converts the area's geometry once into the local container/world projection. Never persist source zone-local frames as shared world coordinates. Preserve relative layout, sizes and group relationships; avoid exporting unrelated personal canvas origin or viewport.

A participant maps an abstract repository/workstream to their chosen local checkout. Joining must not infer that an equal project UUID, repository URL, branch name or filesystem path authorizes local writes. A source object continues to resolve through its actual owner, not whichever project is active locally.

“Share whole workspace” should mean a reviewed shared document containing its admitted zones/object projections. Automatically admitting future objects is a separate explicit policy decision. Moving a private tile across a rectangle must not silently publish its content.

## Operation model: ordered document commands first, CRDT selectively

Recommend authenticated, idempotent commands to one server authority per shared area, yielding a revisioned append-only event stream plus snapshots. Clients can optimistically preview geometry and show transient drag presence; final accepted commands are authoritative. A group capture, group move, object membership change and permission change should each have atomic transaction semantics.

| Lane | Recommended first semantics | Why |
| --- | --- | --- |
| Shared arrangement | Revisioned typed commands; independent property edits may be safely rebased, conflicts rejected visibly | Deterministic authorization and atomic multi-object capture/movement, without whole-document overwrite |
| Shared discussion | Append-only attributed messages with stable IDs; explicit edits/revisions | Preserves human conversation and source references |
| Shared context/boundaries | Immutable revisions with current pointer; explicit dispatch referring to revision | A current agreement is distinct from what each agent has actually received |
| Presence, cursor, hover telemetry | Ephemeral sequence/TTL lane, never materialized into durable layout | High frequency and stale presence must not grow persistent history |
| Agent activity/artifacts | Owner-authoritative projections and immutable version references | Observers do not become execution owners |
| Agent commands | Separately authorized ordered dispatch with accepted/outcome records | Execution effects cannot be merged as document edits |

There is already LWW/CRDT-like spatial machinery in the repository. Reusing its deterministic IDs, fractional ordering, delete-wins discipline and fuzz fixtures is attractive, but **LWW convergence alone does not establish valid membership or authorization**. In particular, the old op set includes active-pointer operations and project scope; those must not be exposed as a human collaborator's arbitrary setters.

If offline simultaneous long-form text editing becomes a requirement, evaluate a text CRDT behind that specific field/document adapter. Current whole-string LWW would lose one contributor's draft. Do not adopt a single generalized CRDT to represent approvals, subscriptions, execution or code merges. A fully offline multi-writer layout is another valid alternative, but needs authority-generation checks and compaction/revocation design before it is a better first implementation.

Local undo should submit compensating semantic commands for the user's own accepted action; it must not restore an entire stale shared snapshot over others' work. Delete wins across stale replay; recreation requires a new identity. Pending offline commands must be reauthorized under current membership when reconnecting.

## Suggested tickets

The parent can assign final board IDs and merge with other research tracks.

### DOM-01 — Define portable shared-area contracts and deterministic reducer

**Outcome:** a schema-versioned Core contract for shared areas, objects, placements, revisioned context/discussion and typed atomic commands. Explicitly model person, replica, source binding and local placement separately. Decide server ordered semantics with an ADR and document supported rebasing.

**Acceptance:** capture of tiles from two projects creates one area-local arrangement without changing source project/zone ownership; malformed/nonfinite geometry and dangling references are rejected; commands are idempotent; independent edits preserve both values; atomic group actions cannot partially commit; stale deletes/reconnect cannot resurrect old objects; unsupported future schema is read-only/refused rather than silently rewritten; local camera/creation scope and host records are absent from encoded shared payloads.

**Witness:** deterministic CoreChecks reducer fixtures compare canonical replicas after duplicate/reordered accepted events, transaction failure and snapshot replay. Include a private-path/handle sentinel in every source binding fixture and assert it is not emitted. Register and confirm the actual matrix leg executes. New user-editable persisted keys must be classified in `WorkspaceAPIExposure` where audited by the existing exposure contract.

**Dependencies:** auth principal/membership contract and server revision/event envelope; can start with fake authority. No dependency on remote execution control.

### DOM-02 — Add local binding/projection store without importing remote projects

**Outcome:** local adapter maps shared references to existing owned objects or remote projections, preserving stable agent execution ownership and local project/workspace invariants. New collaboration cache is channel-isolated and separate from project stores.

**Acceptance:** same source agent visible in two areas still owns exactly one runner; an invitee with no matching checkout renders permitted remote projections without creating a project/agent runtime; closing/removing a shared view does not kill execution; restarting restores mappings or honest unavailable placeholders; cross-project capture leaves original `.array/canvas.json`, registry ownership and zone stamps unchanged; joining does not move focus, camera or armed creation scope unexpectedly.

**Witness:** mounted production workspace scene fixture driven through `mountWorkspaceSceneAtBoot`, with two independent disposable app-support/project roots and sentinel source canvases. Assert runner count, exact world frames, persisted source bytes and registry ownership before/after join/remount. Never call the checks-only `install(into:)` as a substitute for production mount.

**Dependencies:** DOM-01, capture UI track, remote object projection track and persistence track.

### DOM-03 — Integrate shared layout commands, live receive and undo

**Outcome:** production canvas geometry transactions route local shared edits into accepted operations and inbound operations into the actual mounted shared view. Keep existing private canvas actions private.

**Acceptance:** a shared group move is atomic and appears identically on another participant; source/private layout changes follow the selected publication policy; local undo preserves a peer's intervening unrelated edit; permissions lost during a drag prevent commit; stale membership replay cannot re-add removed content; cameras remain independent; paused/disconnected peer catches up without moving tiles twice.

**Witness:** two simulated clients plus fake authoritative server, deterministic delayed/reordered events and revocation during active drag. Assert actual mounted world frames and durable accepted-event/snapshot outcome, not source strings or object stamps. Include one multi-zone/multi-project capture and one zone below hydration tier. Full gate must report the new leg and existing matrix known-red outcomes separately.

**Dependencies:** DOM-01/02, transport/auth, geometry owner integration, persistence/reconnect and UI performance witnesses.

## Open decisions

- Shared area as a dedicated workspace versus an embedded local container with shared internal layout; both can consume the same domain document, but the initial UI choice affects hydration and geometry adapters.
- Whether whole-workspace/zone sharing is initial admission only or an ongoing content publication policy. Initial explicit admission is safer to explain; Dylan has not selected future-object behavior.
- Which text editing needs true simultaneous keystroke convergence versus revisioned paragraphs and messages.
- Membership/service ownership and cryptographic key lifecycle belong to the server/security tracks; this domain recommendation does not settle E2EE or relay persistence.
- Live token usage's scope/aggregation belongs to the usage track. Keep its freshest measurement/presence projection separate from durable area layout; do not let schema choices remove the explicitly requested hover interaction.

No tests were executed during this memo. All witnesses described above are future implementation acceptance requirements.
