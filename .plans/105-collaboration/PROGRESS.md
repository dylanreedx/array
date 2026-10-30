# Multiplayer implementation progress

29 October 2026. Dylan's “goal: … let's start the multiplayer” supersedes the
original planning-only scope. Work stays in this checkout; no Git mutation or
service deployment is implied. The original board receipt is historical.

## Current slice

COL-01 decisions recorded in [DECISIONS.md](DECISIONS.md). The portable COL-03
Core foundation is implemented in
[SharedAreaDocument.swift](../../Sources/ContinuumRevivedCore/Collaboration/SharedAreaDocument.swift)
and [SharedAreaCapture.swift](../../Sources/ContinuumRevivedCore/Collaboration/SharedAreaCapture.swift).

- Schema-versioned typed area/person/host/object/placement/binding IDs.
- Reviewed publications and model WORLD frames convert to area-local geometry.
  Source Tile records and their ownership/runtime metadata are not copied.
- Atomic command batches with expected revisions and SHA-256 intent receipts.
- Immutable context revisions, pinned discussion references, permanent deleted
  identities, validated snapshot restore and deterministic accepted replay.
- Separate offline checks executable and `scripts/run-matrix.sh --collaboration`,
  also registered in the full matrix and its inventory.

The adapter consumes explicitly supplied model tiles; complete selection,
publication review UI and unhydrated-content enumeration remain COL-09.
The reducer expects commands already authorized by the service; it is not an
identity or membership implementation. Snapshot integrity validation is not
cryptographic authentication.

## Remaining before a usable session

COL-02 remains open: actual service routes, host transports and mounted scene
fixtures do not exist for collaboration yet. COL-04/05 must implement authenticated
membership and durable service enforcement; COL-08/10 supply bindings and actual
native scene ownership. No native multiplayer UI, real invites, remote execution,
networked cursors or token hover cards are implemented by this slice.

## Verification

The first targeted matrix run was RED on a fresh operation resurrecting a deleted
object under a new placement. Adding the object-tombstone admission check fixed
that behavior. Additional cases cover rollback, retry mismatch, stale context,
model geometry, source sentinels, restore/replay and schema refusal.

Final rebuilt `scripts/run-matrix.sh --collaboration` PASSED: 2 reported legs
(inventory and the behavioral executable). COL-01 and COL-03 are Done on the
correct board; the remaining 24 cards stay in To Do. The other board received
zero writes. Shell syntax, scoped diff whitespace, new Swift whitespace and
updated local documentation links also passed. Bench inventory was read at
pickup and completion; no benches were created or removed.

One intermediate fixture run exited 133 because it supplied a world x-coordinate
to `FracIndex`, which requires a value between 0 and 1. This was a fixture error,
corrected to valid normalized ranks before the final passing rebuilt gate.
The earlier RED deletion witness exited normally with status 1.
No app launch, real CLI login, default tmux operation, production relay contact,
full matrix or deployment has been performed for this slice.

## Service foundation continuation — 29 October 2026

Previous goal turn: **progress**, evidenced by the Core implementation and
reported RED/GREEN gate. This continuation adds actual service boundaries:

- Extracted the document into
  [portable protocol](../../Sources/ContinuumRevivedCollaborationProtocol/SharedAreaDocument.swift),
  shared by Core and Linux. The Core alias preserves existing callers.
- Added [membership/storage actor](../../Sources/ContinuumRevivedCollaborationService/CollaborationStore.swift)
  and [real NIO routes](../../Sources/ContinuumRevivedRelayNIO/CollaborationRoutes.swift).
  Person and device credentials, registered execution devices, targeted expiring
  invitations, membership epochs, viewer/editor/owner checks and device/member
  revocation are separate from companion v2.
- Attributed author and publication-host checks precede mutations. Transactions
  persist AES-GCM-encrypted snapshots and operations together; stored credentials
  and admission secrets are hashes. This remains a trusted service, not E2EE.
- Added opt-in process configuration and an operator enrollment command; no
  collaboration database/route is enabled by default and nothing was deployed.
- Added a real localhost A/B/C
  [HTTP harness](../../Sources/ContinuumRevivedCollaborationServiceChecks/main.swift),
  including independently admitted identities, second-device ownership, invite
  races/expiry, forged authorship/source refusal, raw denied-response bytes,
  revocation, injected SQLite transaction abort, receipt replay, isolated operator
  subprocess, reconstructed HTTP service and companion credential separation.
