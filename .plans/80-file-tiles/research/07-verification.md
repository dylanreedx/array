# Expanded file tiles: verification and release contract

Research only, 2026-10-23. No app code changed, no build, app launch, or matrix run performed. All proposed flag names below are proposals, not flags safe to invoke today.

## What already exists

- `Sources/ContinuumRevivedCore/FilePreview.swift` admits regular UTF-8 files up to 1 MiB, rejects NUL bytes/non-UTF-8 BOMs, checks 64-bit size before reading and the actual byte count afterward. Its presentation classifier currently knows source and Markdown only. Do not widen this text admission limit merely to admit images or large datasets: each decoder needs its own resource limits.
- `FileDocumentSession.swift` owns editable text baseline, revision, dirty draft, recovery and atomic save. `FileDocumentSessionChecks.swift` exercises stale revision rejection, clean save, dirty external conflict, explicit overwrite, missing-file refusal, recovered draft, write failure and oversized draft refusal. Its existing standalone `--file-document-session-check` is registered in `run-matrix.sh:460` and also runs in full CoreChecks.
- `FileOpenChecks.swift` exercises active project changes, zone placement/persistence, deduplication, actual visible Markdown, real control clicks, source line reveal, clean external reload, same-size/same-timestamp atomic replacements, mounted monitoring, recovery and dirty conflicts. Existing matrix legs include `--file-open-active-context-check`, `--file-markdown-preview-check`, `--editor-web-bridge-check`, `--editor-navigation-check`, `--agent-local-file-link-check` and `--file-markdown-perf-check`.
- **Integration gap:** the file checks' `makeSwitchedHarness` and `makeSingleProjectHarness` call `runtime.install(into:)` directly (lines 174 and 1630). Current AGENTS explicitly requires new scene witnesses drive `AppDelegate.mountWorkspaceSceneAtBoot`. Existing tests are useful behavior regression tests but do not establish production mounting for new renderers.
- `UIProbeAppearance.swift` includes `FileTileNSView` in `tokenAdoptedOwners`; its adopted `fileTile` fixture intentionally has no file path and exercises the unavailable placeholder. It does not, by itself, cover new loaded image/data surfaces. New painted view owners need real loaded fixtures in both appearance and adopted sweeps, owner-scoped legal tokens and `nil` resting fills.
- `WorkspaceAPIService.swift` checks grant before resolving the file, uses `AgentLocalFileLinkResolver`, then `preflightExplicitOpen → ensureSpawner → executeOpen`. The API refuses a different workspace/unhydrated zone/ambiguous occurrence rather than navigating, arming or falling back. `TileSpawner.spawnFile` canonicalizes paths and deduplicates `.file` tiles. Keep this single opening pipeline for new formats.

## Recommended witness structure

Separate format semantics, renderer outcomes and production lifecycle. A parser-only check cannot prove a user can see a cell; a screenshot cannot prove the full dataset was parsed or that disk was preserved.

| Proposed witness | Behavioral contract | Registration |
|---|---|---|
| Core `--file-content-detection-check` | Byte/type/extension decision, supported vs unsupported result, bounded read, decoy names and malformed inputs | CoreChecks dispatcher + full CoreChecks + explicit `run_leg` |
| Core `--delimited-document-check` | Exact fields/rows/encoding/dialect and bounded streaming behavior | Same |
| App `--file-image-preview-check` | Decoded known pixels, orientation/dimensions, mounted fit/zoom controls and visible unavailable states | ContinuumApp pre-AppKit dispatch + `run_app_check` |
| App `--file-table-preview-check` | Mounted visible cell sentinels, row/column navigation, selection/copy and explicit truncation/limits | Same |
| App `--file-preview-lifecycle-check` | Production-mounted open/switch/restore, cancellation, external changes and view state persistence | Same |
| App `--file-preview-resource-check` | Bounded live views, decode/parse/read counts and cache bytes across scale axes | Same |
| Existing API open/grants and exposure legs | New formats preserve grants, explicit destination and published property policy | Extend behavioral arms; keep literal matrix invocations |

