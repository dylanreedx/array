# Collaboration implementation

Implementation status: portable document and initial human membership service.
Live HTTP subscriptions, presence transport, the persisted native-facing controller
and reviewed publication preparation are implemented. Native accounts, shared
scenes and source capture/review are wired. Shared group geometry/causal Undo,
durable pending delivery, explicit person-to-person source-host handoff and
hover-only authenticated usage are implemented in the finish bench. Their current
verification status is recorded in Progress; artifact blobs remain separate work. [Progress](../../.plans/105-collaboration/PROGRESS.md)
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
Deployments must supply TLS, rate/size/storage controls, key rotation and a
backup schedule before admitting real shared content (COL-20/22). The retention
contract and the restore procedure are under Retention below.

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

**History on join, a decision for Dylan.** Removing a discussion or agreement
takes it off the canvas, but its posts and revisions stay in the area document
and its retained operations. Someone invited later therefore still reads that
text. Unpublished artifacts behave differently: their bytes follow current
publication, so nobody, the owner included, can fetch them after the unpublish.
The recorded choice in [DECISIONS.md](../../.plans/105-collaboration/DECISIONS.md)
keeps this. Shared discussion stays one continuous history, and nothing that
was already readable to the area disappears behind a membership date.

The cost: unpublish is not redaction. Text that went to an area is readable by
every future member for the life of the area. A real redaction would need a
per-object history floor in the reducer and in compaction. That is a schema
change, not a setting. The boundary audit pins the current behaviour
(`pinned policy: late joiner D receives a removed discussion's text, never an
unpublished artifact's bytes`), so changing it is deliberate and visible.

One owner is retained: self-removal is refused, and ownership transfer is not yet
implemented. Editors may arrange admitted content, discuss, edit revisioned
agreements and publish observations from their own registered execution device.
Viewers may read. Membership alone conveys no agent control. The source owner
may separately offer exclusive prompting control to a teammate; the teammate
must accept against the current host generation and membership epoch. Provider
approvals, terminal typing and credentials remain owned by the source machine.

`Collaboration.Capability` separates view, discuss, layout, publish and membership
management from separately admitted host actions. The service classifies every edit
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
Host-side pre-effect admission rechecks the exact publication, generation,
controller, membership epoch and immutable context revision. Data recovery uses
the exact persisted request; executable dispatch uses a separate host journal.

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
| `POST /areas/{area}/hosts/{host}/heartbeat` | Beat for this device's own host under a run generation; returns its liveness |
| `DELETE /areas/{area}/hosts/{host}/runs/{generation}` | End exactly that run; the host reads offline at once |

Unknown and excluded areas both return the same 404 response. Invalid credentials
return 401, insufficient capability 403, invalid/expired invitation 410, stale
epoch/revision or changed retry intent 409. The collaboration route body limit is
256 KiB. The shared command's route area, authenticated author and publication
host are validated; client IDs are not authority. Source publication from another
device, even the same person's second device, is refused.

Two status details are deliberate, recorded so that nobody "fixes" them by
accident. First, when a host claims or admits a request whose requester has
since been removed, the answer is 404, not 403. The requester's membership is
gone, so the authority lookup misses; both statuses refuse and change nothing.
Second, a member probing an ID inside an area they belong to can get 403 for a
real dispatch and 404 for a made-up one. Dispatch IDs are random client UUIDs
that other members never see. A person outside the area gets the unknown-area
404 on every nested route, whether the ID is real or not.

Snapshots, operation append and reducer receipts commit in one SQLite transaction.
Retries preserve the original revision; operation identity is bound to its actor
as well as payload. Source privacy relies on typed projections before admission;
this service does not inspect or upload the source filesystem. Operation paging
and compaction are implemented as described below; artifact blobs are under
Shared artifacts.

## Retention

Only the operation log is bounded. Everything that decides identity, authority
or whether a deletion holds is kept for the life of the area. Defaults live in
`CollaborationRetention` and are passed explicitly to `CollaborationStore`.

