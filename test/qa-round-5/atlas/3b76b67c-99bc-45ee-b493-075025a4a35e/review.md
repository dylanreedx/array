Initial UX audit visual review notes.

- review.md: Layer A `palette-leak-check` screenshot review used `fixture-initial-ux-audit/full-page.png`, `bands/01.png`, and `compare/01.png`; visual scoring J= is N/A because this task executes the QA pass and files backlog items rather than changing deterministic rendering.
- verified-working: `canvas-drag-resize` Layer A produced a final-state compare PNG with readable tile chrome and no incoherent overlap in the captured canvas.
- finding filed: `palette-leak-delta` exceeded the perf baseline and was filed through `qa/file-finding.sh` with fingerprint `b26118e71426e710032a38fd2d3da3df5c653037f111e8dd8c069dfab5b5eb74`.
- skipped external visual review: the Layer B top-level screenshots were not reviewable because `screencapture` failed before each first external event PNG.
