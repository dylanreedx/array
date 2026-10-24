# Implementation slices for expanded file tiles

Read [START HERE](START-HERE.md) before commands. Rich image/data implementation is integrated locally; see [CURRENT IMPLEMENTATION](CURRENT-IMPLEMENTATION.md) for concrete ownership and current scope. [IMPLEMENTATION](IMPLEMENTATION.md) records the earlier foundation slice. The original slices below preserve planning context; the status ledger describes current execution. Research describes baseline `81bb3717`; find current symbols rather than relying on historical line numbers. Implement only the selected slice and necessary shared seams.

Active execution now uses the real `file-tile-previews` bench based on `fe734156`. The slice ledger retains the original implementation baseline; new-base rebuild and gate results are recorded under `active_bench` in verification.json.

## Source map

| Concern | Starting point |
| --- | --- |
| Text classification and admission | `Sources/ContinuumRevivedCore/FilePreview.swift` |
| Draft, baseline, save and conflicts | `Sources/ContinuumRevivedCore/FileDocumentSession.swift` |
| Host, navigation, theme, monitoring, focus and surface hooks | `Sources/ContinuumRevived/Canvas/FileTileNSView.swift` |
| Identity and persisted editor/tile metadata | `Sources/ContinuumRevivedCore/DocumentLocation.swift`, `CanvasState.swift` |
| Interactive and explicit API open | `Sources/ContinuumRevived/App/WorkspaceRuntime.swift`, workspace API service/resolver |
| Spawn, boot and hydration | `Sources/ContinuumRevived/App/TileSpawner.swift`, `ContinuumApp.swift` |
| Existing residency contract | `Canvas/TileNSView.swift`, `Canvas/CanvasNSView.swift` under the app target |
| Image pipeline precedents | `CanvasBackgroundImageCache.swift`, `ComposerImageThumbnailPipeline.swift`; locate with `rg --files` |
| Styled choice controls | `ChoiceButton`, `ChoicePopoverController`, `ChoiceListView` |
| Existing behavioral coverage | `FileOpenChecks.swift`, `FileDocumentSessionChecks.swift`, editor/residency checks |
| Gate and inventory | `scripts/run-matrix.sh`, `docs/38-tickets/90-agent-ux/matrix-inventory.txt` |

## FT0 Establish platform behavior and fixtures

Read image, delimited-data, workbook and performance research as needed. Build a fixture manifest with small independent expected values and provenance. Probe ImageIO runtime types and real promised images, and embed Quick Look against actual workbook fixtures on the supported OS floor/current OS. Record missing environments as missing coverage. A Finder thumbnail is not an embedded-view witness.

Measure baseline resource work and qualify native table reuse, wide-column scaling, rectangular selection and VoiceOver. Select per-format admission/cache/index limits from those results. Resolve static SVG scope and workbook preview coverage. No production support claims before the probes pass.

For Quick Look, qualify the provider boundary explicitly: choose verified immutable staging or another evidenced read-time policy; exercise source-path replacement and workbook external links/resources. Establish temporary snapshot/package limits, cleanup, format compatibility and active-preview limits. Measure provider/service resources as well as Array-held bytes. Ordinary successful rendering does not prove those guarantees; see ARCHITECTURE's system provider boundary.

Exit: explicit supported/partial/unsupported table; selected limits with rationale; provider and OS evidence; grid feasibility result; recorded base and performance dependency. Parser fixtures may be developed in parallel with platform probes if authorized.

## FT1 Extract the host boundary

First land a failing witness for the eager text-session/duplicate-read behavior and the desired binary dispatch. Introduce classification before text session construction, one authorized loaded revision, bounded scheduling and generation ownership. Wrap existing source/Markdown presentation rather than rewriting it. Reuse the landed residency lifecycle and retain the same `.file` identity.

Audit init, switchDocument, rename/trash, reload, scene draft capture, removal, boot, spawn and hydration. Ensure every construction route reaches the same content selection. Preserve callbacks supplied by configureFileEditor, source line reveal, navigation and canonical dedupe. Add a reusable host lifecycle harness.

Exit: existing editing/recovery/conflict/navigation witnesses remain green; no binary text session; no duplicate initial full reads in the new contract; stale completion/removal checks pass through production mounting. No new production renderer is necessary to hide a failing extraction.

## FT2 Add images

Connect an ImageIO-backed bounded still renderer, revision/size-aware shared cache and limited decode queue. Add fit/actual-pixel controls, metadata, pan/zoom and transparency using existing styling. Preserve orientation/color/alpha; label first frame/page and downsample limits. Optional codecs use actual capability plus decoding. SVG remains gated separately.

