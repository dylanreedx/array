---
title: "How CLI connections work"
description: "The path from an Array conversation to Claude Code, Codex, or Pi."
section: "Agents"
order: 21
---

Array runs command-line tools on your Mac. A managed conversation translates your prompt into the selected CLI’s native protocol and translates its events back into the tile. The CLI makes the provider requests under its own configuration and authentication.

## Two ways to run an agent

| | Managed agent | CLI terminal tile |
| --- | --- | --- |
| Interface | Array’s conversation and tool transcript | The CLI’s original terminal interface |
| Process control | Array’s harness runner | Interactive program in a terminal |
| Models | Selected harness’s live catalog | CLI’s own model controls |
| Canvas integration | Array’s scoped workspace tools | Not automatically the managed integration |
| Session | Provider session plus Array’s agent record | CLI-owned interactive session |

Choose a managed agent for native conversation and canvas integration. Choose a CLI terminal for the CLI’s complete interactive experience.

## Claude Code

Array starts the real `claude` executable in print mode, using streaming JSON for input and output. The runner keeps a long-lived process for the agent’s conversation, sends user messages over its input stream, and translates responses, tool events, and session information.

Array appends guidance describing the canvas tools and configures the `array_workspace` MCP server for that managed process. It uses a strict MCP configuration for this connection, so do not assume every MCP server in an unrelated interactive Claude configuration is also attached here.

Authentication stays with Claude Code’s own sign-in. Array does not implement a replacement Claude login or extract a subscription token to make its own model requests.

## Codex

The managed runner supports Codex’s **app-server** protocol and an **exec JSON** path. App-server uses structured requests for starting or resuming a thread and running a turn, with streamed notifications for progress. Native operations such as manual compaction depend on that transport.

The current runner pins managed Codex to `workspace-write` and `approval_policy=never`. A tool action that needs an unavailable approval route can fail instead of presenting a permission prompt. The workspace-tool grants described below are a separate Array layer.

[OpenAI’s app-server documentation](https://learn.chatgpt.com/docs/app-server) describes the integration protocol and CLI-owned authentication. Protocol support follows the installed Codex version.

## Pi

Pi is its own harness even when its chosen model comes from Anthropic or OpenAI. Its runner, model discovery, login, session data, role tools, and extension bridge remain Pi-owned.

Array loads a bundled extension for workspace operations. Those operations go through the same host API used by the native-provider MCP bridge; Pi does not need to pretend to be Claude Code or Codex to interact with the canvas.

## Is this safe to use?

There are two separate questions: how credentials are handled, and what the running agent can do.

For credentials, Array delegates sign-in to the installed CLI. Anthropic’s [authentication rules](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use) explicitly distinguish an end user signing into the unmodified Claude Code binary from a third party collecting credentials or routing subscription requests on users’ behalf. Its [plan guidance](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan) currently describes subscription usage for `claude -p` and third-party apps. These references were checked October 16, 2026; account terms and eligibility remain the provider’s authority.

For execution, an agent is a program acting on real project files. Its effective permissions depend on the harness and launch configuration. Array’s workspace approvals protect scoped canvas operations; they do not promise that every shell command or file edit will show an Array approval dialog. Review the work you authorize and the changes it produces.

## Usage and billing

The selected CLI and provider account determine model access, limits, and billing. Several agents can consume the same account’s limits. Running a familiar CLI inside a different interface does not create an extra usage allowance. Array’s own pricing is a separate decision.
