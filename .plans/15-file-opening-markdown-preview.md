# Reliable file opening and native Markdown preview

Status: **IMPLEMENTED 2026-08-12** (phases 1–5), plus the agent local-file link
feature that rides on the same route.

Written 2026-08-12 from the current `array/integration` code. The first phase was
deliberately diagnostic: the repository exposed a credible stale-spawner / split
canvas-state failure, and that explanation was made RED in a behavioral
self-check before it was treated as the root cause.

## What the witness found

The hypothesis below was right, and understated. Confirmed by
`--file-open-active-context-check`, both halves RED before the repair:

1. **The arriving spawner had no owner.** `ZoneRuntimeController.tileSpawner` was
   `weak`, and `WorkspaceRuntime.install`/`switchWorkspace` built the new project's
   spawner as a local. It deallocated before the switch returned, so
   `controller.tileSpawner` was nil for every post-switch caller — not merely
   stale. (Teeth: reverting to `weak` fails the precondition assertion.)
2. **`AppDelegate.tileSpawner` was the boot spawner forever.** It is now computed
   from the active controller, so every app-level spawn action resolves the live
   one.
3. **The install went to the wrong model.** `setZones` leaves `canvasState.tiles`
   holding the DEPARTED project's tiles and `activeZone` pinned to the departed
   placement, so `install(tileView:for:)` appended there and framed the tile
   against the wrong zone origin. `CanvasNSView.installProjectTile` now routes to
   the active `ZoneLayer` when one owns the project. (Teeth: forcing the flat path
   fails the layer-membership assertion.)

Persistence followed the same fork: the layer path writes the layer's tiles
through the active controller's own `ProjectStore`, so project A's canvas is
untouched — asserted directly.

## Scope actually shipped

Everything in "Outcome" plus tile dedupe (opening an open file reveals it),
`FileTileNSView.reveal(line:column:)`, and user-facing failure alerts.

**Deliberately not migrated:** terminal, note, browser, and agent spawns still use
`install` + `saveCanvas(canvasState)` and so remain wrong after a workspace switch
in exactly the way file opening was. `installProjectTile` and
`makeProjectTilePlacement` are the pattern for that follow-up; the coordinate
split (flat = world frames, layer = zone-local) is the trap.

## Rider: an agent's local-file links (shipped in the same slice)

Clicking an explicit Markdown link to a local file in a managed agent's answer
opens that file in a file tile 24pt to the right of the responding agent tile,
top-aligned, and reveals `:line:column` if the link carried one.

The rule that makes this safe: **authored content can only request resolution.**

- `AgentLinkPolicy` gained `.openLocalFile` — a syntactic classification, made in
  the content layer, which resolves nothing. `javascript:`, `data:`, unknown
  schemes, `~/`, Windows paths, and a remote `file://host/` authority are not
  candidates and stay `.displayOnly`.
- `RichInlineTextView` re-evaluates policy at activation time and emits
  `AgentRenderAction.openLocalFile(blockID:destination:)` carrying the RAW
  authored string. A local file never becomes a `URL` action, so it can never be
  mistaken for an externally authorized destination.
- `AgentLocalFileLinkResolver` (Core) resolves it against the responding agent's
  live `AgentRecord.cwd` — never the process cwd, never "the active project", so
  an agent in an isolated worktree opens files from ITS checkout. It strips
  navigation metadata, percent-decodes `file:` URLs, canonicalizes both sides
  (macOS `/var` → `/private/var` makes a raw-vs-resolved comparison meaningless),
  enforces path-COMPONENT containment (a string prefix would accept
  `/tmp/checkout-evil` for `/tmp/checkout`), and requires an existing regular file.
- Scope: explicit Markdown links only. Bare prose and inline code like
  `Sources/Foo.swift:42` are NOT auto-linked.

