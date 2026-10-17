# Look: caption band (the website demo look)

Used by `videos/hero-loop`, `videos/canvas-tour`, `videos/what-is-array`
(2026-10-04) and, with real footage, `videos/board-story` (2026-10-04). Code
lives in `legacy/acts` (Caption, Lockup, Spotlight, KeyChip) and `legacy/lib`.
It is not ported to a kit Look.

## Tokens

| Token | Value | Use |
| --- | --- | --- |
| desk | `#0b0d10` | Behind the app |
| band | `#08090b` | The reserved caption band |
| text | `#f2f4f8` | Captions and the wordmark |
| text 2 | `#9aa4b2` | The lockup's small line |
| state | blue `#5fa8ff` working, amber `#ffb347` needs you, green `#4fd07a` done | The colour motif, in picture and score |

## Type

Geist 600 (OFL, vercel/geist-font 1.7.2). Captions are 84 px at 1080p
landscape and 120 px for the hook, tracking -0.025em, one line at a time, in a
band reserved at the bottom (at the top in portrait). The lockup is the blue
favicon mark in a rounded tile, then "Array" in Geist 600 at -0.045em.

## Motion

- Captions enter on a quick, critically damped rise (2.6 Hz, no overshoot)
  and leave with an 8-frame fade. A `words` line reveals word by word.
- The lens (the film camera) frames subjects on springs (soft: 1.35 Hz,
  damping 0.9) or glides on an exponential approach with tau 100 ms, inside
  the band-free box.
- Spotlight dims everything but the subject.
- The end card: the canvas dims, then the mark springs in (heavy, no
  overshoot), then the word, then the lines.

## What Dylan said about it

2026-10-04: the bottom band makes the eyes "jump back and forth" between the
caption and the action. Pin text where the eyes already are. The website
mocks it drew were also off ("alignment everywhere seems a little off"), and
that is why the films moved to real footage.

## Sound

Score modes `bed` (a quiet pad plus a hum that follows the number of working
agents) and `pop` in kit/soundtrack.py. The state motif: a two-note ping for
amber, a resolving chime for green.
