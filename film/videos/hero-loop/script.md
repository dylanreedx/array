# Hero loop "In view"

Purpose: a silent, seamless 12 s loop for the README, release notes, social, email and OG
video. Three agents work in one zone; one needs you, you approve it, open a Terminal, everything
lands green, and the next round starts where this one began.

6 bars, 120 BPM, 4 beats per bar = 12.0 s = 720 frames at 60 fps (360 at 30 fps).
Formats: `loop` (16:9, 30 fps, silent, mp4 + webm + poster), `loop60` (the same at 60 fps, mp4 +
webm) and `square` (1:1, 60 fps).
Render: `scripts/render.sh hero-loop --silent --formats=loop,square,loop60 --stills=1.1,2.3,3.4,4.2,5.3,6.1 --sheet`.

## Bar table

| Bar | Beat | Picture |
| 1 | 1 | Three agent tiles, all blue/working, gyros spinning out of phase (per-agent phase offsets). The lens holds tight on the zone: in 16:9 the three tiles span 92% of the frame width under the zone's header band; in 1:1 it frames the middle and right tiles. |
| 2 | 1 | Right tile flips to needs-attention: amber pill and dashed amber ring, approval card below its transcript. Lens drifts right to centre it (exponential decay, tau 100 ms). |
| 3 | 1 | Cursor hits Allow once. Amber to working/blue on the beat. |
| 3 | 3 | Keyboard chip "⌘K". Command Center opens; typing "shell" leaves Create › Terminal highlighted; Return. |
| 4 | 1 | Terminal tile lands beside the agent at the agents' size; Tidy grows the zone and snaps it in (110 ms, cubic-bezier(0,0,.58,1), positions only); `swift test` is typed and streams to a green pass line. |
| 5 | 1 | Lens pulls back to the whole zone (1:1: the three agents). Left, middle, right tiles turn done/green on beats 1, 2, 3: pill, gyro stops, the last tool row settles to Completed, Send replaces Stop. The next prompt types into the composers on beat 4. |
| 6 | 1 | Send: the composers clear and all three go back to working/blue on the beat, with no new transcript entry; the lens eases back to its bar-1 framing, settled by beat 3, so frame 720 equals frame 0. |

## What the reducer does on each row

"Lens" in this table is the film lens (`sheet.lens`, lib/Lens.tsx). The website's Mac camera holds
still at 60% (`scene.json` `macCamera`), which leaves the lens room inside the canvas to drift
right and to pull back to the grown zone; at 100% the zone already fills the canvas. Lens keys
are rects in canvas world coordinates, resolved through the Mac camera, so no sidebar or top bar
is ever in frame, and a camera re-centre under a still lens does not show. The Command Center is
portalled into the part of the stage in frame (`<Film commandCenter="frame"/>`) and drawn at the
camera's zoom, so it sits centred near the top of the frame at the size it has next to the
tiles at 100%. Names in brackets are the `CUE` keys in `timeline.ts`. Agents: left `stabilize`
(Codex), middle `audit` (Pi), right `verify` (Claude Code; the website's single approval belongs to
it). Every operation runs as generation 1, which is `scene.json`'s `operationGeneration`.

1. **Bar 1 beat 1 [start].** No action: `scene.json` is the state. One zone, `Canvas Runtime`,
   1070 px wide: three 330x420 agent tiles in Tidy's own positions and no empty slot. All three
   agents `working`, each with one session of 6-7 unique entries (one user turn, tool rows, one
   assistant finding; the last tool row is in progress). The Terminal (the Shell launch profile's
   tile) exists but is closed; the approval is `accepted`, so no card shows; `selectedEntityId` is
   null. Camera `{x:204, y:214.6, zoom:0.6}`: the clamp's own centring of the zone at 60%. Gyros:
   `lib/gyro.ts` passes each agent the app's own phase offset (`gyroSeedPhase`, FNV-1a over the id)
   through DemoStage's `gyroPhase`, and rounds the website's 7.2 s cycle to 6.0 s so two whole
   cycles fit the loop; a gyro renders only while its agent is working.
2. **Bar 2 beat 1 [needsYou].** `ADVANCE_AGENT verify needsAttention` with no entry (amber pill and
   the dashed attention ring), then `REQUEST_APPROVAL` puts the scene's approval back to `pending`,
   so the card appears below the transcript, with the provider's "Allow once" / "Decline". Lens key
   `NEEDS_YOU`: the same scale, centred on the right tile, over 0.6 s on `glide(0.6)`, an
   exponential approach with tau 100 ms (`CAMERA_TAU`). [cursorIn] at beat 3: the pointer heads for
   Allow once.
