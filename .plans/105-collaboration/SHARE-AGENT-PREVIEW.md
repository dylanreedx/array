# Try "Share one agent" (mode A)

Written 1 November 2026, on `array/mp-share-agent`. The spec is
[SHARE-REDESIGN.md](SHARE-REDESIGN.md), mode A.

Two Array windows on this Mac play two people, Array Share A and Array Share
B. They talk through a relay running on this Mac only. Nothing reaches Fly,
your Keychain or a real Claude, Codex or Pi login. Neither of them is your
Array.

## Start and stop

From the bench:

    cd .worktrees/multiplayer-build-shared-agent-t-a0b8b54d
    scripts/share-agent-preview.sh              # builds, then opens both windows
    scripts/share-agent-preview.sh open-link    # give B the link you copied in A
    scripts/share-agent-preview.sh relaunch a   # bring A back after quitting it
    scripts/share-agent-preview.sh stop         # quit both and the relay

`SKIP_BUILD=1 scripts/share-agent-preview.sh` reuses the bundles already in
`~/array-scratch/apps`. Every start begins fresh. Both people start with no
account, as a new person would.

A has two agents on fake CLIs: one Claude Code, one Codex. A prompt containing
`TOOL` shows a tool step, and `SLOW` gives a long turn. Anything else gets a
short reply.

## Things to try

1. **Share from the header.** In A, the Share icon sits in the agent's header,
   beside the Terminal switch. Click it. The popover opens on the agent.
   Nothing is shared yet.
2. **Or from the sidebar.** Hover the agent's row in A's sidebar and click
   the same icon. You get the same popover.
3. **Copy.** Press Copy link. The first time, A is asked for a name: that is
   the sign-up. The link goes on your clipboard. The agent stays exactly
   where it was, and no zone appears. Its tab now reads "Yours · shared".
4. **Open it as B.** Run `scripts/share-agent-preview.sh open-link`. That is
   what clicking the link on B's Mac does. B picks a name. One agent tile
   lands in B's zone, in view, outlined in A's colour, with a tab saying
   whose it is and where it runs. A banner says what arrived.
5. **Prompt from both.** Prompt from B's composer, then from A's own tile.
   Both transcripts show both prompts. Each is tagged "You" on the sender's
   side and with the sender's name on the other.
6. **Controls.** B has no Stop and no approvals. Those stay with A.
7. **Who has access.** Click A's Share icon again. The popover lists B with
   "full access", Remove, and "Revoke everyone's access". A's tab now reads
   "Yours · shared with B's name". Press Remove: B's tile says "A stopped
   sharing", and prompts from B are refused.
8. **Works once.** In A's popover, press New link (Works once), then
   `open-link` again. B is back in, in the same tile. A second person opening
   that same link would be refused.
9. **A goes offline.** Quit Array Share A (⌘Q). B's tile dims, with a dashed
   edge: "A's Mac is offline". Send a prompt from B; it says Queued. Then run
   `scripts/share-agent-preview.sh relaunch a`. The prompt runs once, and B's
   tile is live again.
10. **B relaunches.** Quit Array Share B, then run
    `scripts/share-agent-preview.sh relaunch b`. The tile is back where it
    was, and reconnects.
11. **Move it.** Move, resize or close the tile in B. Nothing changes on A.

## What is different from 0.7.37

- Sharing one agent makes no zone and moves nothing. Sharing several tiles
  with the Share tool still makes a zone, until the portal tile (mode B)
  replaces it.
- The discussion panel ("Select an object / Workspace / Post") is gone.
- A shared zone from 0.7.37 that holds one agent turns into this tile on
  launch. A zone holding more stays a zone for now.

## Known limits

- B's tile shows the agent through its projection, a summary, rather than
  A's full transcript renderer: assistant text, prompts with names, and tool
  steps by kind. Slice A3's richer body is not built.
- No presence avatars on the tab yet. The spec puts them there in mode A, but
  none of the twelve acceptance steps checks them.
- Links are opened with `open-link` because these preview bundles are not
  the app macOS opens `arrayapp.dev` links in.