If a custom workbook parser ships, give it its own Core check and rendered multi-sheet arms in the table app check. For a Quick Look adapter, use deterministic host/lifecycle checks plus real provider fixture smoke on supported macOS; mocks cannot prove workbook rendering. Do not imply XLSX support from a CSV-only green leg. Prefer adding focused arms to existing checks where that leaves clear, separately printed failures; avoid a giant format test that stops on its first failure.

For every substantial slice: create failing fixture first; run rebuilt focused check RED; implement; run GREEN; retain logs. Before release run the real matrix and verify its final report includes every new literal invocation and no unexplained failure. Adding source strings or a registered-but-never-run test does not count. Do not change the matrix's pinned opening lines or existing wrapper names. Do not add new failures to KNOWN-RED as a shortcut.

## Fixture corpus

Fixtures should be tiny, deterministic, committed or generated locally, with no download dependency. Commit expected facts and generation provenance; use known pixel colors/cell values, not the decoder's own output as its expected answer.

**Images:** a common raster per promised format; alpha and opaque; portrait with orientation metadata; unusual aspect ratios; small image enlarged; high-resolution image shown as a bounded thumbnail; multi-frame/animated file if promised; color profile if promised. Include extension/content disagreement, uppercase extension, extensionless image, truncated file, invalid metadata, impossible dimensions and pixel-count/decode-size limits. Assert an image is actually mounted and decoded, not merely that `.png` classifies as image. Test any SVG separately with external references and scripts; a browser document is a different trust boundary from a decoded raster.

**CSV/TSV:** empty file, header only, no header, trailing empty fields, blank records, quoted delimiter, escaped quote, CRLF/LF, quoted multiline field, Unicode, UTF-8 BOM, ragged rows, duplicate/empty headers, embedded NUL, invalid/unsupported encoding, malformed closing quote, very long field and both very wide and very tall files. Keep the exact strings `00123`, `1e3`, `2026-10-23`, `=SUM(A1:A2)`, `+1`, and a large integer as text unless the user explicitly requests a type conversion. Assert the cell coordinates and raw values independently of formatted display. A row limit must show a notice and distinguish a preview count from a complete count.

**Workbook, if shipped:** multiple/hidden/empty sheets; sparse distant cells; merged cells; cached formula values versus formula text; missing cached values; dates/date-system variants; booleans/errors/shared strings; malformed XML/ZIP; archive traversal entry; high expansion ratio; encrypted/password-protected and macro-enabled documents with explicit unsupported behavior. Never evaluate macros, formula code, external workbook links or data connections as a side effect of preview. Formula support must say whether it means formula text, stored cached values or actual calculation.

**Shared failures:** missing, unreadable, directory, device/FIFO/socket, replaced-with-directory while loading, zero bytes, oversize sparse file, format mismatch, stale async completion and decoder failure. Recoverable messages must be visible and bounded; no crash, indefinite spinner, file mutation or silently empty surface.

## Lifecycle and data preservation

Create two temporary project roots with identical relative filenames but different sentinels; two workspaces; multiple zones with nonzero origins; one zone below the live tier. Mount through the production seam, then open each shipped format via user file tree, editor sidebar/document switching, agent link, drop and workspace API as applicable. Assert tile identity, visible sentinel, WORLD frame against target zone content rect, current project owner, persisted canonical path and absence of writes to the other project.

Reopening the same canonical document must reveal/reuse its tile across presentation changes. Switch workspace away and back, evict/reacquire hydration, and reconstruct from persisted metadata. Check exact world frame, content, view mode, sheet selection and scroll/zoom state where promised. Unhydrated tiles must remain in persistence; rendering must not mint IDs, retidy zones or save as a side effect.

Drive real production monitoring, not just a direct refresh helper: clean external write, atomic replacement preserving timestamp and size, deletion, recreation, rename and replacement with a different format. For image/data previews, replace the file while decode/parse is pending and prove only the newest generation reaches the view. Close/switch away during work and prove completion cannot populate a recycled tile or retain its buffers/watchers. Thumbnail or parsed results must be invalidated on replacement, not keyed only by path.

