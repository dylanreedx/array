# Workbook tiles: research and release boundary

Research date: 2026-10-23. Planning only; no production integration or runtime workbook rendering was performed.

## Recommendation

Ship a good CSV/TSV data surface first, and use an embedded, lifecycle-managed **system preview** for workbooks in the next release if the macOS fixture spike passes. Offer XLSX/XLS/ODS/Numbers as **preview attempts**, with a clear unavailable state and Open in Default App. Do not advertise all four as guaranteed native spreadsheet support. Quick Look's public host API does not establish a fixed renderer/fidelity contract for these formats.

Treat a searchable/selectable XLSX data grid as a separately gated extension. A workbook parser is not an Excel renderer: dates, missing formula caches, sheet visibility, sparse coordinates and merges make a superficially successful grid misleading. Broad workbook editing is later work with a different preservation contract.

This is a sequencing recommendation, not measured proof that Quick Look is sufficient. In particular, ODS may have no suitable provider on a clean machine; that case should remain explicitly unsupported rather than depending on an installed office suite.

## Current Array seam

Read `AGENTS.md`, `Package.swift`, `Sources/ContinuumRevivedCore/FilePreview.swift`, relevant `FileTileNSView.swift` presentation/loading paths, and `docs/internals/performance.md`.

Current `FilePreview` admits UTF-8 text up to 1 MiB and classifies only source versus Markdown. Binary workbook data reaches an unavailable message. `FileTileNSView` combines document editing, draft recovery, presentation and external changes; workbook viewing must branch before a text `FileDocumentSession` is created. A read-only workbook must never enter the UTF-8 save path. Numbers can also be a package/directory, while the current regular-file gate rejects directories.

Array targets macOS 14 / iOS 17 with Swift 6 and currently has no workbook/ZIP reader dependency. Keep QuickLookUI in the macOS app target. Any normalized workbook values model should remain platform neutral. Prefer another file-body implementation under the existing file tile identity rather than a new tile kind that duplicates placement/hydration.

## Options