- [Service internals](../../docs/internals/collaboration.md) documents APIs,
  history-on-join, epochs, storage, configuration and remaining identity recovery.

COL-02, COL-04 and COL-05 remain **Doing**, not complete. The harness has real
service routes but still lacks mounted native scenes and scripted host effects.
Membership has no active-stream eviction until streams exist; host admission and
native credential storage remain open. Durable operations need paging/compaction,
complete migration/restore schedules and the full integration harness. The native
sharing workflow, agent dispatch, cursors and hover usage remain future work.

Verification: rebuilt `scripts/run-matrix.sh --collaboration` PASSED **5 reported
legs**: inventory, portable reducer, collaboration HTTP, existing relay Core and
existing relay HTTP integration. The initial service fixture was RED when B could
label a post as A; binding authored content to the authenticated person made it
GREEN. The SQLite abort fixture proves no partial snapshot/receipt commit.
Evidence is retained in [validation](validation/service-foundation-20261029/matrix-summary.txt).

Intermediate build issues from the module extraction (missing direct import and
public geometry validator) and a missing `await` in the test's GRDB injection were
corrected before the passing gate. Direct execution of the pre-existing Linux
check script returned permission denied; it is invoked with `bash` instead.
`bash scripts/check-relay-linux.sh` PASSED: Linux/amd64 Swift 6.1 release
build, all three container suites, then all three suites rerun with networking
disabled except localhost. A final container pass mounted the final portable
protocol file (whose geometry validator became public for Core), rebuilt both
`continuum-relay` and the collaboration checks, and PASSED again. The log confirms
both builds completed and contains no compiler errors; this final command did
not use shell `errexit`, so those build lines were inspected explicitly.
See [Linux summary](validation/service-foundation-20261029/linux-summary.txt).

The [current board receipt](CURRENT-BOARD.json) records revision 38: two Done,
three Doing and twenty-one To Do. No writes were sent to the other board.
Bench inventory was inspected at pickup and end; no benches were created or
removed. Scoped diff checks, shell syntax, new-source whitespace and documentation
links passed.

No Git mutation, production relay request, app launch, native UI verification,
provider call or full release matrix was performed. Existing unrelated dirty
files were preserved. The original board receipt and initial eight research
documents remain historical evidence, not current implementation status.

## Live synchronization continuation — 29 October 2026

Previous goal turn: **progress**, proved by the service implementation and Mac/
Linux HTTP checks. This turn continues COL-06 against the implemented service
storage. Its broader harness/host dependencies remain open rather than being
silently declared complete.

Implemented [update protocol](../../Sources/ContinuumRevivedCollaborationProtocol/CollaborationUpdates.swift),
[paged/held service reads and presence](../../Sources/ContinuumRevivedCollaborationService/CollaborationUpdates.swift),
[client API](../../Sources/ContinuumRevivedCollaborationClient/CollaborationAPI.swift),
[atomic replica](../../Sources/ContinuumRevivedCollaborationClient/CollaborationReplica.swift)
and [session lifecycle](../../Sources/ContinuumRevivedCollaborationClient/CollaborationSession.swift).

The transport uses immediate-wakeup bounded HTTP long polling. It reauthenticates
on every wake, pages all retained operations to a fixed high-water mark, and
requires actual sequential application before advancing the client cursor. There
is no in-memory durable event queue to drop or overflow. Presence is a separate
coalesced latest-value lane with server-issued sessions, sequence checks and TTL;
it never writes durable document history. This is backend/client transport, not
yet a rendered cursor or following UI. Host liveness remains separate work.

The real localhost fixture now exercises 600 messages, page count/byte limits,
concurrent catch-up commits, live wakeup, excluded access, session replacement,
late presence packets, expiry, active member/device removal, cancellation and
subscription limits. It tests automatic client reconnect against a reconstructed
service on the same port, plus v1 head-migration failure rollback and exact
backfill from encrypted snapshots. Native canvas mounting/host effects are still
pending on COL-02/07/08/10 and later cards.

Actual failures corrected before the passing rebuilt Mac gate:

1. The first client stopped after its first catch-up page; the >500-operation
   fixture was RED. Catch-up now drains every page to its fixed head.
2. Canceling a Foundation HTTP request did not reliably release the server's
   held read. An authenticated explicit cancellation protocol, including early
   cancellation receipts, made the active-request count return to zero promptly.
3. A revoked client cleared its replica but stream termination overwrote its
   terminal status. Access loss now retains `unavailable`; explicit view closure
   uses `stopped`. The initial matrix reported this as a failure; the rerun passed.