Witnessed by `--agent-local-file-link-check` (the whole chain, in an isolated
checkout), `runAgentLocalFileLinkChecks` in CoreChecks (9 resolving forms, 13
refusals, symlinked-root containment), and the rewritten `LinkPolicyChecks`
negative witness — which now mutates the local-file branch to `.openExternally`
in an isolated package and requires that to exit 1.

## Outcome

Opening a project file becomes one dependable operation regardless of whether it
starts in Command Center, a file-tree tile, or a drop onto the canvas. The
operation resolves the active project and zone at activation time, creates a
visible file tile there, persists only that project's canvas, and focuses the new
tile.

A UTF-8 Markdown file opens in a styled, selectable native preview by default.
The same tile offers a **Preview / Source** switch so the exact Markdown remains
one click away. Other text and code files retain the existing read-only,
monospaced source viewer.

Done means:

1. File opening works before and after an in-process workspace switch.
2. File opening targets the active project zone, including a non-boot project.
3. Command Center, file-tree activation, and file drop use one active-context
   route rather than retaining their own project assumptions.
4. `.md` and `.markdown` files render useful Markdown with Array's appearance
   tokens and native selection, copy, links, and accessibility.
5. Source mode shows the exact decoded text without creating a second tile or
   changing the tile's identity.
6. Non-Markdown files keep today's horizontally scrollable source behavior.
7. Missing, binary, oversized, and unreadable files retain explicit failure
   states.
8. A deterministic witness runs in `scripts/run-matrix.sh` and proves the real
   workflow rather than scanning source text.

## Current behavior and likely regression

There are currently several file-opening surfaces with different semantics:

- `AppDelegate.openFileFromPalette()` presents an `NSOpenPanel`, validates the
  selection against `activeProject`, and calls the app-level `tileSpawner`.
- A file-tree double-click or Return calls `FileTreeTileNSView.onSpawnFile`,
  wired by `TileSpawner.installFileTreeView` back into that spawner's
  `spawnFile` method.
- A file drop calls `CanvasNSView.onFileURLDrop`, installed by a `TileSpawner`
  during its initialization.
- “Open in Preferred Editor” is a separate external-editor action and should
  remain separate from opening a file as an Array tile.

The strongest regression candidate is a stale ownership path after workspace
switching:

1. `AppDelegate.tileSpawner` strongly retains the spawner created for the boot
   project.
2. `WorkspaceRuntime.switchWorkspace(to:)` creates a new project-scoped
   `TileSpawner` for the new active controller.
3. `ZoneRuntimeController.tileSpawner` is currently `weak`, and the new spawner
   is not handed back to `AppDelegate`.
4. Command Center continues to call the boot-time app-level spawner.
5. `TileSpawner.spawnFile` calls the flat `CanvasNSView.install(tileView:for:)`
   path and saves `canvasView.canvasState`.
6. After `CanvasNSView.setZones`, project tiles are represented in
   `ZoneLayer.tiles`; the existing workspace-switch check explicitly notes that
   the flat `canvasState.tiles` collection does not represent those tiles.

That combination can make an attempted open install into stale or compatibility
state, persist through the wrong project store, or fail to appear in the active
zone. This is a code-grounded hypothesis, not yet witnessed runtime fact.

The existing `--workspace-switch-check` proves zone replacement, focus,
controller identity, ref-counting, viewport restoration, and adapter
registration. It never opens or spawns a file after switching, so it cannot
catch this failure.

## Product shape

### Markdown files

The tile keeps the existing Array file-tile chrome and identity. Its body has
two modes:

- **Preview** — the default. A native scrolling document with styled headings,
  paragraphs, emphasis, strong text, inline code, links, lists, block quotes,
  thematic breaks, and fenced code.
- **Source** — the existing selectable monospaced `NSTextView`, with horizontal
  and vertical scrolling and no editing.

A compact segmented control belongs in the file tile's title-bar accessory
area. It appears only for Markdown files. Switching modes changes the body in
place; it does not create another tile or reread a different copy of the file.

