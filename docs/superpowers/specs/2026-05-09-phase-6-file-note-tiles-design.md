# Phase 6: File and Note Tiles -- Design

**Date:** 2026-05-09
**Status:** Approved for implementation
**References:**
- [docs/07-phased-build-plan.md](../../07-phased-build-plan.md) -- Phase 6 deliverables and exit criteria
- [docs/06-browser-code-file-surfaces.md](../../06-browser-code-file-surfaces.md) -- Notes and file-tree scope, requirements when implemented
- [docs/09-decisions.md](../../09-decisions.md) -- ADR-0014 (Phase 4 pattern), ADR-0015 (Phase 5 pattern)

---

## Context

Phases 1-5 established the full recipe for a live canvas tile: a pure-Core data type, a runtime protocol, a concrete runtime, a tile NSView subclass, a restart placeholder, spawner seam methods, a boot-loop switch case, and a debounced persistence path. Phase 6 applies that recipe to two new tile kinds -- note and file -- while deliberately keeping scope narrow.

A note tile is an editable plain-text surface backed by a `.md` file on disk under `.continuum-revived/notes/`. A file tile is a read-only view of a single file anywhere in the project tree. Neither requires a process, a WebKit instance, or a streaming data source, so neither needs a full runtime protocol. Both need persistence, a boot-loop case, and a smoke-test seam.

The Phase 6 goal is to make the canvas feel like a project workspace rather than terminal wallpaper. The MVP bar is: create a note, edit it, close and reopen the app, see the text. And: pin a file path as a tile, see its contents, reopen the app, still see it. Everything beyond that is deferred.

---

## Decision Summary

The following answers the ten open design questions from the analysis phase. Each answer is a single executable decision.

1. **Note persistence schema.** Notes are stored as raw UTF-8 `.md` files at `.continuum-revived/notes/<noteId>.md`. A small index file at `.continuum-revived/notes/index.json` holds a `NoteState` struct (an array of `NoteTile` entries). Canvas `TileMetadata` carries a `noteId: UUID?` field pointing into that index. No inline JSON note body anywhere.

2. **File-tile format scope.** File tiles render plain text only via `NSTextView`, with a hard 1 MB read cap. Binary files and files exceeding 1 MB show a non-editable label ("Binary file -- open in editor" or "File too large to preview"). No format-aware rendering, no syntax highlighting, no diff view in Phase 6.

3. **Storage policy.** Project-scoped only. Notes live under `.continuum-revived/notes/` in the same project state root as `canvas.json` and `sessions/`. No perProject/shared distinction for notes or file paths in Phase 6. The `NoteState` schema carries no `storageGroupId` field; that field can be added later if multi-project note sharing ever makes sense.

4. **Hotkey allocation.** Palette-only. No Cmd-5 or Cmd-6 hotkeys are wired in Phase 6. The Cmd-1..4 slots (claude, shell, browser, nvim) are load-bearing from Phase 4; reserving Cmd-5/6 now would add implicit contracts with no user benefit. Note and file tiles are spawned exclusively through Cmd-K (the existing `LaunchProfilePalette` will be extended to include note/file rows, or a second palette will be introduced -- see step P6.3). Rationale: the palette is already the universal spawn point; hotkeys should reflect daily-driver frequency, which file/note tiles have not yet earned.

5. **Restart-placeholder semantics.** Note tiles do not have a restart placeholder. If the `.md` file for a note tile is missing at boot, the tile is installed with an empty `NSTextView` and a header label "Note file not found -- edits will create a new file." File tiles that cannot be read show a non-editable label with the error ("File not found", "Permission denied", "Binary file", "File too large"). No restart button for either -- neither kind has a restartable process.

