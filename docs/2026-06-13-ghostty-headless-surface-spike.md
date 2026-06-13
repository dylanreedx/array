# Ghostty headless surface spike (CON-41)

Date: 2026-06-13

## Question

Can a Ghostty PTY/session outlive its rendering surface for Snapshot-tier terminal zones? If not, what does the hidden-surface fallback cost?

## Harness

A throwaway manual flag was added: `--ghostty-headless-surface-spike` (not in the matrix). It creates ten `GhosttyTerminalView` instances backed by `/usr/bin/yes`, marks the AppKit views hidden, keeps the surfaces alive, ticks libghostty for 60 seconds, and logs process RSS plus surface liveness.

Raw artifact: `qa-runs/ghostty-headless-surface-spike-2026-06-13T004159Z/hidden-surfaces.log`

```csv
elapsed_seconds,resident_kb,surfaces_alive,first_surface_exited,first_surface_text_bytes
0,172208,10,false,59
1,174560,10,false,59
2,187552,10,false,59
3,195872,10,false,59
56,237184,10,false,59
57,237184,10,false,59
58,237184,10,false,59
59,237184,10,false,59
60,237184,10,false,59
```

## API finding

The vendored `ghostty.h` exposes `ghostty_surface_new`, `ghostty_surface_free`, `ghostty_surface_process_exited`, `ghostty_surface_set_occlusion`, sizing/input/read APIs, and app-level lifecycle calls. It does not expose a separate PTY/session handle or any API to destroy a surface and later recreate a new surface attached to that existing PTY/session. In the current Continuum integration, `GhosttyTerminalView.closeSurface()` frees the only handle that represents both rendering and the owned child process path.

Answer to (1): no supported surface-less PTY path was found in the public GhosttyKit API currently vendored here. Treat surface destruction as terminal-runtime destruction unless a future Ghostty API exposes a stable session/PTY handle.

## Hidden-surface fallback measurement

Ten hidden surfaces streaming `/usr/bin/yes` stayed alive for the full 60-second run (`surfaces_alive=10`, `first_surface_exited=false`). RSS rose from 172,208 KiB at t=0 to 237,184 KiB at t=60: +64,976 KiB total, about +6.3 MiB per hidden surface for this stress case after startup/scrollback warmup.

The first surface's readable text remained non-empty (59 bytes from `ghostty_surface_read_text`), proving the hidden surface was not merely an inert placeholder.

## Recommendation

Use hidden/offscreen surfaces as the E6 terminal Snapshot fallback. Do not implement a headless-PTY tier by freeing `ghostty_surface_t`; the current API gives Continuum no way to reattach rendering to the same live child process. Snapshot-tier terminal dehydration should instead hide/occlude the AppKit/Ghostty surface, keep the runtime and `ghostty_surface_t` alive, and re-show it on hydration.

Follow-up for implementation: call `ghostty_surface_set_occlusion(surface, true)` when snapshotting if it suppresses rendering work without killing the child process, and add a deterministic check that `sleep 999` survives hide/snapshot → rehydrate → input round-trip.