3. **Bar 3 beat 1 [approve].** The pointer presses Allow once (measured at 0.28, 0.68 of the tile).
   `SELECT_ENTITY verify` (a click selects the tile, as MacWorkspace's pointerdown does),
   `RESOLVE_APPROVAL accept start`, then `complete` on the same frame: card gone, agent `working`,
   blue, summary "Pushing to origin" (the scene's own). `SET_ENTRY_STATUS` (new action) flips the
   `git push` row, which read In progress while the card was pending, to Completed. At bar 5 the
   other two running rows complete with their agents; at bar 6 all three go back to In progress. `SET_TOAST null` on the same frame, because
   the reducer's toast says "Approved on Companion" and Companion is not shipped.
4. **Bar 3 beat 3 [commandK].** ⌘K chip (bottom right, clear of the palette in both formats);
   `OPEN_COMMAND open` shows the home sections: Recent and Create (Needs You is empty, because the
   approval just landed). The palette sits 6% of the frame height below the frame's top.
   [typeFrom → typeTo] `SET_COMMAND_QUERY` types `shell`; the only match, highlighted, is Create ›
   Terminal ("/bin/zsh · Array / Project Root", ⌘1): the Shell launch profile, which the native
   palette titles Terminal. The pointer rests on that row at beat 4. [returnKey]: ↵ chip (the
   footer's "Return Open").
5. **Bar 4 beat 1 [shellLands].** `OPEN_COMMAND close`, then `OPEN_SHELL`: the Terminal opens at the
   agents' 330x420, 40 px right of and below the right agent, above every other tile, selected,
   with a fresh session. [shellTypeFrom] `SHELL_DRAFT` types `swift test` at the prompt. [tidyFrom]
   `UPDATE_ZONE` grows the zone to 1416 px (sizes land at once, as Tidy's growth does in the app)
   and `SET_CAMERA` re-centres on it under the still lens; then [tidyFrom → tidyTo] `tidyTrack` with
   `positionsOnly`, 110 ms on `E.cssOut` (`cubic-bezier(0,0,.58,1)`): the website's `tidyLayout`
   target, committed as `MOVE_ZONE`, moves the Terminal into the fourth slot. [swiftTest]
   `SHELL_EXECUTE swift test`; [stream] four `SHELL_OUTPUT` lines; [testsPass] beat 4:
   `SHELL_COMPLETE` with "✔ Test run with 18 tests in 4 suites passed after 2.412 seconds.", in
   Ghostty's default green. The lines are the website Shell's own `swift test` script.
6. **Bar 5 [pullBack, doneLeft, doneMiddle, doneRight].** Lens key `PULL_BACK`: the whole grown
   zone at 94% of the width in 16:9; in 1:1 the three agents (a square that holds the whole zone
   is taller than the canvas), over 0.52 s on `glide(0.52)`. `ADVANCE_AGENT done` with no entry,
   left on beat 1, middle on beat 2, right on beat 3: the pill turns green, the gyro tail goes, the
   last tool row settles to Completed, Send replaces Stop. [promptFrom] beat 4: "Rebase on main and
   run the checks again." types into all three composers (`SET_AGENT_DRAFT`).
7. **Bar 6 beat 1 [send].** `SET_AGENT_DRAFT ''` and `ADVANCE_AGENT working` with no entry, for all
   three: the composers clear and the agents are blue again. No reducer action was needed:
   `SEND_AGENT_MESSAGE` would append a user turn, and these two existing actions are the send
   without it. Lens key `HOME` again over 0.52 s on `glide(0.52)`, exact at the end. [closeShell]
   beat 3, once the lens has settled (the last 30 frames at 30 fps are static): `CLOSE_TILE
   shell`, `UPDATE_ZONE` back to 1070 px and `SET_CAMERA` back to the scene's camera, all instant
   and all outside the frame but the zone's right edge. **Not in the bar table**: frame 720 cannot
   equal frame 0 while the Terminal is open.

## Why it loops exactly

`scene.json` is the state one round of this timeline leaves behind. No cue appends to a
transcript, so every transcript is the same list at f0 and f360 and its DOM is the same by
construction. The Terminal already holds the previous run, the approval is already `accepted`,
the zone and the camera return to the scene's, and the lens to its first key (lerps are
`a*(1-t) + b*t`, exact at t=1). The gyro phase wraps on the loop to exactly 0.
`scripts/check-loop.ts` witnesses it: state one frame past the end equals frame 0, and the first
and last rendered frames match (mean abs diff < 2/255 and at most 0.1% of samples off by more
than 16). Dropping `closeShell`, `zoneShrinks` or `zoneGrows` turns the state check RED (`cameraHome`
alone does not: at 60% the clamp re-centres the three-tile zone by itself). The lens is not
state, so only the pixel check sees a lens that does not return.

The pixel check was RED at 0.6-1.4% while every track returned exactly. The diff heatmap put all
of it on transcript text, line by line: the transcript follows the bottom, so its scroll offset
is a round longer at the end than at the start, and Chrome rasterizes a composited scroller's
contents in their own space at the lens scale, so offset x scale landed the same lines on a
different sub-pixel row. `lib/determinism.ts` paints the transcript with its tile
(`overflow: hidden`, still a scroll container) and the residual is the gyros' one frame of
motion: 0.006% at 30 fps. The transcripts no longer grow at all (round 2), so this cause is gone
by construction too; the rule stays because it costs nothing and keeps any scroller honest.

## Copy rules

website/DESIGN_SYSTEM.md: direct, spatial, no em dashes. No Companion copy until it ships. Only
real section names and the real launch profile name; no shortcut chip except ⌘K (and ↵, the
palette footer's own "Return Open").

## Open for review

- Resolved: the Create row reads "Terminal" because the app's palette titles the Shell profile
  that way (`LaunchPaletteModel.presentation(for:)`: `displayName == "shell" ? "Terminal"`);
  typing "shell" matches the profile's own name.
- Resolved: Needs You is derived from state, so an approved agent leaves it.
- Resolved: rings. The film draws the app at 60%, so the canvas-space focus and attention rings
  would read 1.7x heavier next to the tiles than at 100%. `<Film ringScale={2}/>` redraws their
  stroke (1.5 pt) and dash (6/4) at a 2x display's weight, about 3 output px; the 8 pt gap around
  the tile is geometry and stays the website's.
- Each transcript is taller than its tile, so it follows the bottom and its first entries
  (including the user turn) scroll out of view, as a real session does.
- The tile title bar reads "Terminal · Shell" (MacWorkspace's kind name plus the fixture's tile
  title).
