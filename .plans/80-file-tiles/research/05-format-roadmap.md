# Additional file formats: roadmap and constraints

Research date: 2026-10-23. Planning only; no production edits or runtime verification.

## Recommendation

Keep the next release centered on the requested images and tabular files. PDF is the strongest additional format to prepare for: it covers research papers, agent-produced reports, invoices and exported charts using a native renderer. JSON/JSONL inspection is the strongest follow-on for Dylan's data work because it can reuse the table infrastructure. Do not turn the first release into a universal document suite.

“Support” must describe a capability, not an extension: readable preview, searchable data, editable source and fidelity-preserving save are separate promises. Preserve source editing for textual formats; binary preview must never enter the text draft/recovery/save path.

| Priority | Format/workflow | Recommended experience | Complexity / release position |
|---|---|---|---|
| Foundation | Existing text, code and Markdown | Preserve editing, line reveal, conflict and recovery behavior | Regression coverage required for every new renderer |
| Next-release core | Images; CSV/TSV; scoped spreadsheet preview | Covered in companion research; share file identity and lifecycle | Primary work; additional formats may not delay it |
| First optional addition | PDF reports, papers, exported charts | Read-only PDFKit view, fit/page navigation, selection/copy, explicit external open | Medium; add only after image/data gates pass |
| Next increment | JSON and JSONL/NDJSON data inspection | Source plus bounded tree/table view, explicit sampling, record diagnostics | Medium; high reuse of data grid, avoid JSON editor rewrite |
| Next increment | Local audio/video output, screen recordings | Native player, explicit play, timeline, frame stepping for video | Medium; needs canvas lifecycle and focus policy |
| Later | SQLite | Read-only schema and paged table browser | High; live-writer/WAL behavior and read-only isolation need their own milestone |
| Later | Parquet, Arrow, DuckDB datasets | Schema, row groups, bounded data page; local embedded engine | High; dependency, memory and data-type decisions |
| Later | ZIP/TAR archives | Bounded contents listing; extraction a separate explicit operation | Medium/high; lower direct workflow value than data/PDF |
| Fallback | Office documents, presentations, uncommon native formats | Explicit Quick Look preview or external application; best-effort badge | Small prototype, medium production hardening; not a substitute for an inspectable spreadsheet |
| Defer | Executing HTML, notebooks, diagram DSLs, 3D/CAD, arbitrary plugin renderers | Continue source/external workflows | Larger trust, dependency or product surface |

Complexities are engineering judgments, not measured estimates. There is no implementation spike yet.

## Existing seams that constrain the plan

`Sources/ContinuumRevivedCore/FilePreview.swift` currently has only `text` and `unavailable` load results and `sourceText`/`markdown` presentations. It admits at most 1 MiB, rejects non-UTF-8 BOMs and NUL-containing data, and otherwise loads complete UTF-8 content. The current limit is a text policy, not an appropriate universal binary limit. `.json` and `.jsonc` already have source-language classification; JSONL does not.

`FileTileNSView.swift` creates `FileDocumentSession` from a path and initializes the editor shell before loading. Successful text application owns recovery drafts, dirty state, external file monitoring and language services. New binary renderers need a separate load/result path that leaves those semantics intact. Its existing surface residency explicitly excludes WKWebView editors pending a dedicated witness; introducing web renderers is therefore not free. Integrate under the same file tile identity rather than spawning a new unrelated tile kind for every suffix.

`WorkspaceRuntime.openDocument` is the shared opening seam. The explicit API path returns precise unsupported/presentation-required outcomes and must not acquire implicit navigation. Renderer choice should sit below this routing contract; opening a PDF must not suddenly acquire a different project/zone policy.

The standing [performance guidance](../../../docs/internals/performance.md) bans work proportional to total content on repeated layout, and requires bounded or virtualized content plus visible truncation notices. Every proposal below inherits those constraints.

## PDF: strongest native addition

