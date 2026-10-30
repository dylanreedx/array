# Shared artifact API (COL-16 / COL-07 nested artifacts)

30 October 2026. Owner: MP worker 6 (artifacts), bench `.worktrees/mp-w6-artifacts`,
branch `array/mp-w6-artifacts`. This is the published shape; it may gain fields,
it will not rename or remove these without a note here.

Types live in `Sources/ContinuumRevivedCollaborationProtocol/CollaborationArtifacts.swift`
under `Collaboration.Artifact`.

## Model

- An artifact is a shared object: a `SharedArea.Item` of kind `.artifact` WITH a
  `source` (owner person, host, binding), admitted through the normal
  `/commands` route. The document holds only the item and its placement.
- Revisions and bytes live beside the document, never in the operation/event
  stream. Each revision is immutable: a `Manifest` (host-minted `id`, `parent`
  = the latest revision it supersedes, `kind`, `base`, `declaration`,
  `entries`, `capturedAt` unix ms) plus blobs named by SHA-256.
- `Record` = manifest + service `sequence`, `publisher`, `host`, `publishedAt`,
  `contentDigest` (= `manifest.contentDigest`, hand-built canonical bytes, not
  JSON), and optional `drift`.
- `State` = the live view: `latest` record, every `RevisionSummary`
  (id, sequence, digest, applicability) and every `ReviewState`.
- `Applicability`: `.current` | `.superseded(by:)` | `.sourceChanged(Drift)`.
  A review is pinned to (object, revision, contentDigest) and is NEVER carried
  to a newer revision. Only `.current` means "the reviewed bytes are the
  owner's latest and the owner's host has not reported drift".

## Coverage

`Declaration` says which changes are in the revision: range
(`files | workingTree | staged | branch`), committed/staged/unstaged/untracked
flags, and COUNTS of omitted changed and omitted untracked paths. Names of
unselected paths are never published. `branch` is `mergeBase...head`
committed changes only. Untracked content appears only when its path was
explicitly selected.

Per selected `Entry`: repository-relative `path` (never absolute, never `..`),
`change`, `coverage` (`included | binary | oversized | symlink | submodule |
unavailable`). Only `included` carries `blob`, `length`, `mediaType`
(`text/plain` file bytes, `text/x-diff` per-path patch). `sourceDigest` is the
owner's working-file hash at capture, used only by the owner's host for drift.

## Limits

1 MiB per blob, 8 MiB per revision, 64 MiB of artifact blobs per area,
256 entries, 1 KiB paths. Over-limit uploads are refused (413).

## Routes (prefix `/collaboration/v1`, bearer auth on all)

| Method and path | Who | Meaning |
| --- | --- | --- |
| `PUT /areas/{a}/artifacts/{o}/blobs/{sha256}` | source owner, from the source host's device | Stage raw bytes; 400 `hashMismatch` if bytes do not hash to the path digest |
| `POST /areas/{a}/artifacts/{o}/revisions` | same | Body `PublishRequest{epoch, manifest}`; 409 `revisionConflict` if `parent` is not the latest; same id+digest = duplicate receipt; same id, other content = 409 `changedIntent` |
| `GET /areas/{a}/artifacts/{o}` | any member | `State` |
| `GET /areas/{a}/artifacts/{o}/revisions/{r}` | any member | `Record` (pinned) |
| `GET /areas/{a}/artifacts/{o}/revisions/{r}/blobs/{sha256}` | any member | Raw bytes; only digests listed as `included` in THAT revision |
| `POST /areas/{a}/artifacts/{o}/reviews` | discuss (editor/owner) | Body `ReviewRequest`; returns `Review` pinned to the revision |
| `POST /areas/{a}/artifacts/{o}/revisions/{r}/drift` | source owner device | Body `DriftReport`; marks that revision `.sourceChanged`; set-once |

## Nested boundary (COL-07)

A blob is reachable only as (area, object, revision, digest) where the caller is
a CURRENT member of the area, the object is CURRENTLY admitted there as an
artifact, the revision belongs to that object, and the digest is an included
entry of that revision. Blobs are stored per (area, object, digest): there is no
cross-area dedup, so a digest from another area, a staged-but-unpublished blob,
an unpublished object or a removed member all get the same 404 as an unknown
id. Bytes are AES-GCM sealed at rest with AAD binding area/object/digest.

## Host and recipient (Swift)

- Producer (owner host, Core): `SharedArtifactProducer` captures files or a
  diff from a checkout read-only (`GIT_OPTIONAL_LOCKS=0`), detects change
  during capture and returns `Collaboration.Artifact.Capture`.
- Applicability probe (owner host, Core): `SharedArtifactProducer.applicability(of:root:)`
  re-reads the source and returns changed-path count / base moved. Worker 8
  (freshness) can drive it and post `/drift`.
- Client (`CollaborationAPI`): `publishArtifact(area:epoch:capture:)`,
  `artifactState`, `artifactRevision`, `artifactBlob`, `reviewArtifact`,
  `reportArtifactDrift`, and `readArtifact(area:object:revision:)` which
  returns verified bytes in memory. The reader takes no filesystem path.
