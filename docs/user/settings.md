---
title: "Make Array yours"
description: "Discover layout, editor, terminal, agent, and notification controls."
section: "Workspace"
order: 13
---

Open **Settings** with **⌘,**. Search settings and commands by name. Each setting can apply immediately, to new tiles, or after relaunch; read its application label before expecting an existing surface to change.

## Layout and appearance

**Appearance** controls command-menu appearance, the canvas background, the focus border, and resize indicators. **Canvas** includes automatic layout, automatic zone colors, zone chrome, shortcut-rail visibility, default naming, tile gaps, zone padding, and drag snapping.

Automatic layout can affect the final position of tiles. When an agent asks to move a tile, the workspace API returns the actual rectangle after those rules have run.

## Keyboard navigation

**Keyboard** holds **Navigation**, which controls the hold-to-navigate key, activation delay, tile label keys, and zone number keys, and **Shortcuts**, which lists global, navigation, inbox, and tile-specific shortcuts.

The default hold-to-navigate modifier is **Option**, alongside the **⌃Space** leader. Discover the current hints and bindings in the app rather than assuming every key works in every focus scope. [Navigation guide](/docs/navigation/).

## Agent defaults and workspace tools

**Agents** selects the default harness, model, and reasoning effort for new agents. Existing agents retain their own harness, model, checkout, and effort. **Settle finished agents** moves idle agents out of the Activity Dock list after a while. The same pane holds **Dictation** (turn the composer microphone on or off) and **Agent colour** (show an agent’s colour as its title bar or its full border). [Dictation and agent colours](/docs/agents/#dictate-a-prompt).

**Agent permissions** decides how much agents may do through workspace tools without asking you:

- **Free within a project** (the default): new agents get workspace tools. Inside their own project they can start child agents, message any other agent, inspect it, open files, and arrange tiles without a dialog. Inspecting an agent or opening a file in another project still asks, and messages never reach another project.
- **Ask first**: new agents get workspace tools, and the first use of each kind of action asks you. An agent can message only the agents it created and the agent that created it.
- **Off**: new agents start without workspace tools.

For an existing agent, use **Workspace Tools** in its tile menu. Turning it off revokes that agent’s workspace grants at once, whatever this setting says. [Canvas tools](/docs/canvas-tools/).

Agent status-row controls can show or hide individual readings. Account usage is shared by agents signed into the same provider account; hiding a reading changes the display, not account limits.

## Editor

Editor settings apply live to Editor tiles. Choose appearance independently of the app theme, font family and size, line height, line numbers, word wrap, and Vim mode.

These settings affect the native Editor surface. A Neovim process inside a Terminal keeps its own editor configuration.

## Terminal

**Keep shells running when Array quits** configures terminal persistence through tmux. The Terminal settings also cover shared unzoned sessions per workspace, font size, precise and wheel scroll multipliers, and the working-directory fallback for unzoned shells.

Keeping a shell alive is different from saving its tile’s location. Process persistence depends on the terminal backend and configuration; a layout backup does not recreate arbitrary running processes.

## Browser and inspection

Set the default Browser URL and optionally turn on **Allow Safari Web Inspector**. Native Safari Web Inspector is distinct from Array Inspector, which provides in-app Elements, Console, Styles, and Network panels.

## Activity and notifications

**General** controls the Activity Dock’s visibility and width. **Notifications & Sounds** holds **Agent sounds**. System notification permissions also affect what macOS shows.
