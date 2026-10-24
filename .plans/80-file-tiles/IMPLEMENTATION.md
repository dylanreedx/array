# Local implementation record

Started 2026-10-24 from `81bb3717eec92bde6c987662d2771db57f591b0e` after Dylan requested local implementation. This is an incremental foundation, not completion of the format roadmap.

## Workspace and transfer

`git worktree add .worktrees/file-tiles -b array/file-tiles` failed with `Operation not permitted` while creating `.git/refs/heads/array/file-tiles.lock`. All implementation remains in `.worktrees/file-tile-research`, the isolated source archive. It is **not a registered worktree**. No branch, stage, commit, push, merge, release or production-app action occurred. Git commands in the archive discover the parent checkout; do not mutate Git there.

The canonical checkout's unrelated dirty work is untouched. A `ThirdParty` symlink points to the canonical checkout's existing binary dependency; SwiftPM copies its build inputs into the archive's own `.build`. Neither the canonical `.build` nor another bench's source is used for verification. No new package dependency was introduced. Transfer both changed and new files below into a real worktree once metadata is writable, along with this plan directory. Omit `.build`, `ThirdParty`, caches and transient QA output.

## Implemented foundation

- `Core/FileDocumentSession.swift`: `FileDocumentSession.load(path:)` produces an immutable `FileDocumentInitialLoad: Sendable`. It contains the preview and canonical path; `makeSession()` creates a mutable editing session on the receiving actor without I/O. Unsupported input creates no session. Existing initializers, save/refresh/recovery semantics remain available.
- `Canvas/FileTileNSView.swift`: ordinary initial and switched-document loads use that single snapshot instead of eagerly constructing a session and separately reading FilePreview. Async work has a retained task, cancellation and a separate load-generation fence. Rename and Trash/Restore restart initial admission where no text session exists. A binary document can be left without querying a stale retained WebKit document. Recovery is exceptional: a real saved recovery draft may still materialize a session for an unavailable file and perform another read.
- `Core/DelimitedTextParser.swift`: bounded incremental strict UTF-8 parser with explicit separator and limits, optional UTF-8 BOM, exact string cells, quoted multiline values and doubled quotes. It emits completed records synchronously rather than retaining a whole dataset. Errors are typed and sticky. UTF-16 decoding, dialect/header inference, indexing, page caching and UI are not implemented. Default parser limits are defensive development defaults, not measured user-facing capacities.
- `scripts/probe-file-tile-images.swift`: independent real ImageIO probe; observed capability and fixture results are in [image-probe-results](image-probe-results.md). This is exploratory evidence, not a released support table.

Existing factory, scene residency, project/zone placement, persistence schemas and workspace API properties are unchanged. No new renderer, visible image viewer, data grid or workbook provider has been connected. The complete coordinator/factory and observation work described in ARCHITECTURE remains pending.

## File inventory

Changed existing files (paths below are relative to the archive):

