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
