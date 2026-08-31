# External QA Driver Flows

These scripts drive the app from outside the Swift process with `cliclick`, `osascript`, and `screencapture`. They cover interaction stress cases that the in-process smoke timeline cannot encode reliably, such as repeated global shortcuts, pointer drags past canvas edges, OS window resizing, and quitting while a browser tile is loading.

## One-Time Setup

Run:

```bash
qa/setup.sh
```

The setup script verifies `cliclick`, `osascript`, `screencapture`, and `python3`. It installs `cliclick` with Homebrew when Homebrew is available and `cliclick` is missing.

Before running flows, grant Accessibility permission to the terminal app or autonomous runner that starts the scripts:

System Settings > Privacy & Security > Accessibility.

## Running A Flow

Build the app first:

```bash
swift build
qa/flows/cmdk-spam.sh
```

Common environment variables:

- `CONTINUUM_APP`: executable to launch, default `.build/debug/Array`.
- `CONTINUUM_QA_RUN_DIR`: explicit absolute run directory (required by release preflight).
- `CONTINUUM_FLOW_ITERATIONS`: iteration count for looped flows.
- `CONTINUUM_RUNS_DIR`: output root, default `qa-runs`.
- `CONTINUUM_QA_KEEP_APP=1`: leave the app running after the flow.

Each run writes:

```text
qa-runs/<flow>-<timestamp>/
  manifest.json
  *.png
  capture/
    manifest.json
    *.png
```

The top-level `manifest.json` records external driver steps. The optional `capture/manifest.json` comes from the app-side Layer A capture path when the flow launches the app with `CONTINUUM_QA_CAPTURE`.

## Reviewing A Run

Use `qa/reviewer-prompt.md` as the reviewer contract. It requires reviewers to read `manifest.json`, inspect every event PNG, compare the run against `docs/05-canvas-and-ux.md` and `qa/expectations/<flow>.md`, and file defects with `qa/file-finding.sh`.

`qa/file-finding.sh` writes normal pending Conductor bugfix tasks with `[qa-finding][severity]` descriptions. The wrapper computes a fingerprint from severity, summary, flow, and step, then skips filing when a pending task already contains that fingerprint.

## Flows

- `qa/flows/cmdk-spam.sh`: opens and closes Cmd-K repeatedly with `cliclick` and captures the final palette state.
- `qa/flows/drag-past-edge.sh`: drags the first tile far beyond the canvas edge to preserve clamp evidence.
- `qa/flows/window-resize-stress.sh`: resizes the app window through widths from 320 to 1920 and captures layout stability.
- `qa/flows/quit-during-load.sh`: starts a browser load flow, quits during load, and compares DiagnosticReports before and after.
- `qa/flows/release-preflight.sh`: proves exact-PID/CGWindow capture, named readiness, Accessibility actions, Retina scale, isolated state, and honest `DISPLAY_DEFERRED` diagnostics.

## Adding A Flow

1. Create `qa/flows/<name>.sh`.
2. Source `qa/flows/lib.sh`.
3. Call `begin_flow "<name>"`.
4. Use `launch_continuum "<in-process-flow>"` when the app should seed a known state.
5. Use `capture_step "<step>" "<notes>"` after each external action.
6. Add at least one positive machine assertion with `assert_flow`; screenshots are evidence, not a pass condition. A flow that calls `finish_flow pass` with zero assertions is converted to failure.
7. End with `finish_flow pass` or `finish_flow fail`.

Run `node scripts/check-qa-flows.js` after adding a flow. `qa/run-autonomous.sh --flow <name>` executes `qa/flows/<name>.sh` and fails for unknown or non-executable flows instead of silently running the default smoke.
