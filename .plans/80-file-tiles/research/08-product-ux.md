# Product and interaction design for richer file tiles

Research date: 2026-10-23. Proposal, not an implementation or a support claim.

## Recommendation

Keep one file tile with a consistent document shell and renderer-specific bodies. Opening an image, dataset or PDF should feel like opening another project file, preserve its location on the canvas, and provide a useful view immediately. The near-release target should be excellent inspection and safe handoff to the owning application. Existing text editing remains available; adding broad binary editing would turn this release into an office-suite project.

Separate three concepts explicitly:

- **Document identity:** path and project ownership; common to every view of a file.
- **Presentation:** image, table, workbook sheet, PDF page or source text.
- **Capability:** read-only inspection versus an editable text draft. A preview is never an implicit promise that Array can save the displayed representation.

Use the existing file tile rather than minting a different persisted tile kind for every extension. This preserves file opening, agent references, workspace restoration, title-bar navigation and project ownership. Renderer-specific view state can persist separately from document data.

## What exists today

- `Sources/ContinuumRevivedCore/FilePreview.swift:5`: only text/unavailable outcomes, UTF-8 text loading and a 1 MiB guard. Markdown/source are the only presentations. Current messages conflate unsupported binary content with a file to open in an editor.
- `Sources/ContinuumRevived/Canvas/FileTileNSView.swift:8`: already owns a substantial editor shell: optional file browser, document switching, reference links, code editing, recovery, saved/draft baselines and external-change detection. Extend behind this shell rather than adding another parallel controller for every file type.
- `FileTileNSView.swift:878`: Markdown has Preview/Split/Edit, reflecting the same draft. `:902`, `:948`, `:1021`: explicit save and conflict handling already exist and must remain authoritative for editable text.
- `FileTileNSView.swift:194`: title-bar Finder action; `:196`: focus promotes a resident body before targeting its responder; `:213` onward: surface residency is already sensitive to scroll offsets and content epochs. New bodies must participate correctly rather than attaching independently.
- `Sources/ContinuumRevived/Canvas/TileNSView.swift:6`: title bar is the tile move target, body is content interaction; do not make an image pan move the tile or make data scrolling pan the canvas.
- `Canvas/AgentComposer/ChoiceButton.swift`, `ChoicePopoverController.swift`, `ChoiceListView.swift`: common token styling, keyboard focus, typeahead, disabled choices, accessible selection and cancellation. New view/sheet/zoom/import choices should use these. Existing stock menus inside FileTileNSView are legacy code, not a pattern for the new controls.
- Read-only review of `/Users/dylan/array-worktrees/note-file-markdown`, HEAD `083d7ba6` (Add shared Markdown document surface): the shared draft/preview idea is established there and already represented in the current checkout. Do not base work on that older tree or modify it.

## Common shell

Retain filename in the title bar and disclose the complete path via its existing context/Finder affordance. Avoid turning the 24-point title bar into an office ribbon. Put renderer controls in one compact body toolbar, using the shared tokens and metrics; let nonessential metadata collapse as width shrinks.

Common actions: Open Externally, Reveal in Finder, Reload and Info. Label the external action with the resolved application name where reliable; otherwise use Open Externally. Info holds file type, size, location and last modification time plus renderer-specific metadata. Read-only is an explicit capability label where an editor might reasonably be expected, especially workbooks and data previews. Do not leave a disabled Save button as its explanation.

Use a small status area for meaningful state: Loading, Updated on disk, Unsaved changes, Changed on disk, Partial preview, Unable to preview. Messages include a useful next action. Preserve these distinctions: unsupported format, malformed file, inaccessible path, missing path and resource limit. A decoder error should not appear as File not found.

Selection, search, sorting, changing sheets/pages, image zoom and metadata inspection never mark a file dirty. Persist view preferences only; none rewrite the file. Reload retains the closest valid sheet/page/scroll/selection rather than resetting the whole document. A stale preview can remain visible while a new version loads, with its status stated; generation checks must prevent completion from an earlier file replacing a newly selected file.

## Presentation and editing semantics

| Content | Initial presentation | Other useful views | Editing promise for this release |
| --- | --- | --- | --- |
| Source text | Existing editor | Existing language services | Preserve current explicit save/recovery contract |
| Markdown | Existing Preview/Split/Edit | Shared draft across all three | Preserve current contract |
| Raster image | Image, fit in body | Actual pixels, metadata, frames/pages if supported | Read-only; Open Externally |
| SVG | Safe image rendering when supported | Source/Edit through existing text document | Source editing only; no drawing tools |
| CSV/TSV | Table | Source; parsing settings | Table inspection first; source editing only within existing safe editor bounds |
| XLSX | System workbook preview when its provider qualifies | Later: native grid, sheet picker, cell value/formula detail | Read-only; provider-dependent preview first |
| PDF | Page preview | Page navigation, fit width/page, text selection/search where supported | Read-only; Open Externally |
| JSON/JSONL | Existing source initially | Later structured view / record table | Existing text edit contract |
| Unsupported file | Metadata and handoff | System preview when reliable and isolated | No edit claim |

