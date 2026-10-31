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


## Claude handoff audit — 30 October 2026

Dylan confirmed the implementation handoff to Claude. Live board **Array feats**
(`F54D4170-AB61-4595-A4D4-A400B76364A5`) was audited and updated through revision
**86**: 2 Done, 15 Doing, 9 To Do. Updated COL-02/06/09/11/13/17/18/19/21;
no other board was changed. The finish bench is `array/collaboration-finish` at
WIP checkpoint `88c183c0`, following foundation `3bef5505` on release base
`d49c0cbe`. This audit changes handoff documentation and board state only.

Native geometry, usage/provider adapters, hover lifecycle, handoff controls,
private drafts, deferred input admission and final delayed-stop generation checks
passed in the restored native run. The always-visible hover mutation was RED;
restored source/build/native checks GREEN. Its report contains 52 actual frontmost
observations, zero focus theft, and a verified isolated physical tmux socket.
Core/service negative tests and restoration receipts remain in
`validation/finish-20261030/teeth/`. This supersedes the earlier pending-native
status above; it does not make the complete integration gate green.

The latest actual pair report is **FAILED**, after both peers started and the
source-zone publication committed once at revision 1. A had one source binding,
B none. The independent review was the third live subscription; the service's
limit of two returned HTTP 429. Old client handling retired the review's generation
as accessDenied, so a valid committed request appeared uncertain. Choices/source
review were valid (2 rows, 2 ready, no pending choice or source drift).

Current source inspection: client retry-on-429 is present in checkpoint `88c183c0`;
service limit is still **2** while the new concurrency witness requires **4**.
Claude must finish that bounded budget/retry witness, rebuild Array and the LOCAL
relay, and complete the real paired sequence (conflicts, Undo, handoff, abrupt
relaunch, relay reconnect, 550 events with snapshot fallback prevented). Those
later pair steps and a final passing matrix report are still unverified. Leave
related cards Doing. Broader artifact/follow/compaction/operational tickets remain
open. No deployment, push, production relay request or real provider validation
was performed. Keep Dylan's live apps untouched.


## Doing-card acceptance audit — 30 October 2026

Dylan challenged the large Doing count. Re-read all 15 cards' acceptance criteria,
current source and retained Core/service/native results. The previous board state
was too conservative: five cards were held for the whole multiplayer integration
even though their own acceptance criteria were witnessed. Moved COL-04/05/08/09/10
to Done and recorded evidence and scope on each card. The shared finish bench and
release/integration gate are still open. The capture transport-capacity issue is
still explicitly tracked in COL-06/21; closing the capture-manifest card does not
claim that the complete live sharing journey passed.

Board revision **107**: **7 Done / 10 Doing / 9 To Do**. Each remaining Doing
card now names its particular missing behavior or direct witness. Neither board
was renamed/closed, and the other board received no changes. Existing-account
operator recovery and real Keychain trials remain recorded under the operational
alpha handoff (COL-22). This supersedes the earlier blanket 'leave related cards
Doing' guidance.

| Card | Status | Acceptance audit |
| --- | --- | --- |
| COL-04 | Done | Identity, targeted invitations, removal and epoch enforcement witnessed on actual HTTP routes. |
| COL-05 | Done | Atomic scoped storage/idempotency, rollback, migrations, restart and companion isolation witnessed. |
| COL-08 | Done | Scoped bindings, private replica/drafts, recovery bytes and source/executor preservation witnessed. |
| COL-09 | Done | Reviewed capture/manifest selection, fresh source reads, WORLD layout and below-tier coverage witnessed; transport capacity tracked in COL-06/21. |
| COL-10 | Done | Two production-mounted shared scenes, private cameras, zero recipient construction and source command isolation witnessed. |
| COL-02 | Doing | Complete combined native/HTTP/host journey has not passed. |
| COL-06 | Doing | Subscription budget/client429 integration and host-liveness proof remain. |
| COL-07 | Doing | Attachment/nested-artifact boundary paths and their end-to-end byte/revocation witnesses remain. |
| COL-11 | Doing | Explicit mounted mid-gesture revocation and failed-save schedules still need direct evidence. |
| COL-12 | Doing | Revision-linked endorsements and complete concurrency/host-sleep cases need direct evidence. |
| COL-13 | Doing | Actual paired handoff/relaunch and all three managed-harness transport seams still need proof. |
| COL-17 | Doing | Fork/subagent/counter-reset/Claude request-run overlap accounting cases remain unproved. |
| COL-18 | Doing | Voluntary follow and exit-on-navigation behavior plus bounded-work cases remain. |
| COL-19 | Doing | Compaction, retention, ancient-client/operational restore and complete native crash sequence remain. |
| COL-21 | Doing | Final combined workflow/matrix, live observations/freshness and pinned artifacts/native budgets remain. |

Audit evidence: `validation/finish-20261030/teeth/05-restored-checks.log`,
`10-native-hover-restored-green.log`, the prior complete native matrix summary,
and the real A/B/C service results retained as
`validation/finish-20261030/service-before-capacity-witness.log`. The latter
predates the new four-reader witness; it does not claim that the current cap2
passes that new test. Only board and documentation changed; no test suite was
rerun and no Git operation or deployment was performed for this audit.

