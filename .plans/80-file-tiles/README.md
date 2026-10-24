# Expanded file and editor tiles

Planning date: 2026-10-23. Target: the next release after the incoming canvas performance work, subject to the gates below. Baseline: `81bb3717eec92bde6c987662d2771db57f591b0e` on `array/integration`.

Array should let a user inspect the files an agent produces without leaving the canvas: images, datasets, spreadsheets, and reports. The proposed first release adds bounded native image viewing, a CSV/TSV data grid, and embedded workbook previews. PDF is the strongest additional format if the core scope passes early. Existing source and Markdown editing retain their save, recovery, and conflict behavior.

Read [LOCAL QUALIFICATION](LOCAL-QUALIFICATION.md) for commands, environment limits and transfer instructions. Read [CURRENT IMPLEMENTATION](CURRENT-IMPLEMENTATION.md) for the concrete architecture, supported local scope and limits. The original engineering proposal below is retained as rationale; the live status is in verification.json. The research index below records the evidence and unresolved platform questions.

## Agent reading order

Start with [START HERE](START-HERE.md) for workspace safety, status, scope and the pickup checklist. Then read [ARCHITECTURE](ARCHITECTURE.md), [EXECUTION](EXECUTION.md) and [TESTING](TESTING.md). This README is the product proposal and decision summary. Research notes explain alternatives and evidence; they are not competing implementation specifications. Where research proposals differ, the execution documents and the current explicit user instruction govern.

Native image, delimited and bounded XLSX viewer code is integrated. Focused Core/native/production-scene checks pass; broader matrix and release evidence are tracked separately. CURRENT-IMPLEMENTATION specifies the implemented budgets and lifecycle interfaces; supported-OS and optional-codec coverage remain release qualifications. Active source is now in the real `file-tile-previews` worktree on `array/file-tile-previews` at base `fe734156`; the older research archive remains preserved. Read START-HERE before Git operations.

## Scope for the next release

| Files | Proposed experience | Release condition |
| --- | --- | --- |
| PNG, JPEG, GIF, TIFF, BMP, HEIC/HEIF and other runtime-supported image formats | Native image viewer with fit, actual pixels, zoom, pan, transparency background and dimensions | Bounded decode and cache; fixtures prove each advertised family on supported macOS versions |
| WebP, AVIF, camera RAW and unusual raster formats | Same viewer when the running OS decoder succeeds | Runtime capability and fixture results determine the advertised support; an extension alone proves nothing |
| SVG | Static preview only through a renderer that passes local-file and external-resource tests; source remains available within text limits | No unrestricted web page loading; SVG can contain active content and references |
| Animated or multipage images | Clearly identified first frame/page initially; playback or page selection only when bounded | Never silently imply the entire animation or image collection is displayed |
| CSV and TSV | Read-only, virtualized data grid, header/dialect controls, selection and copy; source/edit for small text files | Exact strings preserved; large files use bounded indexing; query scope is explicit |
| XLSX | Native read-only sparse data grid, visible sheet picker, raw values and cached formulas | Bounded ZIP/XML/value fixtures and production mounting |
| XLS, XLSB, XLSM, ODS, Numbers | External-open fallback | Embedded provider support remains unqualified |
| PDF | Native PDFKit viewer with pages, zoom and text selection | Optional release slice after required image/data/workbook scope; bounded residency |
| JSON, JSONL and NDJSON | Existing source editor initially; structured data view in the next slice | Do not expand near-release scope with a second data parser until CSV lifecycle is proven |

Workbook preview does not promise cell editing, formula evaluation, or a universal sheet grid. If interactive XLSX sorting/filtering is essential to this release, give that a separate gated slice and adjust the release scope. A workbook reader must correctly handle date systems, shared and inline strings, sparse rows, errors, formulas with missing cached values, hidden sheets and merged cells before its cells can be presented as trustworthy data.

## Why the shared file path needs to change

`FilePreview` currently admits UTF-8 text up to 1 MB and chooses source or Markdown by path. `FileTileNSView` constructs `FileDocumentSession` before loading the preview, so it can perform a text-session read and a second preview read. Local loads are synchronous. Merely putting the new decoder in `loadFile()` leaves the eager text read intact.

