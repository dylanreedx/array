# Format: exploded view (UNBUILT)

Status: an idea, never built. Source: research/20 idea 3 (2026-10-15).

The real canvas tilts into an isometric engineering drawing. Zones lift as
slabs and tiles rise in z on a stagger. Leader lines draw out to part callouts
(`01 AGENT · Claude Code`, `02 BROWSER · localhost:3000`, `03 DIFF`,
`04 TERMINAL`). The view orbits slowly, then snaps flat back into the real
app. It loops.

## Beats (about 12 s loop, as proposed)

| Beat | What happens |
| --- | --- |
| Flat | The real canvas, still |
| Lift | Tilt to isometric; zones and tiles separate in depth |
| Callouts | Leader lines and labels, one part at a time |
| Orbit | A slow orbit around the assembly |
| Snap | Back to flat; the loop seam |

## Open questions before building

- CSS 3D on per-tile crops of a real take (rects from frames.json) keeps
  text crisp. Check it holds at the needed angles before committing.
- It needs one wide take with every tile in frame (a plate).