| Class | Where it lives | Retention |
| --- | --- | --- |
| Current area state (layout, discussion posts, agreement revisions) | sealed head snapshot | Life of the area. Discussion is part of the document, so a post outlives the operation that added it. |
| Operation log (replayable events) | `operations` | The newest 4,096 operations, plus anything younger than 7 days. Older operations fold into the horizon snapshot in batches of at least 512. |
| Horizon snapshot | `areas.horizon_snapshot` | Replaced by each compaction; always the exact document at `areas.horizon`. |
| Deleted object and placement IDs (tombstones) | head and horizon snapshots | Life of the area. A stale create of a deleted ID is refused before and after compaction. |
| Operation receipts (ID, digest, original revision) | snapshots, plus `operation_receipts` for the actor | Life of the area. A retry returns its original revision; another person reusing the ID gets `changedIntent`. |
| Membership epochs, removals, device revocation | `areas`, `members`, `devices` | Life of the service. Compaction never touches them. |
| Artifact items | document items/tombstones | As current state. An artifact item must name its publishing source. |
| Artifact revisions, reviews and published blobs | `collaboration_artifact_*`, sealed | While the artifact stays published. Unpublishing deletes all three: a removed object ID can never return, so its bytes are unreachable. |
| Staged artifact blobs no revision names | `collaboration_artifact_blobs` (`published=0`) | `artifactStagingLifetime` (1 hour), collected on the next upload in the area. They count against the 64 MiB area quota until then. |
| Executable requests not yet admitted by their host | `agent_dispatches` (`queued`, `claimed`) | 15 minutes from enqueue, then refused. The requester reconfirms with a new request under current authority. |
| Admitted attempts and unknown outcomes | `agent_dispatches` (`dispatching`, `uncertain`, `accepted`, `refused`) | Life of the area. Expiry never rewrites them; the host's journal decides between accepted and uncertain. |

Compaction runs in its own transaction after a command commits. It folds the
horizon snapshot forward through the eligible prefix with the same reducer
clients use, writes the new snapshot and horizon, and only then deletes the
covered operations. A fault anywhere in that transaction keeps the full log and
the old horizon, never undoes the command that triggered it, and increments
`compactionFailures`. The next commit retries.

A cursor below the horizon gets `409 snapshotRequired` rather than an empty or
partial page. `CollaborationSession` treats every 409 as a resnapshot: it drops
its replica, fetches the head snapshot and resumes paging from there. That
client ends byte-for-byte equal to one that replayed every operation. Receipts
and tombstones keep growing for as long as the area lives. Pruning them would
need a reducer schema change.

Restore is a whole-file operation. `backup(to:)` writes a consistent online
copy with SQLite's backup API, and a cold copy of every `collaboration.*` file
after SIGKILL is also valid. The key never enters the copy; the operator carries
it separately. `verifyIntegrity()` checks every area: horizon snapshot plus the
retained tail must reproduce the stored head exactly, with one receipt per
revision and no operation left at or below the horizon. Run it against a
restored database before serving it.

Queued executable requests that predate the retention migration have no
enqueue time and are refused the first time they are seen.

## Live updates and presence

The native client uses immediate-wakeup HTTP long polling rather than requiring
WebSockets. A subscription holds for at most 25 seconds and returns on a commit,
presence change, expiry or removal. It retains no event payload queue: after each
wake it reauthenticates and reads durable operations from SQLite. The service
allows four held requests per device/area (native scene, source host, capture
review and one replacing view) and 1,024 globally. Cancellation has an
explicit authenticated endpoint because closing a Foundation request did not
reliably close its server request in the first fixture. Short-lived cancellation
receipts also cover cancellation arriving before the original request.

Each catch-up page contains at most 128 events and at most 512 KiB of encoded
event content. `through` fixes one consistent high-water mark while the client
drains pages. A subsequent request without `through` discovers newer commits.
Out-of-range cursors and history gaps require resynchronization; a cursor behind
the compacted horizon gets `snapshotRequired` (see Retention). The client never
advances to a head it has not applied. The v2 head-revision migration decrypts
v1 snapshots to backfill the exact head transactionally and refuses a wrong key
without committing a schema change.

Presence has a separate version, server clock and 15-second lifetime. A
server-issued session supersedes old packets for the same device/area; sequence
numbers refuse reordered observations. Bursts keep their latest cursor and
coalesce notification to at most 20 Hz per device/area. Presence never writes an
operation or snapshot and does not imply execution-host liveness. Viewport
publication is optional; a client can omit it. Native cursors follow the local
camera transform. Token counts appear only while hovering a cursor or inspecting
it through accessibility; they are absent from resting cursor labels. Following
a teammate's camera remains separate work. Removal/device revocation purges presence and
wakes affected readers immediately.

Execution-host liveness is separate. The app's host session beats every 10 s per
area from the device that registered the host, under a run generation minted per
hosting session. The relay persists last-seen and retires a replaced generation;
a beat from a retired or ended run is refused with 409, including after a relay
restart, and a refused run stops rather than minting another. `Updates.hosts`
projects online, stale after 30 s without a beat, and offline after 90 s, on a
clean end, or as soon as the host's device or person loses access. Held readers
wake at the next transition. Shared agent cards state the host's liveness; cached
discussion stays readable while a host is offline.

