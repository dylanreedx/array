# "Which tab was that?" Brief

Purpose: [initial launch promo](../../purposes/initial-launch-promo.md). Format: [pull-back reveal](../../formats/pull-back-reveal.md)
(this film defined it). Look: [ink + lime](../../looks/ink-lime/README.md) (this film defined it).

Written 2026-10-15 as `.plans/68-launch-film/research/21-which-tab/brief.md`; copied here unchanged
below this paragraph except for "Where work lives". What the film became by r5.3 is in notes.md.

Pilot 1 from research/20, built properly. Dylan's verdict on the artifact pilots
(2026-10-15): "they all look horrible… cheesy, not the motion I'm looking for";
pilot 1 "makes the most sense but it is sooooo fast and looks veryyy ugly…
it needs to transition better to the app."

## Why the pilot failed (don't repeat these)

1. **It zoomed a screenshot.** The pull-back scaled a 1600px still up to 6x, so
   the reveal was blurry mush. Fix: the app does the zoom. The pull-back is a
   real film-harness take, so every frame is rendered crisp by Array itself.
2. **The terminal was a toy.** A grey box of monospace lines. Fix: it has to
   look like a real Ghostty window running real Claude Code sessions.
3. **6 seconds for 3 ideas.** Nothing had time to read. Fix: about 15 s, with
   holds long enough to read.
4. **Cross-fade between two unrelated pictures.** Fix: one continuous
   shared-element move. The tabs ARE the tiles: same agent names, same tasks.
   The window shrinks exactly into its tile's place while the app camera pulls
   back.
5. **Bouncy springs and a "Pilot 01" chip on everything.** Fix: product UI only
   eases (no bounce); there is no chip.

## The film (16:9, 3840×2160 master, 60 fps, about 15 s)

| Shot | Time | What happens |
|---|---|---|
| S1 hook | 0 – 1.2 | Full-frame Ghostty window running `claude`. The tab bar fills 1 → 8 tabs quickly, one soft tick per tab. The headline "Which tab was that?" is legible by frame 0 (the thumbnail). |
| S2 hunt | 1.2 – 5.0 | Tab switching (as with ⌘⇧]), slowing to a readable ~0.45 s per tab. Each tab is a different Claude Code session mid-task, its title one of the canvas's agent names. One tab, never visited, shows a bell (finished). Faked motion blur on content swaps only. |
| S3 beat | 5.0 – 6.2 | The flicking stops. The headline swaps to "Your agents are hiding in tabs." |
| S4 pull-back | 6.2 – 9.5 | The window chrome (title bar, tab bar) peels away. The window shrinks into its own agent tile's place on the real canvas while the real app camera pulls back from that tile to the whole workspace: 5-6 agents working, a browser, a board. Real footage from here. Tab labels can fly to their tiles' titles (rects from frames.json). |
| S5 payoff | 9.5 – 12 | The agent from the bell tab is visible on the canvas in its real finished state. One lime mark on it. "Keep every agent in view." |
| S6 lockup | 12 – 15 | Array wordmark, arrayapp.dev. Hold 3 s. |

## Look

- Ground ink `#0E0F0C`, text paper `#F2F0E9`, ONE accent acid lime `#D2E823`
  meaning "finished" and nothing else. No pink anywhere (the old persona
  `#ff4f8b`, HandCursor, Bubble and CaptionBand are retired for this film).
- Type: not Geist (the old films' signature). An OFL grotesk for headlines,
  JetBrains Mono for the terminal. The agent proposes it in styleframes.
- Motion: camera eases `cubic-bezier(.65,0,.35,1)`, 0.9-1.4 s moves, 0.8 s+
  holds to read. Type enters word by word from one direction. Everything holding
  still drifts slightly. Faked motion blur only on fast moves.
- Sound: a new `soundtrack.py` mode. A tick per tab, a muffled bell for the
  hidden finish, a low drone under the hunt, a breath at S3, a lift into the
  pull-back, a clean chime on the payoff.

## Truth

- Everything in the real-footage half is the real app. Read the current
  finished-agent state from the source (sidebar "Done"/"ready", tile status);
  don't invent one.
- No approval/Allow-Deny beats (real Claude agents don't show them).
- Agent and task names in the tabs must match the canvas tiles exactly.

## Where work lives

- Edit: this folder. Footage: two recorder takes, imported with `scripts/import-take`
  (notes.md lists the runs and the exact commands).
- Renders: `renders/which-tab/r<N>/` (gitignored). The delivered rounds r1 to r5.3 are in
  `.plans/68-launch-film/which-tab-r0/`.
