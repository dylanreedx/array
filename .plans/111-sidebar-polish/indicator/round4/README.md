# Round 4 — a minute of travelling gradient light

Gradient's light direction circles the card over **60 seconds**, keeping the original identity colour, alpha and colour stops. It visits each side instead of merely expanding its reach. Opposed gradient endpoints follow a closed circle on Core Animation's render server; the wash itself stays on the same card. The existing active-row and Reduce Motion gates are unchanged: selected-only rows remain static, and Reduce Motion retains the original left-to-right wash. Duplex, Sheen, current and inactive-row motion have no code changes.

| Appearance | 10 seconds at real time | Whole 60-second loop in 10 seconds, **6× speed** |
|---|---|---|
| Light | [gradient-light-realtime.mp4](gradient-light-realtime.mp4) | [gradient-light-loop-6x.mp4](gradient-light-loop-6x.mp4) |
| Dark | [gradient-dark-realtime.mp4](gradient-dark-realtime.mp4) | [gradient-dark-loop-6x.mp4](gradient-dark-loop-6x.mp4) |

The real-time clips show source seconds 10–20. All four encoded clips are 10 seconds / 24fps / 240 decoded frames. Capture sampled the real off-display sidebar fixture at 12fps for 62 seconds per appearance. The time-lapses compress the first full minute at 6×; frames were duplicated/dropped only to encode 24fps, with no interpolation or synthetic motion. The existing recorder was temporarily adapted to stream PNGs rather than retaining a minute of images in memory; its source was restored before the final build. No new verifier tooling is committed.

Each encoded clip was decoded and every frame inspected in the accompanying two-part contact sheets. The `*-wrap.png` strips also show source frames before and after the minute boundary. The gradient wraps without a visible jump, flash or reversal in either appearance. Background-only mean absolute RGB difference at 0s versus 60s is below 0.024 on a 0–255 channel scale (see `wrap-metrics.json`); this supports the visual review, and does not claim the whole sidebar is pixel-identical because its existing status glyphs still move.

Validation: capture build passed; restored-source `swift build --product Array` passed (41.92s); normal current-style `--sidebar-screenshot-check` passed with 48 images / 4 widths / 2 appearances. `git diff --check` passed. No full matrix or separate Reduce Motion enabled recording was run.
