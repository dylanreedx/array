---
title: "Install and connect"
description: "Get Array running and sign in through the CLI you already use."
section: "Start here"
order: 1
---

Array requires macOS 14 or later on Apple Silicon. Download it from [arrayapp.dev](https://arrayapp.dev/) and move **Array** to Applications.

## Open a project

Choose a project folder on first launch. That folder is the working location for project tools and the home for its `.array` state. Give macOS folder access when prompted.

Start with a folder you are comfortable allowing a coding agent to read. Agents can make real changes according to their runner’s permissions; a conversation tile is an interface to a working program.

## Connect your tools

Open **Help → Environment Setup…**. Array checks for Claude Code, Codex, Pi, tmux, and Git tools, and offers guidance for missing dependencies.

Sign in using the selected CLI’s own flow. For example, launch `claude` or `codex` in a terminal and complete its login. Pi owns its provider login through `/login <provider>`. Array does not ask you to paste provider keys into an Array account form.

You only need the harness you intend to use. Installing one does not make the others available. Pi using an OpenAI model is still Pi; it does not become the Codex harness.

## Start your first agent

Open **⌘K**, choose an agent command, and select from the live models offered for that harness. Ask a small question about the project first. If a provider or model is unavailable, return to Environment Setup and verify the CLI independently.

For the CLI’s original interface, choose **Claude CLI Terminal** or **Codex CLI Terminal** instead. See [the difference](/docs/cli-connections/#two-ways-to-run-an-agent).

## Updates and support

Use **Array → Check for Updates…** to check manually. Automatic checks follow your choice in the app.

Use **Help → Replay Getting Started** for the introduction and **Help → Report a Problem…** for issues. [Release notes](https://github.com/dylanreedx/array-releases/releases) and [public issues](https://github.com/dylanreedx/array-releases/issues) are available on GitHub. Review logs and screenshots for private content before posting.