The first slice keeps this mode view-local. Reopening or restoring a Markdown
tile returns to Preview. Persisting the user's last mode is easy to add later,
but it would expand `TileMetadata` and sync behavior before dogfooding proves it
is valuable.

### Other text and code files

Keep the current `FileTileNSView` source presentation:

- read-only and selectable;
- monospaced;
- horizontally scrollable for long lines;
- vertically scrollable for long files;
- loaded through the existing 1 MB UTF-8 safety boundary.

No Preview / Source control appears for non-Markdown files.

### Unavailable files

Keep an inline tile state when a tile can be constructed:

- `File not found`;
- `Binary file — open in preferred editor`;
- `File too large to preview (> 1 MB)`;
- a distinct readable error when access or decoding fails, if the loader can
  distinguish it safely.

If tile creation itself cannot proceed—for example, there is no active project
or persistence fails before installation—the initiating surface should show a
small user-facing error instead of only beeping or writing to stderr.

## Rendering decision: native AppKit, not WebKit

Array already depends on `swift-markdown` 0.8.0 through
`ContinuumRevivedAgentContent`. `MarkdownAgentMarkupParser` converts its AST
into Array's provider-neutral semantic block tree, and the managed-agent
transcript already has token-aware native renderers for:

- headings and paragraphs;
- inline emphasis, strong text, code, and links;
- ordered and unordered lists;
- quotes;
- fenced code;
- native selection/copy and accessibility roles.

Reuse that semantic pipeline. Do not add an HTML generator, CSS bundle,
JavaScript bridge, navigation policy, or a `WKWebView` process to every Markdown
file tile.

The reuse boundary matters: file documents should share Markdown meaning and
small rendering primitives, but should not impersonate an agent transcript or
inherit agent actions, streaming state, card chrome, and disclosure state.
A document-specific host and render context should own file layout and spacing.

Tables may initially use the parser's existing readable monospace fallback.
Proper native tables are valuable, but they are a separate renderer project and
should not block reliable opening or the basic Markdown experience.

## Architecture

### One active-context file-opening route

Introduce one result-bearing application seam conceptually shaped like:

```swift
@MainActor
func openProjectFile(
    at url: URL,
    placement: FileOpenPlacement
) -> FileOpenOutcome
```

It should:

1. Resolve the active workspace controller and active project zone at call time.
2. Validate and normalize the path against that project root.
3. Ask the active controller's retained `TileSpawner` to create the file tile.
4. Install the tile into the authoritative active zone/layer model.
5. Persist through that controller's `projectStore`.
6. Focus/reveal the tile only after installation and persistence succeed.
7. Return a structured success or user-facing failure.

Command Center, file-tree activation, and file drop should adapt their input into
this seam. “Open in Preferred Editor” remains an external action and does not
use it.

Although this plan migrates and witnesses file opening, the lifetime repair
should establish a safe pattern that note, browser, terminal, and agent spawn
actions can adopt. Avoid a file-only exception layered on top of a stale global
spawner.

### File loading stays separate from Markdown parsing

`ContinuumRevivedCore/FilePreview.swift` remains the bounded filesystem reader
and UTF-8 classifier. It should return enough successful-load metadata for the
AppKit layer to choose a presentation—normalized URL/path, extension or content
kind, and decoded text—but Core should not parse or style Markdown.

`FileTileNSView` becomes a small presentation container that owns:

- the existing source text view and scroll view;
- a new native Markdown document view;
- the Markdown-only mode control;
- loading and unavailable states;
- one immutable loaded-text snapshot shared by Preview and Source.

Using the same loaded string for both modes makes switching instantaneous and
prevents preview/source drift within one tile.

### Native Markdown document host

Add a focused AppKit document view under `Sources/ContinuumRevived/Canvas/`.
It should:

