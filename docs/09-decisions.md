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