4. An initial compiler error selected GRDB's asynchronous overload while preparing
   a held read. Preparation now uses the synchronous actor-owned identity helper,
   preserving a no-suspension read-to-registration handoff.

Final rebuilt `scripts/run-matrix.sh --collaboration` PASSED all **5 reported
legs**, including the expanded real HTTP/client suite and both existing companion
suites. [Retained evidence](validation/live-sync-20261029/matrix-summary.txt)
includes the RED cases and detailed passing update checks. Linux verification is
being run against this final source snapshot and is recorded below when complete.

COL-06 stays Doing: mounted clients, host-liveness publication, native presence
interaction and the complete production workflow are not verified by this slice.
No app launch, provider call, production service contact/deployment, Git mutation
or full release matrix was performed.

Linux's first build found that its Swift Crypto version's `SymmetricKey` is not
Sendable in a migration closure. The migration now captures normalized `Data`
and constructs the key inside that closure. A rebuilt Mac matrix passed again
after that correction. Linux verification is continuing against the correction;
its final result is appended once the specific running process completes.

Current board receipt: revision 40, two Done / four Doing / twenty To Do. No writes
to the other board. New-source whitespace, shell syntax and updated local links
passed; bench inventory was inspected without creating or removing a bench.

The corrected captured-source Linux check PASSED: release build, collaboration
HTTP/update/client suite, and both companion suites, followed by all three suites
rerun under `--network none`. See [Linux evidence](validation/live-sync-20261029/linux-summary.txt).
This receipt covers the live-sync milestone snapshot, before the review/cache/
vault changes in the next batch; it does not certify those subsequent edits.

Dylan requested at most three subagents and fewer matrix runs. The next batch
uses three agents for local cache/bindings, a channel-scoped credential vault and
transport review, with focused witnesses integrated before one broader gate.
The review identified redirect policy, domain-incompatibility retry handling and
database-key identity gaps; their fixes and verification are tracked in the next
batch rather than rerunning the preceding matrix per finding.

## Three-agent local foundation and transport review — 29 October 2026

Dylan's testing/delegation steering is now the working policy: at most three
subagents, focused checks while changes are in progress, then one broader gate
for the combined milestone. Three agents implemented local cache/bindings,
credential storage, and reviewed/hardened transport. No agent ran the matrix,
accessed real Keychain or launched Array.

New foundations:

- [Local cache/store](../../Sources/ContinuumRevivedCore/Collaboration/SharedAreaLocalStore.swift):
  channel + endpoint + person + area scope; atomic document/cursor generations;
  local source ID references, private view and drafts; CAS against racing private
  edits; future/corrupt/recovery-state preservation. No project/runner import.
- [Credential store](../../Sources/ContinuumRevivedCore/Collaboration/CollaborationCredentialStore.swift):
  shared canonical endpoint; explicit memory/Keychain vault injection; channel,
  endpoint, person and device isolation; namespace/payload validation. The real
  adapter disables authentication interaction for all Keychain operations.
  Fixtures use memory only; native account/Keychain UI is not yet integrated.
- [Client boundary fixtures](../../Sources/ContinuumRevivedCollaborationServiceChecks/CollaborationClientBoundaryChecks.swift)
  and [database-key fixtures](../../Sources/ContinuumRevivedCollaborationServiceChecks/CollaborationDatabaseKeyChecks.swift):
  redirect targets receive zero requests; incompatible schemas/accepted commands
  terminate instead of retrying; every database open validates its key before
  migration; legacy key adoption authenticates all ciphertext transactionally.

Focused checks found a genuine missing channel stamp in the initial cache
scope. The implementation now rejects both cross-channel saves and a valid dev
cache copied into a prod path without changing the file. A separate key fixture
failure came from GRDB's stale cached schema after another connection migrated;
it now queries committed `sqlite_master`, retaining the original rollback checks.
The credential witness passed with memory storage and no Security calls.

One combined rebuilt `scripts/run-matrix.sh --collaboration` PASSED all five legs
for this batch. No agent-specific matrix repetitions were run. Subsequent targeted
Linux verification caught FoundationNetworking ignoring the per-task redirect
delegate; the client now owns its URLSession and enforces redirect policy at the
session delegate. The focused Mac boundary/key checks passed after that isolated
correction; no broad Mac rerun was needed. A focused Linux rebuild/check for the
same correction is in progress and is recorded once its handle completes.