## Merged

30 October 2026. Pieces A (`array/mp-gate`), B (`array/mp-pair`) and C
(`array/mp-recovery`) are cherry-picked in that order onto
`array/collaboration-finish`. The tip is **`cc168bed`**: 16 commits on top of
`88c183c0`. Nothing is pushed.

How the overlaps were resolved:

- Held-read cap: C's named `updateDeviceLimit = 4` / `updateGlobalLimit = 1024`
  are kept. A's literal `4` is superseded. The overload check (`1...4`) and the
  recovery/scale check (which reads the constants) both pass with it.
- Scope/State `Equatable`: the two sides were identical. A's version is kept,
  and C's `26e033ea` was dropped because it was empty after the merge.
- Overload check: B's field-by-field scope comparison (`c76e867b`) plus C's
  "refuses writes" assertions (`912d6a66`) applied cleanly on top of each other.
- `CollaborationSession.swift`: C's version is kept. It does everything A's
  `7d1fe618` did (a short probe read after a failure that still goes through
  admission control). The differences: the probe holds 1 ms rather than 1 s,
  and every failure sets `recovering`. It also adds that a partial catch-up
  page reports `reconnecting`. C's teeth receipts `c-partial` and
  `d-recovery-hold` pin both behaviours.
- `SharedAreaPeerRuntime.swift`: B's 40 s wait-out loop, with A's richer
  failure message (it includes the persistence error).

Results, all on `cc168bed`, background-only, isolated `TMUX_TMPDIR`:

- `scripts/run-matrix.sh --collaboration`: **passed, 10 legs, 0 failures**.
  This includes C's 15 `recovery/scale` PASS lines and the `kill/relaunch`
  legs, which run inside the default invocations.
- `scripts/check-collaboration-pair.py` (local relay): **3/3 passed**, each run
  15 behaviours, 552 replayed events, no activation.
- `ContinuumRevivedCollaborationServiceChecks --recovery-scale-only` passed:
  relay SIGKILL/relaunch, 1,500-event replay, bounded overload.
- `ContinuumRevivedCollaborationChecks --kill-relaunch-only` passed: SIGKILL
  before send, after commit, after host claim, and inside the provider call.
- Release-line legs: `--ui-probe-check` (with `CONTINUUM_SKIP_UI_BASELINES=1`),
  `--choice-geometry-check` and `--workspace-chrome-polish-check` all passed.
  The skip variable hides exactly the theme surface-cache witness that
  `8a2e5542` changed, so `--ui-probe-check` was also run once without it. It
  passed, and that witness uses offscreen windows only. The `73834bac` title
  witness passed in the matrix (`every handoff action title fits its label`).

Still needs Dylan:

- Deploying the real relay with the four-reader cap. Every run above used a
  local relay only.
- A real two-person test on two Macs with two human accounts.
- Recovery with the real Keychain and real operator steps. The witnesses use
  disposable vaults and a scripted operator.
- The matrix inventory still reports the collaboration legs as "grew". It was
  deliberately not committed.


## Merged-evidence board reconciliation — 30 October 2026

Read the `Merged` section and confirmed current tip `cc168bed`, its 16 commits
above `88c183c0`, production cap4/global1024, default witness registration and the
latest three actual passing pair reports. Retained copies and readback metadata
are in `validation/merged-cc168bed/`: 15 behaviours and 552 events in every run,
zero recipient executors and no focus violation. The Merged record reports the
10/10 gate, four SIGKILL boundaries, relay restart and 1,500-event scale witnesses.
No test suite was rerun for this board reconciliation.

Moved COL-02 to Done: the isolated complete harness acceptance is now proved.
Updated COL-06/07/09/11/12/13/17/18/19/21/22 with the merged results and resolved
the obsolete cap2/failing-pair notes. Board revision **120** now has
**8 Done / 9 Doing / 9 To Do**. The other board was not changed.

Remaining Doing is based on each original card's broader acceptance: explicit
host-liveness expiry (06), nested-artifact boundaries (07), mounted mid-gesture
revocation/fault schedules (11), concurrency/endorsement cases (12), all three
managed-harness dispatch seams (13), fork/subagent/reset accounting (17), voluntary
follow and bounded-work cases (18), compaction/retention restore (19), and the full
roadmap workflow including pinned artifacts/live freshness/native budgets (21).
The passing current four-feature milestone does not prove these missing parts.

Dylan's remaining actions are explicit on COL-22: real relay deployment, a real
two-person/two-Mac test, and real Keychain/operator recovery. Production is not
deployed, nothing is pushed, and matrix inventory growth remains uncommitted.
Only the selected board and handoff documentation/evidence changed in this audit.

## Lead plan — remaining cards, 30 October 2026

The lead (Claude) took over the board at revision 120. COL-02 is Done. The
Codex audit appended a "Merged evidence audit" section to the Doing cards and
moved COL-02; this plan does not repeat it. The plan below is in dependency
order. Each helper works on its own bench off `array/collaboration-finish` and
owns distinct files.

Wave 1 (running):

