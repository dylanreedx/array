---
title: "Work with agents"
description: "Choose a harness, give useful context, and follow the work."
section: "Agents"
order: 20
---

A managed agent is a conversation tile attached to a specific harness, model, and checkout. Array runs that harness and displays its events; the provider supplies the model and the CLI’s behavior.

## Pick the harness first

**Claude Code**, **Codex**, and **Pi** are distinct runtimes. Each owns its authentication, model catalog, session format, and supported operations. An existing agent keeps its selected harness across relaunches. Changing the default in Settings seeds new agents; it does not convert old conversations.

Models come from the selected CLI’s live catalog. If a model is missing, verify that CLI’s version, login, and account access. Array does not silently run a different harness when one is unavailable.

## Give a useful task

Include the goal, relevant paths, constraints, and the outcome you want to review:

> Read the login flow in this checkout. Explain why a successful login sometimes returns to the welcome screen. Show the relevant file on the canvas, and propose a fix before editing.

For implementation work, state the scope and verification:

> Fix the redirect in the login flow. Keep the change scoped to that issue, run the relevant checks, and report any behavior you could not verify.

A visible note or editor is not automatically model context. Supply file paths, attach content through the composer, or hand over a board task with its description and images.

## Dictate a prompt

Every agent’s composer has a microphone button beside **Send**. Click it, or press **⇧⌘D** while the composer has focus, and talk. The microphone grows into a capsule over the provider controls, with a live waveform, the elapsed time, and a stop button where the microphone was.

Your words land at the caret as you speak. Words still being recognized appear in a lighter colour and settle as the sentence firms up. Dictation never replaces selected text; it inserts at the end of the selection. If you type or move the caret mid-session, what is on screen becomes yours and dictation continues from the new caret.

- **Return**, the stop button, **⇧⌘D**, or clicking outside the composer finishes and keeps the words. Nothing is sent yet.
- **Send** while dictating also only finishes. Press **Send** (or Return) again to send what you see.
- **Esc** discards what this session added. **⌘Z** brings it back.

Dictation runs on one composer at a time; starting it in another agent ends the first session. Speech is transcribed on your Mac with Apple’s on-device speech recognition, in your system language when it is supported. No audio is kept or sent anywhere.

Dictation needs macOS 26 or later; on earlier versions the microphone button does not appear. The first time, macOS asks for microphone and speech recognition access, and the speech model may download before listening starts. Turn dictation off with **Settings → Agents → Dictation → Dictate into the composer**.

## Rename an agent

Array names an agent from its first prompt or the CLI's own title, and that guess is sometimes slightly off. To fix it, double-click the name in the agent tile's title bar, or choose **Rename** from the tile's menu, type the new name and press **Return**. **Esc** cancels, and an empty name keeps the old one. You can also double-click the agent's row in the Activity Dock. The name belongs to the agent, so the tile and the row change together and it survives a relaunch.

Agents with workspace tools can rename themselves, or another agent in the same project, through `array_update_agent`. Ask one ("rename yourself to Parser fix") and it will. An agent may also retitle itself when its automatic name is wrong or its task has clearly changed, but it never replaces a name you typed or asked for. Renaming another agent needs the canvas-change permission, as colours do. [Canvas tools](/docs/canvas-tools/).

## Give an agent a colour

An agent has no colour until you choose one. Open the agent tile’s menu, choose **Color**, then pick Teal, Blue, Mint, Purple, Orange, Yellow, or Red, or **None** to clear it. The Activity Dock’s row actions offer the same choice, for several selected agents at once.

The colour belongs to the agent, not the tile, so it follows the agent across relaunches. It washes the tile’s title bar, marks the agent in the Activity Dock, and tints the dictation capsule. To draw it as the tile’s whole outline instead, set **Settings → Agents → Agent colour → Agent colour shows as** to **Full border**. A colour is an identity mark only; it never signals status.

Agents with workspace tools can set colours too, through `array_update_agent`. An agent can change its own colour; changing another agent’s needs the canvas-change permission, which Array asks you for when **Agent permissions** is **Ask first**. [Canvas tools](/docs/canvas-tools/).

## Read the activity

The transcript shows the conversation and tool events that Array receives. The status surface reports observed activity and context information when the harness provides it. An unknown reading means evidence is unavailable; it does not prove that no work happened.

Provider rate limits, working-context usage, and local process state describe different things. A context meter does not tell you how much of your subscription remains.

## See what an agent left running

Agents often start things that outlive a single command: a dev server, a file watcher, a long test run. When an agent has something running, its status row shows a chip with the ports it is listening on (for example `:3000`), or a count when nothing is listening. Click the chip to open that agent's processes. Each row shows the full command, its ports, its process id and how long it has run, and it updates live while open. Click a port to open it in a browser tile beside the agent, use the row's buttons to copy its URL (or command) or stop it, and click the row itself to see the whole command line. **Stop** asks the process to quit and force-quits it after two seconds if it has not.

While any agent has something running, a small activity icon appears in the top bar, left of search. It opens the same panel for every agent, each under its name with **Show Agent** to jump to its tile and **Stop All** when it has more than one. At the bottom, **Other ports on this Mac** opens to list anything else that is listening, one row per app, such as Postgres or a server you started yourself; macOS's own services are left out, and stopping one of these asks you to confirm. The panel is also in ⌘K (**Processes**) and **View ▸ Show Processes**, even when nothing is running.

Array finds an agent's processes by a label each agent's CLI starts with, which every process it starts inherits. That includes one an agent detached from itself, which keeps running after you stop the agent or close its tile; the menu says so. Array does not stop background processes on its own. Hide the chip with **Settings ▸ Agents ▸ Background Processes**.

## Follow up, steer, or stop

A follow-up after a completed turn continues the conversation. During active work, the harness may support steering or queueing; use the app’s current send state to see which action is available. An accepted message is not the same as a completed task.

Stopping a turn does not reverse commands or file edits already performed. Review the repository and any running processes (the status row's process chip lists them) before resuming. Array’s UI is not a substitute for a Git diff.

## Work with other visible agents

Ask for delegation explicitly when you want a separate agent tile. For example:

> Delegate a read-only review of the parser tests to a child agent in another tile. Keep implementation here, then collect the child’s findings.

`array_delegate` creates a child beside its parent, inheriting its provider, model, and checkout. It does not create a worktree. A provider’s built-in subagent tool can run inside the same tile instead. [Canvas tools and delegation](/docs/canvas-tools/).

## Keep long work grounded

Store durable decisions in project files or a board task. Use [compaction](/docs/compaction/) when appropriate, then ask the agent to re-read the files that matter. Persistent documents are useful anchors when a model’s active context changes.