The file tile already owns document navigation, a sidebar, editor state, draft recovery, external-change detection, CodeMirror, Markdown, focus, surface snapshots and teardown. Adding format branches throughout that class would multiply those responsibilities. Extract a small renderer boundary around the existing text behavior, then attach new viewers to it. Do not rewrite the editor or create unrelated tile kinds.

Relevant starting points:

- `Sources/ContinuumRevivedCore/FilePreview.swift`
- `Sources/ContinuumRevivedCore/FileDocumentSession.swift`
- `Sources/ContinuumRevived/Canvas/FileTileNSView.swift`
- `Sources/ContinuumRevived/Canvas/TileNSView.swift`
- `Sources/ContinuumRevived/App/WorkspaceRuntime.swift`
- `docs/internals/performance.md` and `docs/internals/scalability-tdd.md`

## Proposed architecture

Keep one persisted file tile identity and the existing production open/hydrate paths. Classify the file before constructing any text editing session. Platform-neutral descriptors and delimited parsing belong in Core; ImageIO, AppKit, QuickLookUI and PDFKit remain in the app target. No platform framework dependency flows into Core or iOS.

The host owns document identity, navigation, file access, generation fencing, reload state, focus and tile chrome. Each renderer owns its bounded presentation and transient viewport state. An editable text renderer alone owns `FileDocumentSession`, recovery and language services. A viewer must not create a text draft merely because a binary file has been opened.

Proposed renderer operations are load, activate, suspend, reload, restore view state and dispose. Final names and protocol shape should follow the landed residency work; this is a behavior contract. Every asynchronous result must carry both document identity and a load generation, and be discarded after navigation, reload, removal or workspace teardown. Cancellation must stop queued work as well as prevent stale UI publication.

Classification combines path hints, UTType/resource metadata and bounded content validation. Reject special files and unintended directory reads before opening data streams. Treat package formats deliberately; a Numbers package cannot fall through a generic directory rejection or recursive scan. Explicitly selected text/source mode must remain available where safe. File metadata, external updates and errors use the same host state across renderers.

The host reports capabilities such as source, editable, zoomable, searchable and selectable. Controls follow those capabilities: no meaningless Edit toggle on an image and no workbook Save action when the viewer cannot preserve the workbook. New choice menus use the existing Choice components. Existing adjacent controls are not an excuse for a style cleanup in this project.

## Extension and ownership rules

Use a small internal factory with deterministic renderer selection and an explicit unsupported outcome. Avoid dynamic plugins, service discovery, a universal document model or a protocol for every class. Extract the boundary using existing text behavior and the first image viewer; expand it only when another real renderer needs the capability. Adding PDF should not require touching CSV parsing, text recovery or workspace placement.

| Boundary | Owns | Does not own |
| --- | --- | --- |
| File tile host | Document identity, navigation, chrome, focus routing, load generation and renderer lifecycle | Format parsing or format-specific cell/pixel models |
| Shared resource coordinator | Bounded I/O scheduling, cancellation, revision-aware shared resources and cache accounting | Editor drafts, UI selection or persisted tile placement |
| Format backend | Validated format data, paging/decoding and format-specific resource limits | Canvas, AppKit lifecycle or workspace navigation |
| Renderer | Visible presentation, local interaction and bounded view state | File writes, project selection or independent file-monitoring timers |
| Editable text session | Baseline/draft, conflict handling, recovery and explicit saves | Binary-file serialization or viewer cache policy |

Capabilities describe actual supported operations. Do not build a renderer protocol with required no-op save/search/zoom methods. Reuse the landed scene residency contract rather than adding a second visibility state machine. File revision and load generation are distinct: the first identifies the bytes represented, the second prevents an obsolete request from publishing. A renderer is disposed exactly once when replaced or retired; disposal is safe to repeat defensively and no completion may revive it.

