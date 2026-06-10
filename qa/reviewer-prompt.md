# QA Reviewer Prompt

You are reviewing one completed external QA run. Start from the run directory and read `manifest.json` before inspecting screenshots.

## Inputs

- `manifest.json`: the flow name, run status, ordered events, event notes, and PNG names.
- `docs/05-canvas-and-ux.md`: product expectations for canvas behavior, focus, tile interaction, resize behavior, text overflow, and visual stability.
- `qa/expectations/<flow>.md`: flow-specific expected states for each captured step.
- Event PNG files referenced by `manifest.json`.

## Review Procedure

1. Read `manifest.json` and identify the flow, run status, and ordered events.
2. Open every PNG referenced by the events and inspect it at full size.
3. Compare each PNG against `docs/05-canvas-and-ux.md` and `qa/expectations/<flow>.md`.
4. File each UX issue with `qa/file-finding.sh`.
5. When no finding is filed for a flow, record at least one `verified-working` note that names the flow, step, screenshot path, and the behavior that passed.

## Finding Command

Use this wrapper for each defect:

```bash
qa/file-finding.sh \
  --severity major \
  --summary "Tile header text clips during resize" \
  --expected "Header text remains readable and inside the tile chrome." \
  --observed "The title is clipped at the right edge after resizing." \
  --screenshot "qa-runs/window-resize-stress-20260509T120000Z/03-window-width-320.png" \
  --flow window-resize-stress \
  --step window-width-320
```

Allowed severity values are `critical`, `major`, `minor`, and `trivial`.

## Review Output

Write review notes beside the run as `review.md`. Include:

- Findings filed, with their fingerprint values.
- Duplicate findings skipped by fingerprint, when any are reported by `qa/file-finding.sh`.
- `verified-working` notes for flows or steps that match expectations.
- Any screenshot that could not be reviewed and why.
