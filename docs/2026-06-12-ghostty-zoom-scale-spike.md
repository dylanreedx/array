# Ghostty zoom content-scale spike (CON-132)

Date: 2026-06-12

## Question

Can Continuum re-raster Ghostty at zoom settle by calling `ghostty_surface_set_content_scale` while keeping the logical surface size fixed, without changing the terminal grid (columns/rows)?

## Harness

A throwaway manual flag was added: `--ghostty-zoom-scale-spike`.

It creates a live Ghostty surface, keeps the NSView frame fixed at 900×600 pt, sweeps content scale from 0.5 to 2.0, ticks libghostty after each change, and logs `ghostty_surface_size`.

Raw artifact: `qa-runs/ghostty-zoom-scale-spike-2026-06-12T205010Z/scale-sweep.log`

```csv
scale,columns,rows,width_px,height_px,cell_width_px,cell_height_px,elapsed_ms
0.50,256,54,1800,1200,7,22,19.48
0.75,256,54,1800,1200,7,22,19.12
1.00,256,54,1800,1200,7,22,24.66
1.25,224,46,1800,1200,8,26,16.73
1.50,179,39,1800,1200,10,30,16.68
1.75,163,35,1800,1200,11,34,23.47
2.00,137,30,1800,1200,13,39,18.19
```

## Finding

No-go for a content-scale-only settle re-raster if the requirement is grid stability. With `width_px`/`height_px` fixed at 1800×1200, changing content scale changes reported cell dimensions, and the grid changes from 256×54 at scale 0.5–1.0 to 137×30 at scale 2.0.

The current behavior is monotonic and internally consistent, but it is not rounding-stable (not ±0 columns/rows). It would visibly reflow TUIs during zoom settle.

## Recommendation for T3

Use a preserve-grid call sequence instead of content-scale-only:

1. Capture the pre-settle grid (`columns`, `rows`) and reported cell pixel size.
2. Apply `ghostty_surface_set_content_scale` for raster crispness.
3. Immediately compute and call `ghostty_surface_set_size(columns * cell_width_px, rows * cell_height_px)` using the post-scale reported cell dimensions, or an equivalent libghostty-provided grid-preserving size if exposed.
4. Assert in the T3 check that columns/rows before and after settle are unchanged.

This keeps the fallback described in CON-132 necessary: derive pixel size from reported cell dimensions so the grid is preserved by construction.
