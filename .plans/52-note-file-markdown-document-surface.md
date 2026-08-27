# Note and File Tile Markdown Document Surface

**Date:** 2026-08-26
**Status:** Complete; released in Array 0.6.0 (build 46)
**Scope:** Native AppKit note and file tiles in Array

## 2026-08-26 implementation update

The shared native Markdown document surface described here landed through `083d7ba6`
and merge `fd06f7b5`, then shipped in Array 0.5.13. Notes and Markdown file tiles now
share Preview, Split, and Edit presentation with a live draft preview. The workspace,
transcript, ownership, and hotfix release context is recorded in
[53-session-handoff-2026-08-26-workspaces-transcripts-hotfixes.md](53-session-handoff-2026-08-26-workspaces-transcripts-hotfixes.md).

The remaining durability, authoring, source-file, and file-tree work shipped together
in Array 0.6.0 after the full 188-leg release matrix, optimized production build,
bundle audit, Developer ID signing, notarization, stapling, and Gatekeeper verification.

## 2026-08-26 completion record

- Notes and Markdown files use one native `MarkdownDocumentSurface` with persisted
  Preview / Split / Edit state, live draft rendering, stable selection/scroll state,
  constrained panes, and title-bar controls that survive production drag hit routing.
- Notes expose Saving / Saved / Save failed state. Failed writes remain dirty for a
  later lifecycle retry instead of falsely clearing the pending document.
- Markdown files retain explicit Command-S ownership, external-change conflict choices,
  Save / Discard / Cancel on close, and atomic crash-recovery drafts scoped to the
  checkout (or channel-specific Application Support for standalone files).
- Both document families share native formatting commands, a compact Format control,
  Command-B/I/K, Command-Option-1/2/3 mode shortcuts, list continuation/exit, and
  Tab/Shift-Tab line indentation while preserving the normal editing context menu.
- Source-file tiles add language-aware highlighting, line numbers, long-line scrolling,
  and clean live refresh when an agent changes the file externally. They remain
  read-only; full human IDE editing, diagnostics, LSP, and diff review stay out of scope.
- File-tree tiles add fuzzy multi-term filtering, Command-F focus, file-type icons,
  root/count context, collapse-all, and an explicit Open as File Tile action.
- Deterministic production-path witnesses cover real title-bar clicks, draft/mode
  restoration, source reveals, external edits/conflicts, recovery rehydration,
  authoring commands, file-tree boot persistence/hardening, and surface residency.

## Problem

Note and file tiles have fallen behind the rest of the canvas experience. Agent-to-file linking and connector work now provides useful document context, but the document tiles themselves do not yet feel trustworthy or pleasant to use.

The intended Markdown functionality partially exists:

- Note tiles contain an editable `NSTextView` and a rendered Markdown preview.
- Markdown file tiles contain Preview/Edit controls, dirty state, explicit save, external-change monitoring, and conflict handling.
- Both use the native `FileMarkdownDocumentView` semantic renderer.

Despite that implementation, the file-tile toggle does not work in the real product experience, and file tiles are effectively preview-only. This is therefore not a greenfield editor project. The first responsibility is to reproduce and repair the real interaction path rather than replacing the existing foundation.

