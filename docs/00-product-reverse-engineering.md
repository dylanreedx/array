# Product Reverse Engineering

## Purpose

This document reverse-engineers the public shape of Maestri, Nyx, and the old Continuum project to define the fastest path to a useful `continuum-revived` without copying proprietary implementation. The goal is to understand the value loop, product sequencing, risk surfaces, and scope traps.

The target user is a developer who already uses terminal-first tools, AI coding agents, tmux/vim habits, local dev servers, and external editors. The product should feel like a low-noise control room for real work, not a novelty canvas.

## Source Snapshot

Public sources reviewed:

- Maestri intro docs: https://www.themaestri.app/en/docs/intro
- Maestri workspace docs: https://www.themaestri.app/en/docs/workspaces
- Maestri canvas docs: https://www.themaestri.app/en/docs/canvas
- Maestri portals docs: https://www.themaestri.app/en/docs/portals
- Maestri product page: https://www.themaestri.app/en
- Maestri changelog: https://www.themaestri.app/en/changelog
- Nyx product page: https://getnyx.dev/
- Existing Continuum repo: `/Users/dylan/Library/Mobile Documents/com~apple~CloudDocs/personal/continuum`

Important source facts:

- Maestri positions itself as an orchestration layer around existing agents, not an agent. It uses workspaces, an infinite canvas, terminals, notes, file trees, connections, floors, portals, routines, remote SSH, and an on-device assistant.
- Maestri workspaces remember canvas layout, terminal positions, agent assignments, and settings. Workspaces have a working directory and can remain active in the background.
- Maestri canvas insertion is spatial: choose a node tool, draw a rectangle, and the node appears at that size and position. Node types include Terminal, Note, Text, Drawing, and File Tree; newer product copy also highlights portals.
- Maestri portal docs define embedded WebKit browser windows on the canvas, isolated storage, optional shared storage between connected portals, and agent automation through a CLI.
- Maestri changelog shows the hidden hard parts: focus reliability, first responder recovery, portal stability, file tree performance, terminal compatibility with different TUIs, instant node creation, and reliable paste/duplicate semantics.
- Nyx sells speed and visibility: "Run ten agents. See them all." It supports Claude Code, Codex, Gemini, and any CLI agent through real PTY/TUI tiles. It presents six tile types: agent, terminal, browser, todo, diff, editor.
- Nyx emphasizes one-hotkey spawning, focus mode, browser element picking, diff review, editor tile, live status inference, and a short install-to-running experience.
- Continuum already explored many related pieces in Tauri/React/Rust: canvas stores, PTY management, browser embedding, workspace persistence, groups, focus handling, command registry, file tree, terminal and agent wrappers.

## Competitor Value Map

### Maestri

Maestri's central promise is spatial orchestration. It says: your terminal habit is good, but the surrounding workspace is wrong for multiple agents. Its value is not a smarter agent; it is a bigger, more legible work surface around agents.

What users care about:

- They can see multiple agents at once.
- They can arrange work by mental context instead of terminal tab order.
- They can put notes, file trees, diagrams, terminals, and browsers next to each other.
- Agents can read/write shared markdown notes.
- Workspace state survives sessions.
- Workspaces are local, private, plain files where possible.
- Navigation feels fast enough to replace tmux/window switching.

What looks impressive but should not be first:

- Agent-to-agent cables.
- Rope physics.
- On-device assistant.
- Routines.
- Spotlight indexing.
- Browser automation through a custom CLI.
- SSH workspaces.

What the changelog warns us about:

- Focus ownership is not polish; it is architecture.
- Browsers and terminal nodes are not normal views; they are embedded interactive processes with their own event loops and shortcut expectations.
- File trees must scan asynchronously from the beginning.
- Canvas paste/duplicate becomes complex once nodes have internal state and links.
- Instant creation at cursor is a real product accelerator.
- TUI compatibility must be tested across Claude, Codex, Gemini, Copilot CLI, shells, and editors.

### Nyx

Nyx's central promise is density and action. It sells an "infinite canvas IDE" where every agent is live, every tile is hotkey-spawned, and focus mode collapses the canvas when you need concentrated work.

What users care about:

- They can spawn real PTY/TUI agent sessions.
- Slash commands and confirmations stay native because agents run as real terminals.
- Browser previews live beside agents.
- A diff/review surface shortens the coding loop.
- One hotkey per tile type lowers friction.
- Focus mode gives an escape hatch when the canvas gets visually busy.
- Live status lets users know which agents are working, idle, or ready.

