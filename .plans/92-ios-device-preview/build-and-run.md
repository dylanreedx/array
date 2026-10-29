# Build & Run from an iOS Preview tile

The Preview menu now offers Build & Run after the tile connects to an exact
simulator. Discovery checks the owning project root and its `ios` directory for
Xcode projects/workspaces and asks Xcode for their schemes. The user explicitly
chooses a container/scheme; no arbitrary first scheme is selected. Selection is
per run for now, not a new persisted tile field.

Commands use literal argv, Debug configuration, the iPhone Simulator SDK, signing
disabled and the selected UDID. Every run gets a fresh UUID DerivedData directory
under the current Array channel's developer-tools store. After a successful
build, Xcode's JSON build settings must identify exactly one simulator application
inside that directory; its built Info.plist must agree on bundle identity and
simulator platform. Only then may install and launch execute. Launch replaces a
running instance of that same app on that same device.

The tile reports progress in its existing status line. Preview offers Cancel
Build and Show Build Files. The directory retains build.log and a successful
run.json receipt containing container, scheme, device, app and bundle identity.
After the owned command group settles, only this run's DerivedData is removed
off the main thread. The installed simulator app has its own copy; receipt app
paths describe build provenance. Cleanup failures are recorded in cleanup.log. There is no signing, archive, App Store upload,
provider tool integration or notification-policy change in this slice.

Repeated Run is disabled until the previous operation settles. Disconnect,
device selection, parking and removal cancel the owned operation; hiding the
window suspends streaming while its explicit build continues; cancellation
is checked at each command boundary. An in-flight install may already have taken
effect when cancellation arrives. No simulator shutdown or unrelated process
termination is used. Simulator availability is owned by the connected tile.

Discovery/build/settings/install/launch run asynchronously; build stdout goes to
disk rather than accumulating in memory. The tile reuses ChoiceButton and its
existing status field, with no additional layout measurement or view-per-log-line
rendering. Build stdout and stderr stream to the same retained file; error presentation reads
only a bounded tail. Commands own a separate process group for cancellation.

Verification is recorded in proofs.md after the run completes. The offline
IOSPreviewBuildChecks are invoked by the existing matrix-reported
--ios-preview-tile-check. Optional production live coverage is enabled with
IOS_PREVIEW_LIVE_BUILD_PROJECT (absolute xcodeproj/xcworkspace path) and
IOS_PREVIEW_LIVE_BUILD_SCHEME; the harness creates and deletes its own simulator.

CLI design follows Apple's [Xcode command-line tool reference](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference).
The implementation is checked against the installed Xcode, rather than assuming
that tool names establish build/install behavior.
