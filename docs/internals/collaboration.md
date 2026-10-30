# Collaboration implementation

Implementation status: portable document and initial human membership service.
Live HTTP subscriptions, presence transport, the persisted native-facing controller
and reviewed publication preparation are implemented. Native accounts, shared
scenes and source capture/review are wired; shared geometry gestures, agent
dispatch and artifact blobs remain separate work. [Progress](../../.plans/105-collaboration/PROGRESS.md)
tracks the board and actual verification; the research packet describes the full
intended feature.

## Ownership and trust

`ContinuumRevivedCollaborationProtocol` contains the portable area document and
wire contracts. Core retains its `SharedArea` alias and source Tile geometry
adapter. The portable module depends on Swift Crypto and Foundation and is built
in both the main package and Linux relay package. It imports no app/runner state.

`ContinuumRevivedCollaborationService` owns a separate SQLite database, human
principals, device bearer credentials, execution-host registrations, area
memberships, invitations, ordered accepted operations and encrypted snapshots.
It does not reuse companion device identity. Every database open authenticates a
sealed key marker before further migrations. Legacy unmarked adoption validates
every snapshot and operation transactionally before binding the key, preventing
a deployment key typo from creating mixed-key ciphertext. The NIO server mounts its routes
only when an explicit collaboration store is supplied. `/v2` remains separate.

This first service is trusted with plaintext while processing requests. Snapshots
and operation payloads are AES-GCM encrypted at rest with the deployment-supplied
collaboration key; opaque identity/membership metadata is not encrypted. Tokens
and invitation/enrollment secrets are 256 random bits and stored as SHA-256
hashes. Existing companion encryption is unchanged. This is not group E2EE.
Deployments must supply TLS, rate/size/storage controls, key rotation, backups,
retention and verified restore before admitting real shared content (COL-20/22).

## Admission and recovery rules

Initial people are operator-admitted. A public endpoint cannot claim a person ID
or register a new account by display name. Operator provisioning returns a
single-use enrollment code expiring after ten minutes. An authenticated device
can issue another short-lived enrollment for its own person. Redemption creates
an independent device credential; a consumed enrollment cannot create another.
If the response is lost, an authenticated sibling device can issue replacement
enrollment. With no remaining authenticated device, existing-account operator
recovery is still required work; creating a new person is not recovery. Native
account UI now uses the scoped credential store. Offline witnesses inject a
memory vault and never exercise the actual Keychain adapter.

Area invitations target a specific existing person and cannot grant ownership.
They expire, require the issuing device to remain active and the issuer to remain
an owner, and bind to the area's membership epoch. Acceptance is transactional;
the same person can recover a successful acceptance while it remains current.
Forwarding the code cannot admit a different person. New members receive **all
retained shared-area history**; there is no partial-history mode yet.

One owner is retained: self-removal is refused, and ownership transfer is not yet
implemented. Editors may arrange admitted content, discuss, edit revisioned
agreements and publish observations from their own registered execution device.
Viewers may read. These roles convey no authority to prompt/stop an agent, approve
a provider request or type into a terminal: those routes do not exist yet.

`Collaboration.Capability` separates view, discuss, layout, publish and membership
management from the unavailable host actions. The service classifies every edit
inside its write transaction; a client-supplied grant or principal is not authority.
An editor can arrange a teammate's published observation but cannot remove that
teammate's source publication. The area's owner has the same source-ownership
restriction. Publication owners can unpublish through another authenticated device
of their own person while the original host is down. Admission requires a registered
host on the publishing device; observations require sources, and discussion/agreement
objects cannot masquerade as host-bound sources. Full host-side grant admission,
nested artifact permissions and live projection policy remain COL-07/13/15/16.

Every read and mutation reauthenticates its device and checks live membership
inside its database transaction. Removal increments the area epoch. Document
commands require the current epoch, and member removal requires `If-Match` with
the observed epoch. Revoked devices lose subsequent requests on all their areas;
revoking one device preserves the person's other devices. Held live requests are woken on removal and reauthenticate before any result is
returned. The client ends its session and clears its replica on access loss.
Host-side pre-effect admission and complete recovery remain open on COL-04/07/08.