COL-08 is now Doing, alongside COL-02/04/05/06. Local persistence is implemented
but production scene/host ownership integration, credential UI, online scope
validation, executable outbox/recovery and the complete native workflow remain
open. No feature is deployed and the full goal remains active.

The corrected session-level redirect policy PASSED focused Mac and Linux boundary/
key checks. Linux rebuilt `continuum-relay` and the service checks in a disposable
`--network none` container; its exact compiler output and passing results were
inspected. The container was stopped/removed after verification. This focused
correction did not trigger another full matrix or companion-suite run. The one
combined Mac gate for the preceding cache/vault/key/transport batch passed all
five legs; the final redirect correction was verified by its focused witnesses.
See [focused Linux evidence](validation/local-foundation-20261029/linux-boundaries-key-verified.txt).

Testing limits: real Keychain operations remain deliberately unexercised. Native
canvas mounting, source runner counts under mounted shared views, captures from
unhydrated zones, human discussion UI/dispatch, token accounting/hover and release
operating limits remain open. No production state was used and no Git mutation,
app launch, provider request or deployment was performed.

Board readback after this batch: revision 44, two Done / five Doing / nineteen
To Do. Only the selected collaboration board received writes. Current card
notes link the exact verification scope and retain unfinished native work.

## Reviewed publication and persisted native controller — 29 October 2026

Previous goal turn: **progress**, evidenced by local-store/vault implementation
and Mac/Linux boundary checks. This continuation used exactly three subagents
for capabilities, the native-facing controller and reviewed publication
preparation; root integrated them and added actual HTTP/controller coverage.
No agent ran the matrix or accessed live state.

- [Explicit capabilities](../../Sources/ContinuumRevivedCollaborationProtocol/CollaborationCapabilities.swift)
  distinguish collaboration operations from unavailable host actions. The service
  checks every edit inside the transaction. Editors can arrange another person's
  observation but cannot unpublish their source; the area owner has the same
  source-ownership restriction. Observation/source kind mismatches refuse.
  Actual HTTP fixtures check forged principals/grants, mixed-batch rollback,
  source removal retries, membership removal and allowed snapshot/replay bytes.
- [Review preparation](../../Sources/ContinuumRevivedCore/Collaboration/SharedAreaPublication.swift)
  provides workspace/zone/explicit-tile/enclosed-rectangle contracts, declared
  coverage, explicit unsupported/omitted rows, portable reviewed content and
  private source bindings. Fresh confirmation binds membership, full model tiles,
  content revision/text and geometry. Only admitted members determine the origin.
  Missing note generations and missing managed-agent bindings cannot publish.
  Artifacts stay unsupported until immutable payload storage exists, and agent
  observations explicitly exclude transcript history.
- [Native controller](../../Sources/ContinuumRevivedCore/Collaboration/SharedAreaController.swift)
  connects the real API/session to scoped credentials and local persistence. It
  verifies online person/device identity, treats caches and reconnects as
  read-only, preserves private camera/drafts, handles receipt/stream ordering and
  suppresses cached shared content after known access loss. Presence creates no
  durable generation. Close owns only its subscription, not a source runtime.
- [Actual HTTP integration](../../Sources/ContinuumRevivedCollaborationChecks/SharedAreaControllerHTTPChecks.swift)
  confirms a reviewed manifest through NIO and encrypted service storage, then
  drives two independently authenticated production controller adapters. It
  asserts converged documents/geometry, private camera and draft retention,
  excluded C, active removal and cached reopen suppression, while comparing
  disposable source project files byte for byte. This is not a native mount or
  real runner-count witness.

Review found and corrected two controller issues before the combined gate:
presence-only snapshots rewrote/backed up the whole cache, and a delayed older
stream page could be mistaken for a persistence failure after a newer mutation
acknowledgement. Scripted witnesses assert unchanged local generations and exact
monotonic document behavior, including a cache advanced by another controller.

The first focused Core/controller/HTTP run and capability checks passed. The
negative capability witness deliberately removed only the source-owner guard;
actual HTTP then admitted the forbidden removal and the fixture failed. Restoring
that guard made the same focused witness pass. This was an intentional behavioral
counterexample, not a failing build or a claim about a committed Git revision.