6. **Smoke seam.** At smoke-test boot, seed one deterministic note and one deterministic file under `.continuum-revived/` before the boot loop runs. The seeded note is written to `.continuum-revived/notes/<fixed-uuid>.md` with content `smoke-note-ok`. The seeded file is written to `.continuum-revived/smoke-file.txt` with content `smoke-file-ok`. Both are referenced by fixed tile IDs baked into the smoke-seed path. The `noteOk` and `fileOk` smoke gates verify the tiles appear on canvas, the note content is readable via the tile's `NSTextView`, and the file content is loaded into the file tile view.

7. **Multi-tile dedupe.** Each note tile owns exactly one `.md` file keyed by `noteId`. Two note tiles may not share a `noteId`. Uniqueness is enforced at spawn time: `spawnNote()` always generates a fresh `UUID` as the `noteId` and creates a new `.md` file. File tiles hold a `filePath: String?` in `TileMetadata`; the same file path may appear in multiple tiles (no dedupe constraint). The index does not enforce uniqueness on `filePath`.

8. **Markdown preview engine.** Deferred entirely from Phase 6. The note tile is an editable `NSTextView` showing raw markdown text. The file tile is a read-only `NSTextView` showing raw file content. No `AttributedString`-based preview, no `WKWebView` renderer, no third-party markdown library in Phase 6.

9. **File-contents lazy loading.** File tile content is loaded synchronously on the main thread at tile-install time for files under 1 MB (the cap is checked before reading). This is acceptable because the file is a single local path known at spawn time, not a directory scan. Background loading via `Task { ... }` is added only if the 1 MB cap creates perceptible lag during testing; the design does not require it.

10. **Cmd-K context awareness.** Deferred. The palette shows all spawn options regardless of canvas context in Phase 6. Context-aware filtering (e.g., hiding "New note" when no project root is set) is a Phase 7 polish item.

---

## Data Model

### Pure types in `ContinuumRevivedCore`

#### `NoteState` (new file: `Sources/ContinuumRevivedCore/NoteState.swift`)

```
NoteState: Codable, Equatable, Sendable
  schemaVersion: Int  (currentSchemaVersion = 1)
  tiles: [NoteTile]
```

```
NoteTile: Codable, Equatable, Sendable
  id: UUID               -- the noteId; also the stem of the .md filename
  tileId: UUID           -- foreign key into CanvasState.tiles
  filename: String       -- "<id.uuidString>.md"; computed from id but stored for readability
  title: String          -- the tile's user-visible title (mirrors Tile.title)
  createdAt: Date
  updatedAt: Date
```

`NoteState` is analogous to `BrowserState`. It is the source of truth for note metadata; file content lives in the `.md` file itself.

#### `TileMetadata` (extend existing `Sources/ContinuumRevivedCore/CanvasState.swift`)

Add two new optional fields:

```
noteId: UUID?       -- present when tile.kind == .note; points into NoteState.tiles
filePath: String?   -- present when tile.kind == .file; absolute or project-relative path
```

Both fields are `encodeIfPresent` in the existing `encode(to:)` method. The `CodingKeys` enum gains two new cases: `noteId` and `filePath`.

#### No `FileState` index

File tiles do not need a parallel `FileState` struct. The file path is stored directly in `TileMetadata.filePath` (a `String?`). File content is not persisted by the app; it is read from disk on demand. This keeps the storage surface minimal and avoids a second index JSON for a stateless viewer.

### Disk layout

```
<project-root>/
  .continuum-revived/
    canvas.json              -- existing; TileMetadata gains noteId/filePath
    notes/
      index.json             -- NoteState (array of NoteTile entries)
      <noteId-uuid>.md       -- raw UTF-8 note body
    browser/
      tiles.json             -- existing BrowserState (unchanged)
    sessions/
      <sessionId>.json       -- existing TerminalSessionDescriptor (unchanged)
```

The `notes/` directory is created on first note spawn. The `index.json` is written atomically via `AtomicWriter`. Individual `.md` files are written with `Data.write(to:options:.atomic)` directly -- they do not go through `AtomicWriter`'s backup machinery because the content is recoverable from the user's edits and backup overhead per keystroke is unacceptable.

