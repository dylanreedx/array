# Identity, invitations and authority for shared areas

29 October 2026. Implementation research only. No authentication service, app behavior or deployed configuration was changed or exercised. File/line references describe the inspected working tree, including any pre-existing changes.

## Feasibility finding

**Multi-human sharing is feasible, but the compiled companion identity model is not an area-membership system.** Reuse its durable-token, invitation and revocation mechanisms as engineering patterns. Do not invite a coworker by issuing them a normal companion credential to the owner's entire instance.

The first useful scope can be a small, explicitly admitted coworker cohort with stable human identities and area-specific membership. Full organization management, SSO, billing seats and public link discovery are separate product investments. Strong authorization boundaries are needed even for two trusted participants: capture must not silently expose adjacent private content.

## What exists, and what does not

| Evidence | Current meaning | Reuse or limitation |
| --- | --- | --- |
| `RelayProtocol.swift:17–22` | Only `desktop` and `companion` credential roles; capabilities cover state publication, companion viewing, approval response and stop | Transport vocabulary and explicit capabilities are useful; no human member/editor role exists |
| `RelayStore.swift:52–94` | SQLite instances, credentials, pairing grants, events and commands keyed by desktop instance | Migration/transaction patterns are reusable; adding an area ID to UI alone cannot create a membership boundary |
| `RelayStore.swift:191–203` | An alpha invitation is atomically consumed and provisions a **new desktop instance** | Not an invitation into someone else's collaborative workspace |
| `RelayStore.swift:224–252` | A desktop creates a pairing grant; exchange emits fixed companion capabilities | Do not equate pairing a phone with inviting a human collaborator |
| `RelayStore.swift:206–220,315–321` | Authentication checks credential/instance revocation; device revocation is constrained to the desktop's instance | Reuse hashed-token lookup, revocation and instance scoping patterns |
| `RelayServer.swift:149–162,264` | HTTP authentication, explicit socket authentication and live-hub disconnect on device revocation | Useful integration seams; shared-area membership must invalidate already subscribed sockets too |
| `CompanionRelayProvisioning.swift:29–40,76–118` | Channel-scoped Keychain identity and hosted invite/pair/revoke APIs | Reuse channel isolation and credential storage discipline, not the existing single-instance credential as a person ID |
| `CompanionAuthService.swift:16,158,192–234` | Local companion model has `ContinuumUser`, but pairing attaches a device to the instance's owner | Presence of a user struct is not proof of multi-human hosted login or team membership |
| `WorkspaceAPIService.swift:163–181,211–234` | Supervisor-bound agent identity and per-agent revocation generation | Strong precedent for rechecking authority before effects; agent grants cannot substitute for human membership |
| `.plans/101-subscription-accounts/README.md` | Provider-account switching/limits exploration is parked | Neither an Array collaboration login nor a reason to centralize provider credentials |

Historical ticket `docs/38-tickets/92-small-team-relay/P2.5-workspace-membership-authorization.md` describes a broader membership design. Its named `RelayAuthorization.swift` and `RelayWorkspaceRepository.swift` are absent from the inspected current relay target. Treat it as design precedent, not completed implementation.

Core references: [relay protocol](../../../Sources/ContinuumRevivedRelayProtocol/RelayProtocol.swift), [relay store](../../../Sources/ContinuumRevivedRelayCore/RelayStore.swift), [NIO service](../../../Sources/ContinuumRevivedRelayNIO/RelayServer.swift), [desktop provisioning](../../../Sources/ContinuumRevived/App/CompanionRelayProvisioning.swift), [local companion identity](../../../Sources/ContinuumRevivedCore/Auth/CompanionAuthService.swift), [workspace API](../../../Sources/ContinuumRevived/App/WorkspaceAPIService.swift).

## Proposed model

Use stable, separately typed identities for **Person**, **Device**, **ExecutionHost**, **SharedArea** and **AreaMembership**. Names displayed beside cursors are editable labels bound to authenticated people; they are not proof of identity and cannot be supplied as arbitrary event authorship.

A membership records person, area, role/capabilities, grantor, creation time, optional expiry, revocation state and a membership generation. Device credentials identify their owning person and device, with their own revocation state. One person may use several devices; removing one device does not transfer ownership or remove unrelated members.

Do not reuse an existing local `workspaceId` as a globally authorized resource without a mapping. An area's stored resource membership determines its owner/scope. A caller-supplied `areaId`, `personId`, `ownerId` or role is never sufficient authority.

For a trusted-coworker alpha, recommend service-provisioned stable person IDs with expiring, single-use device enrollment and separate expiring area invitations. The initial roster may be admitted by an operator or an existing owner through an explicit flow. This avoids making implementation depend on provider-account identity or full team billing. The recovery/re-enrollment flow must preserve the person ID and require actual authority; a typed display name must never claim an existing identity.

The final account sign-in mechanism remains a dependency decision. Browser guest participation and a production identity provider can be added without redefining every membership and audit actor. Anonymous bearer guest links should not be the default for durable jointly editable workspaces.

## Invitation lifecycle

An area invitation specifies the area, intended capability ceiling, issuer, expiry and a single-use nonce whose digest is persisted. Acceptance is a transaction: authenticate the accepting person/device, validate the still-authorized inviter and current area policy, consume the nonce, create membership, return the resulting scope. A retry by the same accepted identity needs a recoverable receipt; another identity must not redeem it again.

Compare targeted invitations with owner-approved claims for the initial cohort. An unbound link forwarded to someone else should not silently impersonate the intended coworker. An explicit **who is joining** confirmation is useful when no established account directory exists.