| Bench | Branch | Cards | Owns |
| --- | --- | --- | --- |
| `.worktrees/mp-gate` (reused) | `array/col-scene-gestures` | COL-11 mid-gesture revoke and failed save; COL-18 voluntary follow | scene view, presence overlay/publisher |
| `.worktrees/mp-pair` (reused) | `array/col-agreements` | COL-12 endorsements, agreement conflicts, discussion after host sleep | protocol document, controller, new agreement view |
| `.worktrees/mp-recovery` (reused) | `array/col-compaction` | COL-19 compaction, retention, ancient client, operational restore | service store/updates, client session/replica |
| `.worktrees/col-provider-seams` | `array/col-provider-seams` | COL-13 Claude/Codex/Pi handoff seams; COL-17 fork/reset/overlap accounting | host session, handoff, usage ledger/collector |

The three `mp-*` benches had already landed (their commits are matched by
subject on this branch) and were clean, so they were repointed to new branches
rather than rebuilt from nothing.

Wave 2: COL-06 host liveness; COL-16 artifacts together with COL-07 nested
artifact boundaries; COL-15 live agent snapshots; COL-14 per-agent freshness.
Wave 3: COL-20 adversarial audit; COL-21 final gate; COL-22 handoff steps
written but not executed. COL-22 deployment and COL-23–26 ("Later") stay out of
scope without Dylan.

## Worker roster (coordinator E284CDC7, 30 Oct; Dylan asked for at least 10 Claude workers)

