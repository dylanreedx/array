# Terminal Ghostty Plan

## Decision

The MVP terminal engine must be Ghostty/libghostty-backed. If Ghostty integration cannot satisfy basic terminal requirements, broad app implementation pauses until the terminal architecture is solved.

This is not an aesthetic preference. The terminal is the product's core surface. Poor terminal rendering, broken TUI input, bad resize behavior, or unreliable focus would make the app unusable for the target workflow.

## Why Ghostty

Expected benefits:

- High-quality terminal emulation.
- Native macOS rendering path.
- GPU-accelerated terminal rendering.
- Better fidelity for Claude Code, Codex, Neovim, shells, and other TUIs.
- A future path toward Ghostty config/theme compatibility.

Known risk:

- The embedding API exists but may be lower-level and still evolving.
- Documentation may not cover every Swift embedding scenario.
- Integration may require reading Ghostty source and a local spike.

## Hard Gate

Phase 1 is blocked until a spike proves:

- A Swift/AppKit host can create a Ghostty-backed terminal surface.
- A local shell can spawn under PTY.
- Output renders.
- Keyboard input reaches the PTY.
- Resize updates terminal rows/columns and rendering.
- Mouse selection/scrolling works at least basically.
- Surface can be destroyed without crashing or orphaning uncontrolled resources.

If any item fails, do not pivot to SwiftTerm silently. Pause and choose a deliberate path:

- Fix integration.
- Contribute/patch wrapper code.
- Narrow MVP until Ghostty works.
- Only reconsider terminal strategy with a new explicit decision.

## TerminalEngine Responsibilities

TerminalEngine owns:

- Ghostty/libghostty lifecycle.
- PTY creation.
- Process spawning.
- Input routing.
- Output rendering.
- Resize.
- Process exit detection.
- Restart descriptors.
- Terminal surface focus.
- Status observation.
- Cleanup.

It does not own:

- Canvas geometry.
- Project registry.
- Browser state.
- Command palette.
- Workspace switching policy.

## Adapter Boundary

Create a narrow boundary:

```swift
protocol TerminalRuntime {
    var id: TerminalSessionID { get }
    var tileId: TileID { get }
    var title: String { get }
    var status: TerminalStatus { get }

    func attach(to hostView: TerminalHostView)
    func detach()
    func focus()
    func blur()
    func resize(cols: Int, rows: Int, pixelSize: CGSize)
    func sendInput(_ bytes: Data)
    func terminate(policy: TerminationPolicy)
}
```

`GhosttyTerminalRuntime` implements this protocol. App code depends on `TerminalRuntime`, not Ghostty calls.

## PTY Lifecycle

### Spawn

Inputs:

- `sessionId`
- `tileId`
- `launchProfileId`
- `command`
- `args`
- `cwd`
- `envOverrides`
- initial size in rows/cols

Steps:

1. Resolve launch profile.
2. Validate command exists or show profile error.
3. Create PTY pair.
4. Spawn process with cwd/env.
5. Connect PTY to Ghostty surface.
6. Store runtime in TerminalEngine map.
7. Persist session descriptor.
8. Mark status as `running`.

### Resize

Resize should occur when:

- Tile frame changes.
- Window backing scale changes.
- Font size changes.
- Terminal view becomes attached.

Rules:

- Compute rows/cols from Ghostty font metrics or terminal surface metrics.
- Debounce rapid drag-resize to avoid excessive PTY updates.
- Apply final resize immediately on drag end.

### Input

Input sources:

- Keyboard events.
- Paste.
- Mouse events.
- Scroll wheel.
- Future programmatic prompt injection.

Rules:

- Reserved app shortcuts are intercepted by FocusBroker before terminal input.
- Terminal-native shortcuts pass through.
- Text input must support IME/dead keys if Ghostty/AppKit path allows it.
- Paste may need bracketed paste support.

### Output

If Ghostty owns PTY reading internally, use its native path. If the app owns PTY IO:

- Use bounded channels.
- Coalesce output bursts.
- Avoid main-thread parsing.
- Dispatch only render invalidations to main thread.

Continuum's Rust PTY manager used bounded read channels, small output coalescing windows, and write accumulation. Preserve those concepts if the Ghostty path requires host-managed IO.

### Exit

When process exits:

- Capture exit code/signal.
- Mark runtime `exited`.
- Keep tile descriptor.
- Show restart affordance.
- Do not delete session metadata unless the user closes the tile.

## Status Model

Initial statuses:

- `configuring`: command/profile resolving or process starting.
- `running`: process alive.
- `exited`: process ended.
- `error`: spawn/runtime failure.

Optional later statuses:

- `working`
- `idle`
- `ready`
- `needsInput`

Do not overfit agent output parsing in MVP. Best-effort status is okay only if wrong states do not mislead the user.

## Focus Rules

Terminal focus is explicit:

- Clicking terminal content asks FocusBroker to activate the tile.
- FocusBroker updates visual active tile state.
- TerminalRuntime receives `focus()`.
- Previous terminal/browser receives `blur()`.
- App chrome shortcuts remain available.
- Escape can return focus to canvas if the terminal is not in a mode where Escape is clearly terminal input; if ambiguous, use a stronger shortcut for focus recovery.

Focus tests must cover:

- Terminal to canvas.
- Terminal to browser.
- Terminal to command palette.
- Terminal to settings/modal and back.
- Multiple terminal tiles.
- Closing focused terminal.

## Launch Profiles

Built-ins:

```text
shell:
  command: user's shell
  title: Shell

claude:
  command: claude
  args: []
  title: Claude Code

codex:
  command: codex
  args: []
  title: Codex Review

nvim:
  command: nvim
  args: []
  title: Neovim

custom:
  user-defined command and args
```

Detection:

- Use login shell path lookup or `/usr/bin/env`.
- Cache successful detections.
- Show missing tools clearly.
- Allow manual path override.

## Performance Targets

- Terminal creation overhead should feel dominated by shell/agent startup, not app work.
- Sustained output should not freeze canvas interaction.
- Terminal resize should feel immediate after drag.
- Ten visible terminal tiles should not overwhelm app CPU when idle.
- Offscreen terminal rendering policy should be explicit later; MVP can keep all active surfaces alive if performance is acceptable.

## Failure Modes

### Ghostty Surface Fails To Initialize

Show tile error:

```text
Terminal engine failed to initialize.
Open diagnostics.
```

Keep tile descriptor.

### Command Missing

Show profile error:

```text
Claude Code command not found.
Configure path or install CLI.
```

Do not create a half-running process.

### PTY Spawn Fails

Store error in runtime state. Keep tile so the user can edit profile/retry.

### App Relaunch

MVP restore policy:

- Restore tile descriptors.
- Restart sessions only when policy allows.
- Otherwise show restart button for terminal descriptors.

Do not promise exact process continuity unless tmux/session persistence is added later.

## Future Terminal Work

- Ghostty config/theme import.
- Scrollback snapshot/search.
- tmux attach profile.
- Agent output classifiers.
- Prompt injection for future ask bus.
- Remote SSH profile.
- Terminal split/focus mode.

