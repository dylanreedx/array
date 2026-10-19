---
title: "Find your way around"
description: "Move between tiles, zones, projects, and focused work."
section: "Workspace"
order: 10
---

The canvas gives work a location. Navigation helps you return to that location without having to remember exactly where you left it.

## Command Center

Press **⌘K** to open the Command Center. Use it to discover commands and create surfaces. It is a useful starting point when you know what you want to do but do not know where the control lives.

Shortcuts can be customized. The defaults in this page may differ from your bindings; **Help → All Shortcuts…** (⇧⌘/) and **Settings → Keyboard → Shortcuts** show the live catalog.

## Tiles and focus

Click a tile to work inside it. Drag its title bar to reposition it and resize from its edge or corner. Editing text, scrolling a transcript, and navigating the canvas are different interactions: when a tile has keyboard focus, its content receives ordinary typing.

Use **Focus Mode** to concentrate on a surface, then return to the surrounding canvas. The default global binding is **⌘F**. Canvas movement and content scrolling can behave differently depending on focus; use navigation mode when you want explicit workspace movement.

## Navigation mode

The default leader is **⌃Space**; **Option** is the default hold-to-navigate modifier. The navigation hint shows the actions available in that mode. The default directional keys are **H / J / K / L** for left / down / up / right.

Use zone numbers **1–9** to jump to a zone and **0** to fit all. **Return** focuses the selected destination; **Escape** exits navigation mode. Zone and workspace pickers help when the destination is better identified by name.

## Zones and projects

A zone is a region of the workspace; a project is a folder. Keep related surfaces together in zones such as “Implementation,” “Review,” or “Preview.” The active project zone determines where project-scoped creation happens.

Changing the view does not change a terminal’s working directory or move files between projects. An agent’s home checkout remains part of its identity. Check that identity before asking it to edit another checkout.

## Useful defaults

| Shortcut | Action |
| --- | --- |
| ⌘K | Command Center |
| ⌘F | Focus Mode |
| ⌘, | Settings |
| ⌃Space | Navigation mode |
| ⌘⇧/ | All Shortcuts |
| ⌘⇧S | Activity Dock |

Quick-spawn bindings **⌘1–⌘4** depend on the configured profiles. When the agent inbox owns focus, number shortcuts can jump to inbox rows instead. Check the shortcut’s scope as well as its keys.

## When an agent opens something

Canvas tools can open or reveal a document without changing your camera. Moving a tile through the API does not move the camera, change keyboard focus, or select a different active zone. Ask explicitly to be taken to something if that presentation is part of your intent.

An agent may receive `presentation_required` for a surface in another workspace or a zone that is not currently available. Open that destination yourself before retrying; the tool does not silently switch your workspace.