- `Sources/ContinuumRevivedCore/FileDocumentSession.swift`
- `Sources/ContinuumRevived/Canvas/FileTileNSView.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `Sources/ContinuumRevived/App/EditorNavigationChecks.swift`
- `Sources/ContinuumRevivedCoreChecks/main.swift`
- `scripts/run-matrix.sh`
- `docs/38-tickets/90-agent-ux/matrix-inventory.txt`

New implementation/check files:

- `Sources/ContinuumRevivedCore/DelimitedTextParser.swift`
- `Sources/ContinuumRevivedCoreChecks/DelimitedTextParserChecks.swift`
- `Sources/ContinuumRevivedCoreChecks/FileDocumentInitialLoadChecks.swift`
- `Sources/ContinuumRevived/App/FileInitialLoadChecks.swift`
- `scripts/probe-file-tile-images.swift`

## Witnesses and validation

Core RED: an independent executable compiled against the original loading flow reported `Initial reads: 2; expected 1` and exited 1. Core GREEN: new initial-load tests verify one read, mutation before session materialization, identical display/baseline text, BOM, unsupported/missing/nonregular/size boundaries and save-conflict protection. CSV checks cover all two-chunk split positions in independent small fixtures, byte-by-byte Unicode/BOM/CRLF input, exact identifiers/whitespace/formula-looking values, ragged rows, typed errors and every configured bound. A 10,000-row stream retained at most 8 payload bytes. An intentional quoted-newline mutation failed the parser checks.

New Core flag: `--file-content-foundation-check`. New app flag: `--file-initial-load-check`. Both are registered in `run-matrix.sh` and the literal inventory. The app witness controls the actual asynchronous host loader with a semaphore, captures the pending task, then awaits the whole task before asserting no stale publication after rename, Trash/Restore or removal. It also checks binary rename. This is host coverage; it does not replace production-mount scene/API checks. Existing editor-navigation coverage now includes text → binary → text.

Build commands use a private build folder (the archive's `.build`), two jobs, and writable temporary SwiftPM/module caches:

```sh
swift build --disable-sandbox --product ContinuumRevivedCoreChecks --jobs 2 --cache-path /tmp/array-file-tiles-cache --config-path /tmp/array-file-tiles-config --security-path /tmp/array-file-tiles-security -Xswiftc -module-cache-path -Xswiftc /tmp/array-file-tiles-modules
swift build --disable-sandbox --product Array --jobs 2 --cache-path /tmp/array-file-tiles-cache --config-path /tmp/array-file-tiles-config --security-path /tmp/array-file-tiles-security -Xswiftc -module-cache-path -Xswiftc /tmp/array-file-tiles-modules
```

The initial SwiftPM attempt without `--disable-sandbox` failed because nested `sandbox-exec` was denied. The first app build failed because its source was edited during compilation; it was restarted after source edits stopped. These are recorded failures, not passing builds.

Core product build and both `--file-content-foundation-check` and existing `--file-document-session-check` passed. Matrix inventory validation and shell syntax validation passed. App product build passed (79.49 seconds on the stable incremental build). `--file-initial-load-check` and `--file-markdown-preview-check` passed using unique temporary project and app-support directories with tmux disabled. `--editor-navigation-check` failed with `timed out awaiting real WebKit bridge`; `--file-markdown-perf-check` failed at the existing clipboard byte comparison. Both failures reproduced with the same messages after rebuilding the baseline production sources (234.08 seconds); neither was added to KNOWN-RED. The WebKit failure prevents reaching the newly added navigation assertions, so those assertions remain unverified here. System output includes sandbox-extension denials, but the exact cause of each baseline failure has not been established.

For the baseline comparison, the four changed production files were temporarily replaced with their baseline versions, and the new app check file was held outside Sources. A `finally` block restored every implementation source afterward. Final implementation rebuild passed (312.35 seconds). The checks product was rebuilt afterward. All seven final focused legs passed: `--file-content-foundation-check`, `--file-document-session-check`, `--file-initial-load-check`, `--file-markdown-preview-check`, `--workspace-api-open-check`, `--workspace-api-grants-check`, and `--workspace-scene-owner-check`. The scene-owner check exercised the production boot mount and round-trip hydration/geometry; the API checks covered production open/grants paths. Final result codes are in `qa-runs/file-tiles-foundation/final-results.json`. A review/transfer patch for the 12 implementation/check files is in that same directory as `implementation.patch`; it excludes plan documents, which must also be transferred. Transient output is under `qa-runs/file-tiles-foundation/`; build logs are `/tmp/array-file-tiles-{core,app,baseline}-build.log`. No bare CoreChecks run, default tmux socket, managed-agent marker override, production project/app, visual baseline update or release action was used.

## Remaining gates

No full matrix or bundle/appearance QA has run. Merely registering the checks does not satisfy the release gate: a real full matrix must report these legs. Scene mounting/API/grants, supported macOS floor, Quick Look provider/input/resource behavior, large-image budgets, grid feasibility/VoiceOver and mixed-canvas performance remain pending. Existing local text reads remain synchronous; cancellation suppresses stale publication but does not interrupt synchronous filesystem I/O. The initial snapshot unifies displayed text and editing baseline; it does not yet implement the complete authorized-handle/revision validation contract.

The performance bench currently has `ff881cd2` above the research base and dirty canvas/app integration work. Its residency path was left unchanged; rebase onto its landed interface before new bodies are integrated. Do not copy or overwrite its unpublished work.
