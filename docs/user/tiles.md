---
title: "Every tile, explained"
description: "Choose the right surface and understand what each one owns."
section: "Workspace"
order: 11
---

Tiles keep different kinds of work visible together. Open the Command Center to discover creation commands; some surfaces are opened by another feature rather than offered as standalone launch choices.

## Agent

A native conversation backed by Claude Code, Codex, or Pi. Send prompts, inspect streamed responses and tool activity, and continue the same agent’s work. Array manages the process and translates provider events into its transcript. [Learn about agents](/docs/agents/).

## Terminal

An embedded terminal powered by GhosttyKit. Use it for a shell, development server, interactive CLI, Neovim, or a configured custom command. Terminal launch profiles include **Shell**, **Claude CLI Terminal**, **Codex CLI Terminal**, **Neovim**, and **Custom Command**.

A terminal can execute real commands. Its scrollback is not a managed-agent conversation, and an interactive Claude or Codex terminal does not automatically gain the managed canvas-tool connection. [How CLI tiles differ](/docs/cli-connections/).

## Browser

A web surface for a URL or local development preview. Run your server in a terminal, then open its address here. A browser tile does not start the server for you.

Managed agents with workspace tools enabled can open and use browser tiles in their project. Agent-created browsers use the shared **Agents** profile, separate from your Default profile. You can select Agents on a browser tile to sign in to a development app for agents to use. An agent must ask before taking control of one of your own browser tiles, and control returns to you when you interact with it. The browser header shows who is driving and offers **Take control**. Moving a tile off the Agents profile also takes it back.

With Agent permissions set to Free, an agent can read and screenshot any browser tile in its project, including yours. With Ask first, reading one of your tiles asks first, like taking control.

Localhost, loopback addresses, and files in the agent’s checkout can be opened without a domain prompt. Other domains ask for your approval, including when a navigation redirects. Domain approvals last only for the current session. Screenshots and agent downloads are saved in Array’s private application-support storage.

## Inspector

Array Inspector provides focused Elements, Console, Styles, and Network panels for browser work. Safari Web Inspector is a separate native WebKit inspection option, enabled in Browser settings. Availability and restoration can differ from ordinary browser tiles; keep the browser and its server available when working with it.

## Note

A project note for plans, scratch writing, or context you want to keep beside the work. The note body is a Markdown file under `.array/notes/`, separate from the tile’s geometry. A note does not become an instruction to every agent just because it is visible. Give the agent its path or attach the relevant content. [Storage locations](/docs/storage/).

## Editor

A file surface tied to a real document. Use it to read or edit project files, including Markdown. Saving changes edits that document; moving or closing its tile is a different operation. Ask an agent to use `array_open_document` to reveal a file beside its conversation without editing it.

A file’s path and checkout matter. Two checkouts can contain files with identical names. A stale or ambiguous target should be resolved before opening or editing.

## File Tree

A project folder browser. Explore the repository, then open documents into editor surfaces. The tree is a view of files on disk; rearranging tiles does not rearrange those files.

## Board

An editable kanban document with columns and tasks. Tasks can hold Markdown descriptions, links, images, and an assignee. Use a board to define and track work you want to hand to agents. Its task data lives separately from canvas layout. [Board guide](/docs/boards/).

## Diff

A specialized change-review surface. Use it to inspect differences before deciding what to keep. Reviewing changes is separate from committing them. A diff is a view over a comparison; it is not a backup of the whole repository.

## Artifacts

A run-artifact surface for outputs associated with a run. Use the actual output path when handing a file to another tool or agent. A reference to an output is distinct from copying that output into a new durable location.

## Tickets and Queue

**Tickets** and **Queue** are specialized orchestration surfaces represented in Array’s tile model. They belong to ticket/conductor workflows and are distinct from the general-purpose editable Board. Their presence in the internal model does not guarantee a creation command in every build.

If you want an ordinary task list you can edit and use with agents, start with **Board**. Do not rely on a specialized surface being available or restored identically to a terminal or note.

## What every tile does not share

Tile position, content, and runtime are separate. A board’s task, a file’s bytes, a browser’s page, and an agent’s provider session have different owners and storage. [Local storage](/docs/storage/) explains what you need to preserve to recover a workspace.