| Approach | Realistic value | Limits / integration cost | License / maintenance evidence | Decision |
|---|---|---|---|---|
| Apple `QLPreviewView` | Embeddable AppKit preview host; avoids writing a workbook painter | OS/provider-dependent formats and appearance; no stable cell data API; first-render, sheet navigation, selection and failure behavior require testing | OS framework; Apple owns implementation. [API](https://developer.apple.com/documentation/quicklookui/qlpreviewview) | Next-release spike, then bounded preview feature |
| CoreXLSX | Swift XLSX extraction; can feed the same native grid as CSV | XLSX only, not XLS/ODS/Numbers; no full renderer, calculation engine or writing contract. Significant model/budget gaps below | Apache-2.0. Latest release page lists 0.14.2; do not infer active support solely from that. [Project](https://github.com/CoreOffice/CoreXLSX), [releases](https://github.com/CoreOffice/CoreXLSX/releases) | Best Swift candidate for a constrained XLSX follow-up, only after acceptance fixtures |
| SheetJS CE | One extraction engine for XLSX/XLS/XLSB/ODS/Numbers and many older types | JS runtime/bridge and binary transfer; broad format support does not imply visual fidelity. Requires independent resource protection | Apache-2.0 CE; Pro separate. Official standalone docs currently identify 0.20.3 and warn other mirrors can be stale. [License](https://docs.sheetjs.com/docs/miscellany/license/), [distribution](https://docs.sheetjs.com/docs/getting-started/installation/standalone/) | Credible later breadth candidate; prototype against CoreXLSX before selecting |
| libxls | Focused binary XLS reader from C/C++ | Adds C integration and another malformed-input surface for one legacy format; no XLSX/ODS/Numbers coverage | BSD 2-clause. Repository includes fuzz/test work; no maintenance SLA inferred. [Project](https://github.com/libxls/libxls), [license](https://raw.githubusercontent.com/libxls/libxls/dev/LICENSE) | Do not add solely to widen next-release checklist |
| Automate Excel/Numbers/LibreOffice conversion | Potentially richer producer-specific output | Installed-app dependency, permissions, process lifetime and conversion semantics; may trigger active content/recalculation and alter meaning | Separate products and distribution terms; no bundled conversion engine evaluated | Exclude from automatic preview pipeline |

Apple documents that setting `previewItem` loads asynchronously. Host cancellation and generation checks remain Array's responsibility when the user replaces a file or switches workspaces. Use refresh on actual file version changes, and explicitly tear down/release the preview at retirement; validate the SDK lifecycle contract during the spike. Disable automatic playback for any generic host reused by media. [previewItem](https://developer.apple.com/documentation/quicklookui/qlpreviewview/previewitem), [autostarts](https://developer.apple.com/documentation/quicklookui/qlpreviewview/autostarts?language=objc), [close](https://developer.apple.com/documentation/quicklookui/qlpreviewview/close())

## CoreXLSX: source findings that change the plan

These are observations of upstream `main`, not a claim that a pinned release was compiled or exhaustively tested:

- The [workbook model](https://raw.githubusercontent.com/CoreOffice/CoreXLSX/main/Sources/CoreXLSX/Workbook.swift) contains sheet names/IDs/relationships, but omits workbook date-system properties and sheet visibility state. An adapter must add those inputs before making dates or visible-sheet lists authoritative.
- The [cell model](https://raw.githubusercontent.com/CoreOffice/CoreXLSX/main/Sources/CoreXLSX/Worksheet/Cell.swift) separates formula and stored value, style index, inline strings and typed cells. Formula presence does not mean a stored result exists. Shared formulas also need their own compatibility fixtures; this small formula model should not be assumed to reconstruct every formula form.
- The [worksheet model](https://raw.githubusercontent.com/CoreOffice/CoreXLSX/main/Sources/CoreXLSX/Worksheet/Worksheet.swift) includes merges, dimensions, rows, columns and pane metadata. Reading metadata does not implement merge drawing, row visibility or frozen panes in Array.
- [XLSXFile.parseEntry](https://raw.githubusercontent.com/CoreOffice/CoreXLSX/main/Sources/CoreXLSX/XLSXFile.swift) appends extracted chunks to a `Data`, then decodes the whole XML entry. Its `bufferSize` is a chunk size, **not a decompressed-size limit**. Loading a single sheet still requires bounded shared strings/styles and workbook metadata.
- The [manifest](https://raw.githubusercontent.com/CoreOffice/CoreXLSX/main/Package.swift) adds XMLCoder 0.14.x and ZIPFoundation 0.9.x dependencies. Resolve/pin and review those actual versions and notices; Swift 6 compatibility, cancellation and malformed-file behavior are unverified.

## Data fidelity contract for a future grid

1. **Values and formulas:** keep raw typed value, displayed text and formula separately. Show stored results with a persistent "Saved values; formulas are not recalculated" description. Missing cached result must say "No saved result", not blank or zero. Do not claim cache freshness. Preserve error cells such as `#DIV/0!` as errors. SheetJS explicitly does not automatically calculate formulas. [Formula semantics](https://docs.sheetjs.com/docs/csf/features/formulae/)
2. **Dates and formatting:** read the workbook's 1900/1904 system; the same date differs by 1,462 serial days. Add boundary fixtures around Excel's 1900 leap-day convention, fractional times, ISO date cells, elapsed durations and custom formats. Do not guess dates from numeric magnitude or apply local timezone conversion to a timezone-free spreadsheet date. Keep unknown formats inspectable as raw values. [Microsoft date systems](https://support.microsoft.com/en-gb/excel/date-systems-in-excel), [format record](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-xls/4a5e900a-0eb0-4355-8fc1-81aab8f46e8b)
3. **Layout:** preserve sparse row/column coordinates rather than shifting nonempty cells left. Merges need top-left ownership, safe range bounds, collision handling and correct selection/copy semantics. A data view may show a clear merge indicator instead of reproducing workbook layout. Never silently duplicate the top-left value into every covered cell. [Merge semantics](https://docs.sheetjs.com/docs/csf/features/merges/)
4. **Hidden content:** honor hidden/very-hidden sheets by default; any explicit reveal must label them. Hidden rows and columns need the same deliberate treatment. Hidden is not encryption, but opening a file should not unexpectedly expose content its author hid. [Visibility metadata](https://docs.sheetjs.com/docs/csf/features/visibility/)
5. **Unsupported workbook features:** charts, embedded images, pivots, conditional formatting, validation, comments, print layouts and external-link calculations need explicit exclusions from the grid promise. A plain grid can still be valuable for data inspection. SheetJS CE focuses on extraction and common formatted text; advanced styling and broader encryption are separate capabilities. [Parser options and limitations](https://docs.sheetjs.com/docs/api/parse-options/)

SheetJS's format-specific notes are particularly relevant: its Numbers reader maps individual tables to worksheets, which changes Numbers' multiple-tables-per-sheet organization; ODS support emphasizes extracting/storing raw data rather than implementing the complete standard. Numbers formula extraction is not listed as supported in its formula matrix. This is useful data access, not faithful Numbers rendering. [Format notes](https://docs.sheetjs.com/docs/miscellany/formats/), [formula matrix](https://docs.sheetjs.com/docs/csf/features/formulae/)

## Resource and active-content boundary

The following are proposed Array requirements, not guarantees supplied by these libraries:

- No macro execution, formula evaluation, external workbook fetches, embedded-object activation or automatic opening of hyperlinks. Treat links as inert text until an explicit navigation action. Never shell out to an office application simply to render. XLSM/XLSB/XLS can contain macros; SheetJS's VBA option exposes a blob rather than providing a reason to execute it. [VBA storage](https://docs.sheetjs.com/docs/csf/features/vba/)
- Before parsing ZIP-based workbooks, cap compressed input, entry count, individual/aggregate decompressed bytes, compression ratio and entry-name length. Enforce actual extracted byte counts, not only central-directory declarations. Reject encrypted/unrecognized archives with a usable fallback.
- Never extract arbitrary paths to disk. Resolve internal package relationships within the validated package; reject traversal and external targets. XML DTD/entity/network resolution must be disabled/verified. Bound XML nesting, text size, shared-string count/length, cell count, merge count and index ranges.
- Parse off the main actor with a bounded concurrency queue and generation token. Cancellation of UI delivery alone does not stop memory-intensive parsing. For parsers that cannot enforce time/memory budgets internally, evaluate a separate disposable helper process before treating timeout as a hard guarantee.
- Derive limits from measured fixtures and publish truncation/limit states. A `sheetRows` option does not establish an overall ZIP/XML memory budget. Do not materialize a rectangular million-row × sixteen-thousand-column array from a claimed used range.
- Bound live view count; virtualize both axes for wide sheets. No view per workbook cell and no workbook measurement/parsing in `layout()`. Suspend hidden/offscreen bodies and bound aggregate caches across tiles. Follow Array's existing performance checklist with 1/4/9 open data tiles.

## Release acceptance and witness plan

**Next-release preview spike:** create synthetic XLSX, legacy XLS, ODS and modern Numbers fixtures with two sheets/tables, dates, a formula result and visible styling. Test the supported macOS floor and current OS, with and without installed office apps/providers where practical. Record actual sheet navigation, fidelity, accessibility, copy behavior, first useful paint, RSS, failure UI and teardown behavior. Do not use a Finder thumbnail as evidence that embedded `QLPreviewView` works.

**Deterministic host checks:** inject a preview adapter so missing renderer, asynchronous replacement, deletion/rename, rapid navigation, external modification, window removal and workspace retirement exercise production ownership. Verify the original file hash remains unchanged and no draft/save record is minted. Drive the production scene mount, register the witness in the matrix and confirm its reported run. Add a real bundle/manual fixture smoke because a mock cannot prove OS rendering.

**XLSX grid gate, if pursued:** fixtures for shared/inline strings, Unicode, sparse cells, boolean/error values, formulas with/without caches, shared/array formulas, 1900/1904 dates, custom number formats, merges, hidden/very-hidden sheets, empty/oversized/corrupt/encrypted files, hostile ZIP expansion, stale load completion and multi-tile performance. Assert normalized values and visible outcomes, not source strings. Ship it only once the adapter fills the missing metadata and rejects over-budget input deterministically.

Not run: Swift builds, matrix, workbook import prototypes, Quick Look runtime experiments or appearance rendering. No library installed or production files edited. All support/fidelity claims above remain source research until the proposed fixture gates are executed.
