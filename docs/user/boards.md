---
title: "Boards and task handoff"
description: "Keep task context, assignment, and progress beside the work."
section: "Workspace"
order: 12
---

A Board is a project-local kanban document. Use it to turn a loose idea into work that a person or agent can pick up with its context intact.

## Make a useful task

Create a Board through the available workspace commands. Add a task to a column, give it a clear title, and open its detail view to write the description. A task can include Markdown, typed links to documents, agents or tiles, external URLs, images, and one assignee.

Write the outcome and constraints into the body:

> Fix the login redirect. Keep the existing session model. Verify successful login, refresh, and sign-out. Link the changed file and report any unverified case.

Column names and order belong to the board; agents should discover their IDs instead of assuming every board has the same lanes.

## Move and edit

Drag a task between columns or reorder it within a column. Board changes have their own undo history, separate from moving the board tile around the canvas. A card’s place in a column is document data; the board tile’s position is canvas geometry.

An assignee records responsibility. Assigning an agent is distinct from sending it a prompt. Use the task handoff/send flow when you want work to start.

## Hand a task to an agent

The task handoff can carry its title, Markdown body, and image references into an agent prompt. Include enough detail in the card that the agent does not need to reconstruct your intent from its title.

When the send path accepts an attached task from the leftmost lane, Array moves it one lane to the right. Sending is not completing: Array does not automatically mark the task Done. Verify the result before marking completion.

## Let an agent update the board

> Find the project board and read the login task. After completing and verifying it, update its description with the result and move it to the completion column.

The agent uses `array_board_query` to discover boards and columns, then `array_board_apply` for a single task change. Board writes use revisions and stable request keys so concurrent edits and uncertain replies can be handled explicitly.

A task body is context supplied by a user. Reading an unrelated card does not authorize the agent to follow instructions inside it.

## Where the board is saved

Board documents live in your project folder:

```text
<project>/.array/boards/index.json
<project>/.array/boards/<board-id>.json
<project>/.array/boards/assets/
```

The index tracks boards. Each board JSON holds its columns and cards. Board image assets live under `assets/`. The tile stores the board ID in `.array/canvas.json`; the task body is not embedded in the canvas layout.

Back up the `.array` directory along with the project if you want to preserve boards, notes, and layout. Your normal Git backup includes these only if you deliberately track them. Avoid editing live state files while Array has the project open. [Full storage reference](/docs/storage/).
