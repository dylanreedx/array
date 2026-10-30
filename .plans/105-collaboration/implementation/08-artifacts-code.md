# 08 — Shared artifacts, local changes and previews

29 October 2026. Implementation research only. Source inspection, not runtime verification. No app/provider/tmux invocation, Git mutation, or repository-content operation was performed. The only write is this planning memo.

## Feasibility and recommended first behavior

Sharing local changes is implementable without synchronizing either developer's checkout. Publish a deliberately selected, immutable artifact revision into a shared area; let other participants inspect it, discuss it and deliberately use it as context for their own agents. The source stays on its owning host. A live artifact reference can advance to new revisions while comments/reviews remain pinned to their original revision.

The first deliverable should be bounded text/file and diff artifacts plus explicit still-image previews. It should not claim transparent file replication, a shared remote terminal, session migration, or automatic reachability of a localhost browser. These are separable later capabilities, not prerequisites for coordinating isolated agents.

## Existing code and its actual limits

| Source | Reusable behavior | Gap for collaboration |
| --- | --- | --- |
| [GitDiffEngine.swift](../../../Sources/ContinuumRevivedCore/GitDiffEngine.swift) | Read-only `git diff`, structured Codable `GitDiffModel`, size/time limits; working tree versus HEAD or branch three-dot merge-base range | No immutable revision envelope. Working-tree mode does not include untracked content. Branch range does not include current staged/unstaged working-tree changes. No explicit selected publication manifest. |
| [AgentDiffSource.swift](../../../Sources/ContinuumRevivedCore/Agents/AgentDiffSource.swift) | Reports isolated-agent branch changes; refuses per-agent attribution on a shared working tree | Branch-level diff is not all current live agent edits. Base branch is supplied by caller, not durably captured as an immutable base. Attribution cannot be manufactured for non-isolated agents. |
| [DiffReviewSource.swift](../../../Sources/ContinuumRevivedCore/DiffReviewSource.swift) | Chooses local diff source and metadata | Names movable branches and local computation, not a portable historical artifact revision. |
| [DiffReviewTileNSView.swift](../../../Sources/ContinuumRevived/Canvas/DiffReviewTileNSView.swift) | Read-only renderer; detached Git load and stale-result suppression; bounded structured model | Currently resolves a local repository. A remote read-only variant must accept an already authorized artifact model without reading local disk/Git or installing another executor. Existing source picker is stock AppKit; do not repeat that legacy pattern in new shared UI. |
| [FileDocumentSession.swift](../../../Sources/ContinuumRevivedCore/FileDocumentSession.swift), [FilePreview.swift](../../../Sources/ContinuumRevivedCore/FilePreview.swift) | One initial disk read establishes a draft/baseline; revision checks, explicit conflict/unavailable states; 1 MiB text-preview budget | File paths and recovery records are host-bound. Do not sync the live editor/recovery record as the shared artifact. Binary/large inputs need explicit unsupported or separately handled outcomes. |
| [TranscriptSyncMessages.swift](../../../Sources/ContinuumRevivedSync/TranscriptSyncMessages.swift), [TranscriptProjectionSender.swift](../../../Sources/ContinuumRevivedSync/TranscriptProjectionSender.swift), [TranscriptProjectionReceiver.swift](../../../Sources/ContinuumRevivedSync/TranscriptProjectionReceiver.swift) | Encrypted semantic snapshots, versions, subscriptions; encrypted managed-media/tool-detail message types with no source URL in detail response | Companion transcript scope is not shared-area ACL. Inspected detail messages are not a durable generic blob upload/download service. General artifact authorization, integrity, retention and rejoin retrieval must be added. |
| [RelayProtocol.swift](../../../Sources/ContinuumRevivedRelayProtocol/RelayProtocol.swift), [RelayStore.swift](../../../Sources/ContinuumRevivedRelayCore/RelayStore.swift) | Durable bounded event payloads, sequence/replay and snapshot behavior | Current event limit is 8 MiB and retained tail-byte budget 16 MiB. No general artifact blob store/API was found in the inspected relay source. Do not place unbounded media or every file version in the presence/event feed. |
| [BrowserEngineContext.swift](../../../Sources/ContinuumRevived/BrowserEngine/BrowserEngineContext.swift), [BrowserState.swift](../../../Sources/ContinuumRevivedCore/BrowserState.swift) | Project-scoped WebKit data stores; URL/title/tab state and opaque interaction state | Cookies, login state, navigation history and interaction state are not portable collaboration material. A URL may contain confidential query/fragment data. |
| [BrowserCredentialPolicy.swift](../../../Sources/ContinuumRevivedCore/BrowserCredentialPolicy.swift) | Explicit origin decisions, narrow loopback matching | Existing local credential-fill rules do not authorize remote browsing or tunnel access. |
| [BrowserSnapshotTileNSView.swift](../../../Sources/ContinuumRevived/Canvas/BrowserSnapshotTileNSView.swift) | Transient bitmap representation of a suspended local browser | It is a local residency placeholder, not an implemented shareable screenshot artifact. A new publication lifecycle is needed. |
| [WorktreeManager.swift](../../../Sources/ContinuumRevivedCore/Agents/WorktreeManager.swift) | Local worktree lifecycle, branch ownership and safe cleanup | No cross-machine patch import or collaboration integration transaction was established in this inspection. |

