# Format: pull-back reveal

Built: `videos/which-tab` ("Which tab was that?", 16.5 s, r5.3, 2026-10-16).

A cramped, familiar "before" fills the frame. Then one continuous move carries
it into Array, so the answer is a single camera move. The move only works
because Array is spatial, which is why it suits a "why should I use this" film.

## Beats (which-tab, 60 fps)

| Beat | Time | What happens | Job |
| --- | --- | --- | --- |
| Hook | 0.0-1.2 | The "before" is already on screen at frame 0 (it is the thumbnail). The headline asks the viewer's own question. | Name the pain in under a second |
| Hunt | 1.2-5.0 | The before gets worse: something changes, you go to it, and something else changes while you look. Fast, but readable. | Make the pain felt |
| Beat | 5.0-6.1 | Everything stops. The line changes to name the cause. | A breath before the turn |
| Turn | 6.1-8.8 | Shared-element move: each piece of the before (tab, window) flies to its own counterpart in the real app (tile), while the real camera pulls back. | The answer, shown as one move |
| Payoff | 8.8-11.1 | The real app, wide and still. The thing you were hunting for finishes, live, on camera. | Proof, picture only |
| End | 11.1-16.5 | The promise line alone. Then the lockup alone, then the URL. Hold still. | Brand, call to action |

Proportions that worked: the hook and hunt take about 30% of the film, the
turn 15%, the payoff 15%, and the end card 30%. The end card is long because
each beat gets its own empty field.

## What makes it work

- The before and after are the same story. The tabs are the tiles, with the
  same names, tasks and CLIs, so the eye follows one thing across the cut.
- The camera move is the app's own camera in a real take. The film never
  zooms a screenshot, because zooming a still turned to mush in the artifact pilot.
- Every flying element hands off to real pixels, which are never blank
  (kit/handoff.tsx and its plate take).
- A held frame never drifts. Even a slow drift snaps to whole pixels and reads
  as jitter.

## Needs

Two takes from the recorder: the live pull-back, and a plate held wide with
the same content. Also kit/tui for the before, kit/handoff, kit/blur and
kit/lockup. Probes: blank-faces, plate-parity, jitter, still-hold, lockup.
