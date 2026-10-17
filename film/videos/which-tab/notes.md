# "Which tab was that?": notes

16.5 s, 1920x1080 at 60 fps (4K is the same layout at scale 2). Current round: r5.3, 2026-10-16.
Dylan on r5.3: "it's gorgeous..."

## State

- Purpose: initial launch promo. Format: pull-back reveal. Look: ink + lime.
- Takes: two runs of the recorder's `which-tab-bare` scene, imported as `pullback` and `plate`:

      scripts/import-take which-tab ~/array-scratch/film/which-tab-bare-20261016T205831Z/out/01-pullback --as pullback --rects picker,dark,cart,site,subs,emails,export,board,zone:web,zone:api
      scripts/import-take which-tab ~/array-scratch/film/which-tab-plate-20261016T210030Z/out/01-pullback --as plate --rects picker,dark,cart,site,subs,emails,export,board,zone:web,zone:api

  The run folders are the recorder's old layout (dated, not ours to rename). New takes land in
  `~/array-scratch/film/takes/which-tab/<take>/`.
- Score: `tabs` mode in kit/soundtrack.py.

## Proof that film/ reproduces r5.3 (2026-10-16)

`scripts/render which-tab --round 5.3` from this folder, compared with the delivered
`.plans/68-launch-film/which-tab-r0/preview-opening.mp4` (rendered from `.worktrees/hero-loop/film`):

    probes/compare.py renders/which-tab/r5.3/preview.mp4 .plans/68-launch-film/which-tab-r0/preview-opening.mp4 --audio
    991 frames compared at 1920x1080
    max abs diff 0/255, mean abs diff 0.00000/255, frames with any difference 0
    audio: 793600 vs 793600 samples, max abs diff 0.000000

The only file that differs is cues.json: its `working` array is all zeros here. The old pipeline counted
the website fixture's working agents into it, but the `tabs` score never reads it.

One thing had to be kept for this result. The old bundle loaded the website's production.css (Tailwind
preflight, antialiased glyphs), and every frame was tuned on that page. kit/base.css reproduces that page
without the website. Remove it and the film shifts.

## Rounds

Dylan's notes are verbatim and numbered as he sent them. Each round's cut is in
`.plans/68-launch-film/which-tab-r0/preview-opening-r<N>.mp4`.

### r1 (2026-10-16): a Ghostty/Claude opening, then a cross-fade to the canvas
No notes from Dylan. He watched r2 first ("saw the newest one, not r1"). The self-review found a muddy
double-exposure seam.

### r2: shared element, card to tile
Dylan:
1. "omg that was CLEAN!"
2. "the transition to Array still is not great... we need to think about something better besides just fading between the canvas tiles and the terminal edit: saw the newest one, not r1 and it looks better but i still think we can do better... but definitely geting close!"
3. "the highlight border around the agent tile is yellow, we should have our marching ant dotted border"
4. "all of the agent tiles look like they just started they need to be looking like they are working harder"
5. "i love the motion blur at the start switching between terminal tabs"
6. "let's clean up the end screen, the type/font for Array looks a little weird"

What changed in r3: UNSTACK. The windows fan out and each flies to its own tile. The finish mark became
the app's real marching ants (FINISH_MARK 'none'). The agents were recaptured deep into their work, and
the end card uses the real mark SVG.

### r3: UNSTACK
Dylan:
1. "OMG THAT IS PERFECT PERFECT FUCKING TRANSITION"
2. "there is very subtle slight jitter with the terminal switching and adding tabs"
3. "i also slightly more chaos with the terminal tabs, ik it isn't native with terminals but add statuses on a few to prompt jumping to -> a done one, right after a failed one, after a warning or needs input ,etc... just simple colours or something like circle indicators right next to the tab name or sum?"
4. "we could also think about also having to switch CLIs for LLM providers?"
5. "we need also a better transition from the terminal and tabs to the terminal tab fan out... we need some continuity with the motion of how the tabs separate and fan out -- it looks so good already though!"
6. "the transcripts of the working agents when do see the canvas aren't very smooth i thought we had smoother animations for responses and streaming responses?"

What changed in r4, with the cause of each:
- Jitter. Tab edges were rounded independently, so a centred label stepped back +1.1 px while its tab only
  shrank. Edges now round once each, to even pixels. A 1.8% window scale creep (0.04 px a frame) re-rasterised
  every glyph each frame (±0.4-0.9 px shimmer), so held things now hold still. Measured with probes/jitter.py.
- Status dots on tabs drive a reactive hunt: amber needs input, red failed, lime done.
- Three CLIs. claude, codex and pi each run in their own grammar (kit/tui), and the canvas tiles match.
- The tab pills lift off the bar and unfurl into their windows, so the tab becomes the window.

### r4
Dylan:
1. "OMG ALMOST PERFECT"
2. "the transition between the tabs become windows/cards then becoming tiles onto the canvas, the tiles appear blank for a few moments and it's jarring to my eyes"
3. "it looks like the mask to transition and reveal from terminal tabs to canvas tiles is behind or something we need more attempt to transition between a basic claude code terminal tab to our tile canvas UI"

What changed in r5, with the cause: the card faces were cut from the live pull-back while its camera was
still tight, so most tiles were outside the captured frame and their faces were black. The fix is a PLATE
take: the same run with the camera held wide. Faces are cut from it at the same take frame and hand off to
live only once the tile is wholly in frame and the pixels agree (HANDOFF, from probes/plate-parity.py).
probes/blank-faces.py measures it. The terminal-to-tile morph now goes row by row (CART_ROWS): the title
bar becomes the header, the prompt becomes the composer, and the Update rows become CHANGES cards.

### r5 to r5.2
Dylan:
1. "there is jitter with each tile it could be the borders and the slowly progressive zooming out right? but we need to fix this, it looks shaky or something"
2. "finally i would like to tighten up the spacing at the final shot, vertical and horizontal (between the logo and type Array) our logo is an SVG it should be manipulable right"
3. "do web research there are clean final outro screens like this, maybe Linear has some good ones? Vercel?"

What changed, with the cause:
- r5.2: the camera holds after landing. A slow drift on a real take snaps the tile borders to whole pixels
  and reads as shake, so a real take never drifts. Fresh recordings were made with the camera held.
- r5.1: the end card was split into beats (research/22-end-cards: none of 14 measured launch films stacks
  headline, lockup and URL). Mark 1.4H, gap 0.5H ink to ink, and the mark's viewBox cropped to its ink.
  probes/lockup.py measures it.

### r5.3: the final recordings
Dylan: "it's gorgeous..."

## Still open

- The app bug that filming found (late failed-tool details land below the fold) has its fix in
  `.plans/68-launch-film/which-tab-r0/footage/pin-failed-output.patch`, landing through the app fixes.