1. Parse a complete Markdown string with `MarkdownAgentMarkupParser`.
2. Lay out semantic blocks vertically in one scrolling document.
3. Reuse or extract the existing rich-inline, prose, and fenced-code rendering
   primitives.
4. Apply Array's token roles on appearance changes.
5. Use the existing link policy rather than granting arbitrary file or URL
   navigation.
6. Expose native selection, copying, and accessibility.
7. Render unknown/unsupported constructs as readable source, never silently
   discard them.

This host does not need streaming identity reconciliation, transcript
virtualization, provider provenance, image attachment capabilities, tool
actions, or mutable agent state.

## Implementation sequence

### Phase 1 — make the regression RED

Extend `--workspace-switch-check` or add a dedicated, explicitly registered app
self-check. The check must:

1. Create isolated workspace A and B project roots.
2. Put a sentinel `README.md` in B.
3. Boot A and switch in-process to B through the production runtime.
4. Invoke the same result-bearing file-open action used by Command Center.
5. Assert a real `FileTileNSView` is visible in B's zone/layer.
6. Assert B's persisted canvas contains the new file tile.
7. Assert A's persisted canvas is unchanged.
8. Assert the focus broker lands on the new tile.

The check must fail before the lifetime/routing fix. Merely asserting which
spawner is stored, or source-scanning for a method call, is not a witness.

### Phase 2 — repair spawner lifetime and zone-aware mutation

Likely files:

- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `Sources/ContinuumRevived/App/WorkspaceRuntime.swift`
- `Sources/ContinuumRevived/App/ZoneRuntimeController.swift`
- `Sources/ContinuumRevived/App/TileSpawner.swift`
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift`

Make the active controller own its spawner strongly and make application actions
resolve that controller/spawner at invocation time. Add the smallest coherent
layer-aware canvas mutation seam so a new project tile enters the same model
that `setZones` installed and the same `ProjectStore` that owns it.

Re-run the Phase 1 check and require GREEN before adding Markdown rendering.

### Phase 3 — refactor the file tile into source and preview presentations

Likely files:

- `Sources/ContinuumRevivedCore/FilePreview.swift`
- `Sources/ContinuumRevived/Canvas/FileTileNSView.swift`
- one new Markdown document view under
  `Sources/ContinuumRevived/Canvas/`

Preserve all current source-view behavior and evidence hooks. Add file-kind
selection, the Markdown mode control, and the document host without changing the
persisted tile kind.

### Phase 4 — extract safe renderer reuse

Likely existing primitives:

- `ContinuumRevivedAgentContent/MarkdownAgentMarkupParser.swift`
- `Canvas/AgentTranscript/Renderers/AssistantProseRenderer.swift`
- `Canvas/AgentTranscript/AgentTextStyleResolver.swift`
- `Canvas/AgentTranscript/RichInlineTextView.swift`
- `Canvas/AgentTranscript/Renderers/CodeBlockRenderer.swift`

Prefer extracting generally useful document primitives over making the file tile
instantiate a hidden transcript list. Keep transcript-specific semantics in the
transcript layer and avoid changing the one-way module dependency direction.

### Phase 5 — errors, restore, and matrix registration

Add user-visible failures at each entry point, restore Markdown tiles through
the existing `.file` boot path, register the new app check in
`scripts/run-matrix.sh`, and update the committed check inventory if required by
the matrix contract.

Confirm from the final matrix summary that the new leg actually executed. Its
presence in source or in a section after an early failing leg is insufficient.

## Verification contract

### Core checks

- UTF-8 Markdown is classified as text with Markdown presentation metadata.
- `.md` and `.markdown` match case-insensitively.
- A filename merely containing `.md` does not match.
- Missing, directory, non-regular, binary, UTF-16, and >1 MB behavior remains
  covered.
- Loading does not read an oversized file before rejecting it.

### App behavior checks

- Workspace A → B → open Markdown persists only in B.
- File-tree activation, Command Center, and drop reach the shared action seam.
- Markdown defaults to Preview.
- Preview contains visible laid-out heading, paragraph, list, link, and fenced
  code content—not merely parsed source held offscreen.
- Source shows the raw sentinel Markdown.
- Toggling modes preserves tile identity and loaded content.
- A `.swift` fixture has no mode control and keeps horizontal scrolling.
- Light and dark appearance changes repaint every new surface through tokens.
- Keyboard focus, selection, link accessibility, and code copy remain usable.
- Restore recreates a Markdown preview tile from persisted `.file` metadata.

### Commands

Before running an app flag, enumerate the exact registered flags from
`ContinuumApp.swift`; never guess one. Then run:

```sh
swift build --product ContinuumRevivedCoreChecks
swift run ContinuumRevivedCoreChecks

