# cmdk-spam Expectations

Flow: `cmdk-spam`

This flow repeatedly opens and closes the command palette, then captures the final open state.

## Step Expectations

- `initial`: The app window is visible, stable, and ready for keyboard input before the repeated Cmd-K sequence starts.
- `cmdk-spam-final`: The command palette is visible once, focused, readable, and not duplicated after repeated open and close cycles.

## verified-working Notes

When no finding is filed, record a `verified-working` note that confirms the final palette has readable text, no clipping, no overlap, and no duplicate palette layer.
