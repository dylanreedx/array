---
title: "When something is missing"
description: "Diagnose unavailable models, tools, documents, and sessions."
section: "Reference"
order: 31
---

Start by identifying which layer failed: Array’s workspace, the selected CLI, the provider account, or a process such as a local development server.

## The CLI is missing or signed out

Open **Help → Environment Setup…** and check the selected harness. Run that CLI independently in a terminal to verify its installation and login. A working Codex login does not establish Claude Code or Pi readiness.

If a tool works in your shell but is unavailable in the app, check the executable’s install location and the environment seen by a Finder-launched app. Array augments tool discovery, but it cannot make a removed executable run.

## A model is not listed

Model choices come from the selected harness’s live catalog. Verify the installed CLI version, authentication, and account access. A model available through Pi is not automatically available through Codex, even when both refer to the same provider.

## The agent cannot see canvas tools

Confirm that this is a managed Agent tile rather than an interactive CLI terminal, and that **Workspace Tools** is enabled in its tile menu. The new-agent default is off unless you enable it in Settings. Ask it to discover `array_workspace_context` from the `array_workspace` MCP server; Claude may need tool search first. Pi uses the bundled extension bridge.

If the host bridge did not initialize, prose prompting alone cannot create the missing connection. Report the failure with the selected harness and app version. Do not paste capability tokens or provider credentials into the conversation.

## A document cannot be opened

Check the exact path, project, and checkout. The workspace API refuses ambiguous or unsupported targets rather than substituting a file with the same name. `presentation_required` can mean the user needs to open the target workspace or zone first.

## The preview is unavailable

Check that the development server is actually running and that the Browser points at its current URL and port. A saved browser address does not restart a stopped server.

## A session cannot resume

A persisted tile is not the provider’s complete session. A native session may have been removed or become unavailable to the installed CLI. Keep important decisions in project documents so work can be recovered even when a provider session cannot.

## A request timed out

For workspace writes, recover the original operation’s outcome before repeating it. The request may have taken effect even when its reply was lost. Agents can use `array_get_operation`, recent operation results, and the same idempotency key to resolve uncertain outcomes.

## Report a useful issue

Use **Help → Report a Problem…** or [GitHub issues](https://github.com/dylanreedx/array-releases/issues). Include the app version, harness, action attempted, expected result, observed result, and relevant error. State whether the same CLI operation works outside Array. Remove secrets and private project content from evidence before sharing it.