# exact new --*-check flag after it is registered
.build/debug/Array --<exact-file-markdown-check>

CONTINUUM_SKIP_UI_BASELINES=1 scripts/run-matrix.sh
```

Judge the full gate by its final summary, including expected KNOWN-RED legs and
the number of app legs actually run.

For supervised dogfooding, rebuild only the preview app:

```sh
scripts/dev-app.sh
```

Use `~/Desktop/Array Dev.app` on `~/array-scratch`. Never rebuild, quit, or point
a dev build at `/Applications/Array.app` or Dylan's production project root.

Manual flow:

1. Open `README.md` from Command Center.
2. Confirm styled Preview, selection, link behavior, and code copying.
3. Switch to Source and compare the exact Markdown.
4. Open the same file from a file-tree tile.
5. Switch workspaces and repeat in a different project zone.
6. Open a long `.swift` file and verify source scrolling is unchanged.
7. Relaunch the dev app and verify the Markdown tile restores in Preview.

## Scope

Included:

- reliable, active-context opening of project files;
- one shared route for Array-tile opening;
- read-only native Markdown preview;
- Preview / Source switching;
- native styling, selection, copy, links, and accessibility;
- restore behavior and deterministic witnesses.

Deferred:

- editing external files;
- split Preview + Source;
- live reload after another process changes the file;
- persisted display mode;
- Markdown source syntax highlighting;
- rendered local/remote images;
- Mermaid or executable HTML;
- footnotes and a dedicated native table renderer;
- raising or streaming beyond the 1 MB preview cap;
- previewing PDF, rich text, or other document formats.

## Risks and guardrails

### Split canvas ownership

The largest risk is the existing split between flat `canvasState.tiles` and
`ZoneLayer.tiles`. Fixing only `openFileFromPalette()` could make one route look
healthy while file-tree and drop remain wrong, or could leave every other spawn
action vulnerable. The behavioral witness must inspect both the visible layer
and the target project's persisted canvas.

### Renderer coupling

The transcript renderers were designed around semantic agent content. Reusing
them wholesale may pull in agent actions, measurement assumptions, or card
styling. Share semantic parsing and small native rendering primitives; give file
documents their own host and context.

### Links and local paths

Markdown can contain arbitrary URL and `file:` destinations. Use the existing
link-disposition policy, and do not silently grant file access or navigation
beyond the current project rules.

### Unsupported Markdown

Unknown nodes must degrade visibly to readable source. Silent content loss is
not acceptable, especially for tables, raw HTML, and image syntax.

## Decisions to confirm before implementation

Recommended defaults:

1. **Markdown mode:** Preview by default with a Preview / Source control.
2. **Persistence:** do not persist the chosen mode in the first slice.
3. **Editing:** keep all project file tiles read-only; note editing remains a
   separate tile kind and workflow.
4. **Tables:** ship the existing monospace fallback first; design native tables
   separately.
5. **Live changes:** load once on tile creation/restore; add file watching only
   after the opening and rendering path is stable.

The only product decision likely to change the first implementation materially
is whether Markdown should open in Preview or Source by default. This plan
recommends Preview because the rendered document is the feature, while Source
remains immediately available.