### `ProjectStoreLayout` extension

Add two new computed properties:

```swift
var notesDirectory: URL   // stateRoot/notes
var notesIndexFile: URL   // notesDirectory/index.json
func noteFile(id: UUID) -> URL  // notesDirectory/<id.uuidString>.md
```

### `ProjectStore` extension

Add four new methods:

```swift
func saveNoteState(_ state: NoteState) throws
func loadNoteState() throws -> NoteState
func tryLoadNoteState() throws -> NoteState?
func saveNoteBody(id: UUID, text: String) throws   // atomic write of UTF-8 .md
func loadNoteBody(id: UUID) throws -> String       // read UTF-8 .md
func tryLoadNoteBody(id: UUID) -> String?          // nil on missing/error
```

---

## Runtime Protocols

Neither note tiles nor file tiles have a process or network session that needs a runtime protocol. Unlike `TerminalRuntime` or `BrowserRuntime`, there is nothing to start, stop, restart, focus, or blur at the engine level.

Instead:

- `NoteTileNSView` owns its `NSTextView` directly and persists content through a debounced save closure.
- `FileTileNSView` owns its read-only `NSTextView` and loads content at init time.

No `NoteRuntime` protocol. No `FileRuntime` protocol. No engine context. This is the simplest correct design.

If a future phase adds file-watch invalidation (inotify-style), an agent-write bridge, or live sync, a protocol can be introduced then. Deferring it now avoids prematurely designing a protocol that has no second implementation.

---

## Tile NSView Chrome

### `NoteTileNSView` (new file: `Sources/ContinuumRevived/Canvas/NoteTileNSView.swift`)

Subclass of `TileNSView`. Hosts a single `NSScrollView` containing an `NSTextView` for editing.

Key behaviors:

- `NSTextView` is editable, wraps at the view width, uses system monospaced font at 13pt.
- Title bar shows "Note - \(tile.title)" in the existing `TitleBarView` pattern.
- Body background matches the existing tile dark background (white 0.10).
- `NSTextViewDelegate.textDidChange` fires a debounced save: 400ms after the last keystroke, flush the note body to disk via `ProjectStore.saveNoteBody(id:text:)`. The `updatedAt` field in the `NoteState` index is also updated on flush.
- The debounce timer is separate from the canvas `saveTimer` (which is 200ms and fires on drag/resize). Using 400ms for text input reduces write frequency for fast typing.
- `onTextChange: (() -> Void)?` callback is set by the spawner to trigger the index debounce path in `AppDelegate`.
- At init, load the existing body via `ProjectStore.tryLoadNoteBody(id:)`. If nil, start with an empty string.
- At `windowWillClose` (or equivalent flush path), the AppDelegate calls `flushNoteSave()` to drain any pending debounced write.
- No markdown preview. Raw text only.

Chrome layout:

```
TileNSView (24pt title bar + 8pt resize ring)
  setContentView(scrollView)
    NSScrollView
      NSTextView (editable, wraps, monospaced 13pt)
```

### `FileTileNSView` (new file: `Sources/ContinuumRevived/Canvas/FileTileNSView.swift`)

Subclass of `TileNSView`. Hosts a single `NSScrollView` containing a read-only `NSTextView`.

Key behaviors:

- `NSTextView` is not editable (`isEditable = false`), not selectable by default (set `isSelectable = true` to allow copy).
- Font: system monospaced 13pt.
- Title bar shows "File - \(tile.title)" or the filename if `tile.title` is empty.
- At init, attempt to load the file at `tile.metadata.filePath`:
  - If the path is nil or the file does not exist: show label "File not found".
  - If the file is binary (first 8KB contains a null byte): show label "Binary file -- open in preferred editor".
  - If the file exceeds 1 MB: show label "File too large to preview (> 1 MB)".
  - Otherwise: load UTF-8 content (with lossy fallback) and set as `NSTextView.string`.
