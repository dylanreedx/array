# ZoneRuntimeController extraction inventory

Status: CON-27 audit, 2026-06-12. No production movement in this ticket.

## Scope decision

ADR-0022 supersedes docs/18 Phase C's one-project-at-a-time switch design with a zoned multi-project canvas. The extraction target is therefore not `openProject(root:)` / `closeProject()` on `AppDelegate`; it is a per-project `ZoneRuntimeController` that can be Live, Snapshot, or Cold inside a workspace. The behavior-neutral rule from docs/18 still applies: initial extraction slices must preserve the single active project behavior and keep the full matrix green.

Verification command for this inventory:

```sh
sed -n '482,508p' Sources/ContinuumRevived/App/ContinuumApp.swift \
  | grep -E '^[[:space:]]*private (var|let) ' | nl -ba | tail -1
# 27
```

That count covers every current `AppDelegate` stored `private var` / `private let` in the main property block. Static smoke fixture constants are compile-time test fixtures and are listed separately below.

## Ownership classification

| Property | Current role | Classification | Extraction decision |
| --- | --- | --- | --- |
| `window` | Main application window. | App/window-scoped | Stays in `AppDelegate` or a future app shell. A controller must not own the NSWindow. |
| `ghostty` | GhosttyKit app/runtime context; creates per-tile terminal surfaces. | Global engine | Keep app-scoped and long-lived. `ZoneRuntimeController` owns terminal surfaces/runtimes, not the Ghostty engine. Preserve surface-before-engine teardown ordering. |
| `browserEngine` | WebKit context and data-store cache used by browser runtimes. | Ambiguous global/service | Prefer app-scoped service if storage isolation remains keyed by profile/storage group; document any future per-project store keys before sharing. Controller owns browser runtimes and save wiring. |
| `runtimes` | Live terminal runtimes/surfaces. | Per-project / per-zone | Move to `ZoneRuntimeController`; dehydrate/close terminates or snapshots surfaces per tier while preserving PTY semantics in later E6 work. |
| `browserRuntimes` | Live browser tile runtimes. | Per-project / per-zone | Move to controller; participates in browser Snapshot tier and global WKWebView LRU budget later. |
| `noteViews` | Installed note tile views keyed by note id (`noteViews[view.noteId]`), not tile id. | Per-project / per-zone | Move to controller with note save debounce/flush while preserving note-identity lookup. |
| `fileTreeViews` | Installed file-tree views keyed by tile id. | Per-project / per-zone | Move to controller with file-tree save debounce/flush. |
| `canvasView` | Current canvas view, empty state, tile installation surface. | Workspace/window view | In single-zone compatibility it remains one view. ADR-0022 makes the canvas/workspace app-scoped while controllers provide zone contents/frames. Do not put the whole canvas inside a project controller. |
| `saveTimer` | Debounced project canvas save. | Per-project / per-zone | Move with project store ownership; flush before runtime teardown. Later workspace-doc saves get a separate app/workspace debounce. |
| `browserSaveTimer` | Debounced browser state save. | Per-project / per-zone | Move to controller; must write to originating `ProjectStore`. |
| `noteSaveTimer` | Debounced note state save. | Per-project / per-zone | Move to controller; flush before closing/dehydrating views. |
| `fileTreeSaveTimer` | Debounced file-tree state save. | Per-project / per-zone | Move to controller; flush before closing/dehydrating views. |
| `smokeTestEnabled` | Process/environment QA mode flag. | Test harness / app-scoped | Stays out of controller except as explicit fixture configuration passed into controller checks. |
| `smokeTestExitCode` | QA exit status accumulator. | Test harness / app-scoped | Stays in harness/AppDelegate layer. Controllers can expose check seams but should not own process exit. |
| `projectStore` | Project-local `.continuum-revived` persistence. | Per-project / per-zone | Move to controller. Workspace store remains separate and central. |
| `registryStore` | Central project/workspace registry. | App/workspace-scoped service | Stays app-scoped; controllers receive resolved `Project` identity and project root. |
| `projectLock` | Single-instance lock for current project. | Per-hydrated-project | Move to controller. ADR-0022 changes lock failure from app refusal to per-zone Cold/locked degradation. |
| `activeProject` | Current resolved project identity. | Per-project identity plus app selection | Controller owns its `Project`; app/workspace tracks active/focused zone/project. |
| `tileSpawner` | Creates tiles bound to project store, canvas, engines, and project. | Per-project / per-zone adapter | Move into or behind controller. App palette invokes the focused controller's spawner. |
| `profilePalette` | Launch palette UI/model adapter; rows cache profile/spawn state. | App UI with per-controller rows | App-scoped palette view may stay, but rows must rebuild from the active/focused controller. No stale project rows after controller close. |
| `focusBroker` | Single window focus authority and modal state. | App/window-scoped | Stays app-scoped. Controllers register/unregister their surfaces with it on open/close/hydrate/dehydrate. |
| `qaPerf` | Perf measurement helper. | Test harness / app-scoped | Stays app-scoped; controllers may expose measured events. |
| `launchStartTime` | Boot/perf timestamp. | Test harness / app-scoped | Stays app-scoped. |
| `hotkeyMonitor` | Local key monitor for reserved shortcuts. | App/window-scoped monitor | Stays app-scoped; one monitor only. It routes to broker/focused controller. |
| `tileFocusMonitor` | Mouse/focus event monitor for tile activation. | App/window-scoped monitor | Stays app-scoped; must not duplicate per controller. |
| `canvasScrollMonitor` | Canvas scroll local monitor. | App/window-scoped monitor | Stays app-scoped. It mutates workspace viewport and focused canvas, not project persistence directly. |
| `canvasMagnifyMonitor` | Canvas zoom local monitor. | App/window-scoped monitor | Stays app-scoped. It mutates workspace viewport. |