`ContinuumRevivedCollaborationClient` supplies the authenticated HTTP API,
sequence-checking replica and `CollaborationSession` lifecycle. It has no implicit
production endpoint. HTTPS is required except for explicitly allowed loopback
fixtures. Provider auth, cookies and a shared URL cache are not used. Its owned URLSession
refuses redirects through the session delegate before another endpoint receives
a request; per-request redirect delegates were insufficient on Linux. Unsupported
schemas and incompatible accepted commands terminate the session rather than
being retried as transient network failures. That ends in its own
`incompatible` status, distinct from access loss: the controller closes the view
but leaves the local cache bytes, drafts and outbox untouched, where loss of
access would mark the cache denied. A newer build can then read them. The session
gets a snapshot, catches up from its actual revision, reconnects with bounded
backoff and clears state on access loss. Full replica notifications can coalesce
for rendering after events are applied; durable events themselves cannot drop.
A native view must stop its session on close. The Core controller described below
now persists accepted replicas and pending data requests, and native shared
scenes mount through the production shared-scene entry point.

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
Schema 3 also persists exact data commands, reviewed bindings, delivery state
and matching private drafts before the transport effect. Schema 2 is migrated in
memory without overwriting its original bytes until the next complete save.

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
identical retry. After fresh online admission, cold recovery reconciles retained
receipts first, then may replay the exact still-eligible data command. It never
rebases an obsolete command or treats a later denial as proof an earlier request
did not commit. This data retry policy does not apply to executable prompts.

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
The native window supports discussion/agreement editing, atomic selected-group
moves/resizes and compensating Undo/Redo. Placement write stamps prevent Undo
from overwriting a teammate's intervening change, including equal-looking ABA
moves. A host-local geometry ledger saves the inverse intent and original request
before submission, restoring eligible Undo after crash/relaunch and lost replies.
Observation transcript history is not published. A separate handoff dialog offers
control and sends reviewed context to the original executor.

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
capture can allocate a duplicate. The full reviewed command and bindings are
durable before transmission, so a closed review or restarted app can recover the
original receipt without allocating new object or operation IDs.

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
witnessed through the production-mounted source workspace and connected to the
user-facing selection, destination and explicit review flow.

## Handoff and source execution

A published agent stays on its original machine and checkout. Shared layout,
human context and explicit prompt control travel; source files, provider login,
process handles and terminal sessions do not. Merely publishing a reference
preserves the source owner's normal composer. After a teammate accepts control,
the former controller's prompts are refused with their draft intact. Source view
closure/reattachment does not mint another executor or change its logical host
generation. Reclaiming control is explicit.

`SharedAgentHandoffController` persists immutable pending prompt identity and
private recipient/text/context/timing drafts. The dialog offers send-now or queue
through the shared Choice controls. Network uncertainty retains the same request
and a close-save failure retains the editable draft. `SharedAreaHostSession`
retains the host dispatcher independently of the shared window. Its journal
commits an irreversible attempt marker before supervisor acceptance. After a
crash at that boundary, the outcome is honestly uncertain and never automatically
resent. Queue drain checks the original typed command and current authority;
human text is never interpreted as a grant.

A queued or claimed request that its host has not admitted within the authority
window (15 minutes by default) is refused, not executed late. Retrying its exact
ID returns that refusal. A relay receipt is never execution: `queued` says the
host has not accepted the prompt. An attempt already past admission is the
host's record and is never rewritten by expiry.

## Live agent views

A teammate can watch a published agent without anything running on their
machine. The host session owns one `SharedAgentProjector` per published local
agent. It attaches through the supervisor's atomic `transcriptAttachment`, so
every event after the attach is in the tail and none is in both. An allowlist
on the host decides what crosses: assistant text, tool kind and status, turn
boundaries, phase, bound-runner capabilities and every prompt that starts a
turn, as its sender and the words they typed (0.7.38). A prompt row is fired
from the supervisor's one send seam, so the owner's own prompts and teammates'
cross alike; the "From …" attribution, shared context, reference envelopes and
local paths do not, and another agent's message crosses only as "who sent the
last prompt". Reasoning, tool titles and output, requests and their questions,
usage, error text, provider ids and terminal control characters never cross.
History from before publication is excluded unless the owner chooses assistant
output, and only assistant cards qualify.

