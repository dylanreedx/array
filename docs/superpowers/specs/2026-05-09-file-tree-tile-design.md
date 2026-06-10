# File Tree Tile Design

**Status:** Proposed
**Date:** 2026-05-09
**Scope:** Design only. No production implementation is included in this task.

## Problem Statement

Phase 6 shipped live note tiles and read-only single-file tiles, but it deliberately deferred the file tree because directory scanning, ignore policy, filtering, and status badges are larger than the note/file MVP. The file tree remains the missing workspace-context surface: it lets humans and agents see project shape, spot changed files, and jump from observation to editing without leaving the canvas.

The design must start from the Phase 6 warning: large directory scans can freeze the app if they run on the AppKit path. A file tree implementation that synchronously walks a repository from `NSOutlineView` callbacks or tile construction is unacceptable. Scanning, filtering, and git status refreshes must be backgrounded from the first implementation, with cancellation tied to tile teardown and project changes.

## Decision

Add a live `fileTree` tile kind backed by a pure Core `FileTreeState` and a MainActor AppKit tile view. The state belongs in Core, not inside the tile view, because the tree root, expanded paths, selected path, search query, ignore settings, and status-badge mode are persisted project state in the same family as `BrowserState` and `NoteState`. The tile view owns transient UI state only: scroll position, current in-memory snapshot, pending search debounce, and row selection highlight.

The scanner is a separate non-MainActor service. It accepts a root URL, an ignore policy, an optional filter query, a git-status snapshot, and a cancellation token. It returns immutable snapshots to the MainActor view model. The first implementation should use Swift structured concurrency with `Task.detached(priority: .utility)` plus cooperative `Task.checkCancellation()` checks between directory batches. `NSOperationQueue` and Dispatch queues are rejected for the first version because Swift tasks fit the existing app concurrency style and make tile-close cancellation explicit.

Default ignores are hardcoded and always active unless the user explicitly expands or disables them later: `.git`, `node_modules`, `target`, `.build`, `DerivedData`, `Pods`, `vendor`, `.next`, and `.cache`. The MVP reads `.gitignore` only as a follow-up. Hardcoded defaults avoid partial, misleading gitignore semantics while still protecting the app from the known heavy folders.

Search is local to the tile through an inline `NSSearchField` above an `NSOutlineView`. The command palette remains the global spawn surface and should not become the per-tree filter UI. The search field filters the latest scanner snapshot in memory with a short debounce; it does not start a full filesystem walk for each keystroke unless the root or ignore policy changes.

Double-click, Return, and context-menu "Open in Preferred Editor" use the existing external editor profile when it is configured and available. If no preferred editor is configured, the fallback is `NSWorkspace.shared.open(fileURL)`. Dragging a file from the tree onto the canvas spawns a Phase 6 read-only file tile using the existing file tile path metadata.

Git status badges are cheap-only in the MVP. The scanner shells out once per refresh with `git -C <root> status --porcelain=v1 -z` when the root is inside a git working tree, parses the output off the MainActor, and maps statuses by project-relative path. It does not add libgit2 or refresh status per row. If the command times out or fails, badges are hidden and the tree remains usable.

The default model is one file tree tile per project canvas, spawned through Cmd-K. Multiple file tree tiles are allowed if the user explicitly spawns them, because different roots, filters, or expanded states can be useful. Position, size, z order, root path, expanded paths, and selected path persist through the existing canvas and project-store paths.

## What's In

