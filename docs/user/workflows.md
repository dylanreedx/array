---
title: "Everyday workflows"
description: "Combine the surfaces into a few useful ways of working."
section: "Start here"
order: 2
---

You do not need every tile in every workspace. Start with the few surfaces that make the next decision easier.

## Learn an unfamiliar repository

Open an Agent and a File Tree. Ask:

> Explain the project’s entry points and how to run its checks. Open the most important document on the canvas. Do not change files.

Read the explanation beside the actual document. Use a Note for questions or decisions you want to keep. When the agent needs a file’s contents, give it the path; visual proximity alone does not supply context.

## Implement and preview

Keep an Agent, Editor, Terminal, and Browser together. Run the development server in the Terminal and open its local address in the Browser. Give the Agent a scoped change and the checks you expect.

Inspect the changed source and preview yourself. Review the diff before deciding whether to commit. A successful agent response is a claim to assess alongside the output and checks.

## Turn a plan into tracked work

Create a Board and write a task with its goal, constraints, relevant paths, and acceptance criteria. Add images or links when they convey context that prose misses. Use task handoff to send that context to an Agent.

Keep the Board visible while work proceeds. Check the result and record verification before moving the task to your completion lane. [Board details](/docs/boards/).

## Use a second visible agent

Ask explicitly for a bounded child task:

> Delegate a review of the changed tests to another visible agent. It should read only, report concrete findings, and leave edits to this agent. Wait for its result before concluding.

The child shares the parent’s checkout. Read-only review can avoid simultaneous edits, but it is still an instruction to the agent rather than a separate filesystem boundary. If isolated implementation is required, prepare and select an appropriate separate checkout deliberately.

## Continue after a long investigation

Write the current conclusion, changed paths, test results, and open questions into a document. Use supported compaction, supplying focus instructions if the harness accepts them. Then ask the Agent to re-read the document and continue from the remaining work.

## Tune the workspace

Use Settings and **All Shortcuts** to discover live keybindings, quick-spawn profiles, and navigation controls. Keep zones organized by the work you return to most often. The Command Center is the place to search for actions whose location you have forgotten.
