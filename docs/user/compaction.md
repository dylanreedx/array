---
title: "Context and compaction"
description: "Understand what a long conversation retains and how to keep it useful."
section: "Agents"
order: 23
---

A model works with a limited active context. As a conversation grows, earlier messages and tool output take space that could otherwise hold the next task. Compaction asks the harness to reduce that working history into a smaller continuation.

Compaction is a provider operation. Array requests it and displays its lifecycle; it does not invent a provider-independent summary and silently replace the conversation.

## When to compact

Use compaction during a long task when the conversation contains a lot of completed exploration or repetitive output. First write durable decisions, important paths, remaining work, and verification results to a project document or board task.

A useful focus instruction is:

> Preserve the login bug’s cause, changed files, failed checks, and the remaining verification steps.

A compacted summary can omit details. Afterward, ask the agent to re-read the authoritative files when precision matters.

## Request it through the supported command

Use the managed agent’s compaction action or supported `/compact` command. Availability follows the selected harness and session. A fresh agent with no established conversation may have nothing to compact.

Do not assume that typing an arbitrary provider slash command is equivalent to using the CLI’s interactive interface. Array routes supported commands deliberately and reports unsupported ones.

## Harness support

| Harness | Manual compaction | Focus instructions |
| --- | --- | --- |
| Claude Code | Available when a suitable session exists; the runner sends `/compact` | Supported |
| Codex | Requires app-server transport and an existing thread; uses `thread/compact/start` | Not supported |
| Pi RPC | Exposes native manual compaction | Supported |

Automatic compaction policy belongs to the harness. Array shows lifecycle events and context readings when the provider supplies them; it does not guarantee identical thresholds or timing across providers.

## What compaction does not do

Compaction does not revert code, reset a project, make a Git commit, or grant new permissions. It also does not reset account usage or rate limits. The visible transcript and the model’s active context are different: seeing an older message on screen does not establish that its full text is still being sent to the model.

## Queues and failures

Compaction is managed as an operation rather than an ordinary conversational request. Array guards against duplicate compaction work and can refuse it when the session or harness is not ready. A request being accepted is distinct from its completion.

If unavailable, check the selected harness, transport, and session. For Codex, focus text is rejected rather than silently discarded. If compaction fails, retain your durable task notes and inspect the reported state before continuing.
