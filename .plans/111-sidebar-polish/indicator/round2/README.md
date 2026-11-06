# Round 2 — quiet living selection

Current reference: a 0.75pt full perimeter with a paced clockwise light every 3s, 64pt identity halo and 18pt contrast core (up to 90% contrast alpha); constant speed, no resting interval.
Working titles additionally shimmer through a 70pt band every 2s; helper dots stagger from 28% to 90% opacity over 1.2s. These are render-server animations on stable agent phases, not UI timers.

- Gradient: original caf22324 wash, its reach expanding from 55% to 75% and back over 6s with ease-in/out. No travelling point or border.
- Halo: clear centre, even identity hairline and small halo breathing between 55% and 90% opacity over 6s with ease-in/out. No tinted panel.
- Inset: quiet tinted panel and neutral inset hairline, one broad low-contrast surface sheen crossing during 0.9–2.7s of each 6s loop, otherwise resting.

Startup switch remains `-SidebarActiveIndicatorStyle current|gradient|halo|inset` on dev builds only. Only route-active cards animate; selected cards retain static treatments. Reduce Motion uses the static treatment. Existing ownership sweep is suppressed for alternative styles so the new indicator has one motion signature. Animation changes occur at state/layout seams, never per frame; existing animations are retained through identical layouts.

Clips (each 6s, H.264, 12fps, 72 decoded frames):

| Style | Light | Dark |
|---|---|---|
| Current | [current-light.mp4](current-light.mp4) | [current-dark.mp4](current-dark.mp4) |
| Gradient | [gradient-light.mp4](gradient-light.mp4) | [gradient-dark.mp4](gradient-dark.mp4) |
| Halo | [halo-light.mp4](halo-light.mp4) | [halo-dark.mp4](halo-dark.mp4) |
| Inset | [inset-light.mp4](inset-light.mp4) | [inset-dark.mp4](inset-dark.mp4) |

The existing `SidebarMotionFilm` recorder was temporarily adapted to put its fixture window at x=-10000, open the coloured lead, capture 72 frames over six seconds through WindowServer, and write frame PNGs. This captures actual render-server animation on an off-display fixture. FFmpeg encoded the frames, and every encoded clip was decoded back to 72 PNGs for frame-by-frame visual inspection. The recorder source was restored before the final build; no new verifier or recording tooling is committed. Sheet and per-style stills use the same fixture. The existing non-indicator status glyphs remain visible.

The halo shadow initially filled the entire rounded rectangle; visual review caught the resulting tint. Its shadow now follows the stroked ring only, and both halo clips were re-recorded and reviewed. The gradient expands and contracts continuously; the halo breathes continuously; the inset sheen leaves the surface before wrapping during its rest interval. All three have matching loop endpoints in their layer keyframes. No production timer, display link, or per-frame redraw was added.

Geometry answer: **not pre-existing**. With all Sources restored byte-for-byte to `d41dad04` (confirmed with an empty `git diff d41dad04 -- Sources`), a fresh build and the untouched `--sidebar-screenshot-check` passed with 48 images. Round 1's failure came from my temporary substitution of `SidebarPolishFixtures.rows` into the screenshot suite's density fixture. That substitution is reverted; no geometry fix was needed.

Reduce Motion is wired through the existing row preference closure and the system accessibility preference; its static fallback removes the new layer animations. A separate capture with the system Reduce Motion preference enabled was not run. The full matrix was not run, as requested. Installed apps and the live tmux server were untouched.

Final verification: restored-source `swift build --product Array` passed (54.13s); normal `--sidebar-screenshot-check` on the final implementation passed, 48 images / 4 widths / 2 appearances (`/tmp/indicator-round2-final-captures/manifest.json`). Origin comparison also passed (`/tmp/indicator-origin-confirm-captures/manifest.json`). All four temporary film runs completed with 72 frames per appearance; the corrected halo run likewise completed. Every final MP4 decoded successfully. `git diff --check` passed. Bench inventory was run at pickup and completion; this requested review bench is retained with local commits, never pushed.