One combined `scripts/run-matrix.sh --collaboration` reported all **five legs**.
Four passed: inventory, expanded service HTTP/client/capability checks and both
companion suites. The Core leg caught a real shutdown race: access-loss cleanup
could still be running when `close()` returned. The controller now tracks and
awaits already-retired connections; a held-stop fixture checks completion, rather
than relying on scheduling or weakening the assertion. Review also separated
mutation HTTP 403 (forbidden object action, membership retained) from actual
credential/membership loss. Both scripted and real HTTP fixtures cover that
distinction. The affected rebuilt Core leg PASSED, including the held-stop and real HTTP 403
witnesses. The passing service/companion legs were not repeated; the original
combined matrix report remains a recorded failure rather than being relabeled
as an all-green run.

Focused Linux capability verification PASSED in one disposable linux/amd64
container with networking disabled: rebuilt both `continuum-relay` and the
service checks, then ran `--capabilities-only`. This covers the final portable
capability/service changes; it does not rerun the preceding Linux backlog,
companion, key or native-controller suites. The container removed itself on exit.
See [retained verification](validation/publication-controller-20261029/).

COL-07 and COL-09 are now Doing. Full host grants/admission, production model
enumeration and content rereads, review/selection UI, native scene mounting,
account UI and executable recovery remain open. No card is newly Done. All other
requirements, including deliberate agent dispatch, live observation/artifacts and
hover-only usage, remain part of the active full goal. No Git mutation, app
launch, real Keychain/provider call, default tmux use, production service contact,
deployment or full release matrix was performed.

Final rebuilt affected-leg result: `swift build --product ContinuumRevivedCollaborationChecks`
and `.build/debug/ContinuumRevivedCollaborationChecks` both exited 0. The
[corrected evidence](validation/publication-controller-20261029/controller-corrected.txt)
includes the final review, shutdown, forbidden-action and actual HTTP checks.

Final board readback: revision **49**, two Done / seven Doing / seventeen
To Do. COL-07/08/09 notes and Doing columns were read back after writing.
Only the selected board received writes. Matrix inventory, shell syntax, scoped
diff whitespace, 26 collaboration Swift files and updated local documentation
links passed. Bench inventory was read at pickup/end; no bench was created,
removed or cleaned by this work. The disposable Linux container is absent after
its successful exit.

## Native account, source inventory and shared scene — 30 October 2026

Previous goal turn: **progress**, proved by reviewed publication, capabilities,
controller implementation and the retained Mac/Linux checks. This continuation
again used exactly three subagents, for source inventory, scoped account
bootstrap and the native scene. Root integrated the shipping menu/window paths,
added native hub and actual HTTP account journeys, and owns all verification.
Agents ran no builds or matrix.

Implemented entry points and ownership:

- File > Collaboration now deliberately opens the account hub. It has no
  embedded production endpoint and performs no startup Keychain/network work.
  Native Connect uses an Array enrollment code or a saved device account;
  create/join/open and targeted invitations use current service authority.
  Invitation display and late replies are scoped to account/area. Known-successful
  creation/acceptance failures retain the exact area ID for explicit Open recovery.
- Account metadata is channel-scoped, atomic and CAS-protected, separate from
  credentials. Credential retention precedes metadata; explicit retained-account
  repair never consumes an enrollment code again. An unindexed retained account
  descriptor is still only in memory until repaired, so restart rediscovery and
  existing-account operator recovery are not complete.
- A shared window mounts through the dedicated shipping overload of
  `mountWorkspaceSceneAtBoot`. It receives portable data and its own controller,
  without project spawners, arming or persistence callbacks. Two mounted identities
  keep independent camera/focus and can post human discussion or immutable
  agreement revisions. Observations truthfully state that history/control is not
  available yet. No token counters or permanent presence overlays were invented.
- Rendering, hit-testing and keyboard/object navigation use a bounded visible
  object set. Full content is paged in one selected-entry reader. Draft/camera
  writes are private and debounced; close flushes can refuse after save failure.
  Review added focus-save atomicity, mount-generation fencing, bounded hit tests
  and a preserved unsaved draft through access loss.
- Source inventory now reads the owning live model/persistence merge and pure
  membership resolver, including below-tier persisted tiles. It hashes fresh live
  or stored notes, resolves agents by exact project/tile ownership, and refuses
  named missing-controller/ambient coverage without acquiring or writing a source.
  User-facing capture/confirmation routing is still open; this is the real model
  bridge and mounted witness, not a completed capture gesture.

Initial rebuilt Core/account/actual HTTP checks passed. The account harness now
uses actual API adapters to enroll A/B/C, create, invite, join, remember and register
a host before the existing reviewed-capture and controller journey. Additional
fixtures preserve exact area IDs after local metadata or post-accept state errors
and prove recovery creates/accepts only once.

