# Try the 0.7.39 preview

Written 1-2 November 2026. Branch `array/preview-0739`, bench
`.worktrees/preview-0739`. Local only: nothing pushed, nothing published, no
change to the production relay. No release: this is a preview.

Two Array apps on this Mac play two people, Array Preview A (the host) and
Array Preview B (the guest). They talk through a relay that runs on this Mac
only. Neither is your Array, neither touches ~/Documents, your Keychain or a
real Claude, Codex or Pi login. Agents run on fake CLIs: a prompt containing
TOOL shows a tool step, SLOW gives a long turn, anything else gets a short
reply.

Both apps are built. Agent characters are switched on in both.

Terminals keep tmux persistence. Each app runs its own tmux server in its own
folder (~/array-scratch/preview-0739/a/tmux and b/tmux), never the default
socket your own terminals use. `launch` starts that server itself, without
your ~/.tmux.conf. The reason: your config runs tpm, which can stall a
brand-new tmux server. The app now survives that: a terminal opens without
persistence after 5 seconds, and sharing it falls back to a plain text mirror
after 3. But you'd be trying the fallback, not the real shared terminal. So in
the preview, terminals use tmux's defaults rather than your config.

The local relay and staging both run the same relay code. Staging (v12) is
deployed from this branch; production is untouched.

## Start, launch, stop

Run these from the bench, in this order. Each start is fresh: nobody has an
account, as a new person would.

cd ~/Documents/personal/Array/.worktrees/preview-0739
scripts/preview-0739.sh relay
scripts/preview-0739.sh launch a
scripts/preview-0739.sh launch b
scripts/preview-0739.sh stop

`relay` wipes both apps' state and starts the relay. `stop` quits both apps,
stops the relay and leaves nothing running. A takes the left half of the
screen, B the right.

The apps live in ~/array-scratch/apps ("Array Preview A.app", "Array Preview
B.app"). Opening them from Finder is refused on purpose: only the script gives
them their own state.

## How to share from A to B

1. In A, click the Share icon in an agent's header (beside the Terminal
   switch), or on its sidebar row.
2. Press Copy link. The first time, A asks for a name: that is the sign-up.
   The link is now on your clipboard.
3. Give B the link with this line (it is what clicking the link would do):

scripts/preview-0739.sh open-link

4. B picks a name and the tile lands in B's canvas.

## What to try

A starts with two agents, a Claude Code one and a Codex one. A's project is a
small git repo with one uncommitted change to greet.js, so files and diffs
have something to show.

1. **Share one agent.** As above. One agent tile lands in B, outlined in A's
   colour, with a tab saying whose it is. Prompt from B, then from A: both
   transcripts show both prompts, each tagged "You" on the sender's side. B has
   no Stop and no approvals.
2. **The portal.** In A, press S (or pick the Share tool in the toolbar) and
   drag over several tiles: an agent, a note, a browser, a terminal. The
   popover lists them, the terminal marked "Stays private". Copy, then
   `open-link`. B gets one portal tile showing that part of A's canvas.
   Nothing on A moves. Move a shared tile in A and it moves in the portal.
   In B, scroll pans the portal, pinch or Command-scroll zooms, double click
   fits. Hover the agent and press "Open beside" to prompt it.
3. **Add to share.** In A, drag a tile that isn't shared into the portal's
   region. An "Add to share" pill appears on it. Nothing is published until you
   press it; then it shows up in B's portal.
4. **Notes co-editing.** Share a note on its own, from its header's Share
   icon. Type in it on both A and B: both people's edits survive, in the same
   order on both. Inside a portal a note is read only for B; only a note
   shared on its own is two-way.
