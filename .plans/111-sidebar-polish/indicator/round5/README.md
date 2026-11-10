# Expanded active groups — round 5

Still explorations for Dylan to choose before implementation. No production drawing code or settings changed; Classic is untouched. Nothing merged into or relaunched in the shared preview.

Open `overview.png` for all nine, or `duplex-sheet.png`, `gradient-sheet.png`, and `sheen-sheet.png`. Each style sheet has three variants side by side, light above dark. Each appearance includes the screenshot case (one working helper), then a larger group (one working and two finished helpers). Each scene includes an inactive teal group for contrast; the active group uses the red identity colour Dylan saw.

| Option | Idea |
| --- | --- |
| Duplex A — One lit card | Put the opposed corner fields at the corners of the entire family card. |
| Duplex B — Working focus | Keep the first field at the lead; centre the second beside the running helper. |
| Duplex C — Quiet echoes | Feather the lead light into soft, low-intensity pools around every helper glyph. |
| Gradient A — One flowing wash | Carry a single identity wash continuously through the full group. |
| Gradient B — Soft cascade | Start at full lead strength and dissolve the wash smoothly down the family. |
| Gradient C — Colour thread | Fade the surface wash beneath the lead, then carry its identity through the actual tree connector and subtle glyph light. |
| Sheen A — One coated card | Coat the entire family as one surface, with one shared resting sweep. |
| Sheen B — Soft canopy | Thin the lead's coating continuously toward the card foot, including the helpers without a seam. |
| Sheen C — Satin rim | Move most of the coating to a fine, even perimeter around the family, with a soft lead veil and quieter centre. |

## Capture provenance and review

36 native WindowServer PNGs: 3 styles × 3 variants × 2 appearances × 2 group sizes, at 360pt sidebar width and 2× scale. Filenames encode style, variant, appearance and helper count. The sheets only compose and label those images; surfaces and text were rendered by the real AppKit sidebar and its real expanded group cells. Production typography, group geometry, palette and neutral surfaces were retained. All variant light is drawn in the group's shared coordinate space, clipped only to its overall rounded silhouette and the existing cell slices; no one-sided border was added.

The existing screenshot fixture was temporarily adapted behind `ARRAY_INDICATOR_ROUND5=1`, then restored byte for byte. The temporary drawing prototype remains outside the repository at `/tmp/indicator-r5-prototype-final.swift` for the follow-up; it is not shipping code or a new verifier. Every native scene was reviewed in the sheets, then at native scale in the inspection sheets. No internal horizontal seam or clipped light remained. Sheen C's initial heavy perimeter was reduced to a one-point even rim before the final capture.

These are still poses, not motion implementation or verification. The selected designs will retain the approved render-server signatures: Duplex's second-field breath (6s), Gradient's continuous orbit (60s), and Sheen's single sweep then rest (6s). Only the active group will animate; Reduce Motion will keep the selected treatment static. No timer, main-thread animation loop or idle-group animation is proposed.

Build and the targeted fixture capture passed. The first temporary build failed on a mistyped proposal type name; corrected before capture. No matrix, motion clips or live-app performance checks were run for this still-only review. No preview merge, rebuild, relaunch, preference write to an app domain, or push was performed.