The first compiled `--collaboration-native-check` passed: mounted source inventory,
two shared scenes with actual frames, human content, access loss/remount, private
source byte preservation, inert hub construction, native control callbacks and
late invitation/close fencing. The later review witnesses and appearance census
are being verified in the combined milestone below. The supplied actual recipient
supervisor census remains empty with zero executor constructions; this does not
prove a real source provider process or full host dispatch.

Two shared-checkout app builds were invalidated by concurrent changes to unrelated
board source/check files. A temporary focus-order counterexample build was also
invalidated before its check ran, and its canonical source was restored. Those
are build failures, not behavioral RED receipts. Root then froze a disposable QA
source context and copy-on-write build cache under `qa-runs`, without Git operations
or changes to another agent's files. Relocated Clang module-cache paths initially
refused; only that QA cache was removed. Verification now runs against the frozen
source manifest; final receipt/cleanup is appended after the specific handles finish.

Final frozen-source `scripts/run-matrix.sh --collaboration` PASSED all **8
reported legs**, including the new native journey, full appearance census and
shipping menu contract, plus the previous Core/service/companion suites. The
appearance gate swept **349 TokenThemed views** and **370 layer colors**. The
focus-order counterexample compiled successfully in that frozen context and was
behaviorally RED on the injected focus-save failure, then restored before GREEN.
See [native milestone evidence](validation/native-20261030/README.md).

All four retained hub/scene light/dark renders were visually inspected. This
caught stale “Connecting…” copy after a deliberately discarded invitation reply.
That isolated hub status fix and its accessibility assertion were rebuilt and the
native leg PASSED again; service, appearance/menu and companion suites were not
repeated for the text/status correction. Final source manifests matched **every
recorded collaboration and integration file** in the current checkout, with zero
differences. Frozen verification is not a claim that the full release matrix ran.

COL-10 and COL-12 are now Doing. The selected board is revision **61**: two Done,
nine Doing, fifteen To Do; no additional card is declared complete. Notes on
COL-04/08/09/10/12 preserve acceptance gaps and exact verification scope. No writes
were sent to the other board. Native source capture/review gestures, shared
geometry drag/undo, live observations/artifacts, host dispatch/freshness, token
accounting and hover-only presence/usage remain part of the active full goal.

Real Keychain, real providers, staging/TLS/rotation/restore, Linux packaging for
this native batch, iOS and the full release matrix were not exercised. No UI
baseline, live project, default tmux server, production relay or app bundle was
modified by QA. Only isolated AppKit self-check processes ran, not a normal app
or preview launch. No Git mutation, deployment or outside messaging occurred.

Owned QA source snapshot and cloned build cache were removed successfully;
retained source hashes, behavioral logs and four inspected renders remain under
`validation/native-20261030/`. Final matrix inventory, shell syntax, scoped diff
whitespace, 36 collaboration Swift files and updated documentation links passed.
Bench inventory was inspected at pickup/end; this work created or removed no
Git worktree and preserved unrelated active benches.

Next mixed-window audit: global File > New and registered creation commands
while a shared window is active. The native witness covers the shared scene
controls, not those global routes; inspected palette helpers still resolve the
personal canvas armed scope. Verify and constrain that route before COL-10 can
close. The existing tile-click monitor already rejects events from another window.


## 30 October 2026 — Capture/review and mixed-window command boundary

Three subagents implemented the review UI, pre-effect private binding retention
and mixed-window behavioral witnesses; root integrated the shipping source menus,
destination selection, window ownership and verification. No Git mutation.

File > Share workspace, Share zone and Capture area to share now lead through the
account hub to an explicit per-item review. The area gesture is a temporary input
surface: it neither creates a local zone nor persists source geometry. It uses
the rendered camera, refuses camera changes mid-drag, normalizes negative/reversed
WORLD rectangles and includes fully enclosed model frames. Live model inventory
continues to exclude hover presentation transforms and to name incomplete coverage.

The review opts in no note or agent by default, pages choices and shows one full
content reader plus a bounded layout preview. Confirmation rereads actual owners;
changed content, membership or layout requires another review. Publication retains
opaque private source bindings atomically before remote effects. Save failure sends
nothing; an accepted receipt advances the cached document/cursor beside bindings.
The controller checks receipt revision against the deterministic applied/duplicate
outcome. This remains a private binding cache, not an executable command outbox.