Document each new format in a short entry containing its selection rule, capabilities, resource limits, errors/fallback, view-state schema and fixture cases. Version persisted view state independently where necessary, tolerate missing/unknown optional fields, and fall back to safe defaults if the file's dimensions or sheets change. Preserve the existing file location and tile identity. Decide the shared resource key from the authorized document scope and file revision; a cache hit must never bypass access checks.

## Data fidelity and large files

CSV/TSV values begin as strings. Preserve leading zeroes, long integer identifiers, whitespace, empty fields, duplicate/empty headers and ragged rows. Header detection is a visible guess with an override. Row numbers refer to logical records, not physical lines: quoted fields can span lines. Support escaped quotes and chunk-boundary splits; do not split the file with `components(separatedBy: "\n")`.

Use bounded background reads and a sparse row-offset index, decoding visible row windows into a bounded cache. Virtualize both rows and columns; creating a column object for every field can still exhaust resources on wide files. Qualify native reusable table cells against the required cell selection and accessibility behavior before choosing a custom-drawn grid. The index itself needs a size policy; virtualization alone does not bound retained data. Bound record length and field size, and show a recoverable error when limits are reached. Encoding and delimiter choices must be explicit when inference is uncertain. UTF-8 and BOM-marked Unicode are first-class fixtures; do not silently replace undecodable bytes.

The first usable grid includes row/column navigation, range selection, copy, a cell inspector for long values and clear indexing progress. Search/sort/filter can ship only with honest scope: either the complete indexed file or a prominently labelled preview subset. Never sort the first loaded page while implying a global result. Stable ordering retains original record identity. Sorting and filtering are view transformations; they never rewrite the source.

Small CSV source editing reuses the existing text editor and its conflict protections. Switching to the grid renders the current unsaved draft or explicitly asks the user to resolve it; it must not silently show old disk bytes. Large grid-only files stay read-only in this slice. No spreadsheet formula execution occurs in the data grid.

## Image behavior

Use ImageIO source metadata and thumbnail/downsample APIs to decode for display demand. Compressed file size is not a decoded memory budget. Preserve orientation, alpha and color profiles, and label when viewing a first frame/page. Fit is the default; actual-size semantics must be tested at Retina scale. Image pan/zoom gestures must coexist with canvas navigation and keyboard focus.

Use a shared cost-bounded image cache and a small decode queue rather than one unconstrained task/cache per tile. Cache identity includes file revision and decode size bucket. Camera motion must not decode the image on every tick; refine resolution after demand settles. File replacement invalidates both content and surface snapshot generations.

The running system's decoder capabilities determine optional formats. Probe and decode rather than hard-code an unconditional promise for every extension. SVG requires a separate static strategy; network-denied rendering alone does not prevent unintended reads of neighboring local files.

## Workbook behavior

Use embedded `QLPreviewView` as the first workbook adapter, not a global preview panel shared across tiles. Make provider-dependent support visible in errors and release claims. Define loading, unsupported, encrypted/password-protected and changed-file states. Verify whether the provider shows multiple sheets and cached formula output for the actual fixtures; do not infer that from the container extension.

Provider-owned reads and resources require a separate FT0 qualification: choose verified immutable staging or an evidenced read-time policy, test external references, and measure provider/service retention. Passing a URL to Quick Look does not automatically enforce Array's loader budgets or access contract. See [the system provider boundary](ARCHITECTURE.md#system-provider-boundary); formats that cannot qualify remain external-only.