What should inform our MVP:

- Hotkey spawning matters more than fancy toolbars.
- Status inference is valuable but should be best-effort until it is reliable.
- Browser and diff tiles are part of the AI coding loop, not general browsing/editing features.
- The fastest value loop is likely one project canvas with Claude, Codex, shell, browser, and nvim all visible.

What can wait:

- Todo inbox tiles.
- Diff tile with review comments.
- Browser inspect-to-agent.
- Auto-demo polish.
- Licensing/install polish.

### Continuum

Continuum's value was directionally right, but it accumulated cross-layer complexity:

- TypeScript and Rust models were manually mirrored. We found at least one drift smell: a TypeScript canvas comment described zoom as `0.33..=1.0`, while Rust described `0.02..=64.0`.
- Workspace, project, canvas, tile, group, UI, and persistence concerns crossed stores and IPC boundaries.
- Browser embedding required backend-driven state and careful focus management.
- Terminal focus and global shortcuts needed explicit broker logic.
- PTY lifecycle and session metadata were serious infrastructure, not peripheral code.
- The UI had many feature areas before the native terminal/canvas foundation was truly settled.

Lessons to keep:

- Bounded PTY output channels, coalesced events, and accumulated writes are useful concepts.
- Spatial index outside reactive state is the right shape for large canvases.
- Persisted canvas snapshots need schema envelopes, migrations, atomic writes, and backup files.
- UI focus must be a domain concept, not incidental DOM/AppKit state.
- Tests around focus, persistence, PTY lifecycle, canvas geometry, and browser lifecycle are worth preserving in spirit.

Lessons to reject:

- Do not split authoritative models across frontend/backend languages.
- Do not depend on webview focus behavior for app-wide shortcuts.
- Do not ship broad tile taxonomy before terminal/browser/project restore is excellent.
- Do not treat browser tiles as an easy add-on.

## Feature Classification

### Core Value

These make the app worth opening every day:

- Native project/workspace shell.
- One project equals one canvas.
- Ghostty-backed terminal tiles.
- Launch profiles for shell, Claude, Codex, Neovim, and custom commands.
- Native browser tiles for local preview.
- Durable project-local state.
- Fast project switching.
- Reliable restore.
- Canvas pan/zoom/drag/resize/select.
- Keyboard-first controls.
- Explicit focus ownership.

### Workflow Multipliers

These compound the core loop after it exists:

- File tree tile.
- Markdown note tile.
- External editor handoff.
- Groups inside project canvases.
- Command palette.
- Focus mode.
- Minimap.
- Best-effort agent status.
- Profile editor.
- Session restart/reconnect.

### Differentiators

These can make the app special, but should not define the first foundation:

- Agent-to-agent PTY ask bus.
- Browser element picker to agent.
- Diff/review tile.
- Routines and scheduled prompts.
- On-device companion summaries.
- Portal automation CLI.
- Activity lenses/floors.
- Spotlight indexing.
- SSH/remote workspaces.

### Scope Traps

These are dangerous early:

- Native code editor attempting to compete with Neovim, Cursor, VS Code, or Zed.
- Building agent collaboration before local terminal/session reliability.
- Browser automation before normal browser tile stability.
- Over-designing diagrams/sketching before canvas fundamentals.
- Adding a database before the file model is clear.
- Polishing marketing install flows before the app is used daily.

## Our Product Position

`continuum-revived` should be:

- A native macOS spatial control surface for AI-assisted development.
- Terminal-first, but not terminal-only.
- Project-local and inspectable.
- Built around Ghostty-quality terminal rendering.
- Friendly to Neovim users without forcing Neovim on everyone.
- A better place to run Claude, Codex, shells, browser previews, and project context.

It should not be:

- A clone of Maestri or Nyx.
- An AI agent.
- A new IDE that tries to replace Cursor/VS Code/Zed on day one.
- A web app inside a native wrapper.
- A broad orchestration platform before it is a stable daily workspace.

## Fastest Path To Value

The first true value moment is:

1. Open `continuum-revived`.
2. Create or open a project.
3. Hit a shortcut to spawn Claude Code in a Ghostty tile.
4. Hit another shortcut to spawn Neovim or a shell.
5. Add a browser tile pointed at localhost.
6. Arrange them spatially.
7. Quit the app.
8. Reopen and see the same project canvas restored.

Everything that shortens or hardens that loop is MVP. Everything else waits.

