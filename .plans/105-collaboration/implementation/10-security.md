# Implementation perspective 10: trust, payload boundaries and execution authority

29 October 2026. Implementation research only. Inspected local source; no runtime attack, production relay request, credential access, provider/app launch, Git mutation or product-code change. This memo owns only this file. Board creation belongs to the parent agent.

## Feasible boundary for a coworker alpha

An explicitly admitted human can inspect and discuss deliberately shared objects. They do not become a companion device on another developer's instance. Sharing layout or discussion does not grant terminal access, local file access, approval authority or prompting. Each participant's agent remains on its own execution host, and every execution action is re-authorized there against current membership, per-object grant and actual provider capability.

Once direct prompting is granted, an agent may modify files using its existing local permissions without another approval. Therefore **Can prompt** is a meaningful execution privilege, not harmless discussion access. A shared agreement is context, not a filesystem sandbox. Do not imply that coworker isolation is technically enforced merely because a boundary note exists.

The adversaries worth designing against are a nonmember with a leaked invitation/object ID, a removed member replaying an old operation, a valid member exceeding their object/action grant, and untrusted text/files/links entering shared content. An admitted reader can retain anything legitimately delivered; revocation cannot retract downloaded content or executed changes.

## Concrete source evidence

| Current source | What it establishes | What it does not establish |
| --- | --- | --- |
| [RelayProtocol.swift](../../../Sources/ContinuumRevivedRelayProtocol/RelayProtocol.swift), roles/capabilities and credential structs | Desktop/companion roles, instance/device credentials, bounded payload sizes and command vocabulary | Human membership, area/object ACLs or a general prompt relay |
| [RelayStore.swift](../../../Sources/ContinuumRevivedRelayCore/RelayStore.swift), `authenticate`, `publish`, `events`, `acceptCommand` | Hashed bearer credentials; instance-scoped event log and receipts; stop/approval command checks | Multi-human authority or per-object authorization; event payloads are inserted as supplied bytes, not blanket encrypted by `masterKey` |
| [RelayServer.swift](../../../Sources/ContinuumRevivedRelayNIO/RelayServer.swift), HTTP auth and `RelayWebSocketHandler` | Existing auth, replay/fanout, live disconnect on credential revocation | Fresh area membership checking on every new multi-human action; the socket retains an authenticated context after handshake |
| [TranscriptSyncCrypto.swift](../../../Sources/ContinuumRevivedSync/TranscriptSyncCrypto.swift) | ChaChaPoly payload authentication, route/version associated data, Curve25519/HKDF and pairing-token-derived per-device transcript channels | Group key distribution, member removal rotation, late-join history policy or person identity |
| [WorkspaceAPIService.swift](../../../Sources/ContinuumRevived/App/WorkspaceAPIService.swift), `revoke` and grant rechecks | Per-agent revocation generations and checks before effects | Reusing an `AgentID` as a human collaborator identity |
| [SyncPayloadTaintScanner.swift](../../../Sources/ContinuumRevivedCore/SyncPayloadTaintScanner.swift) | Narrow shape/path/transcript-length backstop for existing spatial/activity boundaries | A general credential detector, permission system or safe full-transcript exporter |
| [AgentRecord.swift](../../../Sources/ContinuumRevivedCore/Agents/AgentRecord.swift) | Host-bound persisted state explicitly must not cross sync | Portable shared runtime state |

These are gaps relative to a new feature, not claims that existing scoped companion behavior promises team sharing or is exploitable.

## Recommended ordering and confidentiality decision

Use an authoritative **server-sequenced area operation log**, with server-side membership and capability checks. The envelope carries area/object identity, authenticated author/device, operation identity, capability/action, schema version and authorization epoch; the host checks these again immediately before any side effect. Discussion, layout and execution have different operations and cannot all be arbitrary opaque mutations.

For the shortest credible coworker alpha, recommend **a trusted relay for new collaboration content**, TLS in transit, dedicated at-rest encryption/key operation policy, and an explicit statement that the service can process that shared content. This is a planning recommendation, not permission to send real content now or a change to existing companion encryption. Preserve the current per-device transcript channel as implemented; do not silently downgrade it when adding the new service.

Before payload implementation, resolve the confidentiality decision in a recorded architecture ticket:

1. **Trusted service:** new shared discussion, agreements and deliberately published artifacts may be processed by the area service. Specify storage/retention and operator access; no E2EE claim. This supports durable shared work when a host is offline without inventing group crypto.
2. **Relay-blind content requirement:** add reviewed area content encryption as a blocking package. Server-authorized envelopes can still order ciphertext; clients must authenticate envelope bindings and validate operation content. The server cannot semantically validate encrypted document bodies, so validation responsibilities and abuse limits differ.

The second option requires actual per-person/per-device public keys, authenticated key admission, area key epochs, per-device key wrapping, rotation on removal, reconnect/offline-device behavior, recovery and a deliberate history grant for new members. Sharing one old pairing token among teammates is not this design. Associated data must bind area, object, author/device, operation/version and key epoch, not only the current agent/session routing fields. Group E2EE should not be promised as an incidental reuse of `TranscriptSyncCrypto`.

## Publication boundary before serialization

Build an allowlisted shared projection from an explicit capture manifest. Geometry is not a crop over a private stream. Resolve exactly which objects and historical revisions are included, then emit only their allowed fields. Re-check publication grants on subscriptions, snapshots, delta replay, blob fetch, usage hover and search; server/client rendering controls alone cannot contain already delivered bytes.

