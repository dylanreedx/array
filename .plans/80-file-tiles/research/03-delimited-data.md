# Delimited data: a trustworthy CSV/TSV viewer

Research date: 2026-10-23. Planning only; no renderer or parser implemented and no runtime claims verified.

## Recommendation

Ship a read-only, native, virtualized **data view** for CSV and TSV in the next release, with a source-view escape hatch. Preserve cell strings exactly; make interpretation settings visible. Read-only here is a data-grid contract: existing source editing can remain available for small supported text files, with the current save/conflict/recovery protection. Grid editing is a separate milestone because serialization is the difficult part, not making an NSTextField editable.

The first version should be useful for real data work: resizing columns, pinned column headers, stable row numbers, keyboard navigation, exact cell inspection/copy, selected-row copy, find, and explicit header/delimiter settings. Global sort/filter is desirable, but must carry an honest complete-file contract; a partial preview must never appear sorted or filtered as though it covered the entire file.

## Repository findings

- `Sources/ContinuumRevivedCore/FilePreview.swift` admits at most 1 MiB, reads the full file, accepts UTF-8 only, rejects UTF-16/32 BOMs and early NUL bytes, and classifies only source text or Markdown. CSV therefore appears as generic text today.
- `Sources/ContinuumRevivedCore/FileDocumentSession.swift` owns a full UTF-8 draft/baseline and synchronous disk reads; its init reads immediately. It rejects the same larger files and non-UTF-8 encodings. Saving uses UTF-8 and atomic replacement; do not route a decoded UTF-16 CSV through this session and silently change its representation.
- `Sources/ContinuumRevived/Canvas/FileTileNSView.swift:101` creates the text session before `loadFile()` separately calls `FilePreview.load` around line 1421. Simply bolting a grid onto `apply(.text)` inherits both full-read paths and the cap. File classification must happen before allocating the text session.
- Tile document generation already guards asynchronous preview delivery; retain that discipline for parsing, page requests, queries and external changes. The current timer and signature machinery need a structured-document path rather than an unconditional full-text refresh.
- `Package.swift` already includes GRDB in Core. A later temporary SQLite query index would not require adopting a new analytics runtime. This is an architectural option, not a claim that the current auth databases are reusable document stores.
- `docs/internals/performance.md` explicitly requires bounded view counts, no measurement in layout, visible disclosure of partial output, count-based witnesses and legacy-scroller coverage. A grid must satisfy these from its first implementation.

## Primary-source evidence

