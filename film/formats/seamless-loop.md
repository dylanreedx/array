# Format: seamless loop

Built: `videos/hero-loop` ("In view", 12 s, silent, r3, 2026-10-04), from the
website demo components (retired; take the structure, not the picture).

A silent loop with no start and no end. The last frame equals the first, so
it plays forever in a README, a hero slot or a feed. One full cycle of state
happens: working, then needs you, then answered, then everything done, then
working again.

## Beats (6 bars, 120 BPM, a bar = 2 s)

| Bar | What happens |
| --- | --- |
| 1 | The settled state: everything working |
| 2 | One thing changes and asks for attention; the camera drifts to it |
| 3 | It gets answered, and something new is launched |
| 4 | The new thing lands and settles in |
| 5 | Pull back; everything finishes in a wave on the beat |
| 6 | Everything starts again, and the camera eases back to the bar-1 framing so the seam is invisible |

## What makes it work, and what didn't

- A seam check proves it: the state at the last frame plus one equals frame 0,
  and the pixels differ only by in-frame motion (legacy scripts/check-loop.ts).
  Gyro cycles round to a whole number per loop.
- Didn't work as the main film. With no context, no narration and no hook,
  it couldn't stand alone on social (TASTE.md, 2026-10-04). Use it as a
  website hero or a README clip, cut from another film's timeline.