Joining a workspace and contributing one's own agent view are separate operations. A member cannot publish another participant's private agent merely because its local ID is discoverable. The execution host must explicitly publish an approved projection of that agent/artifact into the area.

## Authority model and data boundary

At minimum distinguish `area.read`, `discussion.write`, `layout.edit`, `content.publish`, `agent.suggest`, `agent.prompt`, `agent.stop`, `approval.respond`, `terminal.control`, and `sharing.manage`. These are proposed capability concepts, not existing API names. UI roles may bundle them, but backend enforcement must preserve their distinctions.

Useful initial permissions are area read/discuss/layout edit and publishing one's own selected content. Prompting one's own local agent can use existing local authority. Prompting another host's agent is a separate explicit host grant. Owning a collaborative area should not automatically grant terminal or tool-approval authority over every contributed machine.

Enforce membership on every read, snapshot, replay, subscription, attachment/blob fetch, presence fanout and command. Resolve the resource's area from stored state. Filter data **before delivery**, including filenames, transcript text, output, previews, token aggregates and presence metadata. Hidden tiles and unrendered rows are not confidentiality boundaries.

At the host, intersect current membership, resource inclusion, capability and execution-owner policy just before effects. Keep human actor, proposer, accepting operator and actual runner identity distinct. A remote human must not be relabeled as a local agent to inherit the workspace API's default free-in-project grants.

Revocation increments membership generation, blocks new reads/inputs, terminates subscriptions, and invalidates unsent queued operations. An operation already committed reports its real outcome rather than pretending revocation undid it. Device revocation and membership removal are separate. A reconnect reauthenticates and reauthorizes; it cannot resurrect old membership from a cached UI state.

## CLI authentication remains local

Claude/Codex/Pi login stays owned by each CLI. Shared prompting uses the selected host's existing runner policy and authentication without exporting those credentials. Person identity, payment entitlement, provider account, execution owner and prompt author remain separate fields and meanings. Usage hover must not publish provider account identifiers or credentials as a shortcut to attribution.

## Ticket candidates

### AUTH-1 — Establish person/device identity and durable area membership

Outcome: two admitted people retain distinct stable identities and can join the same area from separate devices without gaining access to either complete desktop instance.

Scope: new typed contracts/store migrations, explicit area membership, owner/member capability presets, device enrollment and channel-scoped credential storage. Preserve companion V2 behavior; no automatic migration of paired phones into human area membership.

Acceptance: one person/two devices works; two people have distinct authorship; guessed area/resource IDs are denied without disclosure; owner removal/transfer has an explicit invariant; restart preserves membership; provider credentials never enter the new tables/protocol. Authentication method/recovery policy must be selected before production rollout.

Witness: deterministic Core/relay fixture with two people, three devices and two areas, exercising every role/resource intersection. Proposed new check names must be registered in the real matrix before they are treated as gates. No existing check flag is claimed here.

Dependencies: shared-area IDs/schema and transport service boundary.

### AUTH-2 — Deliver expiring invitations and revocation across active clients

Outcome: an invitation joins only its intended area/capability ceiling and ending access takes effect on already connected clients and pending commands.

Scope: hashed invite nonce, atomic acceptance/receipt, expiry/cancel, targeted-or-approved join, membership generations, socket eviction, queued-operation invalidation and host-side pre-effect rechecks.

Acceptance: two redemption attempts cannot create two different claimants; retries recover the original result; forwarded/expired/cancelled links fail under the selected policy; revoking A preserves B; a paused command revoked before effects does nothing; a committed command returns committed outcome; revoked clients cannot fetch blobs or replay through HTTP after socket eviction.

Witness: disposable relay process with two independent client identities and a barrier-controlled fake execution host. Assert denied data and unchanged host state, not merely an error UI. Matrix reports the new HTTP/socket/reconnect/revocation leg.

Dependencies: AUTH-1, durable command receipts and live subscription hub.

### AUTH-3 — Enforce shared-object projection and host-action grants end to end

Outcome: a captured area includes only deliberately published data, and participant abilities match the share sheet even when APIs are invoked directly.

Scope: resource-area lookup, per-object inclusion, projection allowlist, blob/preview/usage/presence authorization, explicit host grants, verified attribution and no ambient agent-grant reuse. Add share choices using existing Array styled controls and appropriate API exposure classification where new editable fields are introduced.

Acceptance: read-only participants cannot prompt or alter layout; layout editors cannot approve tools; area owners cannot automatically operate contributed hosts; private neighboring tiles never appear in payloads; revocation closes all data paths; permission wording accurately names the affected host and actual runner policy.

Witness: production share/capture route plus a two-person service fixture, asserting raw delivered envelopes and effects. Include intentionally crafted resource IDs and direct command calls. Native sharing surfaces need light/dark renders and interaction witnesses; matrix reports the legs. Notification behavior, if added, must update the maintained path inventory.

Dependencies: AUTH-1/2, area capture membership, artifact projection and runner host gateway.

## Remaining uncertainties

- Existing deployed relay behavior, credential lifecycle and operational recovery were not queried.
- Current production subscription work may exist in separate benches; this memo inspected the main working tree and parked plan, not those benches' unmerged implementation.
- Whether end-to-end encryption is required, and how group key rotation interacts with membership, must be decided alongside transport. Server authorization does not retract already downloaded plaintext.
- Full organizational policy, ownership succession and browser identity recovery are beyond the first coworker-alpha scope, but must not be made impossible by equating people with machines.

No build, test suite, provider login, Keychain access, server request, app launch or live-state mutation was run. This memo records proposed tickets and future witnesses, not completed checks.