Prompt rows are newer than the 0.7.37 relay and app: teammates see prompts
only once the relay is redeployed, and deploying it first costs nothing. A reader that does not ask for prompts (`ReadRequest.prompts`, absent in
0.7.37) is served the same positions with each prompt as `.prompted` and no
prompt row. A host whose relay refuses a batch carrying prompts (400
`invalidRequest`, a 0.7.37 relay's decoder) resends it that way and keeps doing
so for that projection, so nothing stalls behind a frame the relay cannot read.
On the owner's Mac a teammate's prompt draws as their named card
(`AgentMessagePayload.Origin.teammate`), live and on restore, read back from
the attribution the agent was given.

Every frame carries host, object, a host generation persisted per object and a
sequence. The host, the service and each viewer apply the same reducer
(`Collaboration.AgentProjection`). A late join gets the head snapshot. A cursor
gets every retained frame once. A gap, an older generation or a cursor beyond
the retained 512 frames gets an explicit resnapshot, never a guess. The service
refuses a stale generation's frames. Only the device that publishes the
observation, as its owner, may write. Any current member may read.
Unpublishing deletes the stored projection, and backups authenticate it.
Bounds (32 rows, 3 KiB per row, 1 KiB deltas, at most 16 prompt frames per
batch) keep a full snapshot and a full batch under the 256 KiB request limit.

Controls are read from the bound runner (`turnSnapshot`), never from the
harness. Interrupt is advertised only with a bound steering runner, and
teardown is never published. Remotely, only the control holder can send or
queue, and only through the handoff route. Steer, interrupt and provider
approvals have no cross-host route, and a watched session offers nothing.

Selecting a published agent replaces the inspector's reader with
`SharedAgentLiveView`. It polls one agent at a time, stops on deselect and
unmount, and turns into last-confirmed history when the area reports the host
offline. Witnesses: the projection sections of the service checks (portable
and HTTP A/B/C) and the "live agent projections" stage of
`--collaboration-native-check`, which drives the real supervisor and the three
fake CLIs and mounts the scene through the production entry, and
`--collaboration-full-access-check`, which shows every prompt in the owner's
tile and both teammates' views under its sender's name.

## Hover usage accounting

Only explicitly published local managed agents contribute. Codex session counters
use cumulative high-water marks, Claude turns use distinct turn identities, and
Pi messages use stable message identities with cached input included. Provider
observations feed a private atomic ledger outside the source project; duplicate
or reordered measurements and reopened views cannot add the same tokens twice.
Unknown historical day attribution remains partial, while temporary missing
reporters can become complete. UTC-day observed deltas and reported totals have
separate labels. Private counter IDs, source paths and prompt text never enter
the usage report.

The service accepts reports only from that registered publishing device with
current area membership. Durable encrypted reports survive relay restart;
unpublishing the last source for a host removes its future projection. Multiple
registered hosts on one device aggregate for its cursor. Presence supplies the
authenticated human label. Counts and last-measurement/coverage details render
only in the transient hover or accessibility inspection card; exiting the window,
peer expiry or losing access clears inspection. This reports published agents,
not an account-wide provider billing total.

## Shared artifacts

An artifact is an admitted `.artifact` item WITH a source (owner, host,
binding). Its revisions and bytes live beside the document, never in the
operation stream. A revision is an immutable manifest (host-minted id, parent
= the live revision it supersedes, base HEAD/merge base, a coverage
declaration and per-path entries) plus SHA-256-named blobs. The declaration
counts omitted changed/untracked paths without naming them; only `included`
entries carry bytes. `branch` covers committed `mergeBase...head` only.
Limits: 1 MiB per blob, 8 MiB per revision, 64 MiB per area, 256 entries.

Routes under `/areas/{a}/artifacts/{o}`: `PUT blobs/{sha256}` (raw bytes,
hash-checked), `POST revisions`, `GET` (live state), `GET revisions/{r}`,
`GET revisions/{r}/blobs/{sha256}`, `POST reviews`, `POST revisions/{r}/drift`.
Only the source owner, from the source host's device, uploads, publishes or
reports drift. A blob is reachable only as (current member, currently admitted
artifact, a revision of it, a digest that revision includes); storage is per
area and object with no cross-area dedup, and every miss is the unknown-id 404.
Bytes and manifests are AES-GCM sealed; blob AAD binds area/object/digest.

Reviews pin (object, revision, content digest). Applicability is `current`,
`superseded(by:)` or `sourceChanged`; drift is set once by the owner host and a
new revision is the remedy, so approval never carries forward. The owner-host
`SharedArtifactProducer` (Core) runs git on a private copy of the index,
because `git diff` rewrites a stale index even with optional locks off; it
re-reads until two reads agree or refuses with `changedDuringCapture`. The
recipient's `readArtifact` verifies digests and returns bytes in memory; it
takes no path.

Every updates page carries `artifactHeads`: latest revision, sequence, drift
flag and review count for each admitted artifact. Publishing, reviewing and
drift wake held subscriptions after commit, so a view refetches only the
artifact whose head changed. Storage follows the Retention table.

Capture review offers diff tiles as "Diff snapshot" (tracked changes only) or
"Diff snapshot with untracked files" (the explicit opt-in), and file tiles as
"File snapshot" of the saved bytes. Capture runs off main. The draft's
content digest joins the review digest, and confirmation re-captures, so an
edit after review refuses. The confirmed command admits a host-sourced
artifact item with a reserved first revision ID. Before the command is sent,
the exact confirmed capture is staged on disk beside the area's local state
(`uploads/<revision>.json`); after acceptance the controller uploads it. If
that upload fails the item honestly has no revision until the controller
retries the same bytes under the same revision ID, on reconnect and when the
area is opened after a relaunch. It asks the service first, so a revision that
already landed is never sent again; a staged capture whose item was never
admitted is dropped. A branch diff of a branch other than the checkout's HEAD is refused.

In the shared scene, selecting an artifact replaces the text reader with
`SharedAreaArtifactView`: one text view rendered by the diff tile's token
renderer, a revision choice (follow latest, or pin one), the file list with
coverage, and Approve/Request changes on the shown revision. A pinned revision
says which revision is latest; reviews on other revisions are reported as not
applying, and drift shows "not applicable".

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

Share links (`.plans/105-collaboration/workers/share-links.md`) let a newcomer
join without an operator: `POST /collaboration/v1/links/join` takes the link's
token as the enrollment. Joins are limited to 10 per link and 30 per client
address in a rolling hour. Over either limit, the relay answers 429 `rateLimited`
and creates nothing. Override the limits with
`RELAY_COLLABORATION_LINK_JOINS_PER_LINK`,
`RELAY_COLLABORATION_LINK_JOINS_PER_ADDRESS` and
`RELAY_COLLABORATION_LINK_JOIN_WINDOW_SECONDS`; a malformed value fails startup.
The address is the socket peer, unless `RELAY_CLIENT_ADDRESS_HEADER` names a
header a trusted proxy sets. `fly.toml` sets it to `fly-client-ip`, because
behind Fly's proxy every socket peer is the proxy. The relay keeps only a hash of
each address, and only for the window.

Sharing works with no setup. On a Mac with no collaboration account, the first
Share (or Connect in File > Collaboration with no enrollment code) signs the
person up with only a display name. `POST /collaboration/v1/self-enroll`
creates that person and their first device, and grants no area. It allows 10
self-enrollments per client address per hour
(`RELAY_COLLABORATION_SELF_ENROLLS_PER_ADDRESS`; 0 turns self-enrollment off).
Over the limit, the relay answers 429 and creates nothing. A Mac that already
has an account reuses it.

The relay it signs up on depends on the build:
- A Prod build (`dev.arrayapp.macos`) uses `https://relay.arrayapp.dev`.
- Every other build uses staging, `https://arrayapp-relay-staging.fly.dev`, so a
  dev build never signs anyone up on production.
- `CONTINUUM_COLLABORATION_ENDPOINT` overrides both, and may be plain http on
  loopback. The multiplayer preview and local checks use it.

`CollaborationServiceEndpoint.channelDefault` is the one place that decides.

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

The retention fixture (`CollaborationRetentionChecks`, in the default service
run) commits more than 500 operations, then compacts them under an injected
clock. It checks that an ancient cursor gets `snapshotRequired` and that the
resnapshotting client ends byte-equal to a full-replay client. It also checks
that deleted IDs, receipts, removals, revocations and stale epochs survive, and
that a SQLite trigger fault inside compaction rolls back atomically. Then it
restores twice into replacement directories with a separately carried key: once
from an online backup, and once from a cold copy after SIGKILLing the restored
relay mid-burst. Each restore is served by a new relay process and checked
through real HTTP. `CollaborationRetentionRecoveryChecks` in the portable
checks covers three things. A future-schema response leaves the cache bytes
unchanged. A schema-2 cache behind a compacted horizon recovers over real HTTP
with its draft. Unadmitted host requests expire at the real host dispatcher
instead of executing. Receipts and teeth logs are in
[col-compaction](../../.plans/105-collaboration/validation/col-compaction/README.md).

`bash scripts/check-relay-linux.sh` copies only relay/collaboration sources into a
throwaway container context. Its checks stage builds and runs the collaboration
HTTP fixture alongside existing companion suites. This verifies service code;
it does not verify the native canvas, host runner, TLS proxy or deployed service.
