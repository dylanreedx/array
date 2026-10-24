# Current file/editor tile architecture

Research date: 2026-10-23. Source inspection only, in the isolated research snapshot. No production edits, builds, checks, preview launches, or live project-state access were performed. Findings distinguish observed source behavior from implementation proposals.

## Existing product capability

All file types currently use the same persisted `.file` tile and `FileTileNSView`. The content contract is UTF-8 text, at most 1 MiB (1,048,576 bytes). `.md` and `.markdown` receive rendered Markdown plus Preview/Split/Edit; everything else that passes text decoding receives the CodeMirror source editor. CSV, TSV, JSON, SVG and HTML can consequently appear as source text, but there is no image or table renderer. Binary image and workbook files are rejected, usually as binary or oversized files. Non-UTF-8 text (including UTF-16 CSV exports) is rejected.

Evidence:

- `Sources/ContinuumRevivedCore/FilePreview.swift:3-17, 66-115`: text/unavailable result, extension-only Markdown presentation, size and encoding guards.
- `Sources/ContinuumRevived/Canvas/FileTileNSView.swift:1421-1521`: loading, Markdown vs source routing and placeholder.
- `Sources/ContinuumRevived/Canvas/FileTileNSView.swift:1546-1616`: native code presentation and web editor creation.
- `Sources/ContinuumRevivedCore/FilePreview.swift:19-63`: source-language hints cover JS/TS, HTML/CSS, Go, Rust, C/C++, C#, Python, Swift, JSON and shell; other source formats use plain text. These hints are editor syntax selection, not file-format recognition.

The existing one-file-per-tile editor shell includes an optional checkout file browser, document replacement, file operations, cursor/scroll persistence, preferred-editor opening, agent reference relationships and language-service integration. These are useful shared document functions to retain for image/data previews.

## Open, identity, placement and hydration

`DocumentLocation` separates canonical path identity from checkout/standalone scope. Its resolver checks symlink-aware component containment (`Sources/ContinuumRevivedCore/DocumentLocation.swift:3-88`). `WorkspaceRuntime.openDocument` is the interactive path: it resolves source project/zone, can navigate workspaces, executes the common spawn/link operation and enters focus (`Sources/ContinuumRevived/App/WorkspaceRuntime.swift:1797-1880`). The separate explicit API preflight route must retain its restrictions; new formats should flow through its common execution instead of inventing another opening route.

`TileSpawner.spawnFileImpl` canonicalizes the path, deduplicates workspace-wide `.file` tiles, computes world-to-zone placement, creates `FileTileNSView`, runs `fileEditorConfigurator`, installs through `installProjectTile` and persists (`Sources/ContinuumRevived/App/TileSpawner.swift:2629-2710`). Default size comes from the generic `.file` frame. Boot creates the same view in `installFileTile` (`:2797`); workspace hydration creates it from persisted metadata in `ContinuumApp.makeHydratedTileView` (`Sources/ContinuumRevived/App/ContinuumApp.swift:20365-20407`). `configureFileEditor` supplies navigation, document replacement, external opening and language services (`:19392-19449`).

**Recommended seam:** retain `.file` as the durable tile identity and insert format classification plus a content controller inside its shell. Creating a separate tile kind for every format would duplicate opening, placement, identity, agent links and lifecycle unnecessarily. Audit all creation paths above: patching only spawns would leave restored tiles different.

## Editing and persistence guarantees

`FileDocumentSession` owns text baseline, draft, monotonic revision, recovery and disk conflict decisions. It canonicalizes file identity, loads a baseline in its initializer, refreshes without replacing dirty drafts, checks current disk content before save, imposes the 1 MiB limit on draft writes and writes atomically (`Sources/ContinuumRevivedCore/FileDocumentSession.swift:78-291`). It is specifically a UTF-8 text session, not a generic document session.

`FileTileNSView` synchronizes CodeMirror snapshots across a document-ID/generation boundary and freezes the bridge before save/document transitions (`:320-365, 368-455`). Scene transitions capture all editor drafts before moving/closing (`Sources/ContinuumRevived/App/WorkspaceRuntime.swift:1034-1060`; `FileTileNSView.swift:1073-1092`). Removal stops timers/browser, flushes recovery, persists editor state, closes language services and tears down WebKit (`FileTileNSView.swift:164-188`).

Recovery stores path, baseline and draft per tile under checkout `.array/recovery/file-drafts/`, or channel-separated app support for standalone documents (`FileTileNSView.swift:1852-1935`). `FileEditorViewState` persists browser expansion/width/selection/search and source cursor/scroll; metadata also persists document location and Markdown mode (`Sources/ContinuumRevivedCore/CanvasState.swift:240-277, 279-413`). There is no durable image zoom/pan, selected worksheet, table position, delimiter/header selection or preview/source preference today. Any additions need Codable migration and the workspace API exposure classification described in AGENTS.md.

**Recommended seam:** preserve `FileDocumentSession` for source/Markdown editing. Add format-specific read-only document loading first, with explicit capabilities (`canEditSource`, `canSave`, `canSearch`, etc.). Do not coerce images or workbooks into text sessions or promise workbook editing through a text save path. A future editable CSV table should mutate one text-backed authoritative draft and preserve dialect/encoding/newlines; a future XLSX editor requires a separate fidelity contract.

