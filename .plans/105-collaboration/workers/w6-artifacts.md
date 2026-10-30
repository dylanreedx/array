# Worker 6 — shared artifacts (COL-16, COL-07 nested lookups)

30 October 2026. Bench `.worktrees/mp-w6-artifacts`, branch
`array/mp-w6-artifacts` from `array/collaboration-finish` at cc168bed.
API shape: [artifact-api.md](artifact-api.md).

## Commits

- `bfec6779` feat: protocol types, service store + migration code, NIO routes,
  client API/reader, owner-host producer, both witness files. New files only.
- `8d2d3e77` chore: the shared-file hunks, isolated for the lead. Same diff as
  [w6-integration-hunks.patch](w6-integration-hunks.patch): register the
  `collaboration-artifacts-v1` migration in `CollaborationStore.init`; hook
  `CollaborationArtifactRoutes` ahead of the 256 KiB guard in
  `CollaborationRoutes`; make `CollaborationAPI.baseURL/credential/session`
  internal for raw blob requests; `--artifacts-only` + default registration in
  both checks `main.swift` files.
- `7771577c` docs: "Shared artifacts" section in `docs/internals/collaboration.md`.

## What it does

Artifact = admitted `.artifact` item with a source. Revisions/blobs live in
three new tables, sealed with the area key (blob AAD binds area/object/digest),
never in the operation stream. Live latest is separate from pinned revisions.
Reviews pin (object, revision, content digest); applicability is
current / superseded / sourceChanged, and drift is set once by the owner host.
Recipient reads verify every digest and return bytes in memory; there is no
API that writes a recipient checkout.

Finding: `git diff HEAD` rewrites the owner's `.git/index` when stat info is
stale, even with `--no-optional-locks` / `GIT_OPTIONAL_LOCKS=0`. The producer
now runs every git command on a private copy of the index.

## Witnesses (both inside existing `--collaboration` gate legs)

- `ContinuumRevivedCollaborationServiceChecks --artifacts-only`: 41 PASS. Real
  NIO routes + production client. A/B/viewer/C; idempotent publish; hash
  mismatch 400; 1 MiB+1 blob 413; unstaged blob; host-style paths; viewer and
  teammate refusals; pinned approval → sourceChanged → superseded; R1 bytes
  stable beside R2; tampered blob/record refused by the reader; same 404 bytes
  for excluded C, guessed staged digest, sibling-object digest, revision under
  the wrong object, other-area digest/id, removed member, unpublished object;
  no artifact bytes in the update stream; sentinel absent from the SQLite file.
- `ContinuumRevivedCollaborationChecks --artifacts-only`: 27 PASS. Fixture
  owner + recipient repos: staged/unstaged/explicit-untracked included;
  oversized/binary/symlink declared without bytes; unselected content, names
  and absolute roots absent; owner tree incl. `.git/index` byte-identical
  (with stale stat info); branch range excludes working edits; change between
  reads retried, a never-settling source refused; `..`, `/etc/passwd`, `.git/`
  refused; recipient checkout byte-identical after reads; edit during review →
  probe → drift → R2 supersedes; new commit → base moved.
- Full runs: service checks 248 PASS, collaboration checks 402 PASS, exit 0.

Teeth (each restored after): nested digest check removed → RED; supersession
removed → RED; admitted-object check removed → RED; second-read agreement
removed → RED; untracked included without selection → RED; private index
removed → RED.

## Round 2 (30 October 2026, on e17d0a52; tip in the coordinator message)

Lead's items, each with its witness:

1. **Source required for `.artifact`.** `CollaborationStore.authorize`
   refuses an artifact without a source. Witness: service
   "artifact admitted without a publishing source refuses (400)". Three
   existing checks that admitted source-less artifacts now give one.