- No reload button in Phase 6. File content is loaded once at tile-install time. Reload-on-focus is a Phase 7 enhancement.
- No `onAfterRefresh` callback. File tiles carry no runtime state that changes.

Chrome layout:

```
TileNSView (24pt title bar + 8pt resize ring)
  setContentView(body)
    NSView (body)
      NSScrollView (pinned to body edges)
        NSTextView (read-only, selectable)
      -- or --
      NSTextField label (for error/binary/oversize states; centered)
```

### No restart placeholders

Note and file tiles do not have restart placeholder NSView subclasses. Error states are shown inline within the tile itself (label text replacing the NSTextView). This avoids the complexity of a placeholder-to-live swap for tile kinds that have no restartable process.

---

## Spawner Seam

### New methods on `TileSpawner` (`Sources/ContinuumRevived/App/TileSpawner.swift`)

#### `spawnNote(title:at:) -> NoteOutcome`

```swift
enum NoteOutcome {
    case spawned(noteId: UUID, tileId: UUID)
    case failure(Error)
}
```

Steps:
1. Generate a fresh `noteId = UUID()`.
2. Compute `frame` via the existing `makePlacement` helper.
3. Build `Tile` with `kind: .note`, `metadata: TileMetadata(noteId: noteId)`.
4. Create the `.md` file with empty content via `projectStore.saveNoteBody(id: noteId, text: "")`.
5. Upsert a `NoteTile` entry into `NoteState` via `upsertNoteTile(...)`.
6. Build and install `NoteTileNSView(tile:store:noteId:)` via `canvasView.install`.
7. Save canvas.
8. Return `.spawned(noteId:tileId:)`.

#### `installNoteTile(_ tile: Tile, in canvasView: CanvasNSView)` (boot path)

Used by the boot loop. Loads the note body (or starts empty if missing) and installs `NoteTileNSView`. Does not create a new `NoteTile` entry in the index -- the entry was written at spawn time.

#### `spawnFile(path:title:at:) -> FileOutcome`

```swift
enum FileOutcome {
    case spawned(tileId: UUID)
    case failure(Error)
}
```

Steps:
1. Compute `frame` via `makePlacement`.
2. Build `Tile` with `kind: .file`, `title: title ?? URL(fileURLWithPath: path).lastPathComponent`, `metadata: TileMetadata(filePath: path)`.
3. Build and install `FileTileNSView(tile:)` via `canvasView.install`.
4. Save canvas.
5. Return `.spawned(tileId:)`.

#### `installFileTile(_ tile: Tile, in canvasView: CanvasNSView)` (boot path)

Installs `FileTileNSView` for the given tile. File content is loaded by the view at init.

#### `upsertNoteTile(noteId:tileId:title:)` (private)

Analogous to `upsertBrowserTile`. Loads the current `NoteState` (or an empty one), upserts the entry by `noteId`, and saves via `projectStore.saveNoteState`.

#### `writeNoteSnapshot(noteId:tileId:text:)` (called by debounce flush)

Saves the raw text to `.md` and updates `NoteTile.updatedAt` in the index. Called by `AppDelegate.flushNoteSave()`.

#### `notePersistenceHandler: (() -> Void)?`

Mirrors `browserPersistenceHandler`. Set by `AppDelegate` to trigger `scheduleNoteSave()`.

---

## Boot-Loop Integration

In `ContinuumApp.swift`, the boot loop switch in `applicationDidFinishLaunching` currently handles `.note` and `.file` with a `DescriptorTileNSView` placeholder. Phase 6 replaces those arms with real tile installs.

```swift
case .note:
    installInitialNoteTile(tile, in: canvasView, via: spawner)
case .file:
    installInitialFileTile(tile, in: canvasView, via: spawner)
```