## HTTP contract

Prefix: `/collaboration/v1`. JSON dates in responses use ISO 8601. All routes
except enrollment redemption require `Authorization: Bearer …`.

| Method and path | Meaning |
| --- | --- |
| `POST /enrollments/redeem` | Consume operator/device enrollment; body `RedeemEnrollment` |
| `GET /self` | Authenticated person and device |
| `POST /devices/enrollments` | New enrollment for this person; body `DeviceEnrollmentRequest` |
| `DELETE /devices/{device}` | Revoke a device owned by this person |
| `POST /hosts` | Register an execution host bound to this authenticated device |
| `POST /areas` | Create an empty area owned by this person |
| `GET /areas/{area}` | Current scope and validated portable snapshot |
| `POST /areas/{area}/invitations` | Owner issues targeted editor/viewer invitation |
| `POST /invitations/accept` | Redeem targeted invitation |
| `DELETE /areas/{area}/members/{person}` | Owner removes member; `If-Match: {epoch}` required |
| `POST /areas/{area}/commands` | Apply an atomic document command with current epoch |
| `POST /areas/{area}/updates` | Cursor-based catch-up or a held live request |
| `DELETE /areas/{area}/updates/{subscription}` | Authenticated explicit cancellation |
| `POST /areas/{area}/presence-sessions` | Replace this device's presence session |
| `POST /areas/{area}/presence` | Publish cursor/optional viewport in that session |
| `DELETE /areas/{area}/presence-sessions/{session}` | End that presence session |

Unknown and excluded areas both return the same 404 response. Invalid credentials
return 401, insufficient capability 403, invalid/expired invitation 410, stale
epoch/revision or changed retry intent 409. The collaboration route body limit is
256 KiB. The shared command's route area, authenticated author and publication
host are validated; client IDs are not authority. Source publication from another
device, even the same person's second device, is refused.

Snapshots, operation append and reducer receipts commit in one SQLite transaction.
Retries preserve the original revision; operation identity is bound to its actor
as well as payload. Source privacy relies on typed projections before admission;
this service does not inspect or upload the source filesystem. Operation paging is implemented as described below. Snapshot compaction and blob
storage remain future work.

## Live updates and presence

The native client uses immediate-wakeup HTTP long polling rather than requiring
WebSockets. A subscription holds for at most 25 seconds and returns on a commit,
presence change, expiry or removal. It retains no event payload queue: after each
wake it reauthenticates and reads durable operations from SQLite. The service
allows two held requests per device/area and 1,024 globally. Cancellation has an
explicit authenticated endpoint because closing a Foundation request did not
reliably close its server request in the first fixture. Short-lived cancellation
receipts also cover cancellation arriving before the original request.

Each catch-up page contains at most 128 events and at most 512 KiB of encoded
event content. `through` fixes one consistent high-water mark while the client
drains pages. A subsequent request without `through` discovers newer commits.
Out-of-range cursors and history gaps require resynchronization; the client never
advances to a head it has not applied. The v2 head-revision migration decrypts
v1 snapshots to backfill the exact head transactionally and refuses a wrong key
without committing a schema change.

Presence has a separate version, server clock and 15-second lifetime. A
server-issued session supersedes old packets for the same device/area; sequence
numbers refuse reordered observations. Bursts keep their latest cursor and
coalesce notification to at most 20 Hz per device/area. Presence never writes an
operation or snapshot and does not imply execution-host liveness. Viewport
publication is optional; a client can omit it. Camera/follow UI and token hover
usage are still separate work. Removal/device revocation purges presence and
wakes affected readers immediately.