Apple's `PDFView` is an embeddable native view with page navigation, zoom and selectable/copyable text. Use PDFKit directly for a predictable baseline instead of generic Quick Look. Build Array's surrounding controls from its shared components. See [PDFView](https://developer.apple.com/documentation/pdfkit/pdfview).

Initial scope: local read-only document, fit width/page, page count/current page, go-to-page, selection/copy where permitted, reload on external replacement. Store page/zoom only as view state after classifying new metadata keys under `WorkspaceAPIExposure`. Defer annotations, form editing, signing, OCR and write-back.

Treat a PDF as a document with interactions: password-protected files need a bounded locked placeholder; links and remote-page actions need explicit routing; forms must not imply saved edits. PDFKit exposes link and remote document delegate hooks, but those APIs are not evidence that every action can be cancelled. Prove actual behavior with fixtures before promising blocked actions. See [PDFViewDelegate](https://developer.apple.com/documentation/pdfkit/pdfviewdelegate) and [PDF widget types](https://developer.apple.com/documentation/pdfkit/pdfannotationwidgetsubtype).

Witnesses: multipage orientation/crop differences, text selection, empty/corrupt/encrypted PDF, external replacement retaining valid page bounds, link handling, no file bytes changed, tile close releasing document, snapshot/residency restore preserving page and zoom. Profile a large scanned report and several visible PDF tiles; a native framework does not remove the canvas budget.

## Structured data: JSON and JSONL

Add inspection modes on the shared data grid, keeping source as the authoritative editable representation. JSON object trees need bounded depth and lazy children. Arrays of objects can offer a table when shape warrants it; mixed/nested structures must remain representable rather than being silently flattened or coerced. Protect integer precision, distinguish null/missing/string/number, and copy exact values.

JSONL is particularly valuable for agent traces, evaluations, event logs and data exports. Its format is UTF-8 with one JSON value per line; scalars are legal and blank lines are invalid. Stream records with byte offsets rather than loading a whole log and parsing all records upfront. Show malformed line locations, handle an incomplete final record during agent writes, and label total count as unknown until indexed. Do not quietly skip bad lines. See the [JSON Lines specification](https://jsonlines.org/).

Do not put a JSON write-back serializer behind a table edit in this milestone: formatting, duplicate keys, order, numeric precision and JSONC comments make round trips a separate contract. File size, record size, depth and scan budgets must each be bounded. Search/sort over a sampled page must be visibly described as sampled.

## Audio/video: useful after lifecycle is settled

Agent-created demos and recordings deserve direct playback. `AVPlayerView` supplies playback controls and frame stepping. `AVURLAsset` handles local URLs and exposes runtime supported content types; codec/container support is capability-based, so extension alone cannot promise playback. See [AVPlayerView](https://developer.apple.com/documentation/avkit/avplayerview) and [AVURLAsset](https://developer.apple.com/documentation/avfoundation/avurlasset).

Open paused; no media autoplay during restore. Define pause-on-hidden/workspace-switch and stop/release-on-close. Canvas keyboard shortcuts must yield only when the player owns focus. Defer trimming, recording, transcoding and network streams. Reject playlist/network media in the local-file policy until separately scoped; a local playlist may reference remote segments. Test actual play/pause, seek, corrupt codec, removal during load, multiple simultaneous tiles, and no audio after scene teardown. Decide explicitly whether playing media stays live while inactive, instead of silently snapshotting a moving frame.

## Quick Look: useful fallback, limited guarantee

`QLPreviewView` embeds a system preview; it exposes refresh, display state and autostart controls. Its `close()` releases the preview item, so detach/teardown must call it. This offers a useful explicit fallback for document families Array does not own. See [QLPreviewView](https://developer.apple.com/documentation/quicklookui/qlpreviewview).

The API contract does not guarantee fidelity, cell access, editing, availability of a previewer for every format, or deterministic behavior across machines. Do not market “supports all files” or equate a workbook's static page preview with a grid. Prototype focus, gesture interception, theme and surface residency before assigning broad production scope. Always retain file metadata, unavailable state and external open when preview generation fails. Disable autostarts before assigning an item.

## SVG and HTML: render content without executing a project

SVG belongs with images for user expectations, but a top-level SVG document can carry script, links, animation and external references. W3C distinguishes interactive processing from secure static/animated image processing; embedding as image content has different semantics from navigating to the SVG. Prefer native static decoding if supported and witnessed; otherwise an inert image embedding with an explicit no-network policy, not a browser navigation. See [SVG processing modes](https://www.w3.org/TR/SVG/conform.html).

HTML should stay source-first this release. A future static preview needs a separate minimal WKWebView configuration: no editor bridge or injected privileged handlers, JavaScript disabled, denied downloads/popups/top-level navigation, and blocked remote subresources. Apple documents that JavaScript is enabled by default and that setting `allowsContentJavaScript` false disables referenced scripts; this does **not** by itself stop image/font/CSS network requests. Use an installed content rule list for resource blocking and witness a local request recorder receiving zero requests. See [JavaScript policy](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/allowscontentjavascript) and [content filtering](https://developer.apple.com/documentation/webkit/wkcontentruleliststore).

Apple's local file loading API permits reading only the specified file when the read-access URL equals the content URL; passing a directory expands access to related files. Do not grant the project root or home directory to arbitrary generated HTML. If relative assets become a requirement, design an allowlisted resource loader with canonical path containment and symlink handling. See [local file access](https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl(_:allowingreadaccessto:)). Fully executing app previews remain the browser/dev-server workflow.

## Later data formats and archives

**SQLite:** begin with schema/base-table browsing using `SQLITE_OPEN_READONLY`; the simpler open APIs can create files. Avoid arbitrary SQL, extensions and custom functions initially. Bound query work and cancel it. SQLite recommends reducing limits, using an authorizer/progress handler and distrusting untrusted schemas; adopt a deliberate subset. Never use `immutable=1` merely to prevent writes: it disables locking/change detection and can return wrong results if an agent updates the file. Active WAL databases need a separate consistency/sidecar policy; read-only connection mode alone is not a complete promise of zero side effects. See [connection flags](https://www.sqlite.org/c3ref/open.html), [URI modes](https://www.sqlite.org/uri.html), and [SQLite security guidance](https://sqlite.org/security.html).

**Parquet:** high value once actual workflow evidence justifies the dependency. DuckDB can read Parquet directly and push selected columns/filters into scans, so avoid conversion of the whole file to CSV. Start with schema and bounded row pages. Dependency packaging, cancellation, exact decimal/timestamp/nested values and disabling external access/extension downloads deserve a separate engine evaluation. No requirement for a user-installed Python environment. See [DuckDB Parquet support](https://duckdb.org/docs/stable/data/parquet/overview.html).

**Archives:** libarchive supplies streaming multi-format reads. Contents-only inspection can be useful, but compressed size is not a work bound. Cap entries, total metadata, decompressed bytes inspected and nesting; support cancellation. Extraction must be separately scoped with path traversal, symlink and overwrite rules; never extract just to show contents. See [libarchive](https://www.libarchive.org/).

## Release decision

Adopt an extensible renderer capability boundary now; ship the proven image/data subset. Keep PDF as the first optional follow-on and JSONL as the next data investment. Require representative fixtures plus production-open-path witnesses, appearance verification and performance measurements for each renderer. Avoid bundling every native framework behind Quick Look as a shortcut: discoverable, predictable behavior is the feature.

Research used repository reads plus primary documentation. Apple web pages required fetching their linked `.md` endpoints because the web reader rejected the Markdown content type; those endpoints were successfully read via Python `urllib.request`. No app builds, matrix runs, UI launches, dependency installs or production changes were performed for this research.
