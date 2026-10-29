# iOS preview feasibility proofs

The standalone AppKit harness establishes the frame/input transport. A separate
production canvas witness now drives Array's real mount, palette, tile, transport
and workspace restore paths. Both use disposable project/support directories.
The optional live gate creates and deletes its own simulator; it does not adopt
existing devices, pair the companion or touch the live tmux server.

## Production canvas witness

```sh
scripts/run-matrix.sh --ios-preview-tile
```

Builds Array and CoreChecks, runs the offline production scene witness, audits
workspace API field classifications and command-center behavior, and checks
colour hygiene. The scene witness uses an injected transport, real frame pixels,
AppKit input and temporary stores. It asserts placement in world coordinates,
device selection persistence, ownership, save-failure rollback, keyboard release,
parking/stale frames, cold workspace restore, command cancellation and coalesced
frame decoding. It never downloads tools or connects to CoreSimulator.

Set `IOS_PREVIEW_LIVE_TEST_CANVAS=1` alongside the live configuration below to
rebuild Array and exercise the production tile against the gate's newly created
device. This checks integrity-verified tool installation, authenticated capture,
touch, physical typing, Unicode paste, rotated hit testing and reconnect. Native
light/dark/landscape images and an independent UIKit state report are retained
under the run's `canvas/` directory. The production surface remains a regular
project-owned tile with an aspect-correct screen inside it.

## Offline rendering/input witness

```sh
scripts/run-matrix.sh --ios-preview-proof
```

Requires macOS/AppKit, Swift and Python 3.12+ (`tarfile` extraction filtering in the
optional backend probe); no downloaded packages are needed for the fixture gate.
The check rebuilds its Swift executable, generates explicitly labeled JPEG
fixtures, starts a loopback-only HTTP/WebSocket fixture, and checks:

- Streamed JPEG decoding and actual native NSView light/dark snapshots.
- AppKit-injected pointer events through the binary WebSocket protocol; the
  server records input and changes the frame in response.
- Portrait/four-orientation coordinate math, letterboxing and scale factors.
- Physical A-key down/up packets, drag clamping and touch release on focus loss.
- Split multipart input, bounded parser storage and oversized-input recovery.
- One pending decoded frame and rejection of frames from a prior generation.
- Connection teardown observed by the server.
- A separately compiled wrong-rotation implementation must fail the same witness.

Snapshots and JSON reports live in the printed artifact directory. Set
`IOS_PREVIEW_PROOF_OUT` to retain them at a chosen location. Use a fresh directory
per run; the fixture server's origin file belongs to that run.

This is a protocol-compatible fixture, not an iOS simulator. It does not prove
human keyboard focus, arbitrary text, modifiers/IME/paste, simulator input,
H.264/IOSurface performance, actual canvas zoom gestures, or production
TileNSView/zone hydration. The display path uses MJPEG to establish feasibility;
it is not a production performance recommendation. The frame inbox is bounded;
this small harness does not yet bound all decoder scheduling or outgoing input.

## Exact pinned backend preflight

```sh
python3 Tools/IOSPreviewProof/probe-backend.py qa-runs/ios-preview-backend
```

Fetches `expo-device-hub@0.19.0-canary-20261023-1357114`, verifies registry SHA-512
integrity, extracts it into the output directory, loads the native Node addon in
a child process, and records exports plus installed Xcode version. It attempts
discovery against an explicitly empty disposable device set in that directory.
Failure is nonzero and recorded; it never boots a device. Extracted upstream code
retains its own license files and must not be committed or redistributed as part
of this prototype. Loading a native addon executes upstream code.

The probe does not validate runtime capture/HID methods. Real simulator access
requires CoreSimulator service permissions; passing addon loading alone is not a
live preview proof. Do not weaken the fixture report to imply otherwise.

## Live simulator witness

`scripts/run-matrix.sh --ios-preview-live` runs a separately configured, opt-in
live gate. It creates a new simulator, builds/installs a tiny UIKit input witness,
and checks the real app's own state after AppKit-injected touches, HID typing,
Unicode/emoji Command-V paste, and rotation. It restarts the native backend and
asserts app state survives. It always shuts down/deletes only its own exact UDID.
The pinned addon currently resolves the default device set, so the disposable
device is created there; existing devices are never adopted or modified.

Configure these environment variables for the live gate:

- `IOS_PREVIEW_LIVE_BACKEND_PACKAGE`: extracted, integrity-verified pinned package.
- `IOS_PREVIEW_LIVE_WS_PACKAGE`: installed `ws@8.21.0` package directory.
- `IOS_PREVIEW_LIVE_DEVICE_TYPE` and `IOS_PREVIEW_LIVE_RUNTIME`: exact installed
  device type/runtime identifiers; no ambiguous `booted` selection is used.
- `IOS_PREVIEW_LIVE_OUT`: artifact directory (otherwise a new temp directory).
- Optional `IOS_PREVIEW_LIVE_COMPANION_APP`: explicitly built companion `.app` to
  install/launch/capture after the input checks. The gate does not build or pair it.

`live-backend.cjs` wraps only the native capture/HID addon behind a small loopback
MJPEG/WebSocket server. It has no shell/exec route. It is feasibility code, not a
production server or renderer. `InputWitnessApp.swift` contains no Array account,
relay, pairing or project connectivity. No real Codex/Claude/Pi turns are run.

The live check records the frontmost host application before/after input. When
the production-canvas option is enabled, input passes through the real tile's
AppKit event handlers and landscape hit testing. This is injected event coverage;
it does not establish human trackpad/IME behavior, multi-touch, iPad compatibility
or sustained H.264 performance. The offline gates need no installed iOS runtime.

To exercise Build & Run through the actual canvas tile, also set
`IOS_PREVIEW_LIVE_BUILD_PROJECT` to an absolute `.xcodeproj`/`.xcworkspace` path
and `IOS_PREVIEW_LIVE_BUILD_SCHEME` to a shared app scheme. The production check
first discovers the scheme with Xcode, then invokes the tile's Build & Run action,
verifies its exact-device receipt and captures both host appearances after launch
settles. This builds fresh products; allow up to 15 minutes for the build command.
The runner raises its production-check timeout for this opt-in mode. The ordinary
live gate still works without these two environment variables.

`IOS_PREVIEW_LIVE_PERFORMANCE=1` enables an owned-simulator 15/30/60 fps sweep:
12 AppKit taps/rate with UIKit color-patch readback, three-second animated cadence
windows, and host/helper CPU/RSS. Results are `canvas/performance-report.json`.
This measures delivery of decoded frames, not physical display scan-out. The
ordinary live check leaves the activity animation disabled. Set
`IOS_PREVIEW_LIVE_BUILD_OCCLUSION=1` alongside the Build & Run variables to assert
that hiding the viewer pauses streaming while the explicit build continues.