5. **Browser.** Share a browser on a public page (say https://example.com):
   B loads the same page in its own browser and follows A's navigation. Share
   one on a localhost page: B sees pictures of A's page; clicks and scrolls
   from B land on A's page. In a portal, the localhost page is a still marked
   "Still".
6. **Shared terminals.** Share a terminal on its own. The first Copy warns
   "This terminal's output may contain secrets…" and publishes nothing; the
   button becomes "Share anyway". B now sees A's terminal as A sees it: a real
   terminal drawn from A's output, with A's colours, cursor and grid, live as
   A types. Try `ls --color`, `top` or vim in A. B can never type into it: a
   shield takes B's input, and the relay refuses it too. In a portal, a terminal
   is a card ("Terminal stays on A's Mac") unless you opt it in: its row in
   the share popover has "Share live…", which warns once ("Share anyway")
   and then marks it Live. Dragging a terminal into a portal works the same
   way: the Add to share pill warns first. An opted-in terminal is live in
   B's portal, drawn the same way, and A's terminal shows a "Live" badge
   with a Stop sharing button beside it, at the right of its top strip.
   **Stop sharing one terminal:** press that Stop sharing. That terminal
   turns back into a card in B's portal; the rest of the portal keeps going.
7. **File and diff, with Approve.** In A, open greet.js (palette: "Editor") and a
   diff (palette: "Diff review"). Share them. B sees the
   file's text and the coloured diff, updated when A saves. In a portal,
   hovering the diff offers Approve and Request changes.
8. **Revoke.** Click Share on any shared tile in A. The popover lists B with
   Remove and "Revoke everyone's access". B's tile or portal says "A stopped
   sharing" and stops updating; prompts from B are refused. New link (Works
   once) brings B back into the same tile.
9. **Host offline.** Quit A (⌘Q). B's tile and portal dim, with a dashed
   edge: "A's Mac is offline". A prompt from B says Queued. Relaunch A with
   `scripts/preview-0739.sh launch a`: the queued prompt runs once and B is
   live again.
10. **Cursors.** In a portal, A's pointer over a shared tile shows inside B's
    portal, and B's pointer inside the portal shows on A's canvas. Cursors only
    appear over shared tiles.
11. **Characters.** Each agent has a small animated duck in its sidebar row
    and tile header, acting out what it is doing (typing, reading, running,
    waiting for you, finished, asleep). Settings › Appearance › Agent
    characters has the switch, Motion, the set picker and a preview grid. The
    tile's ⋯ menu picks a different duck for one agent.
12. **Sidebar sort and filter.** The sort button sits in the sidebar header,
    between the scope control and New Agent. Most active (the default) puts
    working leads and ones that need you first, quiet ones at the bottom. By
    project groups agents under project headings; a lead under its own
    project's heading no longer repeats the project chip. Newest first is the
    old order. Rows don't jump while the pointer is over the sidebar; they
    slide into place when it leaves. The project filter is the scope list's
    Projects › entry.
13. **Lead glyph.** A lead shows the working glyph (and a working duck)
    while any of its helpers works, even when the lead itself is idle and
    folded.

## Known not to work, or left out

- **The 8 newer commits on array/integration are not in it** (iOS
  simulators on the canvas, the ten app themes, the group agent drag, one
  phone alert per task). The preview is built on 0.7.38 (`b0689628`), as
  asked; those land with the release.
- **Leave has no button.** The relay housekeeping work adds the routes
  (admins delete people and areas; a member can leave an area), but there is
  nothing in the app to press yet. Deleting is checked by the relay checks
  and by the journey's own cleanup.
- **A deleted area's shared-tile content stays in the relay's memory** until
  the relay restarts. Nobody can read it (its members are gone); it is just
  not freed. The share-kinds lane keeps tile content in memory only, and the
  deletion routes were written before it existed.
