# Round 6 — expanded active groups

- **Duplex B / Working focus:** the first light stays on the lead; the second breathes beside the first visible working helper. With no running helper it returns to the opposite corner of the lead through a 600ms Core Animation ease. The group model carries the start position and absolute timestamp across cell replacement.
- **Gradient B / Soft cascade:** the approved identity wash stays full on the lead, dissolves down the family, and keeps the 60-second continuous orbit.
- **Sheen / staggered satin:** the lead retains its coated surface; each helper has a quieter, slightly inset identity-tinted panel. The sweep crosses the lead then each helper at 220ms offsets and rests for the remainder of the six-second cycle. The faint one-point even satin rim is retained around the family; it coheres with the inset panels without separating them from the lead.

Single and collapsed agents continue through the original approved card renderer. Classic is unchanged. Only the active expanded family paints/animates shared light. No timer, display link, per-frame app work or idle-row continuous animation was added. Reduce Motion leaves static surfaces and removes the layer animations; the existing display-preference notification relayouts the shared light.

## Clips and review

| Style | Light | Dark |
| --- | --- | --- |
| Duplex | [duplex-light.mp4](duplex-light.mp4) | [duplex-dark.mp4](duplex-dark.mp4) |
| Gradient | [gradient-light.mp4](gradient-light.mp4) | [gradient-dark.mp4](gradient-dark.mp4) |
| Sheen | [sheen-light.mp4](sheen-light.mp4) | [sheen-dark.mp4](sheen-dark.mp4) |

All six clips are six seconds at 12fps, H.264. Each was decoded to 72 frames and reviewed frame by frame in its `*-frames.png` sheet, with native-scale still inspection. All three motions play; the Sheen clips include the complete lead-to-helper stagger and rest. Duplex and Sheen wrap quietly through their resting pose; Gradient's clip shows six seconds of its continuing 60-second cycle. Light crosses the lead/helper boundary without a hard seam; no clipped glow remained. Native stills are `style-appearance.png`.

The existing `SidebarMotionFilm` fixture was temporarily adapted with isolated defaults and red identity colour, one working plus two finished helpers and an inactive group. Its layer clocks were posed to show the whole stagger. The recorder was restored byte for byte. Its initial attempt tried to modify a read-only CA animation returned by the layer; copying that animation fixed capture. No new verifier/recorder tooling is committed.

## Targeted verification

Production build passed. Requested source-bench legs passed: `--sidebar-screenshot-check` (48 images), `--sidebar-indicator-settings-check`, `--sidebar-ownership-check`, `--sidebar-sort-check`, `--inbox-parent-fold-check`, `--shared-agent-sidebar-check`. The parent-fold leg's additional glyph-morph assertion failed once under concurrent compilation and passed on a targeted rerun after capture. Logs: `/tmp/r6-verified-*.log`, `/tmp/r6-fold-retry.log`, `/tmp/r6-absolute-settings.log`.

The settings witness still uses actual Settings mouse events, isolated defaults and fresh reads. Its rendering expectation changed because expanded groups now paint through a shared sibling layer, rather than inside only the lead's subview. It asserts that shared renderer's actual fields/rim/masks and animations, captures the real row, checks no duplicate row-local motion, and verifies static Reduce Motion. An added helper-completion assertion exposed and verified the actual focus relocation defect; the transition now survives both replacement and repeated layouts on one absolute timeline.

No full matrix or push. Final timing and preview confirmation are recorded separately after integration.
