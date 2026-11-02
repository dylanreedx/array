# Agent characters: the preview

Built 2026-11-01 for Dylan to open when he is back. Nothing was launched on screen.

## Open it

Paste this into a terminal:

open --env CONTINUUM_APP_SUPPORT="$HOME/array-scratch-characters-support" "$HOME/array-scratch/apps/Array Characters.app"

It is its own app ("Array Characters", `dev.arrayapp.macos.characters`), with its own
settings and store. It does not open a project, does not touch your Array or
Array Dev, and runs no agent CLI. Quit it with ⌘Q.

## What you will see

Two windows, Light and Dark, each with the real sidebar on the left and eight real
agent tiles on a canvas. Characters are on. A third window shows every character in
every state, as Settings' preview grid does.

The agents are attached to a real supervisor, and a script feeds them the same
runtime events a CLI would, on a 16-second loop:

| agent | what its character does |
|---|---|
| Rework the sign-in screen | types at a laptop, then reads, then runs a build |
| Find every caller of saveCanvas | searches (splashing in water), then a web search |
| Run the release matrix | runs a command; a step fails every loop (a flinch) |
| Delete the stale benches | waits for your approval (a wave) |
| Fix the zoom stutter | runs tests, then the turn fails (a droop, then the failed pose) |
| Write the release notes | thinks, edits, then finishes (a cheer, then done) |
| Audit the notification paths | quiet for over 3 minutes: asleep |
| New agent | never started: holds still |

The row and the tile of one agent always show the same pose: both are built from
the same supervisor facts. The "noticed" reaction (you just sent a prompt) is not in
the script, because it needs a real prompt.

Each agent's character is picked from a hash of its id, so the two windows (separate
agents) show different ducks for the same title.

## The recording

`~/array-scratch/agent-characters-preview/agent-characters.mp4`: 16 seconds, the same
scene in Light and then Dark, captured offscreen from the preview bundle's own binary
(`--agent-characters-recording-check`).

## In the real app

The branch adds Settings › Appearance › Agent characters: the switch (off by
default), Motion, the set picker with Import…, the themes folder that reloads live,
and a preview grid. A tile's ⋯ menu has Character, to pick one for that agent.
Agents can make sets: see `docs/internals/agent-characters-authoring.md`.

## Clean up

rm -rf "$HOME/array-scratch/apps/Array Characters.app" "$HOME/array-scratch-characters-support" "$HOME/array-scratch/agent-characters-preview"

Rebuild with `scripts/agent-characters-preview.sh` (through `.worktrees/.locks/app-build.sh`).