Dispose of the preview correctly: when the host manages closure (`shouldCloseWithWindow == false`), Apple requires `close()` when finished. Closing is terminal: that view cannot accept another preview item. Residency suspension and permanent disposal are different operations; if resource eviction closes a preview, resumption must create a new view. A parked preview must not leak services or keep doing hidden work, and an inactive tile must not capture shortcuts or focus. See [Apple's lifecycle contract](https://developer.apple.com/documentation/quicklookui/qlpreviewview/close()).

Defer a custom XLSX parser until the grid contract is solid. CoreXLSX is a candidate to evaluate, not a dependency decision. Its workbook semantics and expanded ZIP/XML memory behavior need an adapter, explicit limits and adversarial fixtures. No formula engine, macro execution, workbook writes or conversion service belongs in the first slice.

## Performance integration

The active `canvas-motion-perf` bench modifies the file tile, base tile and canvas residency/motion seams. Do not edit or cherry-pick that bench. Classification, parser fixtures and format research can proceed independently; renderer-host integration starts from the landed performance base or an explicitly agreed stable seam.

Required behavior gates are independent of implementation details:

- Repeated camera motion over unchanged loaded files performs zero file reads, parses or decodes.
- Live views and decoded/indexed data remain bounded as source size grows.
- Cache cost and queued work are globally bounded across tiles; offscreen work does not scale with every retained tile.
- Removing a tile or switching its document cannot publish a stale completion or leave an active preview/player behind.
- Theme, content revision, image zoom, table scroll/selection, and sheet/page changes invalidate the correct snapshot state.
- Repeated open/close and workspace switch cycles settle rather than accumulate viewers, observers, timers or workers.

Add counts to deterministic witnesses and record coarse timings/peak memory alongside them. Pick numerical memory/index budgets using the fixture spike on the target hardware; invented caps are not measured acceptance baselines. Test camera motion with a mixed canvas, not just an isolated image or table. Both 60 Hz and 120 Hz ambitions retain the distinctions in `performance-budgets.md`.

## Implementation sequence

| Slice | Deliverable | Depends on | Completion evidence |
| --- | --- | --- | --- |
| FT0 | Format fixtures, ImageIO/Quick Look probes, baseline work counts and supported OS results | Planning decisions | Real fixture output; no extension-only claims; decide support table and budgets |
| FT1 | Classification before text sessions; renderer host around unchanged text/Markdown behavior | Landed residency seam | Existing text editing/recovery/navigation checks green; binary opens create no text session |
| FT2 | Image viewer, async decode, zoom/pan, metadata and bounded shared cache | FT0, FT1 | Orientation/alpha/color/large-image/reload fixtures; no decode during unchanged camera motion |
| FT3 | CSV/TSV parser, bounded index and native grid | Core parser can start before FT1; UI needs FT1 | Chunked parser fixtures; exact-value selection/copy; large-file scaling and honest query scope |
| FT4 | Embedded workbook Quick Look adapter | FT0, FT1 | Supported OS/provider fixture matrix; focus, disposal and external-change behavior |
| FT5 | PDFKit viewer if required scope has passed | FT1 and memory budget | Pages/search/selection and lifecycle witnesses |
| FT6 | Mixed-canvas integration, visual QA, documentation and release gate | Required slices | Production-mounted scene tests; matrix summary reports all new legs; dev preview light/dark review |

Keep changes reviewable by slice. Start with FT0 and parser fixtures; do not hold the incoming performance release for an unproven workbook engine. At the release cut, omit optional PDF or playback before relaxing correctness or resource gates. This plan does not assign a version number or promise a date ahead of the release owner.

## Verification contract

Every substantive slice gets an offline behavioral witness, staged RED before the fix and GREEN after. Register new real flags in `ContinuumApp.main()`, `scripts/run-matrix.sh` and the literal matrix inventory. Proposed witness names in research notes are specifications, not flags safe to run today. Rebuild products before checking them and require the full matrix summary to show the legs ran.

Drive new scene tests through `AppDelegate.mountWorkspaceSceneAtBoot`, then exercise production UI/API open routes. Some existing file-open checks call the checks-only `install(into:)`; they do not substitute for a production-mounted renderer witness. Assert visible content and persisted outcomes, not source strings or tile kind stamps.

Fixtures cover corrupt and mislabeled input, missing files, wrong file kind, inaccessible paths, atomic replacement, rename/trash, slow old completions, file changes during indexing, navigation away with unsaved text, restore, two projects and multiple zones. Assert world frames, tile ownership and non-installed-zone preservation after opening and restoring each renderer. API opens must retain explicit target/grant semantics without arming zones or falling back to the active project.

Use only disposable project roots and app-support stores. No checks touch Dylan's live project `.array`, prod app, defaults or default tmux socket. Visual QA runs in the shared dev preview through `scripts/dev-app.sh`, in light and dark appearances, with keyboard/VoiceOver, Retina and legacy/overlay scrollers. Any new persisted user-editable view property gets a real coding-key classification in `WorkspaceAPIExposure` and the appropriate production API witness if exposed.

## Efficient tests that remain useful

Most cases belong in fast, platform-neutral table-driven parser/classification tests with tiny fixtures. Use the same fixture manifest for backend assertions and the small number of real renderer smoke cases; expected values must be independently authored. Store fixture provenance, capabilities and expected errors, not whole decoder output regenerated as its own oracle. Generate large scaling fixtures deterministically rather than committing large binaries.

Create one shared lifecycle contract harness for all renderers. It exercises replacement, external changes, cancellation, suspension, resumption and disposal through the production host. Each renderer supplies a minimal fixture and observable result. Test host behavior thoroughly once, then use a focused real mounted case per renderer to prove its wiring; avoid multiplying every format by every opening route, OS, theme and failure. Cover route/grant semantics in their existing integration tests and add representative new-format arms.

Use controlled completion queues and an injectable file-change source for race tests, rather than sleeps or repeated filesystem polling. Count reads, parses, decodes, retained bytes and live views; timings and RSS are supplementary. Test observable outcomes and limits, allowing the implementation to change from tables to custom drawing or from one parser to another without rewriting its behavioral contract. Private helper calls and source-string matches are not substitutes for production behavior.

Keep system-provider probes separate from deterministic host tests. Quick Look's actual rendering needs real macOS fixture smoke, while an injected adapter verifies failure and cleanup reproducibly. Restrict screenshots to appearance/layout cases; exact pixels are inappropriate universal oracles for system text/preview rendering. Record OS and provider context with those results. A mock success cannot establish supported file coverage.

During development, rebuild the affected product and run the focused slice. Run the complete matrix at integration/release and after changes that invalidate shared results; do not run the full matrix once per CSV edge case. Reuse a build for compatible focused runs and report individual failures even when another case fails. Keep proposed new legs visible in the final matrix report. Record actual test durations before setting a suite budget, and review duplicated coverage or slow fixtures when the suite grows.

For every future renderer, acceptance requires its format manifest/fixtures, the shared lifecycle contract, one real production-mounted visible result, resource-count evidence and appearance/accessibility coverage. This is the extension checklist; adding a format should not require inventing a new QA framework.

## Follow-up formats

After the required release scope, prioritize structured JSON/JSONL because agent outputs and datasets often use it; share the grid infrastructure while keeping nesting and missing/null distinctions. PDF belongs near the first release because it is a common report/artifact. Audio/video playback via AVKit is useful next but requires explicit play and reliable suspension. Read-only SQLite and Parquet are valuable data work, with query/resource budgets and dependency evaluation in their own slices. Archives and Office documents can use proven preview fallback before custom readers.

Do not automatically execute HTML, notebooks, scripts, macros or embedded actions to provide a preview. HTML can keep its current source experience until a separate isolated preview contract is designed. Rendering a file and executing its contents are different product capabilities.

## Research index

1. [Current architecture](research/01-current-architecture.md)
2. [Images](research/02-images.md)
3. [Delimited data](research/03-delimited-data.md)
4. [Workbooks](research/04-workbooks.md)
5. [Other formats](research/05-format-roadmap.md)
6. [Performance integration](research/06-performance-integration.md)
7. [Verification](research/07-verification.md)
8. [Product UX](research/08-product-ux.md)

## Workspace record

The session attempted `git worktree add .worktrees/file-tile-research -b array/file-tile-research`. The filesystem policy rejected creation of `.git/refs/heads/array/file-tile-research.lock`. The directory is therefore a clean `git archive HEAD` snapshot plus these research files, not a registered worktree. No branch, commit or staged change was created. Do not run Git mutations from this snapshot: without its own `.git`, Git discovers the parent repository.

Preserve this directory until the plan is transferred into a real bench in a session allowed to write Git metadata. There are no production code changes to land or test in this planning slice. Source inspection and web research establish a design proposal; decoder, Quick Look, performance and UI behavior still require the FT0/implementation witnesses above.
