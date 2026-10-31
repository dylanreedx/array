# Multiplayer preview: try it with two windows

Written 30 October 2026, on `array/mp-preview` (built on `array/collaboration-finish` at
`c7131f8f`).

Two Array windows on this Mac play two people. They talk through a relay
running on this Mac only. Nothing reaches Fly, your Keychain or a real Claude,
Codex or Pi login.

## Start and stop

Run from the `mp-preview` bench:

    cd .worktrees/mp-preview
    scripts/multiplayer-preview.sh        # about 45 s after the first build
    scripts/multiplayer-preview.sh relaunch a   # bring A back after quitting it
    scripts/multiplayer-preview.sh stop   # quits both windows and the relay

Every start begins fresh: a new relay database, new people, new projects.

## What is set up when the windows open

- **Array Dev A** (left half): person A. A owns the shared workspace "Preview
  shared workspace". A's canvas has two agents: one Claude Code and one Codex.
- **Array Dev B** (right half): person B, an editor in the same shared
  workspace. B's canvas is empty.
- Each person has two windows: the canvas on top, the shared workspace below.
  If you close the shared workspace, reopen it from File > Collaboration… >
  Recent shared workspaces.
- The agents run on the fake CLIs from the checks, not on real ones. So:
  - A prompt containing `TOOL` shows a tool step.
  - `SLOW` or `LONG` gives a turn you can stop.
  - Anything else gives a short reply.
  - The Claude fake sends whole messages, so a Claude turn shows its tool step
    without text. Use the Codex agent to watch text arrive in the live view.
- No tiles are shared yet. Sharing is the first thing to try.

## Things to try

Status key:
- **Seen**: I saw it working across the two windows.
- **Pair-witnessed**: the automated two-process check passes it, but I did not
  try it by hand.
- **Expected broken**: the automated check reports this stage as not wired
  across two processes yet. Helper 896A0BA8 is wiring it on
  `array/col-pair-features`.

1. **Both people in one shared workspace.** Both windows opened it, and both
   report the same workspace ID. **Seen.** I could not screenshot the shared
   windows themselves (see the bottom of this file).
2. **Share a tile.** In A: click a zone, then File > Share zone… (or Capture
   area to share…). Pick the shared workspace and choose what each tile
   becomes: a note becomes an agreement, an agent becomes an agent view. Then
   confirm. It should appear in B's shared window. **Pair-witnessed.**
3. **Move tiles together, then undo.** Drag a shared tile in A, then in B.
   Undo in each. One person's Undo must never move a tile the other person
   moved more recently. Each person's camera stays their own.
   **Pair-witnessed.**
4. **Discussion and agreements.** Edit the agreement text in A, then in B.
   Both windows should show the newest revision. Add a discussion and post in
   it. **Pair-witnessed** (agreement edits; discussion only as volume replay).
5. **Endorse.** In B, select the agreement and press Endorse revision N. A
   should see it. **Expected broken** (endorsements stage).
6. **Follow the other person.** Hover or select the other person's cursor and
   choose Follow view. Pan, scroll or zoom to stop. **Expected broken**
   (follow stage). The cursor itself, and hovering it for token use, are
   **pair-witnessed**.
7. **Publish a diff or a file.** Share an artifact from A and open it in B.
   Try Follow latest against a pinned revision. **Expected broken**
   (artifacts stage).
8. **Live agent view.** Share A's Codex agent, select it in B, and send it a
   prompt from A. B should see the turn arrive. It refreshes once a second.
   **Expected broken** (live views and freshness stages).
9. **Hand an agent over, and take it back.** In A, offer the shared agent to
   B. Accept in B, then send a prompt from B. It runs on A's Mac, once. While
   B holds the agent, A's own composer is refused. Then reclaim it in A.
   **Pair-witnessed** for offer, accept and send. Known gap: "Send now" does
   not yet check whether sending is allowed; A's Mac refuses it when it
   arrives.
10. **The host goes offline.** Quit Array Dev A (⌘Q). B should show A's
    agents as offline or stale, not running. Then bring A back with its
    account, workspace and agents kept: `scripts/multiplayer-preview.sh
    relaunch a`. Don't open the app from Finder: without the script's
    settings, it refuses to start rather than use your real dev store.
    **Expected broken** (liveness stage).
11. **Keyboard only.** In the shared window, Tab through every control,
    select tiles, move one with the arrow keys, and undo, all without the
    mouse. Witnessed in one process (the native keyboard check), not across
    two.

## Known rough edges in the preview itself

- **I could not screenshot the shared-workspace windows.** `screencapture -l`
  works on both canvas windows but fails on the two shared-workspace windows
  ("could not create image from window"). I don't know why yet.
- **Focus is not proven.** Both apps launch with `open -g` and preview mode
  skips Array's own activate call. But in my check, B was frontmost
  afterwards. You were already clicking in B by then, so that check could not
  tell launch from your click. The next quiet run should check this.
- **Getting Started.** On the first run, Getting Started covered both canvases
  and offered the real Claude sessions on this Mac. Preview mode now skips all
  of its tasks. That fix is in the code, and runs started before it was
  committed still show the panel.