`ContinuumRevivedCollaborationClient` supplies the authenticated HTTP API,
sequence-checking replica and `CollaborationSession` lifecycle. It has no implicit
production endpoint. HTTPS is required except for explicitly allowed loopback
fixtures. Provider auth, cookies and a shared URL cache are not used. Its owned URLSession
refuses redirects through the session delegate before another endpoint receives
a request; per-request redirect delegates were insufficient on Linux. Unsupported
schemas and incompatible accepted commands terminate the session rather than
being retried as transient network failures. The session
gets a snapshot, catches up from its actual revision, reconnects with bounded
backoff and clears state on access loss. Full replica notifications can coalesce
for rendering after events are applied; durable events themselves cannot drop.
A native view must stop its session on close. The Core controller described below
now persists accepted replicas; an executable outbox and production canvas mount
remain COL-10/19.

## Private local persistence

Core now supplies a separate local cache/binding store and credential vault.
`SharedAreaLocalStore` requires an injected app-support parent, adds the actual
AppChannel directory, and scopes files by channel namespace, canonical service
endpoint, person and area. A dev cache copied into the prod path is refused.
Credentials never enter these files. Document and applied revision commit in one
atomic generation with local ID references, private camera/view state and drafts.
A local generation CAS prevents two same-revision private edits from silently
erasing one another; callers carry forward the state returned by `save`.
Future/corrupt state or missing primary with recovery history refuses overwrite.

Bindings contain local IDs, not a checkout root or `AgentRecord`. A local reference
is a resolution hint, never authority to instantiate a runner. Cached documents
remain read-only until the native controller establishes live identity/scope.
No executable outbox or production scene mount is provided yet.

`CollaborationCredentialStore` requires an injected vault and scopes one device's
credential by canonical endpoint, person, device and AppChannel. Its memory-vault
fixtures never call Keychain. The real adapter uses only its live channel's
Keychain namespace and an `LAContext` with interaction disabled for all Security
operations. That adapter has compiled but has not been exercised against a real
Keychain in this task. Native sign-in/credential selection is now wired;
existing-account operator recovery remains future work.

`SharedAreaController` is the main-actor owner for one native shared scene. Its
production transport adapter connects the existing API and session to the scoped
credential store and local cache. It checks `/self` against the saved person/device,
then fetches current membership before enabling a mutation. Offline/cached,
connecting and reconnecting content is read-only. Each open/close owns a separate
generation; a late identity check or request acknowledgement cannot reopen a closed
view. Closing cancels only this subscription, never a source runner.

Accepted snapshots persist their actual document revision while preserving current
private drafts, bindings and camera. CAS contention reloads and reapplies only the
field being changed. Presence-only updates stay in memory and create no cache
generation or backup. An acknowledgement may arrive ahead of the subscription;
older valid pages cannot regress the visible document or incorrectly revoke it.
A newer cache from another controller stays read-only until this connection covers
its accepted revision and epoch. Conflicting same-revision documents refuse. A forbidden object mutation retains
valid area access and its private draft; it is distinct from revoked credentials
or removed membership.

Access loss clears the controller's visible document, presence and current scope.
An optional backward-compatible `accessDenied` cache field suppresses that cached
content on reopen while preserving private drafts for recovery. Current successful
online revalidation can clear the marker. If a local write fails, visible content
still clears and the persistence error remains observable; a durable denial cannot
be promised after a failed disk write. Cache bytes and backups are not remotely
erased copies. Submission saves an explicitly supplied private draft first, retains
it on conflict/refusal/unknown outcome, and removes only the matching unchanged
draft after acceptance. Unknown outcomes retain the original operation ID for an
explicit identical retry; they do not automatically replay an action.

## Reviewed publication preparation

`SharedAreaPublication` takes model WORLD frames and explicit content choices. It
prepares immutable review rows, an allowlisted portable manifest and private source
bindings. Whole-workspace/zone/rectangle selection requires declared complete model
coverage; explicit tile selection uses a project-plus-tile key and refuses missing
members. Fully enclosed rectangles exclude partially overlapping frames. Only
admitted entries determine the shared origin; omitted/unsupported private tiles
cannot shift published geometry.

