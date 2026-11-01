# Two-app multiplayer journey

`scripts/check-multiplayer-journey.py`, added 1 November 2026 after Dylan's
two-Mac test of 0.7.37. It is the gate for the share redesign.

## What it runs

Two dev-channel bundles, "Array Journey A" and "Array Journey B"
(`dev.arrayapp.macos.mp-journey-a` / `-b`, in `~/array-scratch/apps`). Each
has its own app support, project root, credential file and tmux namespace
under `~/array-scratch/mp-journey`. Both are launched with `open -n -g`, with
their windows transparent and parked off every display, and they never
activate. The check fake CLIs stand in for claude, codex and pi. The relay
is staging by default; `--relay local` runs a `continuum-relay` from this
tree instead.

`MultiplayerDriver` (mailbox `req-N.json` → `res-N.json`) takes each person
through the production path:

1. Avery spawns a managed agent.
2. Avery shares it: `MultiplayerDriver.share` runs the popover's Copy
   (`ShareLinkSession.copy`). **This is the swappable share step**, together
   with `share_step()` in the script.
3. Blake opens the link (`ShareLinkCoordinator.open`) and sees the agent in
   the shared zone.
4. Blake prompts from the shared view's composer.
5. Assertions: Avery's tile shows Blake's prompt as Blake's card, followed by
   the reply; Blake's view shows "You: …" followed by the reply.
6. Once that turn has ended, Avery prompts from the tile's composer.
   Assertions: Blake's view shows "Avery: …" followed by the reply, and
   Avery's tile still shows both prompts.
7. Cursors: a 90-step pointer stroke of posted mouse events, one each way.
   Prints delay per position and for the final position. Budget: median
   ≤ 500 ms, final ≤ 700 ms.

The fake answers a plain prompt with one final assistant message. The
production Claude runner reads `--include-partial-messages` deltas, so it
does not render that message. Prompts therefore use the fake's TOOL /
TOOLFAIL shapes, whose tool rows render on both sides. A prompt typed while
the agent works is a steer, and the fakes answer steers only with text. The
journey therefore waits for the turn to end, and
`--collaboration-full-access-check` witnesses steers reaching teammates.

## Results (1 November 2026)

| Run | Build | Relay | Result |
|---|---|---|---|
| RED | prompt fixes reverted (0.7.37 prompt behaviour) | staging | 4 transcript failures. Avery's tile showed the reply but not Blake's prompt. Blake's view showed only "• Command · done / failed". The cursor checks passed. |
| GREEN | `f2a2c458` | local (new relay) | all 12 passed |
| GREEN except the relay part | `f2a2c458` | staging (0.7.37 relay code) | Avery's side passed. Blake's view had the replies but no prompts: the old relay refuses prompt rows, and the host falls back to "who sent the last prompt" without stalling. This passes once staging runs the new relay. |

Cursor delay over the real staging relay, per position: Blake → Avery median
64-72 ms, final 81-114 ms; Avery → Blake median 77-193 ms, final 101-177 ms.
On a local relay both directions are 20-56 ms median.

Each staging run self-enrolls two throwaway people ("Avery", "Blake"),
creates one area, and revokes its link at the end. No route exists to delete
an area or a person.