Use Preview/Source labels only when both representations are meaningful. Do not present a meaningless Source toggle for JPEG or XLSX bytes. Do not repurpose Markdown's persisted mode enum to express workbook or image state. Do not expose an Edit label for a read-only data grid. A grid editing milestone would require its own honest scope, undo, recovery, conflict handling and lossless round-trip qualification.

SVG source edits should update its preview from the same draft, not silently reload the saved bytes. CSV source edits similarly rebuild the table from the draft when the user returns to Table. Malformed drafts remain editable with a parse error; never replace the draft with a guessed corrected serialization. If a format is viewable above the editor's byte limit, explain why source editing is unavailable rather than attempting an unbounded editor load.

## Image experience

Fit is the default. Provide Fit and Actual Pixels choices plus readable content zoom. Actual Pixels must mean one source pixel per backing display pixel, tested on Retina and non-Retina; avoid an ambiguous 100% label if the mapping differs. Image content zoom is separate from canvas zoom, with unambiguous labels and focus-scoped commands. Keep canvas wheel/pinch conventions consistent; do not silently steal them everywhere in an image tile. Prefer explicit controls first and add content gestures only with a clear focused-body contract.

Transparency uses a quiet checkerboard, with an optional light/dark background choice for asset inspection. Preserve the original color appearance; do not recolor pixels when Array's theme changes. Fit never stretches aspect ratio. Show dimensions, format and image/frame count in metadata. A multi-image file is not a single image pretending to show all of it: identify the current page/frame and allow navigation where supported. Animation defaults to a still frame; explicit playback stops when hidden or parked and respects reduced-motion preferences. No autoplay across a canvas full of GIFs.