The experience to take from [Markdown Viewer](https://github.com/ThisIs-Developer/Markdown-Viewer/) is its interaction model—focused source editing, live preview, split mode, save feedback, and familiar Markdown authoring—not its web implementation or its larger workspace/collaboration feature set.

## Product decision

Create one shared **Markdown document surface** used by both note tiles and Markdown file tiles, while preserving their different ownership and save semantics.

The surface has three explicit modes:

1. **Preview** — rendered Markdown optimized for reading.
2. **Edit** — raw Markdown source editing.
3. **Split** — source and live rendered preview together.

“Edit in preview” is interpreted as Split mode: the user edits the exact Markdown source while continuously seeing the rendered document. True WYSIWYG editing directly inside rendered blocks is out of scope unless explicitly chosen later.

## Document ownership

### Note tile: Array-owned document

- Stable `noteId` remains the document identity.
- Markdown body belongs to the project's Array state.
- Editing autosaves after a short debounce.
- Pending edits flush on workspace switch, app termination, tile removal, and other lifecycle exits.
- The surface visibly reports `Saving…`, `Saved`, or an actionable error.
- Preview and Split always render the current draft.
- Exporting a note to Markdown is non-destructive by default.
- Removing a note tile must not silently destroy the only copy without confirmation or a recoverable deletion policy.

### File tile: repository-owned document projection

- Canonical `DocumentLocation` remains the identity.
- The file on disk is authoritative.
- Markdown files support Preview, Edit, and Split.
- Non-Markdown text files remain read-only during the initial scope.
- Binary, oversized, missing, directory, and permission-denied states remain explicit inline states.
- Markdown edits are saved explicitly with `⌘S`; repository files do not silently autosave by default.
- Dirty state is visible in every mode.
- Preview and Split render the unsaved draft, not merely the last disk snapshot.
- External changes never overwrite a local dirty draft. The user chooses Reload, Overwrite, or Cancel.
- Removing a dirty file tile requires Save, Discard, or Cancel.
- A lightweight recovery draft should protect unsaved file work across crashes or workspace transitions without changing which copy is authoritative.

## Interaction model

### Mode control

- Replace the ambiguous two-state behavior with one consistent three-segment control: **Preview / Split / Edit**.
- Use the same terminology and ordering on notes and Markdown files.
- Persist the selected mode per tile so reopening or restoring a workspace does not unexpectedly reset it.
- New notes may default to Split when wide enough and Edit when narrow.
- Existing Markdown files may continue to default to Preview until the user chooses otherwise.
- When a tile is too narrow for a useful split, preserve the selected mode but present one pane at a time or disable Split with a clear affordance.

### Split mode

- Use one canonical Markdown draft shared by both panes.
- Update preview after a short debounce so typing stays responsive.
- Provide a draggable divider with minimum pane widths.
- Preserve independent scrolling by default.
- Add optional scroll synchronization only after basic split behavior is stable.
- Preserve editor selection, first responder, preview position, and source position across mode changes.
- Rendering must never steal keyboard focus.

### Referenced files and connectors

This project must not rework the agent-connector system unless a document-surface change requires it.

- Existing agent/file relationships survive all mode transitions.
- Connector geometry and reference badges remain independent of Preview/Edit/Split state.
- Revealing `file:line:column` focuses the source location.
- If the file is already in Split, revealing a line keeps Split active and scrolls the source pane rather than forcing the tile into Edit-only mode.
- Note participation in agent relationships is a separate follow-up decision; note content ownership must not be mixed with workspace relationship ownership.

## Native implementation direction

Continue using native AppKit:

- `NSTextView` remains the canonical source editor.
- `FileMarkdownDocumentView` remains the preview foundation.
- Share the document-mode and draft coordination behavior rather than duplicating it between `NoteTileNSView` and `FileTileNSView`.
- Do not introduce Monaco, CodeMirror, a WebView editor, Milkdown, or Lexical for this slice.
- Borrow interaction details from Markdown Viewer, not its browser architecture.

Potential shared responsibilities include:

- Mode state and mode control.
- Source/preview/split body installation.
- Draft-to-preview debounce.
- Focus, selection, and scroll restoration.
- Surface-residency epoch invalidation.
- Save-state presentation.
- Compact Markdown commands.

Persistence remains owned by the note and file tile integrations because their durability contracts differ.

## Markdown authoring quality

After mode switching and save safety work end to end, add a compact native authoring layer:

- Bold, italic, heading, link, list, quote, inline code, and fenced code commands.
- `⌘B`, `⌘I`, `⌘K`, Find, undo/redo, and discoverable mode shortcuts.
- List continuation on Return.
- Exit an empty list item on Return.
- Tab/Shift-Tab indentation for selected lines.
- Clear tooltips and accessibility labels.

Do not begin with the full Markdown Viewer toolbar, diagrams, exports, comments, or collaboration.

### Vim motions are opt-in

- Native macOS text editing is the default for every note and file editor.
- Vim motions must default to **off** for fresh installs, missing preferences,
  legacy settings, new tiles, restored tiles, and workspace hydration.
- Only an explicit user action may enable Vim motions. An explicit enabled
  preference must survive relaunch until the user turns it off again.
- Never infer document-editor Vim mode from the Neovim launch profile, a
  provider's `/vim` command, shell configuration, or the contents of a file.
- When a Vim-motion implementation is introduced, it must ship with a visible
  manual toggle and a deterministic default-off/migration witness. Until then,
  the native editors must not advertise a non-functional Vim setting.

## Likely existing failure seam

Code inspection shows both segmented controls have target/action wiring. The unverified leading hypothesis is that the control lives in draggable title-bar chrome while Array's click/focus routing and surface promotion can intercept the event or strand the swapped body. Mode switching also replaces `contentView`, interacts with parked/surfaced bodies, and must invalidate the correct surface revision.

This hypothesis must not be treated as the fix. The implementation phase begins by capturing the broken real interaction as RED evidence through the production mounting and click route.

## Delivery slices

### Slice 0 — Reproduce the real defect

- Exercise a real hydrated note tile and Markdown file tile through production mounting.
- Click every mode control through the actual title-bar event path.
- Record control action, selected segment, active body, first responder, and surfaced/parked state.
- Confirm whether the failure is event interception, body swapping, surface residency, restoration, or more than one issue.
- Add a deterministic witness that fails before implementation.

### Slice 1 — Trustworthy single-pane modes

- Repair real Preview/Edit switching for notes and Markdown files.
- Preserve tile identity, focus, selection, and scroll.
- Persist mode per tile.
- Ensure agent connectors and reference affordances remain stable.
- Verify cold launch and workspace switching, not only direct view construction.

### Slice 2 — Split mode

- Add shared Preview/Edit/Split state.
- Create a constrained native split container.
- Render the current draft after a debounce.
- Preserve pane positions and first responder.
- Handle narrow tiles deliberately.
- Keep source-coordinate reveals inside Split.

### Slice 3 — Save and recovery correctness

- Add visible note save status and actionable failures.
- Verify note flush across every controller/workspace lifecycle path.
- Preserve explicit file save and external conflict handling.
- Add dirty-tile removal behavior.
- Add bounded recovery for unsaved Markdown file drafts.
- Verify relaunch, workspace switch, external edit, and save failure behavior.

### Slice 4 — Authoring polish

- Add the small formatting toolbar and core shortcuts.
- Add list continuation and indentation.
- Evaluate optional proportional scroll synchronization.
- Refine Markdown typography and renderer coverage based on real documents.

## Acceptance criteria

### Mode behavior

1. Preview, Split, and Edit controls respond to real pointer interaction in mounted production tiles.
2. Mode switching never changes tile identity or document identity.
3. Source selection, editor focus, and relevant scroll positions survive mode transitions.
4. The selected mode survives relaunch and workspace switching.
5. Narrow tiles never produce unusably compressed split panes.
6. Surface residency cannot display a stale body after a mode change.

### Notes

1. Editing a note updates Preview/Split from the current draft.
2. Debounced save persists the body and updates note metadata.
3. Workspace switch and app close flush pending edits.
4. Save failure is visible and does not falsely report `Saved`.
5. Relaunch reconstructs the same note and body.

### Markdown files

1. Editing a Markdown file updates Preview/Split before the draft is saved.
2. `⌘S` atomically writes the exact source draft.
3. An external disk change while clean refreshes safely.
4. An external disk change while dirty never overwrites the local draft.
5. Save conflict presents Reload, Overwrite, and Cancel.
6. Removing a dirty tile cannot silently discard the draft.
7. Non-Markdown files remain read-only and preserve long-line scrolling.

### Agent context

1. Existing agent/file links and connectors remain visible in all modes.
2. Revealing a source coordinate selects and scrolls to the requested location.
3. A reveal from Split does not unnecessarily leave Split.
4. Cold-launch relationship projection is verified after real tile hydration.

## Risks and edge cases

- Title-bar drag handling swallowing segmented-control clicks.
- `contentView` replacement while the current body is parked by surface residency.
- Preview rerender stealing focus or resetting selection.
- Workspace switching while a note debounce is pending.
- File edited simultaneously by Array and an agent or external editor.
- File replacement, rename, symlink retargeting, or worktree identity changes.
- Async file-load results arriving after a tile is deleted or repurposed.
- Missing note body being mistaken for an intentionally empty note.
- Large Markdown files producing too many native semantic block views.
- Scroll synchronization drifting around images, code blocks, and variable-height content.

## Explicit non-goals

- WYSIWYG editing inside rendered Markdown.
- Editing arbitrary source-code file types.
- Replacing the native renderer with a web renderer.
- Multi-document tabs inside a tile.
- Comments, Live Share, GitHub import, or workspace management.
- Mermaid, remote diagrams, MathJax, maps, or media pipelines.
- PDF/PNG/HTML export.
- Redesigning agent connectors.

## Relevant existing code and plans

- `Sources/ContinuumRevived/Canvas/NoteTileNSView.swift`
- `Sources/ContinuumRevived/Canvas/FileTileNSView.swift`
- `Sources/ContinuumRevived/Canvas/FileMarkdownDocumentView.swift`
- `Sources/ContinuumRevivedCore/NoteState.swift`
- `Sources/ContinuumRevivedCore/FilePreview.swift`
- `Sources/ContinuumRevivedCore/DocumentLocation.swift`
- `Sources/ContinuumRevived/App/TileSpawner.swift`
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift`
- `docs/superpowers/specs/2026-05-09-phase-6-file-note-tiles-design.md`
- `.plans/15-file-opening-markdown-preview.md`
- `.plans/38-quiet-surfaced-residency-slice-2.md`
- `.plans/46-transcript-program-ledger.md`

## Research reference

Markdown Viewer demonstrates the transferable baseline: explicit Editor/Split/Preview modes, resizable panes, debounced live rendering, optional synchronized scrolling, visible save state, familiar shortcuts, and source-oriented Markdown formatting.

- Repository: https://github.com/ThisIs-Developer/Markdown-Viewer/
- Feature reference: https://github.com/ThisIs-Developer/Markdown-Viewer/wiki/Features
- Usage guide: https://github.com/ThisIs-Developer/Markdown-Viewer/wiki/Usage-Guide
