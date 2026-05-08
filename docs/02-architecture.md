# Architecture

## Decision

`continuum-revived` is a native macOS app built in Swift, SwiftUI, and AppKit. Swift domain models are the source of truth. AppKit is used where native event handling, first responder behavior, WebKit hosting, and Ghostty surfaces require lower-level control. SwiftUI is used for app shell, panels, settings, and composition where it does not fight focus or performance.

No Electron. No Tauri. No web frontend.

## Architectural Goals

- Make terminal quality a foundation, not a component swap.
- Keep model ownership clear and local.
- Make focus explicit and testable.
- Keep persistence inspectable and recoverable.
- Prevent cross-layer schema drift.
- Keep the canvas engine independent from terminal/browser implementations.
- Avoid broad feature work before the project/session/canvas loop works.

## Subsystems

### Domain

Responsibilities:

- Define workspace, project, canvas, tile, viewport, launch profile, surface status, and persisted state models.
- Own IDs and invariants.
- Define serialization schema versions.
- Provide model validation and migration entry points.

Rules:

- Domain models do not import SwiftUI, AppKit, WebKit, or Ghostty.
- Domain models are the only source for persisted shape.
- Optional/future fields are explicit and migration-aware.

Core concepts:

- `Workspace`: user-facing grouping of projects.
- `Project`: a root directory plus one active canvas.
- `CanvasState`: viewport, zoom, tiles, groups, z-order, selection metadata that should persist.
- `Tile`: persisted spatial node with kind-specific metadata.
- `LaunchProfile`: command template for terminal-backed surfaces.
- `SurfaceStatus`: observed runtime state, not necessarily persisted.

### Persistence

Responsibilities:

- Maintain central registry in Application Support.
- Maintain project-local `.continuum-revived/` folder.
- Read/write project state atomically.
- Maintain backups.
- Apply migrations.
- Detect and report recoverable corruption.

Rules:

- Runtime process objects are never serialized directly.
- Persist descriptors, not live handles.
- Notes are markdown files when notes exist.
- The central registry is an index, not the source of project truth.

### CanvasEngine

Responsibilities:

- Infinite coordinate system.
- Pan/zoom math.
- Tile layout transforms.
- Selection, drag, resize, z-order.
- Spatial indexing.
- Hit testing.
- Group geometry.
- Future minimap/focus mode hooks.

Rules:

- CanvasEngine knows tile bounds and kinds, but not how a terminal or browser renders.
- CanvasEngine emits interaction intents.
- Runtime surfaces subscribe to geometry changes through a narrow adapter.

### TerminalEngine

Responsibilities:

- Wrap libghostty.
- Spawn PTY-backed commands.
- Host Ghostty rendering surfaces.
- Route keyboard/mouse input.
- Resize PTYs on tile resize.
- Track process lifecycle.
- Expose terminal status best-effort.

Rules:

- Ghostty integration sits behind a project-owned adapter boundary.
- App code never calls Ghostty APIs directly outside TerminalEngine.
- If Ghostty cannot satisfy MVP requirements, implementation pauses.

### BrowserEngine

Responsibilities:

- Host WKWebView surfaces.
- Manage navigation state.
- Persist URL/title/basic browser metadata.
- Own per-project browser storage policy.
- Isolate browser focus from app focus.
- Support local dev workflows.

Rules:

- Browser tiles are native WebKit surfaces, not fake previews.
- Browser automation is deferred.
- Element picker and agent DOM context are post-MVP.

### LaunchProfiles

Responsibilities:

- Define built-in profiles.
- Detect installed tools.
- Resolve commands, cwd, environment, arguments, and titles.
- Provide editable custom profiles.

Built-in profiles:

- Shell.
- Claude Code.
- Codex review.
- Neovim.
- Custom command.
- External editor open command.

Detection targets:

- `nvim`.
- `claude`.
- `codex`.
- `cursor`.
- `code`.
- `zed`.
- Xcode via `xed` or app bundle detection.

### AppShell

Responsibilities:

- Window layout.
- Workspace/project switcher.
- Command palette.
- Add-tile UI.
- Settings.
- Status bar.
- Modal/sheet presentation.
- Focus broker integration.

Rules:

- AppShell does not own canvas geometry.
- AppShell does not own PTY process lifecycle.
- AppShell can ask subsystems for commands and state.

### FocusBroker

Responsibilities:

- Track active surface.
- Manage transitions between app chrome, canvas, terminal, browser, modal, settings, and command palette.
- Restore focus after modal dismissal.
- Reserve app-level shortcuts.
- Provide emergency focus recovery.

Rules:

- Every interactive embedded surface must explicitly acquire and release focus.
- FocusBroker is not optional polish; it is core infrastructure.
- Terminal and browser adapters must ask before consuming reserved shortcuts.

## Data Flow

### App Launch

1. AppShell starts.
2. Persistence loads central registry.
3. Last workspace/project is selected if available.
4. Project store loads project-local state.
5. CanvasEngine receives CanvasState.
6. Tile runtime manager creates runtime surfaces for restorable tile descriptors.
7. FocusBroker sets canvas as default active surface.

### Add Terminal Tile

1. User invokes add command.
2. AppShell asks LaunchProfiles for available profiles.
3. User chooses profile.
4. Domain creates a terminal tile descriptor at viewport center/cursor.
5. CanvasEngine inserts tile geometry.
6. TerminalEngine starts PTY/Ghostty runtime.
7. Persistence schedules state write.
8. FocusBroker activates terminal surface.

### Add Browser Tile

1. User invokes browser command.
2. Domain creates browser tile descriptor.
3. CanvasEngine inserts tile geometry.
4. BrowserEngine creates WKWebView with per-project storage context.
5. BrowserEngine navigates to default or user-provided URL.
6. Persistence stores descriptor and URL updates.
7. FocusBroker activates browser surface.

### Project Switch

1. User selects project.
2. AppShell asks current project runtime manager to suspend, keep alive, or close based on MVP policy.
3. Persistence flushes current state.
4. Project store loads target project state.
5. CanvasEngine swaps state.
6. Runtime manager starts/restores target surfaces.
7. FocusBroker activates canvas or last active tile if safe.

## Avoiding Continuum's Failure Modes

### Schema Drift

Continuum mirrored Rust models in TypeScript comments and interfaces. `continuum-revived` keeps one language and one domain model source. Serialization tests assert round trips and migrations.

### Reactive State Overload

Continuum correctly kept spatial index outside reactive store. `continuum-revived` should do the same: CanvasEngine owns mutable spatial indexes and publishes minimal view invalidation signals.

### Focus Bugs

Continuum required repeated fixes for terminal/browser/global shortcut focus. `continuum-revived` starts with FocusBroker and first-responder recovery.

### Browser Surprise

Browser surfaces are special. WKWebView lifecycle, storage, navigation, crash/process behavior, and shortcut routing need a BrowserEngine from the start.

### Terminal As Add-On

Terminal is the heart. Ghostty spike happens before broad app features.

## Implementation Order

1. Docs.
2. Native skeleton.
3. Ghostty spike.
4. Project/persistence.
5. Canvas MVP.
6. Launch profiles.
7. Browser tiles.
8. Files/notes/editor handoff.
9. Hardening.
10. Differentiators.

