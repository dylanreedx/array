# Critique log · "What Array is"

Scores 1 to 10 per the brief: hook (would a stranger stop scrolling), readability at phone size
(9:16 viewed at 540 px wide), pacing (something changes every 3 to 5 s), truth (every label and
claim is real), craft (type, spacing, motion mass). Stop at 8+ everywhere and the reviewer agrees.
The reviewer is Dylan; the scores below are the director's own.

## Round 0 · first stills (2026-10-04)

No scores; four defects found before the first full render.

1. Bar 2 framed the whole zone instead of its agent row, so the sidebar showed at the left edge.
2. Bar 10's whole-window shot sat on a light desk (the stage used the page's light `--canvas`).
3. The lockup mark rendered as a sliver: Tailwind's preflight clamps every `img` to its box.
4. The hook's cutout was loose and showed the zone header stripe and drag dots.

## Round 1 · first full render

| Hook | Readability | Pacing | Truth | Craft |
| --- | --- | --- | --- | --- |
| 7 | 7 | 8 | 9 | 7 |

Three worst problems, fixed:

1. The hook held a still frame for 2 s. Now a slow push from 52% to 60% of the frame width.
2. Bar 3 framed three tiles with no clear subject. Now a soft dim around the tile the caption
   names, gliding with the lens through the tools in bars 4 to 5 and back for bar 9 (`track()`).
3. 9:16 framed whole zones: tiles illegible and window chrome above and below the canvas. Portrait
   now frames two columns, and follows the green wave tile by tile.

Also: the lockup dim went to 0.975 (the browser's white page showed through), bar 10 frames the
four agents instead of the whole window (green pills were 8 px tall), and the gate caught a stray
camera clamp from a 1x1 render tab collapsing the sidebar column (pinned in `lib/determinism.ts`).

## Round 2 · all formats

| Hook | Readability | Pacing | Truth | Craft |
| --- | --- | --- | --- | --- |
| 8 | 8 | 8 | 9 | 8 |

Gate: 0 stray dispatches, 0 console errors over 1440 frames. Audio: -14.0 LUFS, -2.26 dBTP,
lag 0 samples. Website suites: unit 89/89, e2e 44/44.

What still keeps scores from 9, for the next round or the next video:

- Bar 6 ("Zones hold a project.") is the weakest beat: after the pull-back nothing moves for about
  1.5 s, and the zone header rollup is too small to read in 16:9.
- The Browser shows raw appcast XML. True, but not attractive; a rendered page would read better.
- The hook cutout still shows a thin ring of the tile header around the pill.
- The square cut is the least considered format: it reuses the landscape framings.

## Lessons for the next video

- Frame by subject and choose the framing by aspect (`pick(wide, tall)`); a phone never frames a
  whole zone.
- A dimmed surround (`Spotlight`, amount 0.5, no glow) tells the viewer which tile the caption is
  about without cutting away from the canvas.
- Measure every geometry the film depends on from the DOM, and witness it (`PillProbe`).