2. **Native capture.** Diff tiles offer "Diff snapshot" and "Diff snapshot
   with untracked files"; file tiles offer "File snapshot". Capture runs off
   main (`SharedArtifactSource.drafts`); the draft digest joins the review
   digest; confirmation re-captures; the accepted command admits a
   host-sourced item with a reserved revision ID, then the coordinator
   publishes it. Witnesses: Core publication (needsReview, host source,
   reviewChanged on new bytes, missing capture refused); producer (tile →
   source, untracked only by opt-in, stable digest); native journey
   `SharedAreaArtifactChecks` in `--collaboration-native-check`.
3. **Renderer.** `SharedAreaArtifactView` replaces the scene's reader for
   artifacts: one text view through `DiffReviewTileNSView.render`, follow
   latest or pin a revision, file list with coverage, Approve / Request
   changes. Native journey asserts revision 1 current → approval → revision 2
   live with the approval reported as not applying → pinned revision 1
   "superseded" → drift "not applicable"; light and dark token colours;
   recipient checkout byte-identical; no executor.
4. **Live wake.** `Updates.artifactHeads`; publish/review/drift wake held
   subscriptions; controller exposes `artifactHeads`. Witnesses: service
   "held subscription wakes on publication" and heads content; native journey
   follows the new head without polling.
5. **Quota + GC.** Staged blobs no revision names expire after
   `CollaborationRetention.artifactStagingLifetime` (1 h); unpublishing deletes
   blobs, revisions and reviews. Witnesses: 64 MiB quota refuses after 63 MiB;
   expiry frees it; published bytes survive; unpublish leaves 0 rows.
6. **COL-07 nested lookups.** Unchanged boundary from round 1 (41 → 49
   service PASS); worker 9 extends the adversarial audit.

Native journey (`SharedAreaArtifactChecks`, 18 PASS inside
`--collaboration-native-check`): review opts nothing in; both tiles captured
off main; untracked file counted, never named or uploaded; edit after review
refuses with no command or bytes sent; refreshed review publishes both;
recipient scene shows revision 1 current; approval; live wake to revision 2
with the approval not applying; pinned revision 1 "superseded"; drift "not
applicable"; light and dark token colours; recipient checkout byte-identical;
no executor. It first went RED for a real reason: the submission path only
accepted agent bindings, so artifact bindings were refused. Fixed in
`SharedAreaPublicationSubmission` and `SharedAreaPendingOperation`.

Renders: `.plans/105-collaboration/validation/artifacts/artifact-{light,dark}.png`.
In the dark image the header strip is white because the offscreen bitmap does
not include the scene surface the panel sits on (the panel paints no background,
like the agreement panel). Text view, controls and colours show the theme; the
colours are asserted against tokens, not read off the image.

Gate: `scripts/run-matrix.sh --collaboration` under the app-build lock,
isolated TMUX_TMPDIR / CONTINUUM_APP_SUPPORT, CONTINUUM_SKIP_UI_BASELINES=1:
"Collaboration matrix (targeted): 10 leg(s) run ... passed", gate exit 0. One
note: the ui-probe theme surface-cache witness is skipped with display-
dependent checks.

Teeth (each restored): scene not forwarding heads → native RED ("approval
appears" timeout); confirmation reusing reviewed drafts → native RED ("an edit
after review refuses"); no wake on publish → RED; no staging GC → RED;
source-less artifact allowed → RED; no unpublish cleanup → RED; missing
capture accepted → RED; artifact item without host source → RED. Heads
filtered to admitted objects is defence in depth: unpublish cleanup already
removes the rows, so no witness can tell it apart (stays green when removed).

## Not done / not verified

- An upload that fails after the arrangement is accepted leaves the item with
  no revision; after a relaunch nothing retries it (drafts are in memory).
- The native journey uses a scripted authority (the app links no service);
  the real routes, client and controller transport are witnessed in the
  service and Core legs.
- The capture inventory's tile → source mapping is witnessed through
  `SharedArtifactSource.resolve`, not through a mounted workspace inventory.
- API note delivered to worker 8. Workers 7 and 9 refused it three times (mid-turn); the lead was asked to relay.
