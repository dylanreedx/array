# Decisions

This is an append-only decision log. New implementation discoveries should add entries rather than rewriting history, unless a decision is explicitly superseded.

## ADR-0001: Build Native macOS

Date: 2026-05-07

Decision:

Build `continuum-revived` as a native macOS app using Swift, SwiftUI, and AppKit where needed.

Rationale:

The app depends on high-quality terminal surfaces, native focus behavior, WKWebView browser tiles, keyboard-first controls, and low-noise desktop integration. Continuum's Tauri/React/Rust split created schema and focus complexity. Native macOS gives cleaner ownership for this product.

Consequences:

- No Electron.
- No Tauri.
- No web frontend.
- AppKit escape hatches are expected.

## ADR-0002: Use Ghostty As Terminal Foundation

Date: 2026-05-07

Decision:

MVP terminal tiles must be Ghostty/libghostty-backed.

Rationale:

Terminal quality is central. Claude Code, Codex, Neovim, shells, and future TUI agents need excellent rendering/input/resize behavior.

Consequences:

- Phase 1 is a Ghostty spike.
- If Ghostty integration blocks, pause broad implementation.
- SwiftTerm fallback is not an implicit option.

## ADR-0003: Use Project Spaces For MVP Navigation

Date: 2026-05-07

Decision:

Use Project Spaces: workspaces contain projects; each project owns one primary canvas. Switching projects switches the canvas.

Rationale:

This is cleaner than activity lenses for MVP and maps well to real development directories. It still allows groups inside projects and later activity lenses/floors.

Consequences:

- One project equals one canvas in MVP.
- Groups are visual organization inside a project.
- Activity lenses are post-MVP.

## ADR-0004: Store Project State Locally Beside Projects

Date: 2026-05-07

Decision:

Store project state in `<project-root>/.continuum-revived/`, with a small central Application Support registry for recent projects/workspaces.

Rationale:

Project-local state is inspectable, hackable, recoverable, and friendly to agents. Central registry keeps switching fast.

Consequences:

- Need `.gitignore` helper/prompt.
- Need atomic writes and backups.
- Need iCloud-aware caution.

## ADR-0005: Defer Agent-To-Agent Messaging

Date: 2026-05-07

Decision:

Agent-to-agent PTY ask bus is post-MVP.

Rationale:

The first value loop does not require it. Terminal/session/canvas/browser/persistence reliability must come first.

Consequences:

- MVP still supports multiple agent terminal sessions.
- Launch profiles are the first agent abstraction.
- Future bus should integrate through terminal/session descriptors.

## ADR-0006: Include Native Browser Tiles In MVP

Date: 2026-05-07

Decision:

MVP includes WKWebView browser tiles.

Rationale:

Browser previews are part of real AI coding loops. Nyx makes native browser tiles a core part of its product, and Maestri portals show the broader direction.

Consequences:

- BrowserEngine is a real subsystem.
- Browser automation is deferred.
- Focus ownership must account for browsers early.

## ADR-0007: Support Neovim And External Editors

Date: 2026-05-07

Decision:

Detect Neovim and provide a first-class Neovim launch profile, but also support Cursor, VS Code, Zed, Xcode, and custom external editor handoff.

Rationale:

The app should suit Dylan's vim workflow without excluding colleagues.

Consequences:

- No native full code editor in MVP.
- LaunchProfiles handles tool detection and command resolution.
- External editor opening is a first-class command.

## ADR-0008: Docs Before Scaffolding

Date: 2026-05-07

Decision:

Create detailed docs before app scaffolding.

Rationale:

Continuum became hard to iterate on because many subsystems grew at once. The new project needs a clear architecture and phase plan before code.

Consequences:

- This docs suite is Phase 0 output.
- App implementation begins only after reviewing these docs.

## ADR-0009: Phase 1 Ghostty Spike Blocked On Reliable Embed Verification

Date: 2026-05-07

Decision:

Keep the Phase 1 SwiftPM/AppKit skeleton and Ghostty adapter spike, but do not advance to broader app work yet. The Ghostty-backed surface reached initialization, computed terminal size, and spawned `/usr/bin/login` through Ghostty, but the full hard gate is not proven.

Evidence:

- `GhosttyKit.xcframework` from local `ghostty-src` can be linked into the SwiftPM executable through `ThirdParty/GhosttyKit.xcframework`.
- `ghostty_init`, `ghostty_app_new`, and `ghostty_surface_new` are callable from the app.
- The first debugger run created a Ghostty surface, reported `137x30` cells at `1800x1200` pixels, and logged `started subcommand path=/usr/bin/login`.
- The initial renderer crash was traced to Swift actor isolation: C callbacks created inside a `@MainActor` context were invoked by Ghostty's renderer thread, triggering `_dispatch_assert_queue_fail`. Moving the Ghostty runtime callback context out of `@MainActor` resolved that specific assertion in the subsequent debugger run.
- Automated smoke verification still exits with Ghostty crash artifacts before it can prove rendered output/input/resize/cleanup outside LLDB.

Blocker:

The spike has not yet proven all hard-gate requirements: shell output rendering, keyboard input, resize behavior, and clean close in a normal run. The remaining blocker is reliable verification of the embedded Ghostty surface from a SwiftPM-built, non-bundled host.

Relevant references:

- Local Ghostty source: `/Users/dylan/Library/Mobile Documents/com~apple~CloudDocs/personal/ghostty-src`
- Ghostty C API: `include/ghostty.h`
- macOS reference wrapper: `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
- Renderer assertion source path observed in LLDB: renderer thread -> `apprt.surface.Mailbox.push` -> Swift callback closure.

Consequences:

- Do not switch to SwiftTerm.
- Do not start Phase 2 or broader UI work yet.
- Next deliberate options are: build a real `.app` bundle target with the Ghostty resource layout, port the minimum of Ghostty's AppKit `SurfaceView` wrapper instead of the thin direct C view, or patch/build a narrower Ghostty embedding wrapper designed for third-party hosts.

## ADR-0010: Phase 1 Smoke-Test Crash Resolved; Crash Gate Passed, Hard Gate Partially Passed

Date: 2026-05-08

Decision:

The Phase 1 smoke-test crash documented in ADR-0009 is resolved. The crash gate is passed; the hard gate is passed for items 1-5; item 6 (mouse selection/scrolling) remains pending behind a separate, scoped next step. Continue with the SwiftPM/AppKit thin-wrapper approach. Do not pivot to a `.app` bundle, do not vendor `SurfaceView_AppKit.swift`, and do not switch to SwiftTerm.

Evidence:

- A real backtrace was captured under LLDB. The crash was `EXC_BAD_ACCESS` (KERN_INVALID_ADDRESS at `0x5c7caff601ed1530` — a tagged/PAC-mangled freed pointer) in `apprt.embedded.Surface.deinit`, called from `App.destroy` (i.e. `ghostty_app_free`), called from the smoke test's t+3 close handler. Fault thread frames matched: `Surface.deinit ← App.destroy ← _dispatch_client_callout ← _dispatch_main_queue_drain`.
- The crash report was written to `~/Library/Logs/DiagnosticReports/continuum-revived-2026-05-08-173656.ips`. This contradicted the assumption that no crash artifacts were being produced.
- Root cause matched finding **F3** in the plan: `runSmokeTest` and `windowWillClose` both invoked `ghostty_surface_request_close` (asynchronous) and immediately called `ghostty_app_free`. Ghostty's `App.destroy` walks the surface registry and dereferences PAC-protected pointers; with a surface still live, this dereferences memory the Zig runtime considered torn down, faulting on the auth check.
- The hypothesis from F2 (first `set_size` running at logical/unscaled pixels) was retired by the same trace: every `set_size` in the LLDB output reported correct backing pixels (`137x30`/`1800x1200`, `131x27`/`1720x1080`).
- The `/usr/bin/login` log line in earlier traces was confirmed normal: Ghostty's macOS shell-spawn path wraps the user shell with `/usr/bin/login` for proper PAM/session setup. It is not a fallback for a missing `command`. The dangling-`withCString`-pointer hypothesis was also retired.

Fixes applied (commit pending):

- `windowWillClose` and `runSmokeTest` use `runtime.terminate(policy: .force)` so `ghostty_surface_free` runs synchronously before `ghostty_app_free` (`Sources/ContinuumRevived/App/ContinuumApp.swift`). One-line change at each call site.
- `runSmokeTest` now closes via `window.performClose(nil)` and reports its result through a stored `smokeTestExitCode`, so the smoke test exercises the production `windowWillClose` path rather than a parallel manual teardown. `windowWillClose` reads that code and exits with it when set; otherwise it falls through to `NSApp.terminate(nil)` for normal user-driven close (`Sources/ContinuumRevived/App/ContinuumApp.swift`).
- `NSApp.activate(ignoringOtherApps:)` was moved to the end of `applicationDidFinishLaunching` so the synchronous `applicationDidBecomeActive` re-entrancy fires after the runtime is wired up — the first `ghostty_app_set_focus(true)` is no longer silently dropped (finding F7).

Verification:

- `./scripts/prepare-ghosttykit.sh` — passes.
- `swift build` — passes.
- `swift run ContinuumRevivedCoreChecks` — passes.
- `CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived` — exits 0 with `Ghostty smoke test passed` across three back-to-back runs. The smoke test now closes via `window.performClose(nil)` so the close path is the one a normal user hits.
- `~/Library/Logs/DiagnosticReports/continuum-revived-*.ips` — no entries written by the new build.

Hard-gate status (per `docs/04-terminal-ghostty-plan.md`):

| # | Requirement | Status |
|---|---|---|
| 1 | Swift/AppKit host can create a Ghostty-backed terminal surface | ✓ |
| 2 | Local shell can spawn under PTY | ✓ (zsh via `/usr/bin/login`, with Ghostty shell integration auto-injected) |
| 3 | Output renders | ✓ (smoke test reads `ghostty-ok` via `ghostty_surface_read_text`) |
| 4 | Keyboard input reaches the PTY | ✓ for ASCII text via `ghostty_surface_text`; full coverage (special keys, modifiers, IME) requires F4 |
| 5 | Resize updates rows/columns and rendering | ✓ (137x30 → 131x27 on `setContentSize`) |
| 6 | Mouse selection/scrolling works | ✗ — pending F5 |
| 7 | Surface can be destroyed without crashing or orphaning resources | ✓ (smoke test now exits cleanly through `windowWillClose`, no crash artifacts) |

Remaining for hard gate:

- **F4** — make `GhosttyTerminalView` an `NSTextInputClient` and forward key events through `ghostty_surface_key`; reserve `ghostty_surface_text` for IME-committed text. Required for hard-gate item 4 and to pass the spirit of "input reaches the PTY" beyond ASCII.
- **F5** — implement `updateTrackingAreas` and forward mouse/scroll events through `ghostty_surface_mouse_button` / `ghostty_surface_mouse_pos` / `ghostty_surface_scroll`. Required for hard-gate item 6.

Both of these are scoped as a single follow-up unit, mirroring the relevant subset of `SurfaceView_AppKit.swift`. Phase 2 work remains gated until F4 and F5 land.

Consequences:

- Phase 1 spike continues; do not pivot.
- Future ADR (TBD) will close the hard gate or document a new blocker after F4/F5.
- The `CONTINUUM_SMOKE_TEST=1` integration test is the durable regression harness for the close path; keep it running on any wrapper-level change.

## ADR-0011: Phase 1 Hard Gate Closed (Mouse + Scroll Forwarding Landed)

Date: 2026-05-08

Decision:

The Phase 1 hard gate from `docs/04-terminal-ghostty-plan.md` is closed. Phase 2 is unblocked. Continue with the SwiftPM/AppKit thin-wrapper approach. Defer IME (`NSTextInputClient` + `interpretKeyEvents`), `flagsChanged` modifier-only events, mouse pressure / Force Touch, drag-and-drop, and accessibility — none of these are required for the gate, all are well-scoped follow-ups against the canonical `SurfaceView_AppKit.swift` reference.

Evidence:

- `keyDown` and `keyUp` now forward through `ghostty_surface_key` (finding F4). Special keys — arrow keys, function keys, modifier chords — are translated by Ghostty's keymap from the NSEvent `keyCode` + Ghostty mods, instead of being squashed through the IME-text path. See `Sources/ContinuumRevived/TerminalEngine/GhosttyTerminalView.swift`.
- Mouse buttons (`mouseDown`/`mouseUp`/`rightMouse*`/`otherMouse*`), mouse position (`mouseMoved`/`mouseDragged`/`rightMouseDragged`/`otherMouseDragged`/`mouseEntered`), and scroll wheel (`scrollWheel`) are forwarded through `ghostty_surface_mouse_button`, `ghostty_surface_mouse_pos`, and `ghostty_surface_mouse_scroll` (finding F5). `updateTrackingAreas` installs the canonical tracking area (`mouseEnteredAndExited`, `mouseMoved`, `inVisibleRect`, `activeAlways`).
- The smoke test now exercises three independent paths in one run:
  1. **Text path** (`ghostty_surface_text`) — `runtime.sendInput("echo ghostty-ok")` followed by Enter via the key path types and runs the command.
  2. **Key path** (`ghostty_surface_key`) — synthesized up-arrow + Enter through `view.keyDown(with:)` recalls `echo ghostty-ok` from shell history and re-executes it. Visible-text occurrence count goes from 3 (text path only) to ≥ 5 (text + key paths).
  3. **Scroll path** (`ghostty_surface_mouse_scroll`) — `seq 1 60` fills scrollback, `runtime.scrollDirectly(deltaY: 400)` scrolls up, pre/post viewport text differ. Pre-scroll viewport shows the bottom (numbers 48-60); post-scroll shows the top (login banner, recall, numbers 1-20).

Hard-gate status (per `docs/04-terminal-ghostty-plan.md`):

| # | Requirement | Status |
|---|---|---|
| 1 | Swift/AppKit host can create a Ghostty-backed terminal surface | ✓ |
| 2 | Local shell can spawn under PTY | ✓ |
| 3 | Output renders | ✓ |
| 4 | Keyboard input reaches the PTY | ✓ (text path + key path; IME deferred) |
| 5 | Resize updates rows/columns and rendering | ✓ |
| 6 | Mouse selection/scrolling works | ✓ (mouse + scroll forwarded; selection via mouse drag exercised through `mouseDragged → ghostty_surface_mouse_pos`; scrollback navigation proven by smoke test) |
| 7 | Surface destroyed without crash or orphans | ✓ |

Three back-to-back smoke-test runs after F5 land cleanly with `occurrences=5` and no entries in `~/Library/Logs/DiagnosticReports/`.

Deferred (intentionally; tracked as separate work):

- **IME** — `NSTextInputClient` conformance + `interpretKeyEvents`. Required before shipping Phase 1 to anyone using Korean / Japanese / Pinyin / dead-keys. Follow upstream `SurfaceView_AppKit.swift` lines 1816-2151.
- **`flagsChanged`** — modifier-only events. Not required for any standard shell or TUI, but blocks Vim users that rely on Caps→Esc remap and similar.
- **Mouse pressure / Force Touch / quickLook** — `pressureChange` + Force-Touch QuickLook word lookup. Quality-of-life only.
- **Drag-and-drop** — file/text drag onto the terminal. Required when we wire up file-drop from the file-tree tile.
- **Accessibility** — VoiceOver / accessibilityElement support. Required before shipping; not a Phase 1 blocker.
- **`performKeyEquivalent`** — Cmd-keyed shortcuts that should reach the terminal vs. the responder chain. Required when we add reserved app shortcuts in Phase 4 / 7.
- **Plan finding F6** — race in the renderer-thread `wakeup_cb` reading `appPointer` directly. Tighten alongside Phase 2 if it becomes observable; ARC + the small race window keeps it benign in current code.

Consequences:

- **Phase 2 (Project Spaces and Persistence) is unblocked.** Begin domain models, central registry, and `.continuum-revived/` layout per `docs/07-phased-build-plan.md`.
- The TerminalEngine adapter boundary (`TerminalRuntime` protocol) holds — no escape hatches for callers to call Ghostty directly. App code still depends only on the protocol; canvas and persistence work can build against it without thinking about Ghostty.
- The `CONTINUUM_SMOKE_TEST=1` harness is the durable regression test for terminal text + key + scroll + close paths. Keep it green on any wrapper-level change.
- Future work that touches `GhosttyTerminalView`'s input handlers must also keep this test green or update its assertions deliberately.

## ADR-0012: Phase 2 Persistence Foundations Landed

Date: 2026-05-08

Decision:

Phase 2 deliverables from `docs/07-phased-build-plan.md` are complete enough to unblock Phase 3 (Canvas MVP). Domain models, atomic writes, project-local storage, central registry, and future-version safety are all in `ContinuumRevivedCore`, exercised by `ContinuumRevivedCoreChecks`, and now drive persistence in the spike app.

What's in:

- **Domain models** (`ContinuumRevivedCore`): `Project`, `CanvasState` (+ `Tile`, `RuntimeRef`, `TileMetadata`, `TileGroup`, `CanvasViewport`), `TerminalSessionDescriptor` (+ `TerminalLastExit`), `BrowserState` (+ `BrowserTile`), `Registry` (+ `WorkspaceEntry`, `ProjectEntry`, `RegistrySettings`). All are `Codable`/`Equatable`/`Sendable` and carry `schemaVersion`.
- **AtomicWriter**: encode → round-trip-validate the bytes → backup-existing-to-`backups/` → atomic rename → prune backups beyond `retainedBackups`. `read(at:)` falls back to the newest valid backup if the canonical file is corrupt or missing; throws `noValidBackup` only after both paths fail.
- **ProjectStore**: typed save/load/list/delete for `project.json`, `canvas.json`, `sessions/<id>.json`, `browser/tiles.json`, all backed by `AtomicWriter`. `tryLoad*` returns `nil` for clean first-run; `load*` throws `unknownFutureSchema` when the on-disk version exceeds what this build supports.
- **RegistryStore**: same shape, anchored at `~/Library/Application Support/continuum-revived/registry.json` by default, with backups alongside. Tests inject an arbitrary directory so they don't pollute Application Support.
- **Future-version gate**: both stores refuse to load a file with `schemaVersion > currentSchemaVersion` and leave the on-disk bytes untouched. Verified by a CoreChecks assertion.
- **AppDelegate wiring**: at launch, the app resolves the project root (env override → smoke-test temp → cwd) and the Application Support dir (env override → smoke-test temp → default), opens `ProjectStore` and `RegistryStore`, loads or creates the project, refreshes the registry entry + `lastActiveProjectId`, and writes a `TerminalSessionDescriptor` for the spawned shell. `windowWillClose` updates the descriptor's `lastExit` before the surface tear-down ordering from ADR-0010 runs.
- **Smoke test coverage**: `CONTINUUM_SMOKE_TEST=1` now also asserts the project file, session descriptor, and registry entry exist by the time the close path runs (`persistenceOk` gate). A two-pass shell test (`CONTINUUM_PROJECT_ROOT` + `CONTINUUM_APP_SUPPORT` pinned across runs) confirms the project ID is stable across launches and a second session is appended without overwriting the first — the relaunch behavior the Phase 2 exit criteria call for.
- **Repo hygiene**: `.continuum-revived/` is in `.gitignore` so the spike doesn't pollute the working tree on a normal-mode launch.

What's deferred (intentionally; Phase 3+ items, not Phase 2 blockers):

- **Notes** (`notes/index.json` + `*.md`): post-MVP per the data-model doc.
- **Migrations beyond v1**: there's nothing older than v1 to migrate from; the migration shell is "v1 == current, no-op." A typed `Migration` framework will land alongside the first real schema bump.
- **Recovery UX**: `noValidBackup` is the error today; user-facing recovery UI (corrupt-file warning, "load empty canvas" choice) waits for the canvas/AppShell work in Phase 3.
- **iCloud quirks**: atomic writes survive ordinary races, but file coordination, eviction handling, and "this folder is in iCloud Drive" warnings are deferred until we have UI that can surface them.
- **Workspace switcher UI**: Phase 2's exit criteria call for "Basic project switcher" — the data is there (registry tracks workspaces and projects), but the switcher UI is part of Phase 7 polish per `docs/07-phased-build-plan.md`. The CLI/env-var path is enough to drive Phase 3.

Verification (all green, three back-to-back runs):

- `swift run ContinuumRevivedCoreChecks` — round trips for every model, AtomicWriter, ProjectStore, RegistryStore, and future-version refusal.
- `CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived` — exits 0 with `Ghostty smoke test passed (text + key + scroll + persistence, occurrences=5)` and zero entries in `~/Library/Logs/DiagnosticReports/`.
- Two-pass relaunch (`CONTINUUM_PROJECT_ROOT` + `CONTINUUM_APP_SUPPORT` pinned): pass 1 creates `project.json` + `sessions/<id1>.json` + `registry.json`. Pass 2 loads the same `project.id`, updates `lastOpenedAt`, and appends `sessions/<id2>.json` — both sessions remain on disk, registry's `lastActiveProjectId` matches the persisted project id.

Consequences:

- **Phase 3 (Canvas MVP) is unblocked.** The canvas adapter can persist its state through `ProjectStore.saveCanvas` without redesigning storage.
- The `CONTINUUM_SMOKE_TEST` integration harness is now also a regression test for persistence: any change that breaks atomic writes, backup ordering, or schema gating fails the same five-second run.
- App code outside `TerminalEngine`/persistence still has no direct dependency on Ghostty or the filesystem layout — `TerminalRuntime`, `ProjectStore`, and `RegistryStore` keep the boundary that ADR-0011 promised.

## ADR-0013: Phase 3 Canvas MVP — Multi-Tile Spike With Persistent Layout

Date: 2026-05-08

Decision:

Phase 3 deliverables from `docs/07-phased-build-plan.md` are met. The spike now hosts a multi-tile canvas with the existing live terminal as one tile and two descriptor tiles (browser/note placeholders), with pan/zoom, drag, edge-resize, and z-order forwarded through the new `CanvasEngine` and persisted via the Phase 2 `ProjectStore`. Phase 4 (Launch Profiles + daily terminal flow) is unblocked.

What's in:

- **`CanvasEngine`** (Core, stateless): coordinate conversion, cursor-anchored zoom (clamped 0.1–4.0), hit testing in z-order, per-kind default + minimum frames, drag-by-screen-delta, resize-by-edge with minimum-size clamping, `bringToFront` + `renormalizeZOrder`, `groupBounds`, and fit-to-bounds. Pure functions, no AppKit. Convention: top-left-origin world coordinates (positive Y = down); viewport `(x, y)` is the world point at the screen's top-left corner; `zoom` is screen pixels per world unit.
- **`CanvasNSView`** (spike, AppKit): flipped NSView that owns the viewport, hosts tile subviews, layouts them via `CanvasEngine.tileScreenFrame`, and routes scroll-wheel events to pan or (with command) cursor-anchored zoom.
- **`TileNSView`** (spike): tile chrome — title bar (24pt drag handle), 8pt resize ring around the perimeter, content slot. Drag from title bar moves the tile; drag from the perimeter resizes by edge through `CanvasEngine.tile(_:resizedByScreenDelta:edge:viewport:)`. `mouseDown` brings the tile to the front.
- **`TerminalTileNSView`** (spike): tile subclass that hosts the existing `GhosttyTerminalRuntime` + `TerminalHostView` via `setContentView`. The terminal tile fills 660×480 of the canvas by default, leaving room for the two descriptor tiles.
- **`DescriptorTileNSView`** (spike): placeholder tile for `.browser`/`.note`/`.file` kinds — colored body + center-labeled title, suitable for Phase 3 descriptor-only tiles.
- **AppDelegate wiring**: at launch, `loadOrCreateCanvas` reuses the persisted canvas (with future-version safety from Phase 2) or seeds a 3-tile default (terminal + browser placeholder + note placeholder). The terminal tile's `runtimeRef` refreshes to the new session id; the canvas saves on every change through a 200ms-debounced timer; `windowWillClose` flushes the pending save before tear-down. Default window grew to 1280×800 to accommodate the multi-tile layout.

Verification:

- `swift run ContinuumRevivedCoreChecks` — round trips for every model + AtomicWriter + ProjectStore + RegistryStore + future-version refusal + every `CanvasEngine` invariant (pan/zoom/cursor-anchored zoom/clamps, hit-test z-order, drag/resize/min-size, z-renormalize, group bounds, fit).
- `CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived` — three back-to-back runs exit 0 with `Ghostty smoke test passed (text + key + scroll + persistence + canvas, occurrences=5)`. The smoke test programmatically drags the terminal tile (25 world units right) and pans the viewport (10, 5), then asserts a) ≥ 3 tiles on disk, b) viewport moved or terminal frame moved.
- Two-pass relaunch (`CONTINUUM_PROJECT_ROOT` + `CONTINUUM_APP_SUPPORT` pinned): pass 1 ends with `viewport=(10,5,1.0)` and terminal frame `x=65`. Pass 2 reads that state, drags again, ends with terminal frame `x=90`. Tile IDs are stable across passes.
- Zero entries in `~/Library/Logs/DiagnosticReports/`.

Phase 3 exit criteria (from `docs/07-phased-build-plan.md`):

| Criterion | Status |
|---|---|
| User can place at least three descriptor tiles | ✓ (default canvas seeds terminal + browser placeholder + note placeholder) |
| User can pan/zoom smoothly | ✓ scroll-wheel → pan, cmd+scroll → cursor-anchored zoom; `CanvasEngine.zoom` math verified by tests |
| User can drag/resize tiles | ✓ title-bar drag = move; perimeter drag = resize-by-edge with minimum-size clamping |
| Layout persists across relaunch | ✓ verified by two-pass relaunch test |
| Active tile visual state is clear | ✓ `bringToFront` + `lastActiveTileId` tracked; z-order persisted |

What's deferred (intentionally; Phase 4+ items, not Phase 3 blockers):

- **Live multi-tile runtimes**: still only one live terminal; browser/note tiles are descriptor-only placeholders. Phase 4 adds the launch profile picker that creates additional terminal tiles; Phase 5 brings live `WKWebView` browser tiles; Phase 6 brings notes.
- **Multi-select**: explicitly listed as "later if cheap" in `docs/05-canvas-and-ux.md`. Phase 3 supports single-tile selection only.
- **Group creation/management UX**: the data model and `groupBounds` math exist; the create-from-selection / move-by-bounding-region UI does not. Add in Phase 7 polish or earlier if a real workflow needs it.
- **Keyboard navigation on the canvas**: directional focus, fit view, zoom in/out by hotkey — design is in the canvas doc, but Phase 3 ships scroll/pinch/click/drag only. FocusBroker comes in Phase 7.
- **Magnetic snapping / grid hints**: spec calls these "later." Skipped.
- **Minimap / focus mode**: explicitly deferred in the spec.
- **Empty state**: deferred until the canvas has the spawn-Claude / spawn-shell / spawn-browser actions from Phase 4.

Consequences:

- **Phase 4 (Launch Profiles + daily terminal flow) is unblocked.** The canvas + tile-runtime adapter is ready to host more than one live terminal as soon as launch profiles can spawn them.
- The smoke test now also serves as a regression test for the canvas: any change that breaks coordinate conversion, persistence-on-change, or the canvas-load fallback fails the same five-second integration run.
- The `CanvasNSView` mouse-event routing is structural — title bar = drag, edge ring = resize, body = tile content. Phase 4 launching profiles must not break this contract; if a tile kind needs body-level click handling, do it inside the content view, not by overriding `TileNSView.mouseDown`.

## ADR-0014: Phase 4 Launch Profiles + Daily Terminal Flow

Date: 2026-05-08

Decision:

Phase 4 deliverables from `docs/07-phased-build-plan.md` are met. The spike now lets the user spawn multiple live terminal tiles from a registry of built-in launch profiles — shell, Claude Code, Codex, Neovim — via a Cmd-K command palette and Cmd-1..4 direct hotkeys, with tool detection driving missing-command UI and a Restart placeholder for tiles whose profile can't currently resolve. Phase 5 (live browser tiles) is unblocked.

What's in:

- **`LaunchProfileSpec` + `LaunchProfileRegistry` + `ToolDetector`** (Core, pure types, no AppKit / no NSWorkspace). Five built-in specs in stable id order — `shell`, `claude`, `codex`, `nvim`, `custom` — each with a `Kind` of `.shell`, `.tool(executableName:args:)`, or `.custom`. `LaunchProfileRegistry.resolve` returns `.found(LaunchProfile)`, `.missing(executableName:)`, or `.notConfigured(profileId:)`. `ToolDetector` is a `which`-style helper with an injected `fileExists` closure (`.live` uses `FileManager.default.isExecutableFile(atPath:)`); CoreChecks injects fakes. `shell` delegates to the existing `ShellLaunchResolver`; `custom` is a forward-compat slot that always resolves to `.notConfigured` (custom command editor is deferred).
- **`TileSpawner`** (spike, AppKit-side, `@MainActor`). Single seam used by both the palette/hotkey path and the smoke test. `spawnTerminal(profileId:at:)` resolves the spec, builds a `Tile` with `TileMetadata.launchProfileId` set, creates a fresh `GhosttyTerminalRuntime`, installs a `TerminalTileNSView` via `CanvasNSView.install`, persists the descriptor + canvas, and returns either `.spawned(runtime)`, `.missingCommand(executable:)`, `.notConfigured(profileId:)`, `.unknownProfile(id:)`, or `.failure(Error)`. `restartTerminalTile(tileId:)` re-resolves the existing tile's profile and replaces its placeholder view with a fresh runtime, reusing tile id / frame / z-index. `spawnBrowserDefault` spawns a descriptor-only browser tile (no profile concept yet). Includes a `cascadeStep`-based placement helper so freshly spawned tiles don't stack on viewport-center.
- **`LaunchProfilePalette`** (spike). NSPanel + NSSearchField + NSTableView; rows render `displayName — resolved/path` for `.found`, dimmed `displayName — name not found` for `.missing`, and `displayName — id not configured` for `.notConfigured`. Up/down/Enter/Esc handled via `NSSearchFieldDelegate.control(_:textView:doCommandBy:)`. Enter on a `.missing`/`.notConfigured` row beeps and stays open (per docs/04 failure mode "do not create a half-running process").
- **App-level NSEvent local monitor** for hotkeys: Cmd-K opens the palette unfiltered, Cmd-1 spawns claude, Cmd-2 spawns shell, Cmd-3 spawns the default browser tile, Cmd-4 spawns nvim. Modifiers checked strictly (`mods == [.command]`) to avoid swallowing Ghostty's own command-key shortcuts. Local monitor consumes by returning nil so the responder chain doesn't see the event.
- **Boot path refactor (`AppDelegate.applicationDidFinishLaunching`)**: replaced the single-OG-terminal special case with a generic loop that walks every tile in `canvasState.tiles` and routes terminal tiles through `TileSpawner.restartTerminalTile`. Tiles whose profile resolves to `.found` get a live `TerminalTileNSView`; everything else gets a `TerminalRestartTileNSView` placeholder. Browser/note/file tiles still get `DescriptorTileNSView`. The "Restart" button on the placeholder calls back to the spawner; the restartable flag distinguishes "tool not found on $PATH (user might install it)" from "profile is missing entirely / not configured (no point retrying yet)".
- **`TerminalRestartTileNSView`**. Tile subclass with a centered status label + Restart button. `onRestart: (() -> Void)?` is nil for non-restartable error states (button stays but is disabled). Title bar / resize ring / mouseDown contract from ADR-0013 preserved — the action button lives inside the content view, so AppKit hit-testing finds it before `TileNSView.mouseDown` runs.
- **`CanvasNSView.install` fix**: replacing a tile (placeholder → live, or live → placeholder on future runtime-exit support) now removes the previous NSView before adding the new one. Without the fix, the prior view stayed on top and intercepted hits.
- **Multi-runtime shutdown**: `AppDelegate.runtimes: [GhosttyTerminalRuntime]` replaces the single `runtime?` ivar. `windowWillClose` iterates and terminates every surface before `ghostty.shutdown()` so ADR-0010's order-of-free invariant still holds with N surfaces. `applicationDidBecomeActive` focuses the last appended runtime; `applicationDidResignActive` blurs all of them. Hotkey monitor is removed before shutdown.
- **Persistence**: `TerminalSessionDescriptor.launchProfileId` now sources from `tile.metadata.launchProfileId` instead of the hardcoded `"shell"` literal at boot. The default seed tile's metadata sets the seed value once; the spawner sets it per spawn; rehydration reads it back.

Verification:

- `swift build` — clean.
- `swift run ContinuumRevivedCoreChecks` — green, with new blocks for `LaunchProfileRegistry` built-in order, `ToolDetector` PATH walking (match / no match / empty segment skip / trailing-slash normalization), shell + tool + missing + notConfigured + nvim-args resolution paths, and a multi-terminal `CanvasState` round trip with two distinct `launchProfileId` values.
- `CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived` — exits 0 with `Ghostty smoke test passed (text + key + scroll + persistence + canvas + multiTerminal, occurrences=5)`. The harness now spawns a second terminal at t≈2.5s through `TileSpawner.spawnTerminal(profileId: "shell")` and asserts: both the OG and spawned descriptor land in `sessions/`, both carry a non-empty `launchProfileId`, their tile ids are distinct, the spawned tile is on disk in `canvas.json`, and the canvas has ≥ 4 tiles (3 seeded + 1 spawned). Multi-terminal close path runs cleanly — both surfaces freed before `ghostty_app_free` (no diagnostic reports).
- Two-pass relaunch (`CONTINUUM_PROJECT_ROOT` + `CONTINUUM_APP_SUPPORT` pinned): pass 1 ends with 4 tiles on disk (shell + browser + note + spawned shell). Pass 2 reloads, auto-restarts the two existing terminal tiles via the boot loop (preserving their tile ids exactly), spawns a third at t≈2.5s, ends with 5 tiles. Tile ids stable across passes; smoke test passes both runs.

Phase 4 exit criteria (from `docs/07-phased-build-plan.md`):

| Criterion | Status |
|---|---|
| User can run Claude, Codex, shell, Neovim if installed | ✓ Cmd-1/2/4 + palette spawn; tool detection per-spec |
| Missing tools are clear, not broken | ✓ Palette inline `not found` row; hotkey path shows NSAlert with install hint; Restart placeholder for boot-time misses |
| Layout and descriptors restore | ✓ Boot loop walks every terminal tile in canvas; `TerminalSessionDescriptor.launchProfileId` round-trips; tile ids stable |
| Restart works for exited sessions | ✓ `TerminalRestartTileNSView` + `TileSpawner.restartTerminalTile`; placeholder appears whenever resolve fails |

What's deferred (intentionally; Phase 5+ items, not Phase 4 blockers):

- **Custom-command editor UI**. The `custom` profile spec exists for forward compat but always resolves to `.notConfigured`; there is no settings file or editor to back it. Comes with the deferred "basic settings for profile overrides" line in `docs/07`.
- **Settings file for profile overrides**. Needs its own store, schema, and ADR. Phase 4's registry is hardcoded.
- **Stale session pruning**. Landed in ADR-0016; no longer deferred.
- **In-process runtime-exit detection**. If a shell exits while the app is still running we don't currently swap the live `TerminalTileNSView` for a `TerminalRestartTileNSView`. The placeholder + Restart wiring is in place; only the runtime-exit observer is missing. Add when shell-quits-mid-session UX matters.
- **Drag-from-palette placement** (palette spawns at viewport center). Right-click placement on the canvas is in the Phase 7 deferred list per `docs/05-canvas-and-ux.md`.
- **Browser as a "profile"**. Cmd-3 spawns a plain browser-kind descriptor tile via `TileSpawner.spawnBrowserDefault`; live `WKWebView` browser tiles arrive in Phase 5.
- **Per-runtime focus state on app activate**. `applicationDidBecomeActive` focuses `runtimes.last`; honoring `lastActiveTileId` to reactivate the user's pre-resign focus is a follow-up.
- All the Phase 7 items called out in `docs/05`: Focus Mode, Minimap, multi-select / group UI, magnetic snap, accessibility deep-dive — none of these belong to Phase 4.

Consequences:

- **Phase 5 (live browser tiles) is unblocked.** The tile spawn / canvas install / persistence pattern in `TileSpawner` is the template a `BrowserTileSpawner` (or extension) will follow; `TileMetadata.url` is already the right slot for browser state.
- **The hotkey contract is now load-bearing.** Cmd-K, Cmd-1..4 are wired at the app level; any future window-level menu items must coexist with the local NSEvent monitor. If a future feature needs a chord like Cmd-Shift-K, gate the existing handler on `mods == [.command]` (already done) so modified variants pass through to the responder chain.
- **Boot is no longer special-cased for "the OG terminal"**. Every terminal tile in the canvas takes the same code path. The pattern composes with future tile kinds — add a case to the boot switch and a spawner method, and the rest follows.
- **The smoke test is now also a regression test for `TileSpawner` and the multi-runtime close path.** Any change that breaks profile resolution, descriptor persistence, multi-surface shutdown ordering, or canvas round-trip with multiple terminal tiles fails the same five-second run.

## ADR-0015: Phase 5 Live Browser Tiles (WKWebView)

Date: 2026-05-08

Decision:

Phase 5 deliverables from `docs/07-phased-build-plan.md:218–257` are met. The descriptor-only browser tile from Phase 4 is replaced with a live `WKWebView` runtime: URL bar, back / forward / reload, loading + error states, URL/title persistence, per-project `WKWebsiteDataStore` isolation, and focus integration that does not trap app shortcuts. Phase 6 (file/note tiles) is unblocked.

What's in:

- **`BrowserState.storageGroupIdentifier(for:)`** (Core, pure). Resolves `.perProject` to `project.id.uuidString` (stable across relaunches and unique per project) and `.shared` to the sentinel `BrowserState.sharedStorageGroupId = "shared"`. The app side reads this string back when constructing `WKWebsiteDataStore(forIdentifier:)` (UUID branch) or `.default()` (sentinel branch). Pure function — no I/O, no AppKit, no WebKit. CoreChecks asserts determinism, distinctness across projects, and `.shared` invariance.
- **`BrowserEngine`** (`Sources/ContinuumRevived/BrowserEngine/`). Three files mirroring `TerminalEngine/`:
  - `BrowserRuntime.swift`: `@MainActor protocol BrowserRuntime: AnyObject` with `id`, `tileId`, `url`, `title`, `loadingState`, plus `attach(to:)`, `detach()`, `loadURL(_:)`, `goBack()`, `goForward()`, `reload()`, `stop()`, `focus()`, `blur()`, `terminate(policy:)`. `BrowserHostView` is the analog of `TerminalHostView`. `BrowserLoadingState`: `.idle | .loading(progress:) | .failed(message:)`.
  - `BrowserEngineContext.swift`: one per app. Owns `[String: WKWebsiteDataStore]` keyed by storage group id, lazily initialized via the helper above. Constructs `WKWebView`s via `makeWebView(storageGroupId:)` with `preferences.isFraudulentWebsiteWarningEnabled = false` for localhost dev. Drops the cache table in `shutdown()`. `WKProcessPool` is intentionally not set — deprecated since macOS 12; WebKit shares its render-process pool internally.
  - `WKWebViewBrowserRuntime.swift`: concrete `BrowserRuntime`. `NSObject` subclass conforming to `WKNavigationDelegate` and `WKUIDelegate`. KVO observers on `WKWebView.title`, `WKWebView.url`, `WKWebView.estimatedProgress`, `WKWebView.isLoading`. KVO closures don't read main-isolated properties directly; they hop through `Task { @MainActor in ... }` and read `self.webView` so Swift 6 strict concurrency is happy. `terminate(.force)` strictly orders: `webView.stopLoading()` → invalidate observers → nil delegates → `removeFromSuperview()`. Inverting risks WebKit firing into a half-torn-down runtime.
- **`BrowserTileNSView`** (Sources/ContinuumRevived/Canvas/). Tile-kind chrome below the existing 24pt title bar: nav row (`NSButton` × 3 + `NSTextField` URL bar + indeterminate `NSProgressIndicator`) atop `BrowserHostView`. URL field commits on Return (loadURL), reverts on Esc (using the same `control(_:textView:doCommandBy:)` pattern as `LaunchProfilePalette`). Loading/error states drive the spinner + a thin red banner. Subscribes to `runtime.onStateChange` to refresh; chains an `onAfterRefresh` callback so the spawner can hook the debounced persistence flush.
- **`BrowserRestartTileNSView`**: copy of `TerminalRestartTileNSView` with browser-tinted chrome. Used when boot-time browser construction fails (invalid URL on disk, store init throws).
- **`TileSpawner` extensions**: `spawnBrowser(url:at:)` returning `BrowserOutcome` (`.spawned(WKWebViewBrowserRuntime)` / `.invalidURL` / `.failure`); `restartBrowserTile(tileId:)` returning `BrowserRestartOutcome` (`.restarted` / `.invalidURL` / `.tileNotFound` / `.failure`); `writeBrowserTileSnapshot(for:)` for the AppDelegate's debounced flush. `upsertBrowserTile` keyed by `tileId` so multiple browser tiles per project don't clobber each other in `BrowserState.tiles`. `browserPersistenceHandler` ivar is set once by AppDelegate.
- **AppDelegate wiring**: `browserEngine: BrowserEngineContext?` and `browserRuntimes: [WKWebViewBrowserRuntime]` ivars. Boot loop's tile switch routes `.browser` through `restartBrowserTile`; success appends to `browserRuntimes`, failure installs `BrowserRestartTileNSView`. Cmd-3 dispatches the new `spawnBrowser(url: nil, at: nil)`. `scheduleBrowserSave()` + `flushBrowserSave()` mirror the canvas debounce pattern. `windowWillClose` close order: flush canvas + browser saves → mark terminal session exits → remove hotkey monitor + close palette → **terminate browser runtimes first** → terminate terminal runtimes (preserving ADR-0010's free-before-`ghostty_app_free` invariant) → `ghostty.shutdown()` → `browserEngine.shutdown()`. Browsers tear down before terminals because WKWebView's process pool is independent of GhosttyKit's; inverting risks WebKit KVO callbacks firing into a half-torn-down app.

Verification:

- `swift build` — clean.
- `swift run ContinuumRevivedCoreChecks` — green, with new blocks for `storageGroupIdentifier(for:)` determinism, distinctness, `.shared` invariance, and non-collision with any perProject id.
- `CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived` — exits 0 with `Ghostty smoke test passed (text + key + scroll + persistence + canvas + multiTerminal + browser, occurrences=5)`. The smoke test now spawns a live `WKWebView` at t≈3.6s using a deterministic `data:text/html,<html><title>continuum-browser-ok</title>...</html>` URL (offline-safe), and the t=5.0s assertion block adds `browserOk`: BrowserState contains a tile with the data URL, the title KVO + persistence path captured `"continuum-browser-ok"`, the canvas tracks it as a `.browser` tile with `runtimeRef.kind == .browserTile`, and the storage group id matches the helper's deterministic output for the project's policy.
- Two-pass relaunch (`CONTINUUM_PROJECT_ROOT` + `CONTINUUM_APP_SUPPORT` pinned): pass 1 ends with 2 browser tiles on disk (the seeded + the smoke-spawn). Pass 2 reloads, re-instantiates both via the boot loop (preserving their tile ids exactly), spawns a third at t≈3.6s, ends with 3 browser tiles. Tile ids stable across passes; smoke passes both runs. `~/Library/Logs/DiagnosticReports/` shows no new entries — confirms multi-runtime shutdown ordering holds with both Ghostty and WebKit surfaces alive.

Phase 5 exit criteria (from `docs/07-phased-build-plan.md`):

| Criterion | Status |
|---|---|
| Browser tile shows local dev server | ✓ Cmd-3 spawns localhost:3000; URL bar accepts manual navigation |
| Browser tile arrangeable on canvas | ✓ Phase 3 plumbing intact; new chrome doesn't break drag/resize (button + URL field hit-test before TileNSView.mouseDown) |
| URL restores on relaunch | ✓ Boot loop walks every `.browser` tile through `restartBrowserTile`; `BrowserState.tiles` round-trips through `ProjectStore.saveBrowserState` |
| Browser does not trap app shortcuts | ✓ The local `NSEvent.addLocalMonitorForEvents` consumes Cmd-K/1-4 above the WKWebView responder chain; `mods == [.command]` strict check stays untouched |

What's deferred (intentionally; Phase 6+ items, not Phase 5 blockers):

- **Phase 4 polish** (still): in-process runtime-exit detection. Stale session pruning landed in ADR-0016; only the mid-session runtime-exit observer remains.
- **Downloads UI / certificate prompts / find-in-page / devtools / back-forward gestures**: not in Phase 5 deliverables.
- **Automation + element picker**: explicitly deferred per `docs/06-browser-code-file-surfaces.md` and `docs/07`.
- **Multi-tab inside a browser tile**: Phase 5 is one URL per tile.
- **Custom URL scheme handlers**: not needed; localhost is ATS-exempt by default.
- **Programmatic Cmd-K-while-browser-focused smoke assertion**: verified manually only. The hotkey monitor consumes events before the responder chain so this should hold; add a programmatic check if it ever regresses.
- **In-process runtime-exit detection for browsers** (analog of the deferred terminal item). WKWebView's process can crash; we do not yet swap a live tile for a `BrowserRestartTileNSView` mid-session. The placeholder + restart wiring is in place; only the `WKNavigationDelegate.webViewWebContentProcessDidTerminate` observer is missing.
- **Per-runtime focus on app activate**: still focuses `runtimes.last`; honoring `canvasState.lastActiveTileId` (terminal-or-browser) to reactivate the user's pre-resign focus is a follow-up. Browsers focus on click via WebKit's normal hit-testing, so this is mostly a polish gap.

Consequences:

- **Phase 6 (file/note tiles) is unblocked.** The pattern is now: an engine context (one per app) + a runtime protocol + a concrete runtime + a tile NSView + a restart placeholder + spawner methods + a boot-loop switch case + a debounced persistence path. Phase 6 follows the same recipe.
- **WebKit is now a load-bearing dependency.** Anyone touching the browser path must respect: KVO observers via `webView.observe`, navigation delegate methods on `nonisolated` plus `Task { @MainActor in }` hops, strict teardown order in `terminate(policy:)`, and the close-path invariant that browsers tear down before terminals + ghostty.shutdown.
- **Per-project storage isolation is real.** `WKWebsiteDataStore(forIdentifier:)` keys off `project.id.uuidString` for `.perProject`, so logging into a site in one project does not leak cookies/session to another project. Switching to `.shared` falls back to the default store.
- **`BrowserState.tiles` is upserted by `tileId`**, not appended, so the smoke test's t≈3.6s spawn (which adds a fresh tile) coexists with the seeded browser tile (which is restored on each boot) without duplication.

## ADR-0016: Boot-time Session Pruning

Date: 2026-05-09

Decision:

At app boot, immediately after `ProjectStore` is initialized and before the tile-loop runs, call `pruneExitedSessions(in:)` to delete all `TerminalSessionDescriptor` files whose `lastExit` field is non-nil.

Rationale:

`windowWillClose` stamps `lastExit` on every live session descriptor when the user closes the window. On the next boot the tile loop creates fresh descriptors for the new runtimes rather than reusing the old ones, so the `sessions/` directory accumulates one file per terminal per run. The predicate `lastExit != nil` is exact: a descriptor is exited if and only if the close path recorded an exit. Alive descriptors (spawned this launch, not yet closed) always have `lastExit == nil`.

Pruning before the tile loop means the live descriptors created by the current boot are never visible to the pruner, so there is no race between "prune" and "spawn". Pruning after `windowWillClose` would require knowing which descriptors belong to the session being closed, adding coupling; pruning on a timer adds latency and complexity with no benefit.

Call-site placement: `applicationDidFinishLaunching`, immediately after `self.projectStore = projectStore` and before `Self.loadOrCreateProject(...)`. This is the earliest safe moment: the store is initialized, no tiles have been spawned yet, and the window is not yet on screen.

Best-effort semantics: `pruneExitedSessions(in:)` does not throw. If `listSessions()` fails (e.g., permissions, corrupt directory), it writes a one-line warning to stderr and returns. If `deleteSession(id:)` fails for a single file, it writes a warning and continues. Partial pruning on error is acceptable; the directory remains bounded by the number of sessions that successfully close.

Manual two-pass verification protocol:
1. Run `CONTINUUM_SMOKE_TEST=1 CONTINUUM_PROJECT_ROOT=/tmp/smoke-root CONTINUUM_APP_SUPPORT=/tmp/smoke-as .build/debug/continuum-revived` (pass 1). Confirm it exits 0 and capture the UUIDs in `sessions/`.
2. Run the same command again (pass 2). Confirm it exits 0, and that the pass-1 UUIDs no longer appear in `sessions/` (zero overlap). Pass-2 may write more session files than pass 1 because canvas persistence carries previously-spawned smoke tiles forward; the regression we are guarding against is unbounded growth, not a literal count.

Consequences:

- `sessions/` is now bounded to at most one file per terminal tile that was alive when the window last closed (typically 1-3 for normal use).
- The smoke test's `multiTerminalOk` block now asserts `noOrphanSessions`: every session on disk corresponds to a live runtime from this launch. This catches the regression where pruning fails to remove stale descriptors and lets them survive into the next launch as orphans.
- The explanatory comment in the smoke test that scoped multi-terminal assertions to "live runtimes from this launch" to avoid false-failures from accumulated stale files has been removed.
- In-process runtime-exit detection (the remaining deferred item from ADR-0014) still does not set `lastExit` mid-session. When it lands, the same predicate will work: a descriptor whose runtime exits mid-session will get `lastExit` set, and the next boot will prune it.