- `TileKind.fileTree` in Core and the boot-loop switch arm needed to install it.
- `FileTreeState` in Core, stored under `.continuum-revived/file-tree/index.json`.
- `FileTreeTile` entries keyed by `tileId`, with root path, expanded project-relative paths, selected project-relative path, search query, ignored folder names, and git-badge mode.
- `FileTreeScanner`, a non-MainActor service that produces immutable `FileTreeSnapshot` values from directory batches.
- `FileTreeNode`, a Sendable snapshot model with project-relative path, display name, directory flag, child summary, ignored flag, and optional git status.
- `FileTreeTileNSView`, a MainActor tile view with `NSSearchField`, `NSOutlineView`, loading/progress state, empty state, error state, and context menu actions.
- `FileTreeViewModel`, a MainActor coordinator that starts scanner tasks, cancels old tasks, applies snapshots, persists expanded/selected/search state, and bridges drag/open actions to `TileSpawner`.
- Cmd-K spawn action "Open File Tree..." that defaults to the project root and permits choosing a subdirectory.
- Open-with integration that first asks the existing external editor profile path and falls back to `NSWorkspace.open(_:)`.
- Drag-from-tree-to-canvas integration that creates a normal Phase 6 file tile for a selected file.
- Core checks for `FileTreeState` and `FileTreeNode` encode/decode behavior.
- App-level smoke coverage that seeds a small fixture tree and verifies the tile installs without blocking the existing smoke close path.

Suggested Core shape:

```swift
public struct FileTreeState: Codable, Equatable, Sendable {
    public var tiles: [FileTreeTile]
}

public struct FileTreeTile: Codable, Equatable, Sendable {
    public var tileId: UUID
    public var rootPath: String
    public var expandedPaths: [String]
    public var selectedPath: String?
    public var searchQuery: String
    public var ignoredNames: [String]
    public var gitBadges: FileTreeGitBadgeMode
}

public enum FileTreeGitBadgeMode: String, Codable, Equatable, Sendable {
    case off
    case cheap
}

public struct FileTreeNode: Codable, Equatable, Sendable {
    public var relativePath: String
    public var displayName: String
    public var isDirectory: Bool
    public var childCount: Int
    public var isIgnored: Bool
    public var gitStatus: FileTreeGitStatus?
}
```

## Async Scanning Policy

`FileTreeViewModel` starts one scanner task per tile root and search policy generation. Every new root, ignore-list change, refresh command, or tile teardown cancels the previous task before starting another. The cancellation rule is simple: a snapshot from a cancelled generation is ignored even if it arrives after cancellation.

The scanner walks directories breadth-first in batches. Between batches it checks cancellation and yields partial snapshots so the outline can show early results for large repositories. Directory enumeration must request lightweight resource values only, skip hidden/heavy defaults early, and avoid resolving symlinks recursively. Symlinked files may appear as leaf nodes; symlinked directories are not traversed in the MVP.

`FilePreview.load(path:)` is not reused by the scanner. It is a single-file content classifier and reader, while the tree needs metadata-only traversal. The interaction point is downstream: selecting or dragging a file from the tree can spawn a `FileTileNSView`, and that existing tile continues to use `FilePreview` for read-only content display.

## Ignore Policy

The MVP ships a deterministic ignore list:

- `.git`
- `node_modules`
- `target`
- `.build`
- `DerivedData`
- `Pods`
- `vendor`
- `.next`
- `.cache`

Ignored directories are excluded from traversal by default. If a later UI allows manual expansion of an ignored directory, that expansion should be explicit, per path, and persisted in `FileTreeTile`. The first implementation should not parse `.gitignore`; partial gitignore support is easy to get wrong and could imply correctness the app does not have. A later implementation may add a dedicated gitignore parser after the hardcoded list proves stable.

## Search And Filter

The file tree tile owns an inline `NSSearchField` in its header. Search filters file and folder names from the latest scanner snapshot, keeps ancestors visible for matched descendants, and highlights matching rows. Empty search shows the normal expanded tree. Search does not mutate the underlying expanded-path list; clearing the search restores the prior expansion.

The search query is persisted because it changes the user's workspace context. A restored tile may reopen with the last query visible, but it should still show a clear button and allow Escape inside the search field to clear the query before forwarding focus recovery to the future FocusBroker.

## Open With And File Tile Integration

The tree exposes three open flows:

1. Double-click or Return on a file spawns a read-only file tile on the canvas.
2. Context-menu "Open in Preferred Editor" opens the selected file with the configured external editor profile.
3. If no editor profile is available, "Open in Preferred Editor" falls back to `NSWorkspace.shared.open(fileURL)`.

Directories expand or collapse on double-click. Dragging a file row onto empty canvas space spawns a file tile at the drop point. Dragging a directory row is ignored in the MVP unless the drop target is a future file tree spawn action.

