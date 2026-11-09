# Sidebar polish preview / next release

Settings → Appearance → Sidebar → Active agent offers **Duplex** (the default), Gradient, Sheen and Classic. Choices persist and apply immediately; Reduce Motion keeps the highlight still.

The old dev-only `SidebarActiveIndicatorStyle` switch is retired. The normal app preference is `continuum.sidebar.activeAgentStyle`, in the app's own prod or dev defaults domain. Existing users with no saved preference start on Duplex too.

Witness: `--sidebar-indicator-settings-check` opens the real Settings choice in offscreen windows, queues mouse-up before dispatching mouse-down through `NSApp.sendEvent`, and checks all four visible sidebar surfaces and fresh isolated-suite persistence in light and dark. It also confirms the active card and row build count survive the change. The pre-feature run was RED because Appearance had no Active agent ChoiceButton. The witness uses only explicit isolated preference suites and temporary app support.

Motion review stills and clips: [round 3](indicator/round3/README.md), [minute-long gradient](indicator/round4/README.md).

Verification for this change: `swift build --product Array` passed; `--sidebar-indicator-settings-check` was RED before the control existed and is GREEN in both appearances after implementation; `--sidebar-screenshot-check` passed with 48 images. The new app leg and its inventory entries were added without renaming any existing invocation. Existing Classic-specific motion fixtures now select Classic explicitly; the shared-agent fixture follows the selected style’s border policy. Those other legs and the full matrix were not run, as requested; the full gate remains part of release verification.

The settings witness includes 24 helpers and the real “N more” tail: its border policy changes with the active style too, so a Classic border fragment cannot remain after choosing another look. Offscreen choice panels take key focus for the mouse event, matching the production popover's input state.

Round 6 expands the selected agent's light through its helper family: Duplex follows the running helper, Gradient fades down the group, and Sheen cascades a resting sweep over quieter inset helper panels. Single and collapsed cards keep their approved treatments; Classic is unchanged. Motion remains on Core Animation layers with a static Reduce Motion fallback.