- **Signed-in pages** are detected only when they fail for B with a 401 or
  403 (or don't load). Then B falls back to pictures of A's page.
- **The public-page check needs network.** Offline, the journey prints a NOTE
  and skips it.
- **The first terminal after each rebuild asks for consent.** Each rebuilt
  preview app is a new identity to macOS, so the first terminal may raise a
  permission prompt once.
- **B draws terminal glyphs in its own font.** The grid, colours and cursor
  are A's; the letters come from B's Ghostty font. (These preview apps don't
  read either person's Ghostty config, so both use the default palette.)
- **An opt-in lasts one popover.** Reopen the share popover and it asks
  again for each terminal.
- **A 0.7.38 friend can't open a shared note, file, diff, browser or
  terminal.** They see "the relay answered with an error (426). Try it again
  later." and must update. The link isn't spent and nothing lands on their
  canvas. A shared agent and a portal still open for them, unless
  a terminal in the portal was opted in live (that makes it a live share too).
- **A stuck tmux server gives the plain text mirror, not the live
  terminal.** Sharing used to freeze the host here; it now gives up after
  3 seconds and sends the visible text instead. The preview starts tmux
  itself so you won't hit it.
- Note cursors and selections of the other person are not drawn.
- B's pictures of a private page stop while A's tile is off screen; B keeps
  the last one.
- A shared agent in B shows a summary of A's transcript (assistant text,
  prompts with names, tool steps by kind), not A's full renderer.
- Links go through `open-link` because these preview apps are not the app
  macOS opens arrayapp.dev links in.
- **The sidebar's search header is cramped.** Since the sort button
  arrived, the search field and the scope control are each squeezed to
  102 pt, and the sidebar screenshot check fails on it. Reported to its
  owner.

## What was checked before handing over

The apps were built from `array/preview-0739` at `5ca9f761`. Later commits
on the branch are this guide and notes only.

**Two-app journeys** (two real apps, off screen, with agents on fake CLIs).
Each run deletes the people and areas it made on the relay.

| Journey | Local relay | Staging v12 |
| --- | --- | --- |
| Portal (mode B), incl. a live terminal and its Stop | 70 / 70 | 70 / 70 |
| Live shared terminal | 32 / 32 | 32 / 32 |
| Kinds with tmux persistence, whose tmux server stalled | 55 / 55 | (not rerun) |
| One agent + every kind + a real 0.7.38 guest | 98 / 98 | 98 / 98 |

The staging terminal run and both 98-step runs ran one merge earlier,
before the terminal Stop and the freeze fix. In the tmux run, the app's own
tmux server really did stall: the terminal opened without persistence after
5 s, and sharing it fell back to its visible text after 3 s. Before the fix,
the same run froze the host.

**Targeted checks:** every check the merged branches added, and the
existing shared-agent checks, all pass. They cover:

- portal render and migration, every kind in a portal, shared tile render;
- shared terminal render, the terminal stream, and the two tmux-stall checks;
- the note CRDT and the live-tile lane (incl. the 0.7.38 refusal);
- relay deletion;
- characters: theme, pose, sprite, sidebar, tile, settings, live themes,
  perf, agent.update;
- sidebar: sort, inbox, liveness, truth.

The iOS app builds.

**Full matrix** (on `2d53f8f9`, one merge before the final tip: the terminal
freeze fix, the portal Stop and the owner's iOS fix came after it and were
checked by the legs and journeys above). 449 legs, 12 known-red as expected,
6 failed:

- 3 because the screen was locked while it ran (`--tile-surface-residency-check`,
  `--perf-budget-geometry-hold-probe-check`,
  `--perf-budget-surface-host-slope-check`). They wait for the screen to draw
  a frame, which a locked screen never does. 0.7.38's own build fails all
  three the same way tonight.
- 1 old: the film scenes check, 3 of 12 scenes, the same scenes that have
  failed since 0.7.36.
- 2 real, reported to their owners:
  - colour hygiene: two raw colours, in the shared terminal's palette and in
    a fake web page used by a shared-tile check;
  - the sidebar search header (above).

**Relay:** staging is v12, from this branch. Its rollback target is
recorded in .plans/105-collaboration/RELAY-DEPLOY.md. Production is
untouched.

**Not done: the characters motion harness.** It needs an unlocked screen,
and the screen was locked when the proof ran. It takes the screen for a few minutes, so
run it when you can leave the Mac alone, with nothing covering the window.
The Release "Array Motion" bundle it uses is already built from this tip.
From the bench:

scripts/canvas-motion/character-arms.sh

It runs characters off and on, zoom and pan, twice each. Each run's numbers
are in ~/array-scratch/motion-runs/characters-*/summary.txt; on and off
should match, as they did at 80 tiles in the characters work.