The existing I5 host-bound-path boundary means arbitrary local paths must stay local. A new artifact projection may deliberately expose selected repository-relative labels/content under explicit sharing permission; do not serialize host-bound source records or loosen the existing companion taint scanner globally.

## Proposed artifact contract

An artifact belongs to a shared area and has a stable ID. Each published revision has immutable content and:

- Owner person, publishing device/host, originating shared object and optional agent/session/turn reference.
- Repository identity safe for sharing, opaque checkout identity, relative selected paths, captured base/head object IDs where applicable, and a declaration of the range represented.
- Content digest, byte length, media/type metadata, capture timestamp, manifest version and publication sequence.
- A completeness declaration: which tracked, staged, unstaged, untracked, binary, rename/deletion/submodule states were included, excluded, unsupported or unavailable.
- Stable immutable payload reference; the separate live pointer can name the latest available revision.

Do not claim filesystem-wide atomic capture. Build a snapshot from exact captured bytes and validated metadata; detect drift before publishing a coherent claim, retry within a bound or publish an explicit changed-during-capture result. A digest proves the captured bytes, not that every file existed at one universal instant. A captured commit/tree offers stronger repository consistency than an actively changing working tree. Untracked files must be explicitly selected and bounded rather than recursively uploaded as a side effect of sharing a diff.

Git's binary/change models may be enough for a displayed summary, but not necessarily an applyable patch. Keep review payloads and source-transfer payloads separate. A renderer-friendly `GitDiffModel` alone does not define exact file bytes, Git modes or conflict behavior required for integration.

Comments identify artifact ID + revision + stable location/context anchor. After a live pointer advances, retain the old review target and mark it superseded. Check results identify their actual code/artifact revision, not just a tile. Never carry a completed review or check result to a newer revision silently.

For small initial artifacts, bounded inline payloads within a new collaboration event protocol may be sufficient if retention and replay are guaranteed. Larger payloads need separately authorized, content-addressed blob storage with per-area references, byte quotas and garbage collection. Choose inline thresholds using measured envelope/base64 overhead; the existing relay's maximum is not a recommended publication size. A hash is integrity identity, not authorization: cross-area blob dedup must not make content obtainable by guessing a digest.

## Browser/preview modes must be explicit

| Mode | Meaning | Recommendation |
| --- | --- | --- |
| Shared link | Recipient opens the URL using their own network/account | Useful for reachable deployments. Verify URL class, show destination, exclude opaque WebKit state and cookies. Do not imply same page state. |
| Published snapshot | Explicit image captured on the owner's host with timestamp and provenance | Suitable first preview artifact, including a local-only dev page. Review included content; bounded encoding and authorized artifact retrieval. A snapshot cannot be clicked to operate the source browser. |
| Remote frame stream | Owner renders pixels; recipients observe a live stream | Later scoped media subsystem with backpressure, host availability and clear observation status. Existing iOS multipart receiver is a pattern, not a ready browser-sharing protocol. |
| App/port tunnel | Recipient interacts with an exposed development service | Later capability spike: localhost rewriting, WebSocket/HMR, origin/host validation, app authentication, revocation and host downtime are real work. No generic arbitrary-host proxy. |
| Shared browser control | Participants operate one host browser | Distinct authority beyond observation, with interaction ownership and source account consequences. Not needed for first shared work area. |

A colleague opening `http://localhost:3000` reaches their own machine. Merely publishing the URL does not solve reachability. Publishing an image can expose logged-in content even without copying cookies, so the publication review must show the selected content and actual audience. Treat snapshot content as deliberately shared, not automatically sanitized by excluding storage state.

## Code integration choices

