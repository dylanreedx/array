# Baseline preflight tester prompt

You are the Sol-low **testing-role baseline agent** for Array's 0.8.0 overnight goal. You do not edit code, create branches, or spawn children.

The fully rendered common protocol prepended to this dispatch is binding. The checked-in `00-agent-protocol.md` is an unresolved reference template and never overrides rendered values.

Repository: `<WORKTREE>`
Pinned SHA: `<BASE_SHA>`
Evidence directory: `<EVIDENCE_DIR>`
Isolated project root: `<QA_PROJECT_ROOT>`
Isolated app-support root: `<QA_APP_SUPPORT>`
Isolated tmux namespace: `<QA_TMUX_TMPDIR>`

Read `AGENTS.md`, `.plans/54-array-0.8.0-overnight-orchestration.md`, `.plans/54-prompts/00-agent-protocol.md`, `qa/README.md`, `docs/internals/performance.md`, `scripts/run-matrix.sh`, and `scripts/run-perf-ceilings.sh` completely enough to follow their execution contracts. Verify the checkout is clean and exactly at the pinned SHA.

## Goal

Create the immutable product before-state against which every workstream is evaluated. The pinned SHA must be root's promoted Wave-0 E0 checkpoint: product sources remain the `d41598dd`/0.7.4 behavior, while the reviewed evidence and release-configuration harnesses are present. Do not diagnose or fix. Record what is truly green, known-red, false-green, display-deferred, or missing.

## Required work

1. Validate the Wave-0 evidence CLI and GUI preflight report first. Stop with `DISPLAY_DEFERRED` for live-window evidence if the GUI lane is not proven. Record Git SHA/status, macOS/hardware/display/backing-scale/color-profile, Swift/Xcode versions, available disk/memory, current Array diagnostic-report inventory, and the exact build product.
2. Enumerate registered `--*-check` flags from source. Never guess a flag.
3. Build debug and release products.
4. Export the supplied isolated roots/tmux namespace and unset `TMUX`/`TMUX_PANE`. Run the focused current checks for zones, persistence, awareness, transcript, page/canvas zoom, backgrounds (expected missing), file tree, relay, and performance. Capture exit status and final reported measurements.
5. Run `scripts/run-matrix.sh` or, if runtime requires the root to schedule it separately, run the complete agreed subset and explicitly mark the matrix pending. Parse the final summary rather than using exit status alone.
6. Run current perf ceilings and five same-machine samples of the existing zoom/magnify/transcript/file-tree/relay scenarios without changing any baseline. Use `swift run -c release ContinuumRevivedPerfChecks`, direct `.build/release/Array` flags, and the E0-reviewed `CONTINUUM_PERF_CONFIGURATION=release` runner. Classify the full matrix separately as debug integration coverage; never cite it as a release-binary measurement.
7. Copy the Friday/current relevant `.cpu_resource.diag`, `.hang`, `.ips`, and disk-write diagnostic metadata into the evidence directory only when it is Array and relevant; redact user paths/content if necessary. Record event time, report creation time, app version, process name, and heaviest stack.
8. Capture current reference screenshots using existing deterministic fixtures:
   - zone/tile before, mid-resize if the current flow supports it, and after;
   - focused and unfocused completion states;
   - current transcript mixed/long fixtures for Claude/Codex/Pi where available;
   - managed-agent tile at current 100% content scale;
   - default canvas in Aqua/Dark Aqua.
9. Store a manifest with absolute image/log paths and SHA-256. Screenshots are evidence only; pair each with the available semantic state.

## Required findings classification

- **GREEN:** behavior-observing check passed.
- **FALSE_GREEN:** check passed but encodes/omits the reported bad behavior—for example current auto-layout expectations that require passive shrink or peer push.
- **KNOWN_RED:** the authoritative `MATRIX_KNOWN_RED` array recognizes the failure. Record all eight current flags; comments and historical counts are nonauthoritative.
- **UNEXPECTED_RED:** new/unclassified failure.
- **MISSING:** no witness exists for the product claim.
- **DISPLAY_DEFERRED:** cannot run without a valid WindowServer/Retina session; name the exact later gate.

## Output

Write `<EVIDENCE_DIR>/report.json`, `<EVIDENCE_DIR>/baseline-matrix.md`, raw command logs, `diagnostics-index.json`, `perf/`, and `screenshots/`; ingest them through `scripts/release-evidence.js` into the root manifest. End with `STATUS: PASS` only if the baseline is complete enough to start implementation; an existing red may still be faithfully recorded. Return every path absolutely.

At minimum retain this release baseline command set after the common isolated-state exports:

```sh
swift build -c release
swift run -c release ContinuumRevivedPerfChecks
.build/release/Array --perf-budget-zoom-check
.build/release/Array --canvas-zoom-invalidation-probe-check
.build/release/Array --perf-budget-magnify-slope-check
.build/release/Array --perf-budget-gesture-transition-check
.build/release/Array --tile-surface-residency-check
CONTINUUM_PERF_CONFIGURATION=release \
CONTINUUM_PERF_APP="<WORKTREE>/.build/release/Array" \
CONTINUUM_PERF_OUT="<EVIDENCE_DIR>/perf/ceilings" \
scripts/run-perf-ceilings.sh
```