RFC 4180 is Informational, not a universal standard. It describes optional headers, quoted fields containing delimiters and line breaks, doubled quotes, spaces as meaningful content, and a final record without a terminating newline. Its interoperability notes acknowledge divergent implementations. A parser based on `split("\n")` then `split(",")` is therefore incorrect for ordinary CSV. [RFC 4180, §§2–3](https://www.rfc-editor.org/rfc/rfc4180.html)

W3C CSVW describes dialect properties including encoding, delimiter, quote handling, header rows, line terminators, blank rows and trimming. Its schema layer distinguishes string representation from typed interpretation. This supports an explicit parsing-settings model; implementing the full CSVW metadata specification is not a requirement for Array's first viewer. [W3C Metadata Vocabulary, dialect descriptions](https://www.w3.org/TR/tabular-metadata/#dialect-descriptions)

Apple documents NSTableView as a data-source-driven control. Its view-based tables reuse cell views, support native row selection and column resizing/reordering, and supply useful accessibility semantics. This is a good native starting point, but it does not automatically supply spreadsheet-style rectangular cell selection or a bounded arbitrary-width dataset. Measure those properties rather than assuming them. [Apple NSTableView](https://developer.apple.com/documentation/appkit/nstableview), [Apple table view programming guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TableView/TableViewOverview/TableViewOverview.html), [Apple reusable cell delegate](https://developer.apple.com/documentation/appkit/nstableviewdelegate/tableview(_:viewfor:row:))

DuckDB offers CSV dialect/type inference, explicit dialect overrides and `all_varchar`, plus bounded sampling options. It is a credible later analytics backend, but introducing a database runtime solely to draw CSV rows is not justified yet. Compare it only if Parquet/SQL/large global queries become approved scope. [DuckDB CSV import](https://duckdb.org/docs/current/data/csv/overview), [DuckDB auto detection](https://www.duckdb.org/docs/2.0/data/csv/auto_detection)

Formula-like text copied into another spreadsheet can become executable formula content there. Do not evaluate CSV formulas in Array, and do not promise that quoting alone sanitizes exports. Exact copy and any future spreadsheet-safe export are different operations; sanitization must never silently alter the original file. [OWASP CSV injection](https://community.owasp.org/attacks/CSV_Injection)

## Parsing and fidelity contract

1. Use a streaming state machine with `fieldStart`, `unquoted`, `quoted` and `afterQuote` states. Retain parser state across byte chunks, including a quote, CRLF pair, UTF-8 scalar or UTF-16 code unit split at the chunk boundary. Newlines inside quotes are field content. EOF finalization must distinguish a valid final field from an unterminated quote.
2. Default `.csv` to comma and `.tsv`/`.tab` to tab; bounded sniffing may suggest semicolon or another supported separator, but surface the result and allow override through Array's Choice components. A `.txt` file should not suddenly become a grid because it happens to contain commas. Avoid automatic comment skipping or Excel `sep=` handling without a visible dialect decision.
3. Recognize UTF-8 with/without BOM and BOM-marked UTF-16 LE/BE for data view. Validate decoding; never replace invalid sequences silently. Offer a small explicit legacy-encoding choice when needed, or a precise unsupported-encoding message. Avoid guessing a single-byte encoding that can decode every byte but produce incorrect text. UTF-32 and compressed CSV can be deferred with a clear explanation.
4. Preserve leading/trailing spaces, empty strings, empty final fields, line breaks in quoted fields, duplicate/empty column labels, and original row order. Do not coerce identifiers (`00123`), large integers, timestamps, `NA`, `null`, `1e12`, phone numbers or formula-like strings. Visual numeric alignment may be inferred only as a presentation hint.
5. CSV has no intrinsic null/type schema. Distinguish a missing field in a ragged record from an explicitly empty field. An inspector can show “Missing field” versus `""`; don't drop excess fields to fit a guessed header width. Column identity is ordinal, never its possibly duplicated title.
6. Header interpretation is user-controlled. A visible “First row is header” choice is more trustworthy than confident inference. If defaulting it on for CSV usability, preserve a persistent, obvious off switch and make the first record recoverable immediately. Empty files and header-only files have distinct states.
7. Report malformed records with logical record number and physical line/byte position. An unterminated quote invalidates knowledge of later record boundaries: stop at that position and disclose it. Do not claim an exact total count after a parse error or skip records invisibly.

## Large files and resource bounds

Recommended first-release architecture is an asynchronous, cancellable reader with a quote-aware **sparse record-offset index**, not `[[String]]` for the entire file. Emit the first page quickly, then index incrementally on a low-priority worker. Store an offset every fixed number of logical records; page requests seek to a checkpoint and decode only a bounded page. Keep a byte-budgeted LRU of decoded pages. Count rows exactly only after reaching EOF. “120,000+ rows indexed” is honest during indexing; “120,000 rows” is not.

Sparse indexing bounds metadata growth by a much smaller coefficient, but is still proportional to record count. Set explicit index/cache/scan budgets and stop with a visible partial-state notice if exceeded. For a future effectively unbounded mode, move index blocks to a disposable cache file rather than a giant Swift array. Do not persist dataset copies or indexes in `.array/` by default; cache ownership, expiry, privacy and a shared per-app budget need explicit decisions.

Proposed engineering starting budgets, to validate with real fixtures: 256 KiB input chunks, 256-record checkpoints, 128-row decoded pages, 8 MiB decoded-page cache per active document, 4 MiB maximum individual logical record and 256 concurrently exposed columns. These are design inputs, **not measured capacities or shipping commitments**. Large records get an explicit limit/error and external-open action. A very wide file needs a column chooser/window so later columns remain accessible; it must not silently lose columns. A document-wide cache budget is insufficient if dozens of restored tiles each allocate it: add shared scheduling and an aggregate budget.

Do not rely on memory-mapping alone as proof of bounded resident memory. Avoid scanning a restored offscreen document until its renderer is admitted by the canvas visibility/lifecycle policy. Closing, switching documents, removing a tile, changing dialect or changing generation cancels work and drops stale callbacks. A shared read-only document service may deduplicate repeated opens without sharing incompatible view settings.

The table data source must never synchronously read disk. It serves cached data or an explicit loading state and schedules a page. Fixed-height single-line rows avoid per-cell multiline measurement; a detail inspector exposes complete multiline values. Determine initial widths from a bounded sample and cap them. Row count, column count and maximum field length are separate scalability axes. Verify NSTableView's cell count on wide data; row virtualization alone is insufficient.

External changes invalidate the record index and page cache as one generation. Watch atomic replacement as well as in-place writes. If mutation occurs during indexing, stop/reload with visible status instead of mixing generations. Existing source editor drafts remain owned by their text session: grid/source transitions must not discard drafts or render stale disk while claiming to show the current draft. For the initial version, disable data view while a source draft is dirty unless data view explicitly parses that draft.

## Interaction semantics

| Feature | First useful contract | Larger-file extension |
| --- | --- | --- |
| Find | Literal, cancellable, all indexed/source records; show progress and incomplete state until EOF | Stream matches with bounded retention and next/previous navigation |
| Sort | Only if the entire result can be computed within explicit budgets; stable ordering, selectable lexical/numeric interpretation | Disk-backed sort/index after a dedicated proof |
| Filter | Literal contains/equality by column; displayed `matched / scanned`, incomplete until EOF | Disk-backed result ordinal map; explicit null/missing semantics |
| Copy cell | Exact decoded string, including newlines and leading zeros | Bound oversized clipboard operations with an explicit action |
| Copy rows | Correct escaped CSV or documented TSV flavor; no hidden header insertion | Cancellable export to a new file rather than main-thread clipboard allocation |
| Selection | Native row selection plus a keyboard-addressable active cell and value inspector | Rectangular range selection only after explicit interaction/accessibility work |
| Source | Available through existing text editor only within its supported encoding/size contract | Dedicated large-source viewer; don't raise the editor cap blindly |

For a near release, prioritize find over global sort/filter if time is constrained. Never enable a header-sort arrow that only rearranges cached rows while appearing global. Full-file lexical sorting can be an optional bounded small-file capability, clearly disabled beyond its budget. Numeric sorting must not use lossy floating-point coercion for arbitrary integers or identifiers.

## Staged delivery

1. **Shared file dispatch and lifecycle seam.** Choose content kind before text-session construction; async read-only document model, generation/cancellation, status/errors, view-state separation. Keep existing editor save/recovery tests green.
2. **Correct CSV/TSV core and small-data UI.** Streaming parser fixtures, explicit dialect/encoding/header state, reusable native table, keyboard cell inspection/copy, source fallback, light/dark rendering and accessibility.
3. **Real data scale.** Sparse indexing, page cache, cancellation, external replacement, clear partial-state presentation, bounded find and shared aggregate budgets. Validate hundreds of MB as well as tiny malformed files. This is part of “properly,” not optional post-release cleanup.
4. **Convenience queries if the gate remains small.** Bounded complete-file sort/filter. If global query behavior needs a new disk query engine or delays release, defer it explicitly rather than shipping misleading partial semantics.
5. **Later write contract.** A grid edit must preserve encoding/BOM/newlines/quoting and detect conflicts, support undo/recovery, and avoid rewriting unrelated values. Decide whether byte-level minimal edits or canonical serialization is acceptable before promising it. Workbook formulas and XLSX writing are outside this CSV milestone.

## Required behavioral witnesses

Proposed flags below are **new planning names**, not existing runnable flags. Register actual implemented checks in the matrix and confirm the summary reports them.

- Core parser witness: every chunk boundary across quoted delimiters, doubled quotes, multiline fields, CRLF, multibyte Unicode, UTF-16 BOM and surrogate pairs; final line without newline; empty file/header-only; trailing empty fields; duplicate headers; ragged records; invalid encoding and unterminated quotes. Assert exact cell strings and record offsets, not source strings.
- Fidelity witness: `00123`, an integer above 2^53, `NA`, formula-like content and ambiguous dates survive grid load/copy without coercion. Disk bytes remain unchanged after every read-only interaction.
- Resource witness: grow rows, columns and field length independently; assert maximum decoded bytes, live cells, queued page work, index bytes and maximum record allocation. A pan/resize/appearance flip on unchanged content must cause zero parsing and zero new content measurement. Print coarse timing/RSS alongside counts.
- Lifecycle witness: close/reopen, workspace switch through the production boot/mount path, repeated tile opens, external atomic replacement while indexing, deleted file, dialect change mid-page-read, and offscreen restored tiles. Assert cancellations, no stale publish and no duplicate workers.
- UI witness: scroll beyond first page to a known tail record; navigate a column beyond the visible-column window; selected-cell exact copy; correct row identity after any sort/filter; full multiline inspector; explicit partial/error state; `.legacy` and `.overlay` scrollers; light/dark; keyboard and VoiceOver labels.
- Integration witness: opening via tree and workspace API resolves the intended project/zone, preserves world frame and existing tile identity, and rehydrates the data renderer. A data view must not become a new tile kind unless necessary.
- Query witness if included: sentinel match beyond the initial page, stable tie order, cancellation, budget refusal, correct incomplete counts and no false complete result. Editing source then requesting grid must surface the draft policy.

## Open decisions for the parent plan

- Next-release mandatory surface: CSV/TSV grid plus find; whether global sort/filter fits the release is a separate scope choice.
- Confirm representative real datasets with Dylan before freezing budgets; current numerical budgets are hypotheses.
- Share the grid's immutable page contract with XLSX research, while keeping workbook sparse cells, formatting, formulas and worksheet semantics distinct from CSV.
- Follow up on JSONL, Parquet and SQLite viewing after the common lifecycle and grid are proven; those are useful additions for data work but should not inflate the initial CSV implementation.

## Work performed

Read AGENTS.md, performance guidance, current FilePreview/FileDocumentSession/FileTileNSView and package dependencies; consulted the primary sources linked above. Wrote this planning note only. No app builds, matrix runs, runtime benchmarks, preview launches or production edits were performed.