```swift
private func installInitialNoteTile(_ tile: Tile, in canvasView: CanvasNSView, via spawner: TileSpawner) {
    spawner.installNoteTile(tile, in: canvasView)
}

private func installInitialFileTile(_ tile: Tile, in canvasView: CanvasNSView, via spawner: TileSpawner) {
    spawner.installFileTile(tile, in: canvasView)
}
```

Neither method appends to a runtime array (there are no runtimes). Neither needs a restart-placeholder fallback: error states are shown inline by the tile views.

The `NoteState` index is not pruned at boot (unlike `TerminalSessionDescriptor` pruning). Note index entries accumulate until the user deletes a tile. If a `NoteTile` entry in the index has no corresponding canvas tile, it is silently ignored at boot. Orphan cleanup (e.g., a "Manage notes" view that lists unreferenced `.md` files) is a Phase 7 item.

**Ordering with prune step:** Note and file tile installation runs after `pruneExitedSessions(in: projectStore)` (unchanged) and after the canvas is loaded but before `projectStore.saveCanvas(canvasView.canvasState)`. This ordering is already correct from Phase 5 -- the boot loop walks `canvasState.tiles` in order and installs each tile kind.

---

## Debounced Persistence

### Note tiles

Note content changes are debounced separately from canvas geometry changes:

- `scheduleNoteSave()` / `flushNoteSave()` mirror `scheduleBrowserSave()` / `flushBrowserSave()`.
- Timer interval: 400ms (versus 200ms for canvas and browser). Note text changes are typically bursts of keystrokes; 400ms avoids write storms while still persisting within a second of the user stopping typing.
- `NoteTileNSView` calls `onTextChange?()` inside `textDidChange(_:)`, which triggers `AppDelegate.scheduleNoteSave()`.
- `flushNoteSave()` calls `tileSpawner?.writeNoteSnapshot(noteId:tileId:text:)` for each active note tile. The spawner reads the current `NSTextView.string` from the view. The `AppDelegate` keeps a `noteViews: [UUID: NoteTileNSView]` dictionary keyed by `noteId` to support this lookup.
- `windowWillClose` calls `flushNoteSave()` before the tile teardown path (no runtime to terminate for notes, so order relative to browser/terminal teardown does not matter).
- Canvas geometry changes (drag, resize) continue to fire `canvasDidChange` -> `scheduleCanvasSave()`. The 200ms canvas timer and the 400ms note timer are independent; they do not interfere.

### File tiles

File tiles carry no mutable runtime state. `FileTileNSView` never calls back to the spawner. No persistence handler is needed. File path changes are not supported in Phase 6 (you cannot change the path of an existing file tile -- delete and re-spawn).

### Canvas state

`TileMetadata.noteId` and `TileMetadata.filePath` are persisted as part of `CanvasState` via the existing `canvasDidChange` -> `saveCanvas` path. No additional save is needed for these fields.

---

## Hotkey Wiring

No new hotkeys in Phase 6. The Cmd-1..4 + Cmd-K scheme from Phase 4 is unchanged.

Note and file tiles are spawned from Cmd-K. The `LaunchProfilePalette` is extended to show additional rows for "New Note" and "Open File..." below the terminal profiles. Alternatively, the palette is extended as a general "spawn palette" for Phase 6. The exact palette UX is left to the implement phase as long as both actions are reachable from Cmd-K without a hotkey.

Rationale: Cmd-5 and Cmd-6 are not wired because (a) note and file tiles are less frequently spawned than terminals and browsers, (b) the hotkey scheme should grow with demonstrated daily-driver frequency rather than ahead of it, and (c) reserving slots costs nothing -- adding them later is trivial.

---

## Smoke Test Seam

The smoke test runs without an external filesystem, so note and file tiles must be seeded deterministically from within the smoke bootstrap path.

### Seeding

In `runSmokeTest(window:runtime:)`, before the timed action blocks, write:

1. A note `.md` file with fixed `noteId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!` and content `"smoke-note-ok"` to `.continuum-revived/notes/00000000-0000-0000-0000-000000000001.md`.
2. The `NoteState` index entry for this `noteId`, linked to a fixed `tileId = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!`.
3. A plain-text file `.continuum-revived/smoke-file.txt` with content `"smoke-file-ok"`.
4. A `CanvasState` tile with `kind: .note`, the fixed `tileId`, and `TileMetadata(noteId: noteId)`.
5. A `CanvasState` tile with `kind: .file`, a second fixed `tileId`, and `TileMetadata(filePath: smokeFileURL.path)`.

These tiles are injected into `canvasState` before the boot loop runs, so the loop installs them via the normal `installInitialNoteTile` / `installInitialFileTile` paths.

### Assertions (`noteOk`, `fileOk`)

At t=6.0s assertion block:

```
noteOk:
  - noteViews[noteId] is a NoteTileNSView
  - noteViews[noteId].textView.string == "smoke-note-ok"
  - NoteState on disk contains entry for noteId

fileOk:
  - canvasView has a tile view of type FileTileNSView for the file tileId
  - FileTileNSView.textView.string contains "smoke-file-ok"
  - TileMetadata.filePath is non-nil for the file tile
```

The smoke test pass message gains two new flags:

```
Ghostty smoke test passed (...+ note + file, occurrences=N)
```

---

## P6.1 to P6.N Step List

### P6.1 -- Pure-Core data model

**Files to create:**
- `Sources/ContinuumRevivedCore/NoteState.swift` -- `NoteState` and `NoteTile` types

**Files to modify:**
- `Sources/ContinuumRevivedCore/CanvasState.swift` -- add `noteId: UUID?` and `filePath: String?` to `TileMetadata`; add to `CodingKeys` and `encode(to:)`
- `Sources/ContinuumRevivedCore/ProjectStore.swift` -- add `notesDirectory`, `notesIndexFile`, `noteFile(id:)` layout properties; add `saveNoteState`, `loadNoteState`, `tryLoadNoteState`, `saveNoteBody`, `loadNoteBody`, `tryLoadNoteBody`
- `Sources/ContinuumRevivedCoreChecks/main.swift` -- add round-trip tests for `NoteState`, `NoteTile`, `TileMetadata.noteId`, `TileMetadata.filePath`, and `ProjectStore` note methods

**Verification:** `swift run ContinuumRevivedCoreChecks` green. `swift build` clean.

### P6.2 -- `NoteTileNSView`

**Files to create:**
- `Sources/ContinuumRevived/Canvas/NoteTileNSView.swift`

**Files to modify:**
- `Sources/ContinuumRevived/App/TileSpawner.swift` -- add `NoteOutcome`, `spawnNote`, `installNoteTile`, `upsertNoteTile`, `writeNoteSnapshot`, `notePersistenceHandler`

**Verification:** `swift build` clean. Manual: spawn a note from `spawnNote(title:)`, type text, close, reopen -- text persists.

### P6.3 -- `FileTileNSView`

**Files to create:**
- `Sources/ContinuumRevived/Canvas/FileTileNSView.swift`

**Files to modify:**
- `Sources/ContinuumRevived/App/TileSpawner.swift` -- add `FileOutcome`, `spawnFile`, `installFileTile`

**Verification:** `swift build` clean. Manual: spawn a file tile pointing at an existing `.swift` source file; verify content appears. Spawn a tile for a binary file; verify placeholder label.

### P6.4 -- Boot-loop integration

**Files to modify:**
- `Sources/ContinuumRevived/App/ContinuumApp.swift` -- replace `.note` and `.file` `DescriptorTileNSView` arms with `installInitialNoteTile` / `installInitialFileTile`; add `noteViews: [UUID: NoteTileNSView]` ivar; add `scheduleNoteSave()`, `flushNoteSave()`, note save timer ivar; set `spawner.notePersistenceHandler`; call `flushNoteSave()` in `windowWillClose`

