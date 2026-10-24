# Rich file tiles: current implementation

Updated 2026-10-24. Active source is the real worktree `.worktrees/file-tile-previews`, branch `array/file-tile-previews`, based on `fe734156`. The coordinator created it and owns commits. The scoped research delta was transferred, preserving the incoming far-parking method and multiselect gates. The research archive remains intact; do not resume editing there. Read SAFE-EXECUTION before any build/test: every native descendant must run through `/tmp/exc-probe/noexc`.

## Implemented path and ownership

One persisted `.file` tile continues through the existing production open, authorization, deduplication, project/zone and hydration routes. No new tile kind or persisted property was added.

`FileContentKind.select` chooses a bounded backend. `FileTileNSView` remains the shell and text transition owner. Its read-only path asks `FileContentCoordinator` to capture and load off the main actor, validates the request generation, then installs a `FileTileRenderer`. New formats have one selection case, backend and renderer; they do not acquire canvas placement or persistence responsibilities.

| Component | Concrete owner |
| --- | --- |
| Read-time file validation and temporary bytes | Core `SecureFileSnapshot`: no-follow descriptor walk, regular-file admission, streamed byte bound, before/after revision and final path binding, private immutable staging and owned cleanup |
| Initial editable text | Core `FileDocumentInitialLoad`: same snapshot for displayed text and save baseline; no session for rejected input |
| Source/Markdown transitions, drafts and saving | Existing `FileDocumentSession` and host editing/recovery/conflict paths |
| Backend selection, two load workers, weak revision cache, resource reservations | App `FileContentCoordinator` |
| Read-only external-change observation | One `FileContentObservation` clock, coalesced by path and detached with hosts |
| Body lifecycle | `FileTileRenderer`; host generation/cancellation, theme, focus, existing surface demote/promote and disposal seams |
| Image decoding and immutable pixels | `FileImageBackend` / `FileImageDocument`, ImageIO metadata validation and transformed bounded thumbnails |
| Image interaction | `FileImageRenderer`: fit, physical preview pixels, zoom, pan, transparency checkerboard and honest frame/page/downsampling status |
| Delimited storage | Core `DelimitedFileDocument`: immutable staged file, streaming UTF-8/UTF-16, sparse checkpoints and projected bounded page reads |
| Dataset presentation | `DelimitedGridRenderer`: one drawing view, both-axis projected pages, bounded LRU, keyboard/rectangle selection, full-value inspector, quoted TSV copy, whole-file next-match search |
| Shared page/copy/find work | `FileGridWorkScheduler`: two workers, cancellation-aware queued admission; active workers retain sources and leases until actual exit |
| XLSX container validation | Core `BoundedZIPArchive`: stored/raw-deflate ZIP32, CRC, coherent headers, bounded expansion, no path extraction |
| XLSX semantics | Core `XLSXDocument`: bounded XML, sparse cells, shared/inline strings, raw/display/formula/cache separation, date systems, hidden sheet/row/column values, merge notices |
| Workbook presentation | `WorkbookGridRenderer` / `WorkbookGridSource`: visible sheet picker, reusable grid, sparse-only search and raw/formula/cache inspector |

New read-only bodies never construct a text editing session, write source bytes, create recovery drafts, execute formulas or launch providers. CSV/TSV offers source editing only for small UTF-8 files; entering Data Preview resolves a dirty draft with Save/Discard/Cancel first. UTF-16 stays read-only rather than silently converting the user's file.

Source and Markdown retain their existing bounded local synchronous loading. This implementation does not claim to replace the entire legacy editor runtime or to interrupt synchronous OS decoder calls mid-call.

## Format contract

Images use the running Mac's ImageIO decoder, with actual decode validation. Current same-runtime fixtures prove PNG, TIFF, GIF, JPEG, BMP, ICO and ICNS. HEIC/HEIF, WebP, AVIF, RAW and other registered images are attempted when available, but broad compatibility/minimum-OS claims require real fixtures on supported systems. SVG and HTML remain source. Animated/multipage images show an explicitly labelled first frame/page. Reduced previews use a “Preview Pixels” control rather than implying original-pixel inspection.

CSV/TSV preserves exact strings, Unicode, quoted multiline values, empty versus absent fields and ragged rows. Headers and delimiter are explicit choices; nothing coerces identifiers, numbers, dates or formula-looking text. Viewing, selection, search and copy do not save the file. Global sort/filter and cell write-back are outside this version.

XLSX is a read-only data view, not a reproduction of Excel layout. It shows cached formula results without recalculation and preserves raw values for inspection. Missing caches are labelled. Hidden sheets are absent from the picker; hidden row/column values are omitted while coordinates remain stable. Charts, embedded images, conditional formatting, every custom number format and Office editing are not claimed.

XLS, XLSB, XLSM, ODS and Numbers currently have explicit external-open fallback. PDF and structured JSON remain optional later renderers. This is an explicit local scope decision, not a claim to support every spreadsheet format.

