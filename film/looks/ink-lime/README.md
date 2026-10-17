# Look: ink + lime

Used by `videos/which-tab` (r5.3, 2026-10-16). Tokens in code: `look.ts`
beside this file. The kit reads them; nothing in kit/ hard-codes them.

## Tokens

| Token | Value | Rule |
| --- | --- | --- |
| ground | `#0E0F0C` ink | The field. The end card fades to it. |
| text | `#F2F0E9` paper | Every headline and the wordmark. |
| textDim | paper at 56% | Secondary type. |
| accent | `#D2E823` acid lime | ONE accent. It means "finished" and nothing else. |
| no pink | | The old persona `#ff4f8b` is retired for this look. |

The film also uses status colours that belong to the film's story, not the
look: needs-input `#F0A53A`, failed `#EF5B4F`, and working at 62% paper
(videos/which-tab/constants.ts). The app's own colours (Ghostty Vesper, the
CLIs) are truth, so they come from the app and the CLIs, never from the look.

## Type

- Display: Schibsted Grotesk 600, tracking -0.032em, with `ss01` off. Not
  Geist, which was the old films' signature. Headlines are 84 px at 1080, in
  one slot at the top left, on the window's left edge, where the eye enters.
- Mono: JetBrains Mono, Ghostty's own default face, so a terminal reads as Ghostty.
- System (macOS chrome, the title bar and tabs): system-ui, which is SF Pro on a Mac.
- Wordmark: SF Pro Display 720, tracking -0.035em, beside the real
  `array-mark.svg` (website/public), with its viewBox cropped to the glyph's ink.
- URL: JetBrains Mono at 60% paper.

## Motion

- Words rise through a mask, one after another: 65 ms apart, each settling
  in 0.62 s on an exponential ease-out (tau 0.13 s). There is no overshoot,
  and the first 0.25 s carries most of the travel.
- A line leaves by lifting 22% of its size and fading over 0.35 s (ease-in).
- Camera and windows move on `cubic-bezier(.65,0,.35,1)`, never a bounce.
- Motion blur goes on fast moves only: on tab swaps (a horizontal smear) and
  on flights (from velocity relative to the target, capped at 10 px).
- Held things hold on whole pixels. No drift, ever (r4, measured with probes/jitter.py).
- End card in beats (research/22-end-cards): the line alone, 1.2 s, then a
  0.2 s fade and 0.25 s of empty ink. Then the lockup, fading in over 0.45 s
  with a 12 px rise, mark and word as one. The URL follows 0.3 s later. Then
  hold still for 2 s or more.
- Lockup proportions: H (cap height) 75 px at 1080, mark 1.4H, gap 0.5H ink to
  ink, URL ascender 0.5H, with its top 1.2H below the baseline.

## Sound

Score mode `tabs` (kit/soundtrack.py). It is sparse and dry: a soft tick per
tab, a low drone under the hunt, a breath at the beat, and a lift into the
pull-back. Array's own `bloom.wav` plays, unaltered, on the finish. Then a warm
pad, and one low bell on the lockup.
