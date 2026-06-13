# DD-014 stray strip-windows audit

Ticket: CON-118
Date: 2026-06-13

## Finding

The only normal tile spawn path that can create extra process-owned windows is the Ghostty terminal path. Browser, note, file, and file-tree tiles install AppKit/WebKit views inside the canvas; they do not create top-level `NSWindow`s in Continuum's spawn code.

`GhosttyTerminalRuntime.attach(to:)` creates a `GhosttyTerminalView`, then adds it to a `TerminalHostView`. Before this change, `GhosttyTerminalView.init` immediately called `ghostty_surface_new` while `view.window == nil`. That gave GhosttyKit an unattached `NSView` pointer with `GHOSTTY_SURFACE_CONTEXT_WINDOW`, which is a plausible source of fallback/placeholder CoreGraphics strip windows.

## Change

Surface creation is now delayed until `GhosttyTerminalView.viewDidMoveToWindow` sees a non-nil AppKit window. This preserves the embedded `NSView` path while avoiding surface creation against an unattached view. The method is guarded by `surface == nil` so reparenting does not create duplicate surfaces.

## Regression check

`--stray-window-audit-check` samples `CGWindowListCopyWindowInfo` for this process at four points:

1. baseline,
2. after a normal AppKit main window is ordered front,
3. after a Ghostty terminal runtime is attached,
4. after close.

The check fails if terminal attach increases the process-owned CG window count beyond the main-window baseline. It writes the measured window metadata to `qa-runs/<timestamp>/stray-window-audit/manifest.json` for diagnosis.

## Remaining scope

If future hardware/WebKit/Ghostty versions add a documented auxiliary window, the check should be adjusted only with measured artifact evidence and a narrow signature. No suppression is currently committed.