Managed-agent observations contain opaque owner/host/binding IDs and explicitly
exclude transcript history. Notes require selected captured text and an owner-read
content revision, becoming an immutable agreement revision or discussion post.
Terminals, browsers and other unsupported surfaces are named in review rows;
artifacts remain unsupported until their immutable payload storage exists.
Unsupported/omitted rows create no wire edits. Source titles, local IDs, paths,
metadata, cameras and runner records are excluded from the portable manifest.

Confirmation compares the exact reviewed digest with freshly supplied owner model
and content values, retaining stable operation/object IDs. Changed membership,
frames, host binding or content refuses. The digest is a local drift check, not
authentication or a server/host grant. The model/notes inventory bridge now reads
the owning native controllers, as described below. User-facing capture selection
and explicit review still require integration; a pure helper cannot establish
that its caller actually read fresh values.

## Native account and shared windows

File > Collaboration opens the account hub deliberately. Startup constructs no
collaboration account session or Keychain request. The user supplies a service
URL and one-time Array enrollment code, or selects a previously remembered
device account. Provider CLI login is unchanged. No production endpoint is
embedded. Enrollment saves the scoped credential before safe account metadata;
incomplete local remembrance has an explicit Save connection action that does
not consume the code again. The retained descriptor is currently in memory;
quitting before repair does not automatically rediscover an unindexed vault item.

The account registry contains endpoint/person/device IDs, local labels, known
area IDs and an optional host-registration hint. It never contains enrollment
codes or bearer credentials. It uses channel stamps, atomic generations and CAS,
and preserves corrupt/future/recovery states. Native create, join and open go
through current service identity/membership. A known successful creation or
invitation acceptance followed by local/state failure retains the exact area ID
and directs explicit Open recovery, preventing a second creation or code replay.
Invitation controls use the observed owner role; service authorization remains
authoritative. Displayed invitation replies are scoped to the current account
and area and are discarded after a context change. No invite notification is sent.

`SharedAreaWindowController` mounts through the dedicated overload of
`AppDelegate.mountWorkspaceSceneAtBoot`, also used by the native witness. The
scene receives a shared controller/person and a host view, with no source spawner,
zone arming or project persistence callback. It renders portable observations,
discussions and immutable agreement revisions on a jointly arranged model with
private camera/focus. Joining and closing cannot mint or stop a source executor.
The native window currently supports human discussion/agreement creation and
editing; observation history and execution controls are explicitly unavailable.
Geometry dragging/semantic undo remain separate work.

Collaboration windows and their sheets own a separate UI command scope. Personal
creation, palette/toolbar callbacks and the hold-leader keyboard routes refuse
that scope before resolving a source project. The explicit workspace API does
not read this UI gate. AppKit supplies the foreground window in production;
background self-checks inject that platform observation without activating over
the user, while exercising actual windows, events, menus and source outcomes.

File > Share workspace, Share zone and Capture area to share choose a destination
through the account hub. Capture draws a temporary fully-enclosed WORLD region
using the rendered viewport; it creates no local zone or source membership. The
review requires explicit note/agent choices, lists unsupported exclusions, shows
captured content and portable layout, and rereads source owners at confirmation.
Each review owns an independent area controller, so closing the destination
scene leaves its receipt-recovery path intact. Closing the hub cancels setup;
post-await checks fence account/source changes and late windows.

`submitPublication` validates confirmed area/author/source identity and saves
private source bindings before any remote effect. It verifies acknowledged
revision against the deterministic applied/duplicate outcome. Identical retry
retains the reviewed operation and IDs; every rejected retry after uncertain
delivery remains uncertain, because current permission/epoch errors cannot
disprove an earlier commit. A pending review is brought forward before another
capture can allocate a duplicate. The full command remains in memory: durable
restart recovery/outbox and close-independent pending delivery are still open.

Rendering uses one drawn canvas, at most 128 frontmost visible objects and bounded
800-character previews with a visible limit notice. The inspector pages full
entries instead of creating a native view per message. Drawing, hit testing,
object navigation and exposed frames share the same visible subset. Tab/Shift-Tab
and the Objects choice control navigate existing objects. Presence-only updates
do not rebuild document previews or the object choice list. Private drafts and
camera writes are debounced, with an explicit close flush that can retain the
window when saving fails. Focus changes commit only after private persistence;
per-mount generations fence old asynchronous outcomes after a remount.