Each review owns an independent controller/connection. Closing a destination scene
cannot strand it. Unknown delivery keeps the exact confirmed operation across
reconnection and every subsequent rejection, including stale-epoch conflicts that
cannot disprove an earlier commit. New source sharing brings a pending-delivery
review forward instead of allocating another capture. Unknown operations remain
in memory: durable restart recovery and a close-independent outbox are still open.
Hub close cancels pending setup; post-await account/source checks fence late UI.

Shared/hub/review windows and their sheets now have explicit UI ownership. Personal
File > New, registered commands, stale palette/toolbar callbacks, destructive key
events and hold-leader activation cannot act on the armed personal canvas from
those windows. The explicit workspace API retains its independent project authority.
The mixed-window witness exercises the real production mount, actual AppKit window
hierarchy with an injected platform foreground lookup, forced menu callbacks and authorized API open, then returns to personal
Note creation. The root capture witness exercises the production-mounted pointer
gesture through the actual hub and review callbacks and checks source file/model
preservation, exact local source binding and zero added executor constructions.

Verification is in progress. An initial frozen app build caught an async alert
overload, an ambiguous CGFloat maximum and a moved pagination variable; these
compile errors were corrected. Other work is compiling in the shared checkout,
so root uses a disposable QA source/cache context with scoped source manifests.
The planned verification is a behavioral command-boundary counterexample, then
one combined collaboration gate, followed only by affected-leg corrections if
needed. No normal app/preview, provider, real Keychain or production relay is used.

The binding-order counterexample compiled and was behaviorally RED: removing the
private pre-send retention broke the explicit local-save refusal witness. The
correct source was restored. An earlier command counterexample compiled, but its
execution stopped on the inactive host's inability to become a real AppKit key
window; that is an environment refusal, not a behavioral RED. Native routing now
injects the platform foreground lookup in checks, with AppKit as the production
default; no activation or new KNOWN-RED was introduced.

The single combined targeted matrix ran all eight legs: seven passed; the native
leg waited beyond its expected bounds. Root confirmed the isolated QA PID/cwd,
sampled its idle event loop, and stopped only that check with SIGTERM (recorded
exit 143). The matrix continued through appearance, menu and companion coverage
and reported the native failure. Root added unbuffered stage output and an explicit
native behavioral deadline and is rerunning only the affected native leg. This is
not an 8/8 claim. Child-window (choice-menu) scope inheritance and bounded review
pagination/legacy scrolling are included in that affected-leg correction.

Final correction PASSED. Stage output located the stalled sheet fixture call;
using its explicit nonwaiting completion-handler form let the complete native
journey finish. That rebuilt native leg proves actual production-mounted area
drag → destination hub → independently owned review → confirmed publication, exact
relative agent/note WORLD layout and saved local source binding. Source canvas/note
bytes, project/workspace ownership and supplied executor census stay unchanged.
It also proves foreground-gated menus/keys/palette/toolbar/hold-leader across shared,
hub, child and sheet windows; authorized workspace API opening remains independent
and personal Note creation succeeds afterward. No app activation was used.

The 121-source review witness passes four complete pages, at most 40 picker
choices, one retained full-content reader, preserved choice/text across paging and
legacy scroller access to the last line. Layout assigns changed frames only and
performs no text measurement. This applies the new-surface performance checklist;
maximum workspace inventory and wall-clock performance remain unmeasured.

A partial source refresh encountered a concurrent board enum/main generation
mismatch; refreshing the complete source tree together corrected QA compilation.
The final coherent app build passed. Because appearance/menu sources also changed,
only those two additional affected legs were rerun: both PASSED, with **351
TokenThemed views / 372 layer colors**. The previously passing service, Core/HTTP
and companion suites were not repeated. The original combined gate remains a
recorded 7/8 result, followed by passing corrected native/appearance/menu receipts;
there is no claim of a second complete green matrix.

All six retained light/dark hub, scene and capture renders were inspected. All
**1,033 final Swift source files** matched the current checkout. The gate script
and inventory changed independently after the frozen run; their current syntax
and **757-record inventory** passed, retaining the native invocation and all seven
Core collaboration check sections. Full receipts, failure history, source hashes
and inspected renders: [capture milestone evidence](validation/capture-20261030/README.md).