## Lifecycle and performance risks found in source

1. **Loading is not actually generally asynchronous.** `FileTileNSView.init` creates `FileDocumentSession`, whose initializer reads disk synchronously, before `loadFile` runs. `loadFile` performs another `FilePreview.load`; only a volume explicitly reporting nonlocal uses `Task.detached` (`FileTileNSView.swift:102-111, 1421-1440, 1962-1970`; `FileDocumentSession.swift:95-110`). Thus ordinary opening reads the same file twice, and the nonlocal branch still has an earlier synchronous read. Larger media/data loading must start with metadata/probe and a cancellable off-main loader, with no synchronous eager session initializer in front of it.
2. **Two loaders can disagree.** `FilePreview.load` and `FileDocumentSession.readDisk` independently inspect/read/decode disk. `apply` prefers session text over preview content. Files changed between reads can produce different content/signature/recovery comparisons (`FileTileNSView.swift:1442-1459`). One immutable loaded document result should initialize the content session and visible surface.
3. **Per-tile polling.** Each successfully loaded visible tile starts a common-runloop timer every second; it stats the file and synchronously refreshes changed disk contents (`FileTileNSView.swift:948-981, 1843-1850`). A dirty conflict does not advance `loadedFileSignature`, so the same changed file can be reread each tick. Avoid multiplying this work for large grids, remote files or animated image sources. A shared/coalesced watcher with bounded reload scheduling is the better extension point.
4. **Text-centric focus and surface assumptions.** `acquireFocus` targets CodeMirror, Markdown or NSTextView (`:203-217`). `surfaceableBody` excludes source and Markdown edit/split because WKWebView snapshots lack a dedicated witness; Markdown preview surfaces use explicit scroll origin and an epoch (`:220-259`). Every new content controller needs its own focus, residency revision and scroll/zoom state contract. A generic offscreen bitmap must not stale after pan, worksheet change or external reload.
5. **Switch/rename currently assumes text.** `switchDocument` creates another text session, resets source/Markdown state and keeps WebKit mounted (`:368-455`). Project rename notifications preserve a draft and rebuild a text session (`:726-755`). Supporting image→CSV→source navigation requires disposing prior content/tasks and reclassifying; avoid stale WebKit or a source draft attached to a binary path. Existing rename routing does not visibly reclassify Markdown presentation when the extension changes; treat as a risk to witness, not a proven runtime regression.
6. **Limits are text-size limits, not media/data budgets.** A 500 KB compressed image may decode into hundreds of MB; small XLSX archives may expand hugely. New types need independent input, expansion, pixel, cell, column, string and cache budgets. Raising `FilePreview.maxReadBytes` globally would also enlarge editor/recovery/bridge workloads.
7. **Web content boundary.** `CodeEditorHostView` loads bundled editor resources with read access limited to their directory (`Sources/ContinuumRevived/Canvas/CodeEditorHostView.swift:340-355`). Do not render arbitrary SVG/HTML via that trusted editor bridge. SVG is currently inert editable text.

These are static findings; no runtime bug claim was validated in this research pass.

## Deterministic witnesses and integration checklist

Existing gate legs include Core file document session (`scripts/run-matrix.sh:460`), file spawn (`:889`), active-context open (`:1136`), file operations (`:1137`), Markdown preview (`:1176`), editor bridge/navigation (`:1177-1178`), Markdown performance (`:1185`) and file zoom (`:1227`). `Sources/ContinuumRevivedCoreChecks/main.swift:3051-3112` covers text loading, binary/UTF BOM/oversize rejection including pre-read sparse-file limits. These expectations must remain meaningful for the text loader when format dispatch is added.

New witnesses should exercise the real production open→view→hydrate path, plus replacement in both directions across text/image/table; canonical dedupe; read-only close without creating drafts; rename/delete/recreate/reload; cancellation and stale completion; same-file agent links; workspace switch; focus and keyboard ownership; theme/accessibility; surface residency; and bounded memory/view/decode/measurement counts under oversized input. Binary rejection tests should target text capability explicitly rather than declaring all binary files globally unsupported.

`docs/internals/performance.md:189-201` requires measured largest input, bounded AppKit view count, cached measurement outside layout, no unchanged frame assignments, legacy scrollers, count assertions and visible sampling/truncation. A spreadsheet must virtualize both rows and columns; an image should decode/downsample outside layout and keep a bounded cache. Coordinate these interfaces with the incoming performance work before implementation.

## Recommended architecture direction

Use a small extensible document pipeline rather than adding cases throughout this 2,000-line view:

1. Canonical `DocumentLocation` + metadata/content probe → a typed descriptor/capability set.
2. Cancellable background loader → immutable format payload and explicit bounded/partial result.
3. Existing file-tile shell → dedicated source/Markdown, image, delimited-table or workbook controller.
4. Shared lifecycle hooks → focus, search, external reload, preview/source switching, view-state persistence, scene capture and teardown.
5. Text edit/save remains one authoritative `FileDocumentSession`; nontext controllers begin read-only.

Keep classification/parsing and resource limits in platform-neutral Core where feasible, and AppKit presentation in the app target. Avoid a generic registry abstraction until the first concrete image + CSV + workbook implementations establish the necessary protocol; the important boundary now is durable file identity versus disposable rendering state.