**Verification:** `swift build` clean. Manual: note and file tiles from a prior session restore on relaunch with correct content.

### P6.5 -- Cmd-K palette extension

**Files to modify:**
- `Sources/ContinuumRevived/Canvas/LaunchProfilePalette.swift` (or equivalent palette file) -- add "New Note" and "Open File..." rows below terminal profile rows; "New Note" calls `spawner.spawnNote(title: "New Note")`; "Open File..." opens `NSOpenPanel` restricted to the project root, then calls `spawner.spawnFile(path:title:)`

**Verification:** `swift build` clean. Manual: Cmd-K shows note and file options; selecting each spawns the correct tile kind.

### P6.6 -- Smoke test seam

**Files to modify:**
- `Sources/ContinuumRevived/App/ContinuumApp.swift` -- add smoke seed logic for note and file tiles (fixed UUIDs, seed files, inject into `canvasState`); add `noteOk` and `fileOk` gates in the t=6.0s assertion block

**Verification:** `CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived` exits 0 with `...+ note + file` in the pass message. Three back-to-back runs clean. No entries in `~/Library/Logs/DiagnosticReports/`.

### P6.7 -- Two-pass relaunch

**Verification:** Two-pass relaunch with `CONTINUUM_PROJECT_ROOT` + `CONTINUUM_APP_SUPPORT` pinned. Pass 1: note tile created, text written to `.md`, index written. Pass 2: note tile restored, text matches. File tile restored with correct path. Smoke exits 0 both passes.

---

## Verification

Phase 6 is done when all of the following are observable:

1. `swift build` clean with no warnings introduced by Phase 6 files.
2. `swift run ContinuumRevivedCoreChecks` green, including new round-trip tests for `NoteState`, `NoteTile`, `TileMetadata.noteId/filePath`, and `ProjectStore` note methods.
3. `CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived` exits 0 with `noteOk=true fileOk=true` in the pass message, three back-to-back runs.
4. Two-pass relaunch: note text written in pass 1 appears in pass 2 without re-seeding.
5. File tile shows correct plaintext content for a real source file in the project tree.
6. Binary-file and oversize-file states show a non-editable placeholder label rather than crashing or showing garbage.
7. Note tile created via Cmd-K (palette) and file tile opened via Cmd-K (palette + NSOpenPanel) both appear on canvas and persist across relaunch.
8. No entries written to `~/Library/Logs/DiagnosticReports/` during any of the above.

---

## What's Deferred

The following are explicitly not in Phase 6:

- **Markdown preview rendering.** Phase 6 shows raw `.md` text in an `NSTextView`. A `WKWebView`-based or `AttributedString`-based preview is Phase 7+ or a standalone spike.
- **File tree tile.** A directory-scanning file tree (async scan, ignore lists, git status badges, search/filter) is called out in `docs/07-phased-build-plan.md` as a Phase 6 deliverable but it is the highest-scope item in the list. It is deferred from this MVP-within-Phase-6 to a follow-on step. The file tile (single file, read-only) is the lightweight stand-in. Rationale: the file tree scan has its own threading, ignore-list, and UI complexity that should not block note tiles from shipping.
- **File-watch invalidation.** The file tile does not watch the file for external changes (FSEvents or similar). Content is loaded once at tile-install time.
- **Drag-and-drop to create file tiles.** Dropping a file from Finder onto the canvas is not wired in Phase 6.
- **Note deletion UI.** There is no "Delete note" action in Phase 6. A tile can be removed from the canvas (if a canvas-level delete gesture exists), but the `.md` file and index entry are not cleaned up. Orphan cleanup is Phase 7.
- **Agent read/write bridge.** Notes being writable by agents (a key long-term differentiator) is Phase 8+ per `docs/07-phased-build-plan.md`.
- **Connected notes / note chains / inline images.** All deferred per `docs/06-browser-code-file-surfaces.md`.
- **Rich text formatting.** Notes are plain UTF-8. No bold/italic/heading rendering.
- **External note reference (dropped external `.md` files).** Phase 6 only creates new notes. "Dropped external note references if practical" from the Phase 6 deliverables list is deferred.
- **File content reload on focus / file-watch.** Not in Phase 6; content is static until tile is replaced.
- **Preferred external editor integration.** "Open in editor" from a file tile is a Phase 7 / Phase 6.N item, not in the initial steps.
- **Storage group distinction for notes.** No perProject/shared note policy in Phase 6.
- **JSON tree / code-aware rendering.** Explicitly out of scope.
- **Cmd-5 / Cmd-6 hotkeys.** Deferred (palette-only).