Static smoke ids and bodies (`smokeNoteId`, `smokeNoteTileId`, `smokeFileTileId`, `smokeFileTreeTileId`, `smokeNoteBody`, `smokeFileBody`, `smokeFileLongBody`) are deterministic QA fixtures. Keep them in the harness layer or move to a dedicated self-check fixture type; they are not runtime project state.

## Registration and lifecycle inventory

- Boot creates the project lock, `ProjectStore`, Ghostty context, `BrowserEngineContext`, `CanvasNSView`, `TileSpawner`, and palette, then installs restored tile runtimes/views.
- `CanvasNSView.focusBroker` registers the canvas surface; tile installs register tile surfaces; tile removal unregisters individual tile surfaces.
- Event monitors (`hotkeyMonitor`, `tileFocusMonitor`, `canvasScrollMonitor`, `canvasMagnifyMonitor`) are installed once for the window and removed during window teardown.
- Current close path flushes save timers, invalidates monitors, terminates browser runtimes, terminates Ghostty surfaces before shutting down Ghostty, clears view maps, closes the browser engine, and releases the project lock.

## Controller boundary contract

A `ZoneRuntimeController` should own:

- `Project` identity and `ProjectStore`;
- per-hydrated-project `ProjectLock`;
- terminal/browser/note/file-tree runtime and view collections;
- canvas/browser/note/file-tree save debounces and flush methods;
- project-bound tile spawning and restored tile installation;
- broker surface registrations for that project's tile surfaces;
- tier transitions that flush before dehydrate/close.

The app/window/workspace layer should own:

- `NSWindow`, app activation/resign, and process exit;
- one `FocusBroker` and one set of local event monitors;
- central `RegistryStore` and later `WorkspaceStore`;
- the canvas/workspace view and viewport;
- global services (`GhosttyRuntimeContext`, likely `BrowserEngineContext`) whose per-project use is mediated by controllers;
- smoke/perf harness exit handling.

## Ambiguities resolved

1. **Canvas view:** docs/18 said to recreate the canvas during project switching. ADR-0022 retargets this: the canvas is the workspace surface and must remain app/window-scoped; project controllers supply zone-local tile content.
2. **FocusBroker:** the broker remains single-window global. Surface registrations are controller lifecycle responsibilities; stale adapter cleanup must be a reviewer focus for every extraction slice.
3. **Ghostty:** the Ghostty engine is global. Terminal runtime/surface ownership moves, and close/dehydrate must terminate or snapshot surfaces before any engine shutdown.
4. **BrowserEngineContext:** treat as a global service unless a later implementation proves its cache carries project-local state. Browser runtimes and browser state saves are still controller-owned.
5. **Timers:** all project-data debounce timers move with the project store. Workspace viewport/zone-layout saves must use a separate workspace debounce later.

## QA oracles for the extraction tickets

Extraction is behavior-neutral only if these remain true:

- Full matrix stays green with no semantic check weakening.
- Flushing order is unchanged: canvas/browser/note/file-tree pending writes flush before views/runtimes/stores are replaced or torn down.
- Terminal surfaces are terminated before Ghostty engine shutdown.
- Browser runtimes are stopped and browser state saves go to the originating project store.
- Broker has no stale tile surfaces after controller close/dehydrate.
- Only one set of app/window monitors is installed.
- Lock ownership is per hydrated project; lock release happens exactly once.
- Palette rows rebuild after controller open/focus changes and do not keep stale project-bound spawner references.

## Follow-on slice checklist

- E4-2 should introduce the controller skeleton with stores, identity, lock, and open/close flush ordering only.
- E4-3 should move runtime/view collections without changing checks.
- E4-4 should move debounce timers and prove note/browser/file-tree persistence.
- E4-5 should move broker registration lifecycle and palette rebuild seams.
- E4-6 should run the broad equivalence gate and record the final boundary ADR note.
