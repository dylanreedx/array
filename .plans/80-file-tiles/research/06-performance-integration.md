# File viewers: performance and lifecycle integration

Research only, 2026-10-23. Source references below describe the research worktree;
numbers marked **proposed** are design inputs to measure, not verified budgets.
No app, checks, builds, default tmux socket, production state or preview was run.

## Recommendation

Keep images and data documents within the existing `.file` tile identity, with
separate renderer/document sessions behind the shell. Classification must happen
before creating a text editor or `FileDocumentSession`. Make the loading contract
asynchronous and cancellable before supporting large images or workbooks. A new
renderer must have a bounded presentation working set even when the file is
unbounded. Put source parsers and data access behind UI-independent interfaces so
they can proceed while the canvas motion work lands.

The near-term release should not depend on a general canvas rewrite. It does
depend on agreement with the active motion branch about the file body's mounting,
snapshot and animation contracts. Rich file types should not each invent their
own visibility/LOD state machine.

## Findings from the current implementation

| Finding | Exact source reference | Consequence |
| --- | --- | --- |
| File tiles eagerly construct `FileDocumentSession` before `super.init`, then call `loadFile()` again. Session initialization reads disk. | `Canvas/FileTileNSView.swift:98–101,154`; `Core/FileDocumentSession.swift:100–111,239–269` | Moving only preview decoding into a detached task leaves the first read on the main thread and duplicates reads. Binary viewers should never instantiate the text session. |
| `loadFile` uses an unretained detached task only for a non-local volume. Local files use synchronous `FilePreview.load`. | `Canvas/FileTileNSView.swift:1421–1440,1962–1969` | Larger local images/data need a new loading seam; keep heavy reads and parsing out of init and layout. |
| Async load has a generation guard, but the task is not retained/cancelled; removal does not change that generation. | `Canvas/FileTileNSView.swift:32,1429–1435,170–179` | Stale application is guarded for document navigation; resource consumption and scene-removal cancellation still need explicit ownership. Cancellation alone also needs a generation check. |
| Text preview and text session cap at 1 MiB and reject binary/non-UTF8 data. | `Core/FilePreview.swift:4,88–130`; `Core/FileDocumentSession.swift:81,239–269` | Raising this one cap is the wrong architecture. Each format needs compressed-byte, expanded-byte, record/dimension and decoded-resource admission limits. |
| A one-second timer checks file signatures and can reload text. It is controlled by window attachment rather than viewport visibility. | `Canvas/FileTileNSView.swift:161–168,946–975,1843–1851` | Do not copy one timer per image/workbook. Coalesce file observations by canonical document and distinguish semantic change from visible rendering. |
| Scene removal already flushes recovery, persists editor view state, stops the browser and tears down WebKit. | `Canvas/FileTileNSView.swift:170–179` | Add cancellation, decode release and animation stop here while preserving editor recovery. Binary viewers should not enter dirty-text capture/save flows. |
| File tiles hydrate in Phase A using their own project's controller. | `App/ContinuumApp.swift:20338–20364,20377–20407` | Use the same renderer factory from boot/spawn and hydration; do not introduce a second opening path or perform migration/persistence from render initialization. |
| Persisted tiles can be absent from the live tier. Persistence merges covered zones rather than replacing the whole project tile set. | `Canvas/CanvasNSView.swift:6973–7027`; `Core/CanvasPersistenceMerge.swift:33` | Renderer eviction must not delete tile metadata, file references or viewer state. Test non-live-zone preservation. |
| Zone hydration defaults to four live zones, not a file-memory budget. | `Core/ZoneHydrationBudgetConfig.swift:9–12` | Four zones can still contain hundreds of images. Add a shared document resource budget, not a per-zone image allowance. |

References use `Sources/ContinuumRevived/` for `Canvas/` and `App/`, and
`Sources/ContinuumRevivedCore/` for `Core/`.

## Existing surface cache is a separate budget

`TileNSView.swift:367–443` opts each family into surfaces and asks it for content
revision, animation status and scroll offsets. `FileTileNSView.swift:225–249`
currently excludes source/Markdown editor WebKit bodies and opts Markdown preview
into snapshots. Its body handle is tracked separately from the surface host.

`CanvasNSView.swift:4130–4240,4500–4595` prioritizes visible bodies, caps bakes,
checks duplicate IDs, focuses/animation, content revisions, body size, appearance,
scroll offsets, sharpness and memory admission. Baking parked bodies is known
incorrect. Do not bypass this with an image viewer's own subtree capture.