Integration lead: 411E45C2-B37D-46FA-A145-31703571FEA3 (owns SharedAreaDocument, Controller, Store/Updates, Supervisor, Scene and the main/script registrations; merges every branch onto array/collaboration-finish).
Workers 1-4 (the lead's wave 1): COL-11+18 scene, COL-12 agreement, COL-19 recovery/compaction, COL-13+17 provider. IDs are in the lead's own notes.
Workers 5-10 (started by the coordinator; each reports to the lead and writes .plans/105-collaboration/workers/<slug>.md on its bench):
- 5 COL-06 host liveness: 6B5C446C-34A1-4629-A2A1-EAC3F7B40B2C, array/mp-w5-liveness
- 6 COL-16+07 artifacts (owns the artifact DTO/API): E06E8F11-DA07-4C4B-B015-F21CB4363EC2, array/mp-w6-artifacts
- 7 COL-15 live agent views: B7624240-9165-4103-A51A-093A146AEBF7, array/mp-w7-live
- 8 COL-14 freshness/provenance: DE92D619-0EB0-467D-866C-14B6077C9E02, array/mp-w8-freshness
- 9 COL-20 security boundaries (owns new check files): 50B885E3-10DE-41BC-8910-25DF8CCFBB7F, array/mp-w9-security
- 10 COL-21 + non-deploy COL-22 acceptance/release prep: 896A0BA8-F412-4D37-BDE1-572700179E60, array/mp-w10-acceptance
Builds: at most one Array/App build at a time; no full matrix per worker.


## Ten Claude workers confirmed — 30 October 2026

Dylan explicitly requested at least ten Claude workers, replacing the earlier
three-agent limit. Root routed creation through Claude coordinator E284CDC7
because Array delegation inherits the caller's harness. Six new Claude workers
were added to the four existing Claude workers; each of all ten was read back as
`Claude Code` and `working`, with a separate registered bench. Coordinators and
unrelated sidebar/auto-layout agents are excluded from that count. Integration
remains with 411E45C2-B37D-46FA-A145-31703571FEA3.

| Worker | Scope | Cards | Agent ID |
| --- | --- | --- | --- |
| 1 | Geometry and voluntary follow | COL-11, COL-18 | `0B75131B-87E2-44E5-90AD-C7298F21796A` |
| 2 | Agreements and endorsements | COL-12 | `32E6F97B-2419-41CA-BFD7-72F9F0815ABF` |
| 3 | Compaction and recovery | COL-19 | `39A1E531-BDFD-4FAD-B6B8-E593783B54EA` |
| 4 | Handoff and usage accounting | COL-13, COL-17 | `D4915E0C-1350-4F98-A710-EEE117688858` |
| 5 | Host liveness | COL-06 | `6B5C446C-34A1-4629-A2A1-EAC3F7B40B2C` |
| 6 | Artifact storage and publication | COL-16, COL-07 | `E06E8F11-DA07-4C4B-B015-F21CB4363EC2` |
| 7 | Live agent projections | COL-15 | `B7624240-9165-4103-A51A-093A146AEBF7` |
| 8 | Context freshness and provenance | COL-14 | `DE92D619-0EB0-467D-866C-14B6077C9E02` |
| 9 | Security boundary witnesses | COL-20 | `50B885E3-10DE-41BC-8910-25DF8CCFBB7F` |
| 10 | Acceptance and non-deploy operations preparation | COL-21, COL-22 | `896A0BA8-F412-4D37-BDE1-572700179E60` |

Machine-readable roster: `CLAUDE-WORKERS.json`. All fourteen remaining alpha
cards are assigned to their actual workers. Board revision **148**:
**8 Done / 14 Doing / 4 To Do**; only later COL-23–26 remain To Do. Assignment and
starting work do not establish completion. The other board was not modified.

Shared-file ownership and interface dependencies are coordinated by the lead;
workers use distinct benches and scoped changes. No full matrix per worker, and
at most one Array/App build at a time. Final integration must wire production
paths and report deterministic behavior/RED witnesses, with batched verification.
No production relay, push, live app, default tmux, real Keychain or deployment
step was authorized by this expansion. The existing Dylan-only operational
checks remain explicit.

## Resume on the 0.7.35 release — 30 October 2026

- `array/collaboration-finish` merges the shipped 0.7.35 release (`0c28fc06`)
  in `c825629c`, then carries the finished worker branches: w6 artifacts, w8
  freshness, w9 security and w10 acceptance (19 commits, tip `e17d0a52`). The
  conflicts were only check and migration registrations; each was resolved by
  keeping both sides.
- Build environment: once the manifest recompiles, plain `xcrun` resolves the
  Command Line Tools 27 SDK, which Xcode's Swift 6.3.3 cannot read ("SDK is not
  supported by the compiler"). Builds pin
  `SDKROOT=$(xcrun --sdk macosx --show-sdk-path)`. The shared wrapper
  `.worktrees/.locks/app-build.sh` takes an exclusive lock (one app build or
  gate at a time across helpers) and pins SDKROOT.
- Board: COL-11, COL-12, COL-17 and COL-19 are Done, on the 10/10 gate at
  `eb5b5c7b`, which included the pair run.
- Eight helpers are running: w5 liveness (finish), w7 live views (finish),
  D4915E0C refused-admission fix plus the freshness production hook,
  w10 Linux relay gate plus the pair feature stages, w6 native artifact capture
  and renderer plus live wake, w8 excerpts in discussion plus the freshness UI,
  w9 COL-20 close-out over artifacts and retention, and 0B75131B COL-21 native
  keyboard, Reduce Motion, budgets and census.
- Decision recorded for Dylan: per-agent freshness receipts stay visible only
  to the requester and the agent's owner. A teammate-wide projection would need
  a privacy call.

## Gate on the merged release tip — state at handoff

Gate: `CONTINUUM_SKIP_UI_BASELINES=1 .worktrees/.locks/app-build.sh
scripts/run-matrix.sh --collaboration`, started on the sources of `e17d0a52`.
`8e4a01f2` only adds docs, so the sources are the same. Log:
`qa-runs/lead/gate-merge-0735.log`. **It had not finished at handoff**:
`run-matrix.sh` was still running (pid 5333) inside
`check-collaboration-pair.py`, and the two companion relay suites come after it.

Results so far:
- Matrix inventory: passed. It reports 16 "grew" records, deliberately not
  committed.
- `ContinuumRevivedCollaborationChecks`: passed.
- **`ContinuumRevivedCollaborationServiceChecks`: FAILED** at w10's backup
  check: `BackupCheckFailure("verification refuses a backup with damaged
  pages")`. The suite stops at the first failure, so every service section
  after it never ran in this pass. Likely cause, not yet confirmed: w10's
  `CollaborationBackup` against COL-19's new horizon/`operation_receipts`
  tables or its own `verifyIntegrity()`; the two backup paths were written
  separately. w10 was told to unify them (item 3 of its brief).
- `--collaboration-native-check`, `--ui-probe-check`, `--menu-contract-check`:
  no failure printed (UIProbe: 525 TokenThemed views).
- CoreChecks `--collaboration-usage-telemetry-check`: passed.
- Pair check and relay suites: still running or not yet run.

The first attempt at this gate died before compiling anything (the SDK
mismatch below). The wrapper now pins SDKROOT.

## Handoff to coordinator (E284CDC7) — 30 October 2026

Every helper's brief says the same things:
- Wrap every app build and gate in `.worktrees/.locks/app-build.sh`
  (exclusive lock, pins SDKROOT).
- Background only, never take focus. Use `CONTINUUM_SKIP_UI_BASELINES=1`, an
  isolated TMUX_TMPDIR and CONTINUUM_APP_SUPPORT (`mktemp -d` + `pwd -P`), and
  unset TMUX/TMUX_PANE.
- Witnesses are behavioural, run inside existing legs, and are teeth-tested
  RED then GREEN.
- Commits under Dylan's identity with no trailer. No push, stash, inventory
  commit or deploy, and never `mcp__plan__*`.
- Finish with one gate run under the lock, write a receipt, and deliver the
  **final answer to the lead (411E45C2) as the turn's final message**. Each was
  started with `array_message_agent`, so their answers are collected with
  `wait_agents` on these message operation ids.

Those messages were delivered. A follow-up note about the SDK was refused by
D4915E0C, 6B5C446C and B7624240 because they were mid-turn. The lock wrapper
covers their app builds, but their non-app builds may hit "SDK is not supported
by the compiler"; the fix is
`SDKROOT=$(xcrun --sdk macosx --show-sdk-path)`.

| # | Agent | Bench / branch | Task | Wait handle |
| --- | --- | --- | --- | --- |
| 1 | `6B5C446C-34A1-4629-A2A1-EAC3F7B40B2C` (w5) | `.worktrees/mp-w5-liveness` / `array/mp-w5-liveness` | COL-06: commit the uncommitted native wiring, rebase onto `collaboration-finish`, rendered liveness card witness (light/dark), handoff dialog warns before "send now" to a host that isn't online, expose `controller.hostLiveness` for w7. Receipt `workers/w5-liveness.md` | `toolu_01B8JcfjxAPU9AXtSPER5SyN` |
| 2 | `B7624240-9165-4103-A51A-093A146AEBF7` (w7) | `.worktrees/mp-w7-live` / `array/mp-w7-live` | COL-15: commit the uncommitted projector, rebase; late join snapshot+tail or resnapshot, no private side channels, no duplicate executor, runner-capability controls, all three harnesses, read-only live view; gate controls on w5's `hostLiveness`; owns turn/sequence shapes and adjusts w8's provisional types. Receipt `workers/w7-live.md` | `toolu_01EMikzgxoisecBrGMGfXACS` |
| 3 | `D4915E0C-1350-4F98-A710-EEE117688858` | `.worktrees/col-provider-seams` / `array/col-admission` (from `e17d0a52`) | w9 finding 1: definitive refusal (403/404/409) before `execute` → `refused`, not `uncertain`, in `SharedAgentHandoffTransport.dispatch`; tighten w9's R3; align a lapsed-claim host label with the service. Wire w8's freshness ledger into `SharedAgentHandoffController` (production witness). Read codex `forkedFromId`. Receipt `validation/col-admission/README.md` | `toolu_01B9sDv4zWNM9jKqpK7s56YM` |
| 4 | `896A0BA8-F412-4D37-BDE1-572700179E60` (w10) | `.worktrees/mp-w10-acceptance` / `array/mp-w10-acceptance` (reset to `collaboration-finish`) | Linux relay gate (`check-relay-linux.sh`) passing on the merged tree and recorded in ACCEPTANCE.md; add it as a `--collaboration` leg (no inventory commit); unify w10 backup with COL-19 `backup(to:)`/`verifyIntegrity()` and cover artifact + horizon/receipt tables (**this is the area of the current service FAIL**); pair `features` stages for endorsements/follow/compaction/artifacts/freshness, with w5/w7 stages left pending. Receipt `workers/w10-acceptance.md`, `ACCEPTANCE.md` | `toolu_01HbHhzH2uprLbhATvWpFhin` |
| 5 | `E06E8F11-DA07-4C4B-B015-F21CB4363EC2` (w6) | `.worktrees/mp-w6-artifacts` / `array/mp-w6-artifacts` (reset to `collaboration-finish`) | COL-16+07: diff/file publishable in capture review; read-only artifact renderer in scene (perf checklist); `artifactHeads` live wake on the updates page; require a source for `.artifact`; quota witness; blob GC per retention; own narrow artifact-boundary witness. Receipt `workers/w6-artifacts.md` | `toolu_01FxxvaHUnu27skAmhXPf3ve` |
| 6 | `DE92D619-0EB0-467D-866C-14B6077C9E02` (w8) | `.worktrees/mp-w8-freshness` / `array/mp-w8-freshness` (reset to `collaboration-finish`) | COL-14: additive `Post` excerpt reference in `SharedAreaDocument` (turn, host, artifact manifest+digest), native freshness and excerpt UI, witness through the production controller and a mounted scene. Told not to wire the controller hook (D4915E0C does it) and not to change turn/sequence types (w7 does). Visibility decision: requester and owner only | `toolu_01SMCKZHNa6azLAo5xU43xzE` |
| 7 | `50B885E3-10DE-41BC-8910-25DF8CCFBB7F` (w9) | `.worktrees/mp-w9-security` / `array/mp-w9-security` (reset to `collaboration-finish`) | COL-20 close: extend the A/B/C audit to artifact routes and compaction/retention; pin "all retained history on join" plus a documented decision for Dylan; log/storage review; no E2EE claim. Told not to touch the handoff transport. Receipt `workers/w9-security.md` | `toolu_019uvtdwtPKgYNciYcuMszHY` |
| 8 | `0B75131B-87E2-44E5-90AD-C7298F21796A` | `.worktrees/mp-gate` / `array/col-native-budgets` (from `e17d0a52`) | COL-21 native slice: keyboard parity via the real event path, Reduce Motion, count-based budgets on the production mount, token-owner census, light/dark renders (ACCEPTANCE.md "Native budgets and accessibility still owed"). Its keyboard parity also closes COL-18. Receipt `validation/col-native-budgets/README.md` | `toolu_01KnvgWdWNg2RPvwYWry3r6r` |

Planned merge order, each cherry-picked onto `array/collaboration-finish` with
a `--collaboration` gate after each batch:
1. D4915E0C `array/col-admission`, then w10. Both are small and fix
   correctness; w10 includes the backup fix for the current service FAIL.
2. w5 liveness, before w7, which reads `hostLiveness`.
3. w6 artifacts, before w8, which pins artifact manifests, and w9, which
   audits artifact routes.
4. w7 live views, then w8 freshness. Recheck the turn/sequence types after both
   land.
5. w9 security.
6. 0B75131B native budgets last, so its generic census and budget witnesses
   see every new view.

Expected conflicts are registrations in the checks `main.swift` files, the
migration list in `CollaborationStore`, and small `SharedAreaSceneView`,
`SharedAreaController` and service `CollaborationUpdates` hunks: keep both
sides. After w10 adds the Linux leg, the inventory "grew" records stay
uncommitted.

Board at handoff (revision 156): COL-11/12/17/19 moved to Done. COL-13 waits
for the refused-admission fix, COL-18 for keyboard parity. COL-06/07/14/15/16/
20/21 wait for their helpers. COL-22 operations stay with Dylan, and COL-23–26
stay To Do.

Working tree at handoff:
- Everything above is committed through `8e4a01f2` (this section is the next
  commit).
- `.plans/105-collaboration/workers/INBOX.md` has an uncommitted change from
  the coordinator, not the lead.
- `port-release-0735.patch` and `scripts/__pycache__/` are untracked leftovers.
- Nothing unmerged or half-applied.
- The scratch `col-merge` worktree and its branch are removed.
- Stale benches `mp-pair` (`array/col-agreements`) and `mp-recovery`
  (`array/col-compaction`) are fully merged and can be returned with
  `git worktree remove`.
- Branches `array/col-scene-gestures`, `array/col-provider-seams`,
  `array/mp-gate`, `array/mp-pair` and `array/mp-recovery` are fully landed.
- `.worktrees/.locks/app-build.sh` is the shared lock wrapper; it is
  uncommitted and outside git.

**Final gate result (finished after handoff):** 10 legs ran, 9 passed, 1
failed. The failure is `ContinuumRevivedCollaborationServiceChecks`, at the
backup "damaged pages" check above. The pair passed (15 behaviours, 552
replayed events), and so did both companion relay suites. Log:
`qa-runs/lead/gate-merge-0735.log`.

## Integrator gate — admission + w10 on `5fa07c36`, 30 October 2026

The coordinator cherry-picked `array/col-admission` (refused-admission pins,
freshness ledger in the production controller, codex `forkedFromId`) and
`array/mp-w10-acceptance` (one verified operator backup path, every backup
page damaged in the check, relay retention overrides from the environment, and
`check-relay-linux.sh` as a `--collaboration` leg) onto `collaboration-finish`.

Gate: `CONTINUUM_SKIP_UI_BASELINES=1 .worktrees/.locks/app-build.sh
scripts/run-matrix.sh --collaboration`, with its own TMUX_TMPDIR and
CONTINUUM_APP_SUPPORT. Log: `qa-runs/coordinator/gate-5fa07c36.log`.
**11 legs run, all passed.**

- ServiceChecks passed, including "verification refuses a backup with damaged
  pages". It failed before because the check damaged 512 bytes at the file's
  midpoint, which could land on a free page that SQLite never reads. `cdc244a4`
  now damages every page, and `a330d7de` makes the verified operator backup
  the only backup path.
- The new Linux relay leg (`check-relay-linux.sh`, in Docker) passed.
- Pair, both relay suites, native, UI probe, menu contract and usage telemetry
  passed. The inventory reports "grew" records, and they stay uncommitted.

Board: nothing moved to Done. COL-13 still owes the handoff transport-seam
witness for each managed harness (Claude, Codex, Pi). COL-21 still waits on
the remaining helpers.

Next merges, as each branch reaches done: w5, w6, w7, w8, w9, then
`array/col-native-budgets`. At this gate, w5 and w7 had commits but still had
uncommitted work and no committed receipt. w6, w8, w9 and native budgets had
nothing committed past `e17d0a52`.

## Integrator gate — w8 freshness on `a040bd80`, 30 October 2026

Merged: w8 `array/mp-w8-freshness` (`c7d7f919`, `bfdc6951`), cherry-picked
clean. It went in ahead of w5–w7 because its receipt and own gate were done
and its dependencies (artifacts, the freshness hook) were already on the tip.

Gate: `--collaboration` under the lock, isolated. Log:
`qa-runs/coordinator/gate-a040bd80.log`. **11 legs run, all passed**,
including all 17 `PASS shared freshness scene` lines.

Board: COL-14 stays Doing. Every acceptance row has a witness (receipt
`workers/w8-freshness.md`), but turn/sequence on excerpts are still
provisional until w7 lands, and no control yet composes an excerpt from an
agent result.

Then merged w5 `array/mp-w5-liveness` (all but `040704a7`). That commit
patched the backup "damaged pages" check to damage one page header; the tip
already has w10's `cdc244a4`, which damages every page, so it was left out.

## Integrator gate — w5 liveness + w9 security + two Linux fixes on `4b83a7c3`, 30 October 2026

The gate on `cfab6252` (w5 alone) failed only at `check-relay-linux.sh`, for
two separate reasons:

1. **`continuum-relay` did not compile on Linux Swift 6.1** after w5's
   heartbeat commit: `CollaborationUpdates.swift:112: sending 'db' risks
   causing data races`. The presence `.map` closure captures the
   transaction's `db`, and the stricter Linux compiler refuses any later use
   of `db` once it has been sent into that closure. `hostLiveness(db)` was
   added after it. Fixed in `75aefe90` by reading host liveness first, in the
   same transaction. The Mac compiler accepted both orders. A native arm64
   container compile confirmed the relay builds.
2. **The build was flaky under amd64 emulation.** SwiftPM's copy of GRDB's
   `PrivacyInfo.xcprivacy` failed with EINTR, which Foundation does not
   retry. `bbbf11e4` retries the docker build once, only on that error.
   Separately, w9's `3eec1012` caps the service checks build at two codegen
   threads: at fifteen it ran out of the 7.75 GB Docker VM.

Merged: w9 `array/mp-w9-security` (`7bac65cf`..`91b902c6`, five commits,
clean).

Gate: `--collaboration` under the lock, isolated. Log:
`qa-runs/coordinator/gate-4b83a7c3.log`. **11 legs run, all passed**,
including the Linux leg. Unrelated containers were running in Docker
during the run.

Board (revision 158): COL-06 → Done (w5's independent host liveness:
heartbeats, lost/expired/rejoined/fenced over HTTP, production-client and
rendered-card witnesses). COL-20 → Done (w9's audit across artifacts,
retention, backups and logs, receipt `workers/w9-security.md`). The
history-on-join and 404/403 policies are recorded as decisions for Dylan in
`docs/internals/collaboration.md`.

Still to merge: w6 artifacts, w7 live views, then `array/col-native-budgets`.

## Integrator gate — w6 artifacts on `fe041913`, 30 October 2026

Merged: w6 `array/mp-w6-artifacts` (`3311b913`, `6cb18aa6`, `1aee3de1`,
`6d2c9d18`). Conflicts, each resolved by keeping both sides:
- `Updates`, `CollaborationReplica` and `SharedAreaController`: w5's `hosts`
  and w6's `artifactHeads` both stay. The service reads `artifactHeads(db)`
  before the presence map, like `hostLiveness`, so the Linux "sending 'db'"
  error cannot come back through it.
- `SharedAreaSceneView`: the freshness panel (w8) and the artifact panel (w6)
  both stay. They share a frame but show only for an agent and an artifact
  respectively.
- `docs/internals/collaboration.md` retention table: w6's rows. Unpublishing
  now deletes an artifact's revisions, reviews and blobs
  (`refreshArtifactAccess`), so w9's "unreachable but not deleted" row was
  stale.

Gate: `--collaboration`, under the lock and isolated. Log:
`qa-runs/coordinator/gate-fe041913.log`. **11 legs run, all passed.**

Board (revision 160): COL-16 → Done. Its receipt
(`workers/w6-artifacts.md`, round 2) has a witness for every acceptance
item: coverage, live versus pinned review, drift, recipient byte-identity
and the bounded quota with GC. COL-07 → Done: the nested artifact lookup
boundary is covered by w6's routes and w9's artifact audit. Known limits
that w6 recorded: an upload that fails after the arrangement is accepted
leaves the item without a revision, and nothing retries it after a
relaunch.

Remaining: w7 live views, then `array/col-native-budgets`.

## Integrator gate — w7 live agent views on `8dbfa899`, 30 October 2026

Merged: w7 `array/mp-w7-live` (twelve commits, `9e97f8e8`..`7e1c4401`). w7
had rebased onto `fe041913`, so the cherry-pick was clean, and the merged
tree differs from w7's own gated tree only in this file.

Gate: `--collaboration` under the lock, isolated. Log:
`qa-runs/coordinator/gate-8dbfa899.log`. **11 legs run, all passed.**

Board (revision 162):
- **COL-15 → Done.** Receipt `workers/w7-live.md` has a witness for every
  criterion: late join or resnapshot, snapshot/tail race, gaps, no private
  history or side channels, background turns, stale generation, no duplicate
  executor, all three harnesses through the production runners, controls from
  the bound runner, and no QA-only capability false positive.
- **COL-14 → Done.** w7 replaced the provisional turn/sequence on excerpts
  with projection positions (`a63f28fe`, `88ac5a62`). That was the last open
  item against COL-14's criteria.

Known limits, not acceptance gaps:
- No control yet picks an agent result to quote; `shareResultExcerpt` is the
  entry point.
- The live view polls once a second while an agent is selected.
- Handoff "Send now" does not yet read the projected `canSend`; the host
  still refuses at dispatch.
- The Claude fake sends whole messages, so a Claude turn through it shows a
  tool step without text.

Remaining: `array/col-native-budgets` (COL-21 native slice, which also closes
COL-18's keyboard parity). COL-13 still owes its per-harness handoff seam
witness.

## Integrator gate — artifact gaps + per-harness handoff on `c20a3819`, 30 October 2026

Merged in one batch, both cherry-picked clean:
- `array/mp-artifact-gaps` (`a7ee9817`, `ffe5481c`, `ba93a7bc`): a failed
  artifact upload is retried after relaunch, and the artifact panel is
  rendered in a real offscreen window. Receipt `workers/artifact-gaps.md`.
  Its own gate failed only on the damaged-pages backup check because its base
  predates `cdc244a4`; on this tip that check passes.
- `array/col-handoff-seams` (`a7fe1f0f`, `7f7d2afe`): the per-harness handoff
  witness. Receipt `validation/col-handoff-seams/README.md`.

An earlier gate started on `6a5d8337` (artifact gaps alone) was stopped so the
batch could be gated once.

Gate: `--collaboration` under the lock, isolated. Log:
`qa-runs/coordinator/gate-c20a3819.log`. **11 legs run, all passed.** The
three `PASS handoff seam: claude / codex / pi` lines are in it.

Board (revision 163): **COL-13 → Done.** The last item was the handoff through
each managed harness's real runner. It is now witnessed for Claude Code,
Codex and Pi: the new controller's prompt reaches the CLI once, the former
owner's input is refused while the agent is handed over, and a prompt that
the reclaim overtook reads refused with no write.

Remaining: `array/col-native-budgets`.

## Integrator gate — native budgets on `9d1a3b90`, 30–31 October 2026

Merged: `array/col-native-budgets` (`4bdfca62`..`89dd2e11`, five commits).
Conflicts:
- `SharedAreaSceneView`: the keyboard work's focus hold now wraps the w6/w7
  panel logic in `refreshReader`. `setText(statusLabel…)` keeps w6's
  `artifactPanel.headsChanged`.
- `ContinuumApp` native stages: the host-liveness stage and the three new
  stages are all registered, with the census last.

Integrator additions, as the coordinator asked:
- `6d5137ae` adds two census surfaces, an agent selected (freshness panel and
  live view) and an artifact selected (artifact panel). The class census also
  counts `SharedAgent*` views: `SharedAgentLiveView` matched neither
  "SharedArea" nor "Collaboration", so the census could not see it. It now
  reports 12 classes on 9 surfaces. w5's liveness has no view of its own: it
  is a line on the scene's agent cards, which the scene surface already
  covers. Teeth: dropping the agent surface → RED naming exactly
  `SharedAgentLiveView` and `SharedAreaAgentFreshnessView`; restored by `cmp`.
- `9b5837a2` adds the live view row budget (ACCEPTANCE item 5). One
  projection delta over 10, 100 and 1,000 produced rows renders 10, 32 and 32
  rows (`maxRows`), creates no Array view, and costs 1 Array layout pass and
  10, 12 and 12 TextKit fragment layouts (visible rows only). Teeth:
  remounting the text view per delta → RED at "no Array view created";
  restored by `cmp`.
- `9d1a3b90` fixes a real defect the token census then found:
  `SharedAreaArtifactView` left its text view's `textColor` at AppKit black,
  so plain messages ("No included content in this revision") were black in
  dark mode. It now takes `TextToken.textPrimary`.

Gate: the first run on `9b5837a2` failed only `--ui-probe-check`, on that
colour. The run on `9d1a3b90` (log `qa-runs/coordinator/gate-9d1a3b90.log`):
**11 legs run, all passed.**

Board (revision 164): **COL-18 → Done**. Keyboard parity, Reduce Motion and
bounded follow work are witnessed, and follow itself already was.

**COL-21 stays Doing, for one named gap.** Its acceptance asks for two
participants working through discussion, agreement, own-agent delivery *and
pinned review artifacts*, and for the matrix to report the new legs. The core
pair passes. But `scripts/check-collaboration-pair-features.py` (run once,
`--allow-pending`, log `qa-runs/coordinator/pair-features.log`) reports all
eight feature stages PENDING: liveness, artifacts, liveViews, freshness,
endorsements, follow, compaction and harnesses. The peer runtime
(`SharedAreaPeerRuntime.swift`) lacks their mailbox ops, listed in
ACCEPTANCE.md "Pair feature journey contract". The features are witnessed
natively and over HTTP, but not in the real two-process journey, and that
journey is not registered in the gate. Closing COL-21 means adding those
peer ops and then registering the journey as a `--collaboration` leg.

Board counts: To Do 4 (COL-23–26, later phase), Doing 2 (COL-21, COL-22),
Done 20.

## In-canvas round — part 1 share links on `e231be9d`, 31 October 2026

Design: `.plans/105-collaboration/IN-CANVAS.md` on the design bench
(`5fb4315e`). Builders work off `c7131f8f`. Merge order: pair-features and
part 1, then part 4 (full access), then part 2 (canvas zone), then part 3
(share entry) last.

Merged: `array/mp-share-links` (`84ad76ca`..`728326bc`, five commits,
clean). Receipt `workers/share-links.md`. It includes a website page
(`website/src/pages/s/`, `vercel.json` rewrite) that hands
`arrayapp.dev/s/<slug>` to the app. It is only on this local branch; nothing
was deployed.

Gate: `--collaboration`, under the lock, isolated. Log:
`qa-runs/coordinator/gate-e231be9d.log`. **11 legs run, all passed**, with
31 `PASS share links` lines.

Open, from the receipt:
- A brand-new person cannot onboard from a link alone. The link carries no
  relay address, and enrollment needs an operator code. This is a relay
  decision.
- A slug collision leaves an empty owned area behind.
- Prod and Dev both claim `array://`.
- There is no universal link yet: the AASA file covers only `/pair`.
- The website hand-off was not opened in a browser.
- `--collaboration-native-check` ran in 34–42 s against its own 45 s limit.
  Parts 2–4 add stages, so the limit needs raising, or the 13 s hover-usage
  stage needs to be faster, before they land.
