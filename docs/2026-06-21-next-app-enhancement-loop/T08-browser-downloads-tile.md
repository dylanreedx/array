# T08 — Browser downloads tile/drawer

Status: draft implementation-ready candidate

## Goal
Make browser downloads visible and manageable inside Continuum instead of silently relying on default system behavior.

## Implementation decision
Add a Downloads surface as a tile or inspector panel only if existing download delegate already tracks enough events. Prefer a `Downloads` panel within Browser Inspector if T01–T07 landed; otherwise add a simple global downloads tile.

## Scope
- List recent downloads: filename, source URL, destination, state, bytes if known.
- Reveal in Finder action only for completed downloads.
- Clear completed action.
- Persist recent download metadata, not file contents.

## Out of scope
- Download manager rewrite.
- Pause/resume unless already supported by WebKit hooks.
- Opening arbitrary external URLs.

## Code seams
- Existing `--browser-download-check` implementation
- `WKDownloadDelegate` usage if present
- `TileActionCatalog`

## Deterministic checks
Add app flag:

```text
--browser-downloads-surface-check
```

Must trigger a controlled download fixture through real WKWebView delegate path and verify surfaced metadata.

## Stop condition
If current download delegate only proves policy but does not expose reliable progress/completion, convert this ticket to a spike and output a follow-up implementation ticket.
