# iOS Preview — next release handoff

## Release note draft

- Run an iOS Simulator directly on the canvas. Add an iOS Preview tile, choose a
  simulator and connect to interact with its screen, keyboard, Home and rotation.
- Build and launch a shared Xcode scheme into the selected simulator from the
  Preview menu, with progress, cancellation and retained build logs.
- The preview runs at 30 fps, with frame processing off the UI thread and bounded
  queues. Saved tiles remember their simulator without automatically booting it.

Requires macOS with Xcode, an installed iOS Simulator runtime and Node.js.
Connect downloads verified, pinned capture/input helper dependencies.

## Release validation

The final development gate passed seven offline legs, two live legs, appearance,
workspace scene ownership/API checks and bundle verification. Live checks include
the actual companion build/install/launch and a build continuing while its viewer
is hidden. See [the sanity/performance report](sanity-and-performance.md) and
[proof history](proofs.md).

Full release matrix and release-configuration signed bundle checks remain for
release preparation under RELEASE.md. This change does not bump a version,
publish artifacts or modify the updater feed.

Tested: Xcode 26.6 / iOS 26.5 / Node 22.22.2 on this Mac. The pinned native helper
uses private simulator APIs; Xcode 27 compatibility is not established. Physical
devices, native trackpad scrolling, IME/multitouch, sustained multi-tile memory and
physical display scan-out latency are outside these proofs. Agent device control
APIs are an uncommitted follow-up described below; App Store submission
automation remains future work. Repeated builds still
compile fresh products; only the run's logs and receipt remain after cleanup.

## Agent control follow-up

The [agent-control plan](agent-control-plan.md) specifies the future automation
surface, dependencies, ownership, acknowledgements, residency and acceptance
gates. The visual API, bounded swipe/text/key/Home/rotation and service-owned exact-device
build jobs are implemented; see
[progress](agent-control-progress.md) and the [API contract](../../docs/internals/workspace-ios-preview.md). This follow-up is uncommitted and outside the `efcce530` preview
release baseline.

The 2026-10-29 follow-up's focused matrix passes **12/12** and actual native MCP
companion build/control gate **2/2**. The latest dev bundle builds. Its bundle
verification failed `--terminal-theme-fidelity-check` (`spawned terminal surface
missing`) in two isolated runs at 03:56 and 03:59 EDT. The terminal investigation
(`qa-runs/overnight-2026-10-29/terminal-bundle-handoff.md`) traced it to Ghostty
returning OutOfMemory while the display was asleep (03:46–04:21 EDT); the same leg
passes with the display on. That is an environment finding, not an iOS defect, but
the bundle gate must still be rerun green before release. This note does not
approve a release. Semantic inspection remains a separate decision.