`SharedAreaInventory.capture` reads WORLD model geometry through the persistence
merge boundary and pure project-owned membership resolution. It rereads live
unsaved note text or persisted bodies and hashes the current content. Exact
project/tile matches resolve managed agents without creating one. It never
acquires a missing controller, writes a membership repair or copies lifted hover
frames. Missing project access or projectless ambient ownership is named as
incomplete coverage; those members are not silently omitted. This bridge is
witnessed through a mounted source workspace, but the user-facing selection and
review flow has not yet been connected to it.

## Opt-in process configuration

The existing relay starts collaboration only when both
`RELAY_COLLABORATION_DATABASE_PATH` and a base64-encoded, at-least-32-byte
`RELAY_COLLABORATION_MASTER_KEY` are supplied. The database must be distinct from
the companion database. Configuration errors fail closed. No default endpoint,
production data migration or deployment is activated by this change.

With isolated configuration, `continuum-relay --collaboration-enroll "Label"`
creates a new person and prints one-time enrollment JSON, then exits without
binding network listeners. Treat this intentional operator output as admission
material. It is separate from CLI provider login. This command does not yet
provide existing-account recovery, cancellation or operator roster management.

## Verification

`scripts/run-matrix.sh --collaboration` rebuilds the portable checks, service HTTP
checks, relay executable and existing relay suites. It reports inventory,
portable reducer/review/native-controller witnesses, real localhost HTTP A/B/C and
companion regression legs. Core/controller checks use memory credentials and
separate temporary app-support roots. Their actual HTTP adapter fixture confirms
a reviewed manifest through NIO, converges two independently authenticated clients,
preserves separate cameras/drafts and source files, and suppresses a removed
collaborator's cached content on reopen. These are controller assertions, not proof
of a mounted native scene or real runner counts.

The same targeted gate now also builds Array and reports
`--collaboration-native-check`, `--ui-probe-check` and `--menu-contract-check`.
The native flag drives the owning source workspace mount, dedicated shared-scene
mounts and actual hub controls with injected account/area transports and memory
vaults. It checks actual frames, failure/close/remount/draft behavior, bounded
pointer/keyboard navigation and zero recipient executor construction. The source
and recipient provider effects still need the complete host workflow. All three
collaboration token owners are in the live appearance sweep and adopted-value census. Retained
light/dark renders and exact source hashes are in the
[native evidence](../../.plans/105-collaboration/validation/native-20261030/README.md).
The [capture milestone](../../.plans/105-collaboration/validation/capture-20261030/README.md)
adds the actual production-mounted pointer → hub → review → publication journey,
exact source/layout/binding preservation, independent review lifetime and stable
uncertain retries. Mixed-window checks use real window/event hierarchies with an
injected foreground lookup and explicit nonwaiting sheet attachment. The bounded
review witness checks 121 memberships, four complete pages, at most 40 choices,
one reused full-content reader and legacy scrolling. Its original combined gate
reported seven passing legs plus a stalled native fixture; corrected affected
native, appearance and menu legs passed. This is separate from a complete
native-to-HTTP/provider host acceptance or a full release matrix.
The service fixtures use independent temporary databases and an injected clock;
they never open a real checkout, call a provider or access tmux. One aborts a
SQLite operation insert after the snapshot write to prove atomic rollback.
The live fixture replays 600 retained messages, races catch-up with a new commit,
checks byte limits, publishes/coalesces/expires presence, cancels held reads,
removes active members/devices, reconstructs the server on the same port and
verifies automatic client recovery plus the v1 migration rollback/backfill.

`bash scripts/check-relay-linux.sh` copies only relay/collaboration sources into a
throwaway container context. Its checks stage builds and runs the collaboration
HTTP fixture alongside existing companion suites. This verifies service code;
it does not verify the native canvas, host runner, TLS proxy or deployed service.
