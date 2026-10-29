---
title: "Agents on the canvas"
description: "How agents discover, inspect, and act on the workspace through scoped tools."
section: "Agents"
order: 22
---

Array’s workspace API gives managed agents a structured way to interact with the canvas. Claude Code and Codex receive it through an MCP server named `array_workspace`; Pi uses a bundled extension bridge to the same host operations.

## Enable workspace tools

New agents get workspace tools unless **Settings → Agents → Agent permissions** is **Off**. For an existing agent, use **Workspace Tools** in its tile menu. Turning tools off revokes the agent’s workspace grants. What an agent may do without asking is set by **Agent permissions**; see [Permissions and transport](#permissions-and-transport).

## Try it in a prompt

> Use Array’s workspace tools to identify your checkout and zone. Open the project README as a tile, keeping my camera where it is. Tell me which tile you opened.

For an intentional layout change:

> Use the canvas tools to place the README tile beside your tile. Query the current layout first and preserve my focus.

You do not need to remember JSON parameters to ask for these actions. Specific intent helps the agent choose the right operation and avoid an unwanted camera move.

## How agents know the tools exist

Array supplies tool names, descriptions, schemas, and usage guidelines from a shared catalog. It also supplies explicit guidance that the agent is running on an Array canvas.

Claude receives an appended system-prompt instruction and MCP initialization instructions. This matters because MCP tools can be deferred behind tool search: the model needs to know to look for them. Codex receives developer guidance with its per-run MCP configuration. Pi’s extension registers the catalog tools and their prompt guidance.

This teaches the agent that a workspace API exists. It does not give the agent a screenshot or automatic access to the contents of every visible tile.

## Discover identity and layout

`array_workspace_context` returns the agent’s identity, home checkout handle, workspace/zone/tile identifiers, current capabilities, approval requirements, and recent operation outcomes. It is the authority on what this agent may do now.

`array_canvas_query` lists zones and tiles with world-coordinate rectangles, a structural revision, and hydration coverage. World coordinates do not change as you pan or zoom. An unhydrated zone may have no tiles in the response even though it contains saved work.

`array_find_agent` searches observed agent metadata. `array_inspect_agent` returns bounded evidence for a particular agent; inspecting another agent asks for approval unless **Agent permissions** is **Free within a project** and that agent is in the same project. A missing transcript means unknown, and ambiguous search results require a choice.

## Open documents and change layout

`array_open_document` opens or reveals a document and returns the real tile identity plus the presentation outcome. It does not edit the file. A target in another checkout or an unavailable presentation context can produce a structured refusal rather than a guessed substitute.

`array_canvas_apply` moves or resizes one tile in the agent’s checkout. The agent must query first and pass the current structural revision. A concurrent user drag or layout change can reject the request. The returned actual rectangle reflects layout and minimum-size rules.

Canvas movement uses the same geometry route and undo history as a user drag. It does not change the camera, focus, selection, or armed zone.

`array_update_agent` sets or clears an agent’s [identity colour](/docs/agents/#give-an-agent-a-colour) and [renames](/docs/agents/#rename-an-agent) it. An agent can change its own colour and name; changing another agent’s in the same checkout needs the canvas-change permission. A rename says whether it was asked for (`requested`) or the agent's own idea (`proactive`); a proactive rename is refused on a name you typed or asked for.

## Work with boards

`array_board_query` discovers boards and columns or reads a board’s tasks, revision, bodies, links, image metadata, and assignees. `array_board_apply` creates, edits, moves, assigns, unassigns, or deletes one task through the same durable board machinery as the UI.

The agent queries before writing and supplies a revision and stable request key. A board task is user-authored content; its presence does not automatically instruct every agent to execute it. [Board workflows](/docs/boards/).

## Visible delegation

`array_delegate` creates a child agent in a visible tile, inheriting the parent’s provider, model, and checkout. It creates no worktree. Use it only when the user has asked for delegation.

`array_reveal_agent` presents an existing child without creating a new one. `array_message_agent` starts a turn on another agent: under **Free within a project**, any agent in the same project, so you can ask an agent to “message the agent to your right”; under **Ask first**, only the agents it created and the agent that created it. It never interrupts an active turn. A chain of agent-to-agent turns with no prompt from you stops after 20, so two agents cannot keep each other running forever. `wait_agents` collects child results using the returned operation handles.

The provider’s built-in subagent tool is different: it can run work inside the current tile without creating an Array tile. If you want visible parallel work, say so explicitly.

## Permissions and transport

The native MCP bridge communicates with an Array host bound to `127.0.0.1`. Each registered agent has a capability token; the host validates identity and permissions before dispatching an operation. The token is written to a private file rather than put into the agent’s inherited environment or command-line arguments.

Under **Free within a project** (the default), nothing an agent does inside its own project asks you. Inspecting an agent or opening a file in another project still does. Under **Ask first**, the first inspect, delegation, message, open-file, or canvas change asks you in an Array dialog: **Allow Once**, **Allow for This Agent Session**, or **Deny**. A session approval lasts until Array quits or that agent’s Workspace Tools are turned off. Use `array_workspace_context` for the current capability and approval list. A declined request is not permission to attempt the same action through a shell workaround.

Whatever the setting, an agent never grants itself anything, never writes to another project’s canvas, and never messages an agent in another project.

This scopes the workspace API. It is not an operating-system sandbox for all programs running under your macOS user.

## If an operation fails

| Result | What it means |
| --- | --- |
| `revision_conflict` | The layout or board changed; query again before deciding what to do. |
| `target_conflict` | A target is ambiguous or being manipulated; resolve it first. |
| `presentation_required` | The destination needs the user to open the relevant workspace or surface. |
| `permission_denied` | Stop; the scope or user decision does not allow the operation. |
| `outcome_unknown` | Recover the original operation’s outcome before repeating it. |

For uncertain writes, `array_get_operation` and recent operations help recover the outcome. Reusing the same idempotency key for the same request prevents a dropped reply from creating a second agent or delivering a message twice. An expired outcome is not permission to repeat it blindly.
