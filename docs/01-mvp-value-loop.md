# MVP Value Loop

## Definition

The MVP is not a stripped-down demo. It is the smallest version that can replace a messy stack of terminal tabs, browser windows, and editor windows for one real project session.

The core loop:

1. Create or open a workspace.
2. Add a project with a root directory.
3. Open the project's canvas.
4. Spawn terminal/agent/code/browser surfaces quickly.
5. Arrange them spatially.
6. Work for a while.
7. Quit or switch away.
8. Return later with the layout and useful state restored.

If that loop is slow, fragile, or visually noisy, the app has failed no matter how many advanced features exist.

## MVP User Story

Dylan opens `continuum-revived` and selects a project. The project canvas appears exactly where he left it. On the left is Claude Code, in the center is Neovim or a shell, on the right is a browser preview, and below is a secondary Codex review terminal. He can pan/zoom around the project, drag and resize tiles, create new surfaces with shortcuts, switch to another project, then come back without losing context.

The app feels like a control room:

- It does not hide work in tabs.
- It does not steal keyboard focus randomly.
- It does not require manual session archaeology after restart.
- It does not force a colleague into Neovim.
- It does not require cloud accounts, telemetry, or a remote database.

## Primary Personas

### Terminal-First Agent Operator

Uses Claude Code, Codex, shell, tmux, Neovim, and local dev servers. Needs a single spatial overview and fast keyboard control. This is the primary MVP persona.

Needs:

- Ghostty-quality terminal rendering.
- Shortcuts that respect terminal/vim/tmux habits.
- Multiple terminals visible at once.
- Stable project restore.
- Browser preview nearby.

### External Editor Developer

Uses Cursor, VS Code, Zed, or Xcode. Wants agent terminals and browser previews, but edits code elsewhere.

Needs:

- Open project in editor.
- Launch profiles for external editor commands.
- File tree and project context eventually.
- No hard dependency on Neovim.

### Agent Reviewer

Runs Claude for implementation and Codex for review. Wants multiple sessions on one canvas, even before agent-to-agent messaging exists.

Needs:

- Named launch profiles.
- Clear tile titles/status.
- Easy duplication/restart of agent sessions.
- Durable layout.

## MVP Surfaces

### Required

- Ghostty terminal tile.
- Native browser tile.
- Project switcher.
- Workspace/project list.
- Canvas.
- Launch profile picker.
- Settings enough to configure commands/editors.

### Deferred

- Agent-to-agent messaging.
- Diff/review tile.
- Markdown note tile.
- File tree tile.
- Browser automation.
- Focus mode.
- Minimap.
- Activity lenses/floors.
- On-device companion.

### Borderline

Markdown notes and file tree are very high value, but they are not necessary to prove the first loop. They become Phase 6 unless implementation discovers that notes are cheaper than expected after persistence is in place.

## Non-Negotiable Acceptance Criteria

### Project Creation

- User can create a workspace and project from a directory.
- The project root becomes the default cwd for launch profiles.
- The project appears in a fast switcher.
- A hidden project-local state folder is created only after the user confirms/opening the project.

### Terminal

- User can spawn a shell tile.
- User can spawn Claude Code from a profile.
- User can spawn Codex from a profile.
- User can spawn Neovim if installed.
- Terminal accepts input, renders output, resizes correctly, and can close without orphaning process state.
- App-level shortcuts do not break terminal-native shortcuts.

### Browser

- User can create a browser tile.
- User can enter a URL, navigate, reload, go back, and go forward.
- Browser tile persists its last URL.
- Localhost works without special ceremony.

### Canvas

- User can pan, zoom, select, drag, resize, and bring tiles forward.
- New tiles appear at a predictable location, ideally viewport center or cursor.
- The canvas remains smooth with at least 20 tiles.
- The canvas does not require grid layout; freeform spatial placement is the default.

### Persistence

- The app can quit and relaunch with the project canvas restored.
- State writes are atomic.
- A corrupt state file does not destroy the previous working state.
- Unknown future fields do not crash the app.

### Switching

- Switching projects is faster than opening a new terminal/editor/browser window manually.
- Switching away does not destroy sessions unless the user explicitly closes them or chooses a cleanup policy.

### Focus

- Active surface is visible.
- App knows whether focus belongs to app chrome, canvas, terminal, browser, or modal.
- Escape/Command shortcuts recover focus predictably.
- Browser and terminal surfaces cannot trap the entire app.

## MVP "Done" Scenario

The MVP is done when the following sequence works twice in a row:

1. Create workspace `Personal`.
2. Add project `continuum-revived`.
3. Spawn a shell tile.
4. Spawn a Claude tile.
5. Spawn a Codex review tile.
6. Spawn a Neovim tile if installed, otherwise open configured external editor.
7. Spawn a browser tile pointed at `http://localhost:3000`.
8. Arrange all tiles spatially.
9. Switch to another project or close the app.
10. Return to `continuum-revived`.
11. Layout, titles, browser URL, project root, and launch profile metadata are restored.
12. Closed/exited sessions are represented clearly and can be restarted.

## Metrics For "Feels Right"

These are qualitative but testable:

- Time from app launch to first useful terminal: under 5 seconds after first setup.
- Time to create a new Claude tile in an existing project: under 2 seconds plus CLI startup.
- No more than one modal/sheet in the main create-project flow.
- No layout jump when a terminal starts producing output.
- No lost keyboard after switching between terminal and browser 20 times.
- No state loss after five quit/relaunch cycles.