Board notes on COL-02/08/09/10 were committed and read back on the selected board
at revision **65**, all still Doing: two Done, nine Doing, fifteen To Do. No writes
were made to the other board. Source capture is now wired; shared geometry/undo,
live observations/artifacts, host dispatch/context freshness, durable pending
delivery/restart recovery, hover-only token presence and complete native→HTTP
multi-host/provider acceptance remain in the full active goal. Real Keychain,
providers, default tmux, production state, normal/preview app launch, Git mutation,
staging/TLS/rotation/restore, Linux/iOS for this batch and deployment were not used.

Owned disposable QA source/build context was removed successfully after final
receipts and six renders were retained. Final comparison still found zero changes
among all 1,033 Swift sources. Scoped whitespace/doc links passed. Bench inventory
was inspected at pickup/end; no worktree was created, mutated or removed by this
work. Other active benches and unrelated source changes were preserved.


## 30 October 2026 — Finish pass on release-0735

Coordinator request: finish shared drag/undo, person-to-person agent handoff,
durable crash/relaunch recovery and hover-only teammate usage, then run two
background Array processes against a local relay. Neither live app, the Desktop
preview, production relay, focus nor default tmux may be touched. No deployment
or push. Scoped commits under Dylan; no matrix-inventory commit.

Created `.worktrees/collaboration-finish`, branch `array/collaboration-finish`,
from exact release tip `d49c0cbe`. Ported only collaboration changes; left the
canonical checkout and its unrelated dirty work intact. Resolved the sole token
owner conflict by retaining both managed-badge and collaboration rules. Preserved
the release's stronger focus/tmux matrix guards. Reviewed foundation is committed
as `3bef5505` (`feat(collaboration): add reviewed shared workspace foundation`),
without an inventory change or AI trailer. That commit's port still awaits the
finish-pass integration gate; previous receipts remain historical evidence.

Three Codex helpers own geometry/causal Undo, durable delivery/paired harness and
service-to-supervisor handoff. Root owns usage accounting, hover presence, UI
integration and combined verification. All changes are in this bench.

Current implementation (not yet verified): causal placement stamps, compensating
Undo/Redo and a pre-effect persistent geometry ledger; schema3 data outbox with
exact-command/receipt cold recovery; source-owned targeted handoff/control CAS,
immutable context prompts, fresh pre-effect host admission and a durable no-blind-
resend host journal; independently retained source host sessions; normalized
provider usage (Codex cumulative sessions, Claude turns, Pi stable message IDs
including cached input), a durable deduplicated UTC-day ledger and authenticated
service projection. Teammate cursors draw counts only in a transient hover/focus
card; unknown/partial measurement is explicit. Sharing a reference alone preserves
normal local owner input; accepting a teammate handoff gates the former controller.

The paired harness launches separate real Array check processes with explicit
app support, project roots, preference suites and physical tmux namespaces. It
uses local live HTTP and scripted provider transports; APNs and proxy environment
are stripped. Planned witnessed flows include conflicting native geometry/Undo,
SIGTERM/relaunch before send and after commit, restored inverse/camera, >500
ordered events through a held subscriber, local relay restart, source/recipient
handoff and hover-only usage. Static parse checks alone do not establish this.

First build refused the ignored Ghostty artifact absent from a fresh worktree;
its existing artifact was copied into this bench only. The first Core typecheck
then reached one root error using an old StoreFileWrite helper; corrected to this
release's StoreFileWriter.perform. Integration and behavioral testing continue.

Focused rebuilt Core/controller and real service suites passed. Five compile-valid
teeth mutations were each RED on the intended behavior: causal Undo/ABA, failed
outbox-before-effect, uncertain host attempt replay, duplicate usage accounting,
and forged publishing-device usage. Exact source bytes were restored and fresh
builds/checks returned GREEN; receipts are under `validation/finish-20261030/teeth`.
The native lifecycle review also corrected stopped accounting observers, host
sequence reuse, temporary coverage becoming permanently partial, repeated Codex
sessions represented by multiple local records, and deferred input authority.

The first combined finish gate reported **10 legs, 8 passed / 2 failed**. Native
checks found a stationary hover surviving camera navigation because a newly
clamped card was mistaken for the previous hover target. The pair witness refused
its first peer before ready: Foundation's `/private/tmp` canonicalization differed
from Python/pwd-P/tmux. Both fixes are staged in source, not yet verified by a new
native run. The gate still reported the other eight legs, including appearance,
menu contracts, provider telemetry and both existing relay suites. No baseline
was updated. Light/dark cursor renders were inspected; handoff renders remain
pending because the earlier native failure stopped that stage.
