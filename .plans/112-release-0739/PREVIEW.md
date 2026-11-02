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
   **Stop sharing one terminal:** press that Stop sharing. That terminal turns back into a card in B's portal;
   the rest of the portal keeps going.
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

- **The 8 newer commits on array/integration are not in it either** (iOS
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

## What was checked before handing over

RESULTS