| Option | Feasibility judgment |
| --- | --- |
| Remote read-only artifacts | Recommended initial capability; no checkout writes, sufficient for useful review/context exchange. |
| Explicit patch/file package import | Viable later. Require source/base identity, selected immutable bytes, destination checkout confirmation, conflict detection and no partial-success ambiguity. Validate paths against traversal/symlink escape and refuse unsupported modes. Receiving an invitation must never trigger it. |
| Commit/branch exchange | Viable where both participants have repository access; use their own Git transport/auth. A shared commit hash is not enough if recipient cannot fetch objects. Avoid automatic merge/cherry-pick on receipt. |
| Automatic working-tree replication | Larger, risky product: concurrent local edits, ignored files, generated state and active agents require a true conflict/ownership model. Defer from the initial roadmap. |
| Common hosted environment | Separate execution product; can make code inherently shared but introduces runtime, secrets, billing and availability responsibility. |

The code-transfer phase should follow observed demand: if participants primarily need to plan and compare results, a review-only first version removes the prompt-file coordination burden without solving full remote development.

## Ticket candidates

### ART-1 — Publish selected immutable diff/file revisions into a shared area

Outcome: a person publishes explicitly selected local artifacts; authorized members retrieve exact immutable revisions without acquiring local paths, filesystem control or file synchronization.

Scope: portable artifact manifest/payload; host-side bounded capture off main; area authorization on every publication/read; a separate live-latest reference; byte/time budgets; publication state and cleanup/retention. Include declaration of untracked/binary/oversize omissions. Preserve existing companion protocol separation.

Dependencies: shared-area identity/membership and durable authenticated event/storage service. Requires an explicit inline-versus-blob decision before implementation.

Acceptance and witnesses: temporary repositories with staged/unstaged/new untracked files, renames/deletions and binary/oversize files; source edits during capture cannot create a false coherent revision; snapshots reproduce identical bytes after host goes offline; excluded files and absolute host paths never reach serialized payloads; cross-area and revoked-member reads fail at the service; replay does not duplicate content. Register Core/relay behavior checks in the matrix, asserting actual responses and bytes.

### ART-2 — Render remote revisions and keep review/check feedback pinned

Outcome: collaborators inspect a remote artifact without a local clone; comments and check evidence remain attached to the reviewed version while the source continues changing.

Scope: remote read-only diff/file presentation using existing typography/render models; author/host/provenance; live/pinned mode; explicit changed-since-review state; unavailable/partial/cached states; no accidental local-file fallthrough or second runtime.

Dependencies: ART-1, shared-area surface projection and discussion/artifact references. No cross-checkout writes in this ticket.

Acceptance and witnesses: owner publishes A, reviewer pins A, owner publishes B; reviewer still reads A and new-version indicator links to B; comment/check result never silently applies to B; duplicate refresh/reopen remains the same artifact, no runner starts and no local file is written. Production canvas mount witness across workspace switch/relaunch with remote-only and host-offline data; light/dark native appearance and bounded large-diff render work recorded through the actual matrix leg.

### ART-3 — Publish explicit preview snapshots and label reachable links honestly

Outcome: captured browser areas can include a still preview with identity/time, or a normal shared link; local-only URLs never masquerade as usable teammate previews.

Scope: explicit snapshot publication into authorized artifact storage, URL classification/review, no WebKit interaction-state/cookie export, cached/offline display and bounded image decoding. No tunnel, stream or shared browser input.

Dependencies: ART-1/storage, capture-area review UI and surface metadata; no generalized remote browsing dependency.

Acceptance and witnesses: loopback URL remains labeled host-local and is not auto-opened on another client; reachable URL opens only deliberately using recipient context; WebKit state/cookies cannot be found in serialized payloads; selected snapshot contains the intended rendered content and cannot grant input control; revoked/unauthorized fetch, oversized image and malformed encoding fail cleanly. Use isolated static fixture web pages and local artifact service in matrix; no user browser session or external site required.

## Deferred implementation investigation

Explicit **Bring selected changes into my checkout** deserves its own later ticket, not a hidden button inside view access: immutable export specification, path validation, destination/base preflight, dry-run/conflicts and transactional outcome recovery must be designed first. Active recipient work and concurrent agent edits are refusal/conflict cases, not license to stash/reset them. Shared-agent control or invitations never grant automatic Git mutation.

No timings, transfer bandwidth costs, production blob service, snapshot-image capture pipeline, patch-import behavior or actual cross-machine review flow were benchmarked or tested here. All proposed witnesses remain future implementation work.