Preserve the existing text editing contract: a local draft is canonical, preview does not implicitly save, external changes cannot destroy it, ordinary save refuses conflict and missing files, explicit overwrite is deliberate, write failure preserves draft, recovery restores after relaunch. If first-release data/workbook viewing is read-only, prove preview, sort/filter and copy leave a byte-for-byte identical file. Editing XLSX requires its own lossless round-trip policy; do not route it through UTF-8 `FileDocumentSession`.

## Paths and active content

`DocumentLocation` is currently **host-local**, with checkout or standalone scope; it is not a remote-file transport. A remote environment elsewhere in the project model does not authorize treating remote paths as local files. Keep `file://other-host/...`, SSH/SFTP/HTTP URLs and remote-only paths unsupported by the local renderer unless a separate explicit transport design is approved. Add fixtures that prove no network fetch occurs.

Retain checkout-bound agent/API resolution, component-based containment, canonicalization of both root and candidate, regular-file checks and the grant-before-path-disclosure order. Exercise `../`, absolute outside path, prefix lookalike root, symlink escape, remote `file://` host, spaces/percent escapes/Unicode and a symlink target replaced during a load. Explicit user-opened standalone files are a different authorization path; do not accidentally apply agent checkout limits to those user actions or let agent links acquire standalone authority.

Canonicalization at open time is not a complete read-time race defense. New asynchronous loaders should document whether they open a verified descriptor/read snapshot, revalidate containment after replacement, and how they reject a file that changes type mid-read. A regression witness should swap the path between resolve and read using an injected seam and assert no outside-file bytes reach the rendered result. Do not claim this is currently protected merely because `resolvingSymlinksInPath()` exists.

Treat file-derived labels, CSV cells, SVG/XML and workbook metadata as data. Render a literal `<script>` and `javascript:` cell as text; assert no execution or implicit navigation. If copy/export to spreadsheet consumers is added, separately specify how formula-like strings are preserved versus escaped; preview itself must not run them. Any web-backed renderer needs a closed local resource/navigation policy, with an injectable request observer proving no remote resource load.

## Performance gates and release evidence

Follow `docs/internals/performance.md`, `performance-budgets.md` and `scalability-tdd.md`. Count work: zero reads/parses/decodes on unchanged layout, pan and zoom where the retained camera contract permits it; bounded visible cell views independent of total rows; bounded image decoded bytes; cancellation and cache eviction on close/eviction. Repeated resize and theme changes should perform only the work the changed input requires. Keep coarse time/RSS reports alongside deterministic counts, not as the sole green assertion.

Vary axes independently: rows, columns, field length, image dimensions, visible tiles, installed-but-offscreen tiles and repeated restore/switch cycles. A 10-column × 100k-row table and a 10k-column × 100-row table find different bugs. Verify `.overlay` and `.legacy` scrollers, fractional canvas zoom, minimum tile width and light/dark appearances. Reuse upcoming performance work rather than redefining its budgets; freeze baseline/counters before integration so slope changes are reviewable.

Before next-release inclusion: focused red/green logs; final matrix summary (including explicit skips and current KNOWN-RED); deterministic fixtures; light/dark rendered artifacts showing real loaded surfaces and errors; UI-probe/token coverage; production-mounted multi-project/restore evidence; API grants/exposure evidence for persisted fields; resource reports and decoder dependency/license review if dependencies change. Exercise release bundle smoke with `scripts/check-app-bundle.sh`; follow RELEASE.md for any actual release. This research authorizes neither a version bump nor publication.

All QA must use temporary app-support **and project roots**. Never touch `/Applications/Array.app`, its project `.array`, or the default tmux socket. The matrix establishes its own tmux namespace; ad-hoc suites need the same isolation. Preserve `CONTINUUM_ARRAY_MANAGED_AGENT`; any deliberately deferred crash witnesses must be reported and run externally before calling that coverage complete. Never update UI baselines to make a mismatch pass.
