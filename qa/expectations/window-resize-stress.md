# window-resize-stress Expectations

Flow: `window-resize-stress`

This flow resizes the app window through narrow and wide widths to check layout stability.

## Step Expectations

- `before-resize`: The app window is visible at the starting size before scripted resizing.
- `window-width-320`: The narrow layout keeps controls reachable, text readable, and tile chrome inside the window.
- `window-width-480`: The compact layout does not overlap controls or clip primary labels.
- `window-width-768`: The medium layout preserves canvas focus and readable tile headers.
- `window-width-1024`: The standard layout keeps canvas content stable without sudden position jumps.
- `window-width-1440`: The wide layout uses available space without stretching chrome text awkwardly.
- `window-width-1920`: The widest captured layout remains stable, readable, and free of accidental overlap.

## verified-working Notes

When no finding is filed, record a `verified-working` note that names at least one width and confirms readable text, no clipping, and no overlap.
