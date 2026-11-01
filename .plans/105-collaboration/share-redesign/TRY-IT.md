# Try "Share one agent"

Written 1 November 2026, on `array/mp-share-agent` (cursor lane merged in).

Two preview apps play two people: Array Share A and Array Share B. They are
already built in `~/array-scratch/apps`, and not running. They talk through a
relay on this Mac only. Neither one is your Array, and neither touches your
Keychain or a real Claude, Codex or Pi login.

## Start

    cd ~/Documents/personal/Array/.worktrees/multiplayer-build-shared-agent-t-a0b8b54d
    SKIP_BUILD=1 scripts/share-agent-preview.sh

This starts the relay and opens both apps in the background. Switch to them
from the Dock. Each start begins fresh, with no account on either side.

## Try it

1. In A, click the Share icon in an agent's header. The popover opens.
2. Press Copy link. Give A a name; that is the sign-up. The link is copied.
   The agent stays put, no zone appears, and its tab reads "Yours · shared".
3. Run `scripts/share-agent-preview.sh open-link`. This is what clicking the
   link does on B's Mac. Give B a name. One agent tile lands in B's canvas,
   and a banner says who shared it.
4. Prompt from B, then from A. Both sides show both prompts.
5. Quit A (⌘Q). B's tile dims and says A's Mac is offline. Prompt from B,
   then run `scripts/share-agent-preview.sh relaunch a`. The prompt runs once.

The full list of things to try is in
[../SHARE-AGENT-PREVIEW.md](../SHARE-AGENT-PREVIEW.md).

## Stop

    scripts/share-agent-preview.sh stop

That quits both apps and the relay, and leaves nothing running.