## Why XLSX changed from the Quick Look proposal

The research proposed provider previews. Public Quick Look controls do not establish Array's required external-resource and memory boundary. This implementation therefore uses a narrowly bounded native XLSX data reader and leaves unqualified formats external-only. It does not admit a system provider and then assume staging suppresses external references. No third-party parser dependency was added: ZIP inflate/CRC uses the system zlib and XML uses Foundation's parser with DTD/entity rejection and external resolution disabled.

The container layout was rechecked against [PKWARE APPNOTE 6.3.10](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT), and string/cell handling against Microsoft's [shared-string documentation](https://learn.microsoft.com/en-us/office/open-xml/spreadsheet/working-with-the-shared-string-table) and [cell reference](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.spreadsheet.cell). These specifications inform the implementation; behavioral fixtures remain the acceptance evidence.

## Enforced limits and honest accounting

- Snapshot input: image/XLSX 64 MiB; delimited data 256 MiB. Packages/special files/symlinks are refused.
- Images: source at most 100 million pixels; decoded output at most 4096 per dimension and 64 MiB by actual row bytes. OS decoder scratch allocation is opaque; this is not a hard process-RSS guarantee.
- Delimited: 1 million rows, 4096 columns, 4 MiB record/field, checkpoints every 128 records, at most 256 rows / 8 MiB payload per backend request.
- Grid: 64×16 projected pages, at most eight pages and 4 MiB accounted cache; 100,000-cell / 8 MiB quoted selection copy. Empty cells incur an overhead estimate in cache accounting.
- XLSX ZIP: 2048 entries, 8 MiB per expanded entry, 32 MiB aggregate declared expansion, compression ratio at most 200, no encryption/ZIP64/multidisk or unsupported methods. Actual inflate lengths and CRC are verified.
- XLSX XML/value model: 16 MiB parsed XML, 16 MiB accounted text, 100,000 stored cells/row declarations, 128 sheets, bounded depth/nodes and valid Excel coordinates.
- Shared resource reservations: 128 MiB separate from the canvas surface cache. Image pixel cost is exact; data/backend/viewer reservations are conservative accounting policies, not exact Swift allocator RSS. Each grid renderer has its own 32 MiB reservation even when documents share a weak cache hit. Resource exhaustion is visible with Reload and external-open actions.

Conservative reservations deliberately limit simultaneous large previews. Measure mixed-canvas resource use before tuning them upward. Temporary staged files are disk resources and are deleted when their owning document/snapshot is released.

## Execution and verification

On the active `fe734156` worktree, fresh Array and CoreChecks builds passed (171.61s and 24.17s). The focused matrix harness passed 13 registered legs: the eleven file/editing/API checks plus both multiselect witnesses. The own-hunks landing patch is `qa-runs/file-tile-previews/landing.patch`; its cached apply check passes without staging. The coordinator owns review, commit and the final full integration gate. Historical research-base details follow.

Core product build and `--file-format-backends-check` passed after fixing test fixture defects. Native image, grid, initial-load, Markdown preview, workspace API open/grants and scene-owner checks passed. The production file-format scene check passed after fixing retired hosts reacting to rename notifications and releasing rich resources when parked. It covers PNG, CSV, UTF-16 TSV and XLSX through API open, mounted content, persisted world frames, workspace round-trip, exact values and resource release; CSV also covers external edit, rename, deletion and tile removal. The final focused matrix harness passed 11 registered legs and printed its summary. The full matrix stopped at the iOS cache restriction; its diagnostic continuation later hung in an existing WebKit palette check. Neither is a full release pass. Consult verification.json and LOCAL-QUALIFICATION.md for exact outcomes. Existing source navigation/WebKit and clipboard-related failures were previously reproduced on rebuilt baseline sources. Do not relabel new failures KNOWN-RED.

The required new gate legs are `--file-format-backends-check` (Core), `--file-image-check`, `--file-data-grid-check`, and `--file-formats-scene-check` (app). They are registered in the matrix/inventory. Registration is not a completed full-matrix run. Scene checks use the production boot mount/API and workspace round-trip; optional `ARRAY_FILE_APPEARANCE_DIR` captures actual light/dark renderer PNGs.

Final local evidence includes the 11-leg focused report and inspected light/dark renderer captures. Remaining release evidence includes the full matrix, live accessibility/preview bundle inspection, supported OS floor and performance-branch landing. No release, version bump or production app replacement is authorized by this record.

The rendering boundary was rechecked against Apple’s [clipsToBounds](https://developer.apple.com/documentation/appkit/nsview/clipstobounds) and [default drawing clipping](https://developer.apple.com/documentation/appkit/nsview/wantsdefaultclipping) contracts. Background draws intersect their own bounds, roots have opaque themed backgrounds, and the regular scene witness catches toolbar overpainting in both appearances.
