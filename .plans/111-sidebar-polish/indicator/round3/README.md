# Round 3 — quiet surface motion

Dev startup key: `SidebarActiveIndicatorStyle`. Values are `current`, `gradient`, `sheen`, `duplex`; old `halo` / `inset` values fall back to `current`. Current remains the default and production ignores the key.

- Current: unchanged original ownership sweep, text shimmer and helper dots.
- Gradient: unchanged round-2 identity wash, reach gently widening from 55% to 75% and back over six seconds.
- Sheen: a continuous tinted surface, with the recessed neutral hairline removed; the single broad sweep still crosses during 0.9–2.7 seconds of its six-second loop, then rests.
- Duplex (chosen): two broad radial identity fields at opposing corners. The second field softly gains and releases focus over six seconds, shifting the balance of light across the card without a border, moving dot or texture.

Inactive rows across the three alternative styles acknowledge hover with a single 0.2% compression and 280ms ease back to their exact resting scale. The model transform never changes; CA removes the animation on completion. No animation is added while a row is idle, regardless of list size. Current is unchanged. Reduce Motion suppresses both this response and the alternative active loops; interaction fills apply statically. No per-frame main-thread work, timer or display link was added.

## Exploration

`concepts.png` compares three concepts in light and dark before selection. Rejected exploration code was removed.

- Duplex: opposed soft light fields, the strongest separation from both a wash and a framed card; built.
- Porcelain: a pale coated panel with a thin even neutral perimeter; saved as stills only.
- Contour: a translucent two-pixel identity perimeter with a clear centre; saved as stills only.

## Motion review

All clips are six seconds, 12fps, 72 frames, H.264, captured from the off-display real sidebar fixture through WindowServer. Each MP4 was decoded back into 72 PNGs and every frame visually inspected. The accompanying `*-frames.png` sheets retain that inspection sequence. Active loops are continuous at wrap; the sheen leaves the surface before its resting interval and wraps off-card. The inactive clip hovers a standalone inactive agent twice and returns it to rest; it includes the same active Duplex lead for comparison.

| Clip | Light | Dark |
|---|---|---|
| Gradient | [gradient-light.mp4](gradient-light.mp4) | [gradient-dark.mp4](gradient-dark.mp4) |
| Sheen | [sheen-light.mp4](sheen-light.mp4) | [sheen-dark.mp4](sheen-dark.mp4) |
| Duplex | [duplex-light.mp4](duplex-light.mp4) | [duplex-dark.mp4](duplex-dark.mp4) |
| Inactive hover | [inactive-light.mp4](inactive-light.mp4) | [inactive-dark.mp4](inactive-dark.mp4) |

`sheet.png` compares the final active surfaces. `SidebarMotionFilm` was temporarily adapted for capture and restored; no recording or verifier tooling is committed. No full matrix was run. The pre-merge preview built successfully but its existing `--inbox-parent-fold-check` failed “motion: opening a parent must unfold its children instead of only fading their final positions”; this predates the round-3 merge. Open/close latency is measured separately with that check's existing measurement loop after merging the performance fixes and indicator changes in the preview bench.