Current policy has a 256 MiB surface-store cap
(`Core/TileSurfaceResidencyConfig.swift:58`), a nominal 24 MiB per baked surface
density cap (`Canvas/TileResidencyPolicy.swift:56`, with rest-density allowance),
and four normal bakes per pass (`TileSurfaceResidencyConfig.swift:46`). These
are canvas surface limits, **not** limits on source bytes, decoded images, grid
cells, workbook models, WebKit processes or animation frames. A 10 MB compressed
image can decode into hundreds of megabytes. Avoid counting only the disk size.

A still image already backed by an admitted `CGImage` may ultimately supply a
direct presentation resource rather than acquire a second raster copy, but that
is a proposed extension requiring pixel/fidelity and lifecycle evidence. Do not
assume the current surface cache supports direct provider images.

Animated formats must report `surfaceIsAnimating` while playing or explicitly
pause with an honest playback indicator; otherwise a quiet tile can freeze on a
cached frame while claiming playback. Frame changes, image orientation/zoom,
sheet selection, cell formatting, search highlights and data scroll must all
invalidate or participate in the renderer revision vector. Do not enumerate a
grid/document tree to compute that vector on every 10 Hz residency pass.

## Concrete overlap with work already in flight

Read-only `git status --short` and `git log -6 --oneline` were run in
`.worktrees/canvas-motion-perf`. No source files there were read or edited.
At inspection its HEAD was `81bb3717` and the visible recent sequence included:

- `81bb3717 perf(transcript): retain unchanged cells across structural updates`
- `c9c080a1 perf(transcript): read the stream source only for reasoning deltas`
- `05b3c12a perf(markdown): skip re-rendering an unchanged preview draft`
- `3e3d86e9 perf(canvas): pace camera commits from completion, not start`

Its dirty tracked paths overlap directly: `App/ContinuumApp.swift`,
`App/TileSurfaceResidencyChecks.swift`, `Canvas/CanvasNSView.swift`,
`Canvas/FileTileNSView.swift`, and `Canvas/TileNSView.swift`. Untracked paths were
`App/CanvasMotionPresentationChecks.swift` and `App/CanvasMotionWorkload.swift`.
Status is evidence of overlap, **not evidence of the unpublished implementation**.

Landing sequence:

1. Begin Core content classification, parsers, bounded document readers, fixtures
   and the renderer protocol without editing those overlapping host files.
2. Before host integration, obtain the motion branch's final lifecycle/snapshot
   contract and land/rebase that work first where practical. Do not reimplement
   `surfaceableBody`, promotion, mounting or camera invalidation in parallel.
3. Integrate the file host/factory in one scoped pass across spawn, hydration,
   document replacement and removal. A build-time protocol stub is sufficient
   for independent parser work; a guessed canvas lifecycle is not.
4. Run existing Markdown/editor/navigation/residency witnesses and a mixed file
   motion fixture on the combined tree. Preserve the motion branch's accepted
   work ceilings; do not normalize a slower mixed scene as the new baseline.

## Proposed architecture and budgets to calibrate

These are **proposed**, not measurements or release claims.

- Shared loader/resource coordinator, not one unbounded detached task per tile.
  Start calibration with two heavy decode/parse jobs active and a finite pending
  queue; prioritize focused, visible and halo requests. Coalesce duplicate file
  requests and discard queued offscreen work. Keep I/O/probe work distinct from
  AppKit apply work.
- Request identity: canonical document scope + file identity/signature + tile
  document generation + renderer revision + requested size bucket. Retain a task
  handle and cancel on replacement/removal/demotion. Check identity before
  applying completion. Cooperative cancellation must be checked inside long
  parsers, index construction and archive entry loops.
- Image loading: probe dimensions/frame count/orientation first, use thumbnail
  decoding to admitted output dimensions, cache by signature/orientation/size
  bucket, and decode full detail only when explicitly requested/admitted. Start
  measuring with 32 MiB max ordinary decoded still per tile and 128 MiB shared
  decoded-image pool; these are tuning candidates in addition to the canvas
  surface cache, never an entitlement per tile. Oversized source dimensions need
  overflow-safe arithmetic and visible fallback rather than a full decode.
- Animation: a bounded frame window and one playback owner; stop playback when
  dormant or occluded. Do not preload every GIF/APNG/WebP frame. The actual
  formats supported are determined by the image research track, not assumed here.
