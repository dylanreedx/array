# Canvas And UX

## Product Model

MVP uses Project Spaces:

- Workspace contains projects.
- Project owns one primary canvas.
- Switching projects switches the active canvas.
- Groups organize related work inside a project.

This model won over Activity Lenses and Spatial Map for the first version because it is cleaner to navigate and easier to persist. It still leaves room for later activity lenses/floors.

## UX Principles

- The canvas is the workspace, not a dashboard.
- Terminals are first-class surfaces.
- Keyboard creation must be faster than toolbar hunting.
- Spatial layout should reflect how the developer thinks about the project.
- Focus state must always be visible.
- Restore should feel boring and dependable.
- Empty states should help create the first useful setup immediately.

## Canvas Coordinate System

World coordinates:

- Infinite 2D coordinate system.
- Tile frames are stored in world coordinates.
- Viewport stores world origin and zoom.
- Window size does not mutate tile frames.

Viewport:

```text
viewport.x
viewport.y
viewport.zoom
```

Zoom policy:

- MVP range: `0.1...4.0` unless Ghostty/browser rendering imposes constraints.
- Future wide range can expand toward Figma-style zoom.
- Avoid negative letter spacing or viewport-scaled fonts in chrome.

## Navigation

Trackpad:

- Two-finger pan.
- Pinch zoom.

Mouse:

- Space + drag pans.
- Configurable modifier + scroll zooms.
- Middle mouse pan if available.

Keyboard:

- Fit view.
- Zoom in/out.
- Focus next/previous tile.
- Move focus by direction.
- Add tile commands.
- Project switching.

Vim/tmux-friendly expectations:

- Do not steal common terminal/editor chords.
- App-level commands should be configurable.
- Directional focus should feel like window navigation.
- Project switching should be faster than Command-Tab.

## Tile Creation

MVP creation methods:

- Command palette.
- Hotkeys for common tile kinds.
- Context menu at cursor/canvas point.
- Add button for discoverability.

Suggested hotkeys:

```text
Command+1: Agent/launch profile tile
Command+2: Shell tile
Command+3: Browser tile
Command+4: Neovim/code profile
Command+K: Command palette
```

The exact chords can change after testing against terminal conflicts.

Creation placement:

- If invoked from canvas context menu, place at clicked world point.
- If invoked from keyboard, place at viewport center with slight cascade.
- If another tile is selected, optionally place to the right of selected tile.

New tile defaults:

- Terminal: 900x620.
- Browser: 1000x700.
- Neovim/code terminal: 1000x720.
- Shell: 850x560.

## Tile Interaction

Required:

- Select.
- Multi-select later if cheap.
- Drag.
- Resize from edges/corners.
- Bring to front on focus.
- Close.
- Duplicate later.

Drag behavior:

- Freeform by default.
- No hard grid.
- Optional magnetic snapping later.
- Dragging a terminal should not select text inside it unless drag starts in chrome/handle.

Resize behavior:

- Stable minimum sizes per tile kind.
- Terminal resize updates PTY rows/cols.
- Browser resize updates WKWebView frame.
- Resize should not cause title/header text overflow.

Z-order:

- Focused tile comes forward.
- Z values are renormalized when needed.
- Persist z-order.

## Groups

MVP groups are visual organization inside a project canvas.

Fields:

```text
id
title
tileIds
color
collapsed
```

Behavior:

- Create group from selected tiles.
- Move group by moving bounding region.
- Rename group.
- Ungroup.
- Collapse can be deferred unless cheap.

Why groups matter:

- A project may have many sessions, browser previews, directories, and agents.
- Groups let the user build regions like "Feature Build", "Review", "Research", "Dev Server", and "Release".

## Project Switcher UX

Goal:

Switching projects should feel as fast as tmux session switching.

MVP:

- Sidebar or compact project rail.
- Command palette search.
- Recent project ordering.
- Pinning.
- Last active project on launch.

Later:

- Numeric project shortcuts.
- Workspace folders.
- Spotlight indexing.
- Activity lenses/floors.

## Focus Mode

Deferred, but design now.

Nyx demonstrates a strong pattern: fold canvas into split pane where one tile pairs with one agent. For `continuum-revived`, focus mode should eventually:

- Select one primary tile.
- Select optional companion tile.
- Collapse visual noise.
- Preserve original canvas layout.
- Exit with Escape or dedicated shortcut.

Do not build before canvas basics and focus broker are stable.

## Minimap

Deferred, but design now.

Minimap should:

- Show tile bounding boxes.
- Show current viewport.
- Allow click/drag navigation.
- Stay lightweight.

Do not implement until many-tile canvas performance is measured.

## Visual Design Direction

This is a tool surface, not a landing page.

Principles:

- Quiet, dense, legible.
- Dark mode first, with light mode possible.
- Terminal content gets priority.
- Chrome should not look like marketing cards.
- Tiles may be framed, but page sections/chrome should not be nested cards.
- Status should be subtle but visible.
- Active focus must be unmistakable.

Avoid:

- Decorative gradients/orbs.
- Huge hero-style empty states after onboarding.
- Soft toy-like rounded controls everywhere.
- One-note purple/dark-blue palette.
- Text that explains obvious UI inside the app.

## Empty State

First project empty canvas should offer direct actions:

- Spawn Claude.
- Spawn shell.
- Spawn browser.
- Open project in editor.

No long prose. No marketing copy. The empty state exists to get the user into work.

## Canvas Tests

Unit tests:

- World/screen coordinate conversion.
- Zoom around point.
- Fit bounds.
- Hit testing.
- Z-order renormalization.
- Group bounds.
- Tile minimum sizes.

UI tests:

- Drag tile.
- Resize tile.
- Switch focus between terminal/browser/canvas.
- Create tile at cursor.
- Restore viewport/layout.

Performance tests:

- 20 live tiles.
- 100 descriptor-only tiles.
- Pan/zoom under load.
- Resize terminal while output is streaming.

