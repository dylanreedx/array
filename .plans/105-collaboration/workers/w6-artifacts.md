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

## Not done / not verified

- Native: capture review still lists diff/file tiles as unsupported, and the
  shared scene has no read-only artifact renderer. Wiring is in lead-owned
  files (`SharedAreaPublication`, Scene). Entry points: producer
  `SharedArtifactProducer.capture`, client `publishArtifact` / `readArtifact`.
- No live wake for new revisions: recipients see them by fetching
  `GET /artifacts/{o}`. An `artifactHeads` field on the updates page would fix
  that (lead's Updates file).
- The service still admits an `.artifact` item without a source (pre-existing
  rule). Such an item can never get revisions. Optional hunk: require a source
  for `.artifact` in `CollaborationStore.authorize`.
- Quota (64 MiB/area) is enforced but not witnessed. No retention/GC of staged
  or unpublished blobs (COL-19). Linux relay container not run.
- API note delivered to worker 8. Workers 7 and 9 refused it three times (mid-turn); the lead was asked to relay.