Exit: independent pixel/orientation fixtures, visible mounted image and failure states, exact lifecycle contract, bounded resource counts and zero decode work during unchanged camera motion. Retina actual-pixel semantics and image-versus-canvas gesture ownership are verified.

## FT3 Add delimited data

Develop Core parser/index tests first: chunk boundaries, quoting, Unicode, ragged rows and exact strings. Add sparse indexing and bounded page cache; define record/field/index limits and cancellation. Build the native grid with both-axis bounds, header/dialect/encoding choices, cell inspector, selection/copy, navigation and find. Show indexing and query scope. Add small-file source mode only with same-draft behavior and existing safe text-save semantics.

Exit: parser fixtures plus real visible cell outcomes, full-value copy, no coercion, bounded tall/wide scaling, external mutation while indexing, dirty-draft transitions and VoiceOver/keyboard acceptance. Global sort/filter remains unavailable unless complete-file or clearly labelled subset semantics are implemented and witnessed. Do not add grid write-back in this slice.

## FT4 Add workbook previews

Use a narrow embedded Quick Look adapter only for coverage qualified in FT0. Handle provider failure, unsupported/locked/corrupt files, external updates, focus, autostart and terminal close/recreation correctly. Do not assume access to provider-owned cell/sheet controls. Offer external open and accurate status.

Use the FT0-qualified input policy rather than handing an unverified mutable source path to the provider. Ensure snapshot ownership survives asynchronous preview loading and ends on disposal; source revisions produce new generations. If resource or external-reference behavior cannot satisfy the documented contract, narrow embedded format support and retain external handoff.

Exit: deterministic host failure/cleanup checks and actual workbook fixture smoke; original file hashes unchanged; no text session/recovery; multi-tile/switch/close resource behavior qualified. The initial provider approach was superseded by an explicit bounded native XLSX decision; see CURRENT-IMPLEMENTATION.md for the rationale and narrower format contract.

## FT5 Optional PDF

Proceed only after required slices pass. Native read-only PDFKit body with page/zoom/selection, controlled links/actions, locked/error states and valid viewport restore. No annotations/forms/write-back promise.

Exit: mounted PDF content, lifecycle/resource and interaction fixtures; no unexpected file mutation or action execution; required scope remains on schedule.

## FT6 Integrate and qualify the release

Run the combined mixed-canvas fixtures, current API grants/open/exposure checks, persistence/restore coverage and appearance/accessibility review. Register actual flags and literal inventory entries before the full matrix. Confirm every required new leg appears in its final summary; explain all skips and current KNOWN-RED. Perform dev bundle smoke with isolated project state and follow the current release owner's process.

Exit: verified support matrix, red/green logs, resource results, visual artifacts, matrix summary, user-facing format limits and reviewable changes. No version bump or publication follows automatically from this plan. Return the real bench only after work is preserved/landed according to current instructions.

## Status and evidence ledger

Replace pending entries as work completes. Never record a proposed command or research inference as a passing check.

| Slice | Status | Implementation base | Evidence | Remaining decision |
| --- | --- | --- | --- | --- |
| FT0 | Current-Mac image fixtures and bounded native backend selected | `81bb3717` | image-probe-results.md, CURRENT-IMPLEMENTATION.md | Minimum OS and optional codec fixtures remain unqualified |
| FT1 | Implemented; focused production lifecycle qualification passes | `81bb3717` | Native builds and initial-load/API checks pass | Full release matrix and integration |
| FT2 | Implemented; native image checks pass | `81bb3717` | ImageIO pixels/orientation/limits/retina/light-dark checks | Supported OS coverage |
| FT3 | Implemented; parser, encoding, projected grid and scheduler checks pass | `81bb3717` | Core backend + native grid checks | Supported-OS and release qualification |
| FT4 | Native read-only XLSX implemented; Core checks pass | `81bb3717` | CURRENT-IMPLEMENTATION.md, Core backend checks | Native scene/appearance passes; other workbook formats external-only; broader OS/release qualification remains |
| FT5 | Optional, deferred | — | None | Outside required image/data scope |
| FT6 | In progress | `81bb3717` archive | Registered matrix/inventory and focused checks | Final matrix, UI inspection, transfer into writable Git worktree and release-owner integration |

Each evidence entry records the command, build/base, result, fixture/OS context and durable log or artifact path. Keep transient QA output out of Git; retain concise findings and required fixtures according to live repository rules.