A selected agent can print or repeat source content and secrets. Once full output is intentionally shared, no text heuristic guarantees secret removal. Offer a clear history/content preview and distinguish full live output from curated artifacts or selected messages. Do not export a complete agent record, environment, raw provider configuration, inherited tokens, host absolute paths or unrelated tile metadata. The current taint scanner should remain a backstop for its original lane; weakening it to permit long shared discussion would mix incompatible contracts. New content needs a separate typed lane with its own validation.

Explicit capture membership must not expand because a private terminal is moved nearby. Removal of an object stops new delivery and future operations for that object; it does not pretend recipients forgot old revisions.

## Revocation, reconnect and host commands

Revoke area membership transactionally, advance its authorization epoch, terminate active subscriptions and deny subsequent history/blob/hover fetches. Invalidate unsent proposed instructions and prevent stale queued remote actions from becoming executable on reconnect. A host offline at revocation must fetch fresh authority before executing remote actions; reject or wait when freshness cannot be established. Preserve confirmed historical outcomes and distinguish accepted/committed execution from unexecuted requests.

Commands need independent idempotency identity bound to their area, target and canonical payload. Reusing an ID with changed content must fail. A valid member cannot claim another author's identity, request an unshared host target, turn a discussion message into an action through embedded text, or expand a grant by including an `authorized` flag. The host—not an agent-generated payload—owns grants and operation dispatch.

## Files, links and previews

Attachment access follows the owning shared object and current membership. Apply actual-byte size/MIME validation, immutable digest identity, bounded downloads and non-executable rendering. Escape human/agent content; imported Markdown/HTML must not gain arbitrary local resource access. Link previews should not automatically fetch arbitrary URLs from the relay: that creates a new remote request surface and can disclose private network resources.

Do not hand a collaborator the host's browser cookie store, local credentials or general localhost proxy. For an initial alpha, use deliberately published immutable images/artifacts or an explicitly reachable preview URL. If live local previews are added, require a separate owner-approved, revocable tunnel bound to one service/port and area; deny arbitrary destination URLs, private-network hopping, cross-port redirects and credential inheritance. Browser-controlled actions and terminal streams are independent privileges. Whole-machine access is not implied by a shared preview tile.

Cursor presence and token hover need the same audience rules as other area data. Sharing a personal aggregate can be an explicit choice; it must not accidentally expose private project/agent names through the metadata backing that total. Measurements should be scoped and allowlisted before fanout, not hidden afterward.

## Proposed tickets

### SEC-01 — Adopt the collaboration trust boundary and payload contract

**Dependency:** domain and identity proposals. Before shipping real shared content, choose trusted-relay handling or fund the blocking group-encryption package. Specify projection schema/history floor, owner-visible inclusion manifest, retention, operator access and cipher/plaintext lanes. Preserve companion encryption and host-bound record exclusions.

**Acceptance:** the design has one honest confidentiality statement; a nonmember receives no area bytes; a captured object exports only its manifest-approved content; adding/moving a nearby private tile does not publish it; unrelated metadata cannot appear in usage, search or late-join snapshots.

**Offline witness:** encode a synthetic workspace with selected/public and unselected/private agents, misleading filenames, host fields and content; request live, snapshot, replay and hover projections and inspect actual delivered DTO bytes. Mutate inclusion and history floor, then assert only allowed objects/revisions reach each principal. This must test outcomes rather than source strings and be registered/reported by the matrix when implemented.

### SEC-02 — Enforce revocation through relay and execution host

**Dependency:** human membership/grants, area event store and host dispatch. Authenticate each area operation and author; carry authorization epochs; recheck before host effects; bind idempotency to exact intent; close subscriptions and deny late fetches after removal.

**Acceptance:** a removed collaborator cannot publish, fetch blobs, subscribe, replay history or trigger queued commands; reconnect cannot execute pre-revocation uncommitted work. An already committed result stays distinguishable and is never duplicated or falsely undone. Revoking one member leaves other members functional.

**Offline witness:** fake clock, in-process relay and two isolated fake hosts. Revoke at handshake, between relay acceptance/host dispatch, during blob fetch and after commit; replay old IDs/epochs, spoof author/target and change payload under the same ID. Assert zero unauthorized effects and exactly one authorized committed effect across restart/retry. No real providers, tmux or production state.

### SEC-03 — Bound shared attachments and preview publication

**Dependency:** artifact/presence exports and capture manifest. Implement per-object blob authorization, content validation and safe rendering. Keep arbitrary link fetching and general host proxy outside alpha; a later live preview tunnel needs a separate narrow contract and witness.

**Acceptance:** unshared or removed objects cannot yield attachment bytes; mismatched/oversized content is rejected; content cannot execute local markup/scripts or resolve host paths. A URL in a human message does not silently cause a server fetch. A preview cannot inherit host cookies or broaden access to unrelated services. New invitation/action notification paths must be classified in the maintained notification inventory before implementation ships.

**Offline witness:** fake blob store and loopback test server in a disposable namespace; malformed MIME/size/digest, traversal names, redirected URLs and revoked grants. Assert exact allowed requests/bytes, no unintended requests, and unchanged cookie/credential handling. A future tunnel test must demonstrate origin/port restrictions through real dispatch, without probing the user's network.

## Coordination

Aligned with transport and recovery perspectives: server ordering, current authorization and explicit confidentiality decision; no assumption that pairing becomes multi-person identity or group encryption. These ticket candidates are implementation planning, not completed checks or authorization to deploy.