---

## Risks and Mitigations

**Risk: NSTextView performance on large files.**
Mitigation: The 1 MB cap prevents `NSTextView` from receiving very large strings. Above the cap, show a label instead. If 1 MB turns out to be too generous in practice during testing, lower the cap to 256 KB. The cap is a named constant (`FileTileNSView.maxReadBytes: Int = 1_024 * 1_024`) so it is easy to adjust.

**Risk: Binary file detection is imprecise.**
Mitigation: The null-byte scan of the first 8 KB is a widely-used heuristic and is correct for common cases (ELF binaries, object files, images). Files that pass the heuristic but contain unusual encodings will render as garbled text -- acceptable for Phase 6. Full MIME-type detection is deferred.

**Risk: Smoke seed fixed UUIDs collide with real user data if someone runs CONTINUUM_SMOKE_TEST=1 in their own project directory.**
Mitigation: The smoke test resolves to a fresh temp directory (`FileManager.default.temporaryDirectory` + a `UUID` prefix) unless `CONTINUUM_PROJECT_ROOT` is explicitly set. The fixed seed UUIDs are isolated to the temp directory. They cannot reach a real project unless the user explicitly overrides `CONTINUUM_PROJECT_ROOT` to their own project root while also enabling `CONTINUUM_SMOKE_TEST=1`, which is an unusual operation.

**Risk: `NoteTileNSView` text change -> debounce -> `writeNoteSnapshot` ordering on close.**
Mitigation: `windowWillClose` calls `flushNoteSave()` before any teardown. `flushNoteSave()` drains the debounce timer and writes immediately. This is the same pattern used for `flushCanvasSave()` and `flushBrowserSave()`, both of which are verified to work by existing smoke tests.

**Risk: `NoteState` index grows unbounded if note tiles are frequently created and the canvas is cleared without cleanup.**
Mitigation: Accepted for Phase 6. The index is project-local and `.md` files are small. An orphan-cleanup step (detect index entries with no corresponding canvas tile and offer to delete them) is a Phase 7 item.

**Risk: `NSOpenPanel` in the Cmd-K file spawn path requires the app to have access to the selected file. SwiftPM-built non-sandboxed app has full filesystem access, so this is not a blocker, but a future sandboxed distribution will need scoped security bookmarks.**
Mitigation: Noted. Phase 6 runs non-sandboxed. The file path is stored as an absolute string. When sandboxing is introduced, `TileMetadata.filePath` will be supplemented with a security-scoped bookmark blob. That migration is out of scope for Phase 6.

---

## Out of Scope (Explicit Non-Goals)

- Native code editor (syntax highlighting, LSP, multi-cursor). ADR-0007 defers this explicitly.
- File tree tile with directory scanning. Deferred from Phase 6 MVP.
- Git status badges on file or note tiles.
- Any agent-to-agent messaging involving note content.
- iCloud Drive awareness or conflict resolution for `.md` files.
- Migration of note content from any other note-taking format.
- Per-tile encryption or access control.
- Shared notes across projects.
