# drag-past-edge Expectations

Flow: `drag-past-edge`

This flow drags the primary canvas tile beyond the visible top-left edge to preserve clamp and stability evidence.

## Step Expectations

- `before-drag`: The canvas and first draggable tile are visible before the external pointer drag starts.
- `after-drag-past-edge`: The tile remains recoverable, the canvas does not tear or jump, and visible chrome remains readable after the drag.

## verified-working Notes

When no finding is filed, record a `verified-working` note that confirms the dragged state is stable, readable, unclipped where visible, and free of incoherent overlap.
