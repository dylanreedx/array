# Look: pink persona

Used by `videos/power-tour` (accepted 2026-10-05) and `videos/full-day` (r0,
v2 r1, 2026-10-05). Code lives in `legacy/acts/edu` (HandCursor, Bubble, Pill,
Tag, Icon) and `legacy/previews/day` (the transitions). It is not ported to a
kit Look. Port it to `look.ts` here if a new video borrows it (`--look pink-persona`).

Dylan, 2026-10-05: "The pink and white outline kind of grew on me ... poppy
and distinguishable." Retired 2026-10-15 for the poppy pivot ("no pink").

## Tokens

| Token | Value | Use |
| --- | --- | --- |
| persona | `#ff4f8b` | The user's hand, its bubble, its pills |
| on persona | `#ffffff` | Text and outline on pink |
| amber | `#ffb347` on `#2a1700` | Needs you |
| green | `#4fd07a` on `#04210f` | Done |
| blue | `#5fa8ff` on `#03162e` | Working |
| night | `#0b0d10` | The desk under the footage |
| plum | `#2a0f1c` | Transition shadows (full-day) |
| blush | `#ff86ad`, `#fff6f9`, `#f3d6e1` | Transition fills (full-day) |

## Type

Geist (OFL), weight 650 in pills and 600 in captions, tracking -0.02 to
-0.025em. Captions are pinned to the tile they are about, or ride the cursor
when the line is about the cursor. Icons go inline (provider marks, line
icons), and never emoji.

## Motion

- The cursor: fast (0.25-0.4 s), ease-in-out, no overshoot. It stays an arrow
  while dragging, squashes to about 0.85 on a press, and the glove appears
  while dragging (Dylan's pick, 2026-10-05).
- The bubble trails the cursor on a short lag and morphs between lines on a
  spring (3.4 Hz, damping 0.62): old words lift away and new ones pop in one
  by one.
- Punches: a small push toward the hand on a payoff (5-6%).
- Transitions (full-day): themed for the time of day, 4.5-5 s each, ending
  with the clock chip docking on a spring.
- Never: gesture decorations (circles, trails, rings), which Dylan called ugly
  (2026-10-04).

## Sound

Score modes `app` (power-tour) and `day` (full-day) in kit/soundtrack.py: a
groove built from Array's own bundled sounds (Resources/AgentSounds), with
every effect mapped onto them.
