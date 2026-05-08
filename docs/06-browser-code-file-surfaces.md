# Browser, Code, And File Surfaces

## Scope

MVP includes:

- Native WKWebView browser tiles.
- Neovim launch profile when installed.
- External editor handoff.
- Configurable launch profiles.

MVP defers:

- Browser automation.
- Element picker to agent.
- Diff/review tile.
- File tree tile.
- Markdown note tile.
- Native code editor tile.

File tree and notes are Phase 6 because they are high-value but not required to prove the daily terminal/browser/project loop.

## Browser Tile MVP

Browser tiles are embedded native web surfaces on the project canvas.

Required controls:

- URL field.
- Back.
- Forward.
- Reload/stop.
- Title display.
- Loading indicator.
- Basic error display.

Required behavior:

- Create browser tile from hotkey/command palette/context menu.
- Navigate to URL.
- Persist last URL and title.
- Restore browser tile descriptor on relaunch.
- Work with `localhost`, `127.0.0.1`, and common dev-server ports.
- Keep browser focus from trapping app commands.

Initial metadata:

```text
id
tileId
url
title
storageGroupId
createdAt
updatedAt
```

Storage:

- Default to per-project browser storage.
- Model supports storage groups even if MVP uses one group per project.
- Browser cookies/storage are not exported to JSON.

Error handling:

- Navigation failure shows inline error.
- TLS/self-signed behavior should be considered for local dev, but full trust management can wait.
- WebView crash/process termination should keep descriptor and offer reload if detectable.

Focus rules:

- Clicking browser content activates browser tile.
- Command palette and app-level shortcuts remain recoverable.
- URL field focus is separate from page focus.
- Escape from URL field reverts to last committed URL.

## Browser Automation Later

Maestri portals support agent control: click/type/scroll/navigate/screenshot/JS/DOM/console. Nyx shows browser inspect mode where a selected element and screenshot can be sent to an agent.

For `continuum-revived`, defer this until normal browser tiles are stable.

Future model:

- Browser tile exposes automation adapter.
- Agent can target browser by tile ID.
- Element picker captures DOM path, accessibility info, screenshot, and user comment.
- Data sent through future agent bus or manual prompt injection.

## Code Surface Strategy

The app should be code-aware without trying to become a full IDE in MVP.

Primary coding paths:

- Neovim in Ghostty terminal tile for users who have it.
- External editor handoff for Cursor, VS Code, Zed, Xcode.
- Shell/agent terminals for everything else.

Why not native editor first:

- Editor scope explodes quickly: syntax highlighting, LSP, file watching, search, diff, vim modes, multi-cursor, settings.
- Target users already have strong editor preferences.
- A bad native editor would weaken the product.

## Neovim Detection

Detection order:

1. User-configured path.
2. `PATH` lookup for `nvim`.
3. Common Homebrew locations.
4. Show not installed state.

Profile:

```text
title: Neovim
command: nvim
args: []
cwd: project root
```

Behavior:

- If found, show Neovim profile prominently.
- If missing, hide or mark unavailable.
- Do not block app use.

## External Editor Handoff

Supported MVP targets:

- Cursor.
- VS Code.
- Zed.
- Xcode.
- Custom command.

Detection examples:

```text
cursor .
code .
zed .
xed .
open -a Xcode <path>
```

Rules:

- User can choose preferred editor per project or globally.
- App should expose "Open Project In Editor".
- External editor commands do not create canvas tiles unless the user creates a terminal profile for them.

## Launch Profiles

Launch profiles are the bridge between generic terminal tiles and user workflows.

Fields:

```text
id
name
kind
command
args
cwdPolicy
env
icon
defaultTitle
availability
```

Kinds:

- shell.
- agent.
- editorTerminal.
- custom.

Built-ins:

- Shell.
- Claude Code.
- Codex Review.
- Neovim.
- Custom Command.

Availability:

- `available`
- `missingCommand`
- `needsConfiguration`

## File Tree Phase

File tree is a Phase 6 workflow multiplier.

Why users care:

- Agents and humans need project context on the canvas.
- File status makes agent changes legible.
- Open-with shortens the jump from observing to editing.

MVP-for-file-tree requirements when implemented:

- Async scanning.
- Ignore common heavy folders: `.git`, `node_modules`, `target`, `.build`, derived data, vendor caches unless user expands intentionally.
- Search/filter.
- Open with preferred editor.
- Git status badges if cheap, otherwise later.

Maestri changelog warns that large directory scanning can freeze the app. Therefore scanning must be backgrounded from the first file tree implementation.

## Notes Phase

Notes are Phase 6 unless pulled earlier.

Why users care:

- Shared memory that lives with the project.
- Agents can read/write markdown.
- Human can keep task context beside terminals.

Requirements when implemented:

- New note creates markdown file under `.continuum-revived/notes/`.
- Dropped external markdown/text files stay in place and are referenced.
- Notes persist canvas position.
- Basic markdown rendering and editing.
- No database required.

Later:

- Connected notes.
- Note chains.
- Inline images.
- Agent read/write bridge.

## Diff/Review Tile Later

Nyx highlights diff review as a tile type. This is valuable for the Claude-implements/Codex-reviews loop, but it should wait until:

- Terminal profiles work.
- Project state is stable.
- File tree or git integration exists.

Future diff tile should:

- Show changed files.
- Show hunks.
- Let user add review comments.
- Send review context to an agent.
- Avoid becoming a full git client too early.