- CSV/data grids: virtualize rows **and columns**; initially propose materialized
  cell views `<= visible cells + one viewport halo`. A wide CSV must not allocate
  one `NSTableColumn`/view for every source column or auto-measure every cell.
  Column widths should sample a disclosed bounded prefix or visible cells.
- Workbook import: separately cap archive entries, expanded bytes, sheet/row/
  column coordinates, shared strings and single-cell text. Sparse huge sheet
  coordinates must not allocate a dense rectangular matrix. Use immutable pages
  or a bounded page cache rather than retaining every parsed value twice.
- Data access: bounded preview may ship first if it states exactly what is
  omitted and exposes the original. A full large-file promise requires streaming
  record boundaries, chunk/index memory accounting, cancellation and indexed
  access. Sorting/searching are background jobs with explicit scan progress and
  cancellation; a preview sample must not be labeled a complete result.
- Lifecycle dimensions stay separate: document semantics, heavy-resource
  residency, visible presentation detail and interaction pins. Focused editing,
  selection, accessibility and in-progress gestures pin the required interaction
  surface. A tile outside the viewport may keep a current signature/draft while
  doing zero decode, grid apply or playback work. `window != nil` is insufficient.
- Persist file identity and small viewer state only (sheet, scroll, zoom, fit,
  selected range). Do not write decoded bytes/cell arrays into `canvas.json`.
  Classify new coding keys in `WorkspaceAPIExposure` and witness persistence
  through the production mount/switch path.

## Proposed measurable release gates

Every row below is a **proposed check**, not an existing flag or verified pass.
Register actual implemented checks in the matrix and inspect its final inventory.
Prefer deterministic counters over stopwatch assertions; establish timing/memory
ceilings with repeated paired trials and record hardware, fixture and source SHA.

| Proposed witness | Deterministic assertion with teeth |
| --- | --- |
| Load scheduling and teardown | Main-thread file reads/decodes/parses = 0 for new binary/data viewers; active jobs never exceed configured limit; removal/replacement cancels; delayed old result applies = 0; at least one valid current result applies. |
| Image admission | Huge dimensions rejected/downsampled before full decode; decoded resource ledger remains within admitted bytes; static relayout and pan cause 0 decodes; repeat open at same bucket causes a cache hit. |
| Grid scaling | With identical viewport, 1k/100k/1m record fixtures do not increase mounted cell count or relayout measurement count; large column axis measured separately; source omissions visibly stated. |
| Workbook expansion | High compression ratio, huge sparse coordinates and long shared strings terminate at explicit budgets; cancellation stops work; no dense sheet allocation; normal worksheet fixture displays expected cell values. |
| File mutation race | Replaced same-path file never receives old decoded content; changed signature invalidates cache; dirty source edit retains conflict/recovery behavior. |
| Offscreen/occlusion | Current document/signature advances as designed; dormant decode/grid applies/frame advances = 0; returning visible produces one catch-up apply; focused tile retains responder/selection. |
| Snapshot fidelity | Images and grids remain pixel faithful across native/surfaced transitions, appearance/backing-scale changes and scroll/sheet/zoom changes; animating viewer remains live or honestly pauses. Never bake while parked. |
| Mixed canvas motion | Hold visible set fixed while installed tiles grow 16/32/64/128, run zoom 1.0 and 0.35; pan/zoom must add 0 file reads/parses/decodes/whole-grid measurements per step. At least one renderer visibly changes after a legitimate content update to prevent inert-test greens. |
| Restore and persistence | Drive `mountWorkspaceSceneAtBoot`, switch projects/workspaces, evict a non-live zone and relaunch; same file/state reappears with correct world frames and project owner; untouched/non-live file tile records survive saves. |

Existing witnesses to retain include `--file-markdown-perf-check`,
`--file-markdown-preview-check`, `--file-tile-zoom-check`,
`--zone-tile-hydration-check`, `--file-open-active-context-check`,
`--project-file-operation-check`, editor navigation/recovery checks, the canvas
motion/perf budget suite and `--tile-surface-residency-check`. Enumerate exact
current flags from `ContinuumApp.swift` before running. Existing KNOWN-RED entries
must remain distinguished from new failures.

## Evidence and limitations

Read `AGENTS.md`, `docs/internals/performance.md`,
`docs/internals/performance-budgets.md` and
`docs/internals/scalability-tdd.md`, then inspected the referenced source paths
with `rg`, `sed` and `cat`. The performance docs' historical timings explain
failure mechanisms; they are not measurements of a new image/grid renderer.
No external API claim is required by this integration audit. No build, runtime,
memory profile, source mutation, renderer experiment or benchmark was performed.
