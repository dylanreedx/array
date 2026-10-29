# Agent control: bounded interactions and build loop — 2026-10-29

The final focused gate passed **12/12**; real native MCP companion build/control
passed **2/2**. The actual companion was built, installed and launched on the
receipt-owned disposable simulator, while its workspace was switched away.
Retry retained operation identity and the same helper survived. Hidden capture
acknowledged 1 FPS and delivered **4 frames in 3 seconds**; interactive rate
restored. The build loop took **67.59s** in this run. This is not a comparison of
build performance or a CPU/RSS/physical-display benchmark.

`evidence-origin.json` records source paths and SHA-256 digests. The offline log
is a verbatim suffix containing every behavioral leg and the matrix summary;
compiler diagnostics are omitted. Full logs and the detailed dated handoff are
in `qa-runs/overnight-2026-10-29/ios-control/`.

- `device-build-report.json`, `device-api-report.json`: live outcomes and exact
  metric endpoints; no actual provider model turn is claimed.
- `owned-resource-cleanup.json`: six exact source/guest IDs absent, ledgers empty,
  DerivedData removed, compiler log budgets and provenance retained.
- `key-partial-red.log` / `key-partial-green.log`: ambiguous key-down cleanup
  failed before intent tracking and passes after it.
- `capture-profile-negative.log`: disabling native frame-rate reduction fails
  the production bridge's behavioral witness.
- Appearance PNGs and actual companion JPEG were visually reviewed. No phone
  notification permission was enabled and no synthetic push was sent.

**Bundle release gate remains RED**: `dev-bundle-manifest.json` records the second
fresh isolated failure of `--terminal-theme-fidelity-check` (`spawned terminal
surface missing`). Seven other bundle checks, code signing, LaunchServices smoke
and production-state pollution guards pass. Cause is not established; coordinator
was notified to route to the terminal/theme/canvas owner. No source outside this
feature was changed to mask it. `dev-bundle-build.log` proves the shared Desktop
dev bundle rebuilt with the standard script, without persistent relaunch.

Changes are uncommitted. Full release matrix, signed/notarized release bundle,
real model turns, sustained two-device CPU/RSS, hard host-crash compiler cleanup
and Xcode 27 compatibility are not verified. Semantic inspection remains proposed.