Keep image content unobscured by controls. Apple distinguishes displaying images from making a button out of an image and cautions about overlay legibility; controls around the content suit this case. [Apple Image views](https://developer.apple.com/design/human-interface-guidelines/image-views).

## Data and workbook experience

Show row numbers, stable column headers and resizable widths. Preserve text faithfully: postal codes, long IDs, leading zeroes and date-like strings must not be silently coerced. Type inference is an optional presentation aid, with the raw value always reachable. Empty, absent and null are not interchangeable. Embedded newlines can be visually shortened in the grid but the selected-cell detail displays the full value.

Provide a selected-cell detail strip that can expand to show/copy a long value without making every row dynamically tall. For workbooks, identify address, displayed value and formula separately. Clearly state when formula results are cached or unavailable. Never present an uncalculated formula as a verified current result. Render unsupported workbook features as omissions with a visible notice; charts, formatting, merged cells and hidden content must not be silently claimed as supported.

For a later native workbook grid, sheet choices use `ChoiceButton` with count and selected name; a workbook with many sheets should not require dozens of horizontal tabs. Start on the first visible sheet, expose hidden sheets only through an explicitly labeled choice if supported, and preserve selection on reload by identity/name rather than index alone. The first-release Quick Look adapter exposes only controls its provider actually supports; these grid requirements do not imply host control over system-preview internals.

CSV dialect controls belong behind a compact Parsing choice: delimiter, header interpretation and supported encoding. Guess, show the guess, and let users correct it. A delimiter or header change is a view change, never a rewrite. Missing headers use Column A/B/etc.; duplicate headings remain distinguishable by position. Do not rename actual fields in the file.

Selection and Copy are the baseline useful operations. Copy a rectangular selection as TSV; copying a single cell copies its full value. Search works over the declared scope, with unloaded/indexing/partial state explicit. Sorting/filtering can follow only when the implementation can honestly state whether it operates over the entire dataset. A sample of 10,000 rows sorted locally must not look like a global sort. Always label sample/limit counts and offer a continuation or external handoff.

Apple recommends descriptive headers, resizeable columns and useful column sorting in macOS tables. Those are appropriate affordances here; sorting remains a projection rather than a change to the source. [Apple Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables).

## Save and outside changes

Continue explicit Command-S for editable text and the existing clean/dirty/conflict state machine. A view-only renderer should refresh after an outside write while preserving view state; a broken or mid-write version should produce a recoverable status rather than flashing a generic missing placeholder. No automatic conversion or save-back for workbooks, images or PDF.

Dirty drafts must survive renderer changes, workspace switches, file navigation and application restore. A save failure leaves both the draft and dirty indicator intact. A conflicting external change is visible immediately, not only when Save is pressed. Retain Cancel, Reload from Disk and explicitly destructive Overwrite; offer Save Copy where useful. A future compare action can improve this, but a comparison UI is not a prerequisite for the preview release.

Deletion, rename and replacement need the existing file-operation behavior: do not recreate a removed file just because a preview refreshed. If another tile opens the same path, text sessions need a documented ownership/conflict contract; adding formats must not introduce divergent saves. Read-only tiles can share immutable decoded representations and invalidation without sharing local selection.

## Keyboard, accessibility and small tiles

Every action must be reachable with Full Keyboard Access and expose a meaningful accessibility label/value. Selection, dirty/conflict/partial states use words or symbols as well as color. In a data grid, expose row/column headers, cell coordinates, value and selection to VoiceOver; a custom-drawn grid without a usable accessible table is not release complete. Do not create one accessibility object per million cells up front: represent visible/queried cells lazily while retaining logical table counts and navigation.

Scope Command-C, Command-F and Command-S to the actual focused body. Arrows navigate a focused grid; Shift extends selection; Escape closes a popover/search before affecting the tile. Tab must offer a way out of the grid to the toolbar/canvas rather than trapping keyboard users. Keep existing editor undo, save and find behavior intact. Do not assign new app-wide shortcuts until existing bindings are audited. Shared Choice controls already implement arrow navigation, Home/End, Return, Escape and typeahead; reuse that behavior.

At narrow widths retain the selected sheet/view and external handoff; collapse secondary controls into a shared Choice action menu. At low canvas zoom, a file can become a surface snapshot, but gaining keyboard focus must restore its real interactive body. Enlarging body text/content cannot require enlarging the entire canvas.

Apple recommends preserving familiar shortcuts and testing Full Keyboard Access. Its accessibility guidance calls for adaptable text, contrast checks in both appearances and information conveyed beyond color. These support the requirements above; the exact grid and tile behavior is this proposal. [Apple Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards), [Apple Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility).

## Performance is part of the interaction contract

Opening a large file yields a responsive loading state, with cancellable work when the path changes or tile retires. Data bodies virtualize rows and columns; image bodies decode at appropriate resolution. Panning the canvas cannot rescan a workbook, parse CSV, decode images, measure every cell, or regenerate a PDF page. File and theme changes invalidate only the required cached representation. Parked previews stop animation and unnecessary observation; reactivation validates freshness.

Do not quietly truncate. A partial preview reports what is shown, whether counts are known and which operations cover only the preview. See `docs/internals/performance.md` and `TileNSView`'s surface/parking lifecycle. These are requirements for the design, independent of whichever backend is chosen.

## Suggested release boundary and acceptance evidence

Recommended first slice: common shell/capability states, broad still-image inspection, virtualized CSV/TSV inspection and a bounded workbook preview if fidelity, accessibility and performance qualify. PDF is a valuable adjacent addition if its lifecycle can share this shell; it should not displace the requested data work. JSON/JSONL structured views and audio/video inspection are good later additions. Keep the source editor functioning as it does now.

Before release, behavior witnesses should drive real opening and workspace restore; verify the selected presentation, visible content, no writes during inspection, preservation of source drafts on view changes, external refresh/conflict behavior, and teardown of loads/watchers. Include real adversarial content: transparent and very large images, multi-frame images, quoted newlines and ragged CSV, zero-prefixed IDs, huge/wide cells, duplicate headers, multi-sheet workbooks, formula-only/cached cells, malformed files, rename/delete, and a file changing during load. Appearance sweeps cover both light and dark; interactive QA covers VoiceOver, keyboard-only use and mouse/trackpad scrolling. Matrix legs must assert outcomes, not source strings.

## Explicit non-goals

- Spreadsheet formulas/recalculation, pivots, workbook authoring or lossless XLSX editing.
- Image retouching, cropping, annotation, conversion or animation editing.
- PDF editing, signatures, OCR or document conversion.
- Running HTML/scripts/macros or activating workbook external connections to obtain a preview.
- Network-backed data import, a database client, or dashboard/chart authoring.
- Silent encoding conversion, automatic value coercion, or save-back of sorted/filtered rows.
- A new separate persisted tile kind per file extension.

## Decisions to settle before implementation

1. Exact file support matrix and honest fallback: distinguish fully supported, partial preview and external-only. Choose against real fixtures rather than a list of extensions.
2. Whether workbook cached-value fidelity qualifies for the upcoming release. If not, ship CSV/images first and make XLSX the immediately following milestone.
3. The grid's accessibility implementation and scale limits; qualify this before polishing a custom renderer.
4. Content zoom ownership relative to existing canvas/editor shortcuts and gestures; test focused versus inactive tiles.
5. Whether Source for CSV/SVG is a same-tile mode in the first slice or a later extension. Same-draft consistency is mandatory if offered.
6. Which view state is worth restoring (sheet, image fit/zoom, PDF page, table widths); classify any persisted keys in `WorkspaceAPIExposure` as required by AGENTS.md.
7. The scope and latency of Find/sort/filter. Omit controls whose global semantics the backend cannot meet.

## Research limits

No UI implementation, app launch, rendering, runtime tests or performance measurements were performed in this UX research. Apple HIG pages were inspected on the research date; the web tool exposed JavaScript shells, so their linked Markdown versions were read using `curl`. Recommendations about Array-specific controls, release scope, conflict behavior and grid semantics are design judgments grounded in the inspected code, not claims from Apple.