## Git Status Badges

Git status is opportunistic. On scan refresh, the app runs one background process for the root if the root is inside a git work tree:

```text
git -C <root> status --porcelain=v1 -z
```

The parser maps statuses to project-relative paths and stores them only in the transient `FileTreeSnapshot`. Persisted state stores the badge mode, not the latest status. Badge rendering should be compact: modified, added, deleted, renamed, untracked, and conflicted are enough for the first pass.

The process has a short timeout and no per-row shell calls. Failure hides badges and records a debug log line. The tree must never block rendering, scanning, search, or open-with actions while git status is unavailable.

## Verification

- **Core checks gate:** `swift run ContinuumRevivedCoreChecks` covers `FileTreeState`, `FileTreeTile`, `FileTreeNode`, and `FileTreeGitBadgeMode` round trips.
- **Scanner checks gate:** a unit-style executable fixture walks a small tree, proves heavy defaults are skipped, proves symlinked directories are not traversed, and proves cancellation prevents stale snapshots from applying.
- **Search checks gate:** filtering keeps ancestor folders visible for descendant matches and clearing search restores expansion.
- **Git checks gate:** porcelain parser maps modified, added, deleted, renamed, untracked, and conflicted rows without spawning a process per row.
- **Build gate:** `swift build` completes cleanly with no Swift concurrency warnings.
- **Smoke gate:** `CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived` seeds a small fixture tree, installs a file tree tile, confirms the tile reports at least one visible row, and exits through the existing close path.
- **Manual visual gate:** a medium repository opens without main-thread stalls; font/readable row labels remain visible; loading and empty states do not clip; badges, disclosure triangles, and row labels do not overlap.

## Phase Exit Criteria

The file tree tile is ready to ship when all of the following are concurrently true:

1. A file tree tile can be spawned from Cmd-K for the project root.
2. Directory scanning starts off the MainActor and can be cancelled by closing the tile before the scan completes.
3. Default heavy folders are skipped without user setup.
4. Search filters the loaded tree without changing persisted expansion.
5. Double-click or Return on a file creates a normal read-only file tile.
6. The context menu opens the selected file in the preferred editor or falls back to `NSWorkspace.open(_:)`.
7. Git badges appear when the cheap status command succeeds and disappear without blocking when it fails.
8. Tile position, size, z order, root path, expanded paths, selected path, and search query survive relaunch.
9. `swift build`, Core checks, scanner checks, git parser checks, and the smoke gate all pass.

## What's Deferred

- `.gitignore` parsing and full gitignore semantics.
- Per-language icons, file-type color themes, and image previews.
- File watching through FSEvents.
- Inline rename, delete, create-file, and create-folder actions.
- Multi-select tree operations.
- Directory drag-to-create-a-second-file-tree behavior.
- libgit2 integration or persistent git status caches.
- Security-scoped bookmarks for sandboxed distribution.
- Cross-tile global file search.
- Agent file-operation permissions and write mediation.

## Consequences

Positive:

- The canvas gains project structure without forcing users into a separate sidebar.
- The file tree composes with the existing single-file tile instead of replacing it.
- Core-owned state keeps persistence and tests out of AppKit.
- Background scanning protects the app from the known large-directory freeze risk.

Tradeoffs:

- A Core state file and scanner service are more infrastructure than a tile-local outline view.
- Hardcoded ignores are intentionally less complete than `.gitignore`.
- Cheap git status can be stale between refreshes.
- Multiple file tree tiles can show different snapshots of the same root until refresh.

Rejected alternatives:

- Keep all file tree state tile-local. This would avoid a Core type, but it would lose persisted root, expansion, selection, and search context.
- Share `FileTileNSView`'s async path with the tree scanner. The file tile reads file content; the tree scanner needs metadata batches and cancellation semantics.
- Add libgit2 for status badges in the first pass. It would avoid shell process parsing but adds dependency and packaging weight before badges prove worth it.
- Put search in the global command palette. Filtering is local, continuous tile state; the palette should remain a spawn and command surface.
