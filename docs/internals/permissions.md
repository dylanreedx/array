# macOS permissions

Every macOS privacy permission Array can touch: what feature needs it, when it
is asked for, what happens on a denial, how to recover, and whether a grant
needs a relaunch. Written 2026-11-23 against `982d241e2`.

## The rule that explains most of what people see

**macOS charges Array for everything that runs inside it.** Array is a
terminal host. Every shell, every agent CLI (`claude`, `codex`) and everything
they launch is a child of Array, and TCC (macOS's privacy system) treats the
app that launched a process as the *responsible* app. So when an agent in an
Array tile runs `screencapture`, `osascript` or `cliclick`, the prompt and the
usage count go to Array, exactly as they would go to Terminal.app, Ghostty or
iTerm if the same command ran there.

That is why Dylan's Mac reported "Array has accessed your screen 440 times".
The prod Array binary does not capture the screen in normal use (see the next
section). The helper agents running in prod Array tiles do: in the 30 days
before this was written, their transcripts hold about 300 `screencapture`
commands (`-l <window>` stills for the fidelity bar and review queue, `-v`
screen recordings), plus every `--*-check` leg launched from those shells that
grabs its own window with `CGWindowListCreateImage`. Each one counts against
Array, because Array is the responsible process.

A colleague who never runs agents that take screenshots will never see a
Screen Recording prompt from Array.

Array does not disclaim responsibility for its children, on purpose. If it
did, a CLI run in a tile would prompt as itself (`screencapture`, `zsh`) and
those grants are confusing and hard to undo. Terminal apps keep
responsibility for the same reason.

## Screen capture in Array's own code

| Call site | Runs when | In a prod user's normal use? |
| --- | --- | --- |
| `App/Film/FilmCapture.swift` (ScreenCaptureKit) | film build only (`-DARRAY_FILM`, `scripts/film-capture.sh`) | No: not compiled into prod; `scripts/check-film-absent.sh` |
| `App/QACapture.swift` (`CGWindowListCreateImage`) | `CONTINUUM_QA_CAPTURE` set | No |
| `App/SidebarMotionFilm.swift` | `--sidebar-motion-film-check` | No |
| `ContinuumApp.swift` sidebar live screenshot | sidebar screenshot check flag | No |
| `AgentFaceChecks`, `ComposerOutlineChecks` | their check flags | No |
| `GhosttyTerminalRuntime.runStrayWindowAuditSelfCheck` (`CGWindowListCopyWindowInfo`) | its check flag | No |
| iOS Preview | streams the simulator's framebuffer over a local URL | No screen capture; no TCC |
| Browser tile thumbnails | `WKWebView.takeSnapshot` / `cacheDisplay` | No TCC |

So nothing in the prod app captures the screen without being asked to. There
was nothing for Array itself to stop. To cut the count on Dylan's Mac, take
helper stills from the preview app or a terminal outside Array (that charges
Terminal instead), or capture offscreen windows with `cacheDisplay` where the
content is not Metal.

## Inventory

"Live" means a grant takes effect in the running app with no relaunch.

### Microphone

- **Feature:** composer dictation (⇧⌘D or the mic button), macOS 26+.
- **Asked:** on the first dictation, from
  `SpeechAnalyzerDictationEngine.ensureMicrophoneAccess`. Never at launch.
  Hardened runtime entitlement `com.apple.security.device.audio-input`, usage
  string `NSMicrophoneUsageDescription`.
- **Before the prompt:** the user just pressed the mic button; the system
  prompt shows Array's usage string.
- **On deny:** the button and the composer's hint row say "Turn on the
  microphone for Array in System Settings › Privacy & Security". Clicking the
  mic again opens System Settings at Privacy › Microphone (macOS never
  re-prompts after a denial; before this sweep the click just failed again).
- **Relaunch:** live. The next click after the grant dictates.
- **QA:** checks use `FakeDictationEngine` and a swapped permission probe and
  Settings opener; they never reach AVFoundation. Witness:
  `--composer-dictation-check` step 12b.

### Speech recognition

- **Feature:** dictation transcription.
- **Asked:** the engine uses `SpeechAnalyzer` / `DictationTranscriber`
  on-device and never calls `SFSpeechRecognizer.requestAuthorization`. The
  usage string `NSSpeechRecognitionUsageDescription` is there in case macOS
  asks; if it does, it asks at the first dictation.
- **On deny:** `DictationFailure.speechPermissionDenied` has its message and a
  deep link to Privacy › Speech Recognition, but no engine currently throws it.
- **Relaunch:** not applicable today.

### Notifications

- **Feature:** MAC-01 needs-attention banner and MAC-02 CLI-version banner
  (see [notification paths](notification-paths.md)).
- **Asked:** on the first banner Array tries to deliver
  (`NeedsAttentionNotification.deliver`, `AgentCLIUpdateNotifier.deliver`).
  Never at launch: MAC-01 needs Array inactive and an agent newly needing
  attention; MAC-02 records the first CLI version it sees silently.
- **Before the prompt:** nothing from Array; the system prompt names Array.
- **On deny:** banners are skipped with a line on stderr. The Dock badge and
  in-app attention signals (MAC-03..08) still work, because they need no
  permission. There is no in-app hint that banners are off. Recovery is System
  Settings › Notifications › Array.
- **Relaunch:** live.
- **QA:** `qaSink` replaces delivery in checks, and bare binaries never reach
  `UNUserNotificationCenter`.

### Files and folders (Documents, Desktop, Downloads)

- **Feature:** a project root inside `~/Documents`, `~/Desktop` or
  `~/Downloads`.
- **Asked:** when Array opens such a project. At boot that is the
  last-active project, so for these folders the first boot after install shows
  Array's own alert, "Grant Array access to this project folder", then a
  folder picker (`requestProjectFolderAccessIfNeeded`). Picking the folder is
  the user's grant; Array then remembers it per path. This is the one
  launch-time ask, and it only appears for a project in a protected folder.
- **On deny / cancel:** Array opens an empty workspace instead of hanging.
  Recovery: open the project again, or System Settings › Privacy & Security ›
  Files and Folders › Array.
- **Relaunch:** live.
- **QA:** a dev build's ad-hoc signature changes every rebuild, so the system
  forgets the grant and the alert returns each launch. That is why the preview
  app is pinned to `~/array-scratch` (CLAUDE.md, "Running the app").
  Checks use `CONTINUUM_PROJECT_ROOT` temp dirs outside the protected folders.

### Removable and network volumes

- **Feature:** a project root on an external disk or network share.
- **Asked:** by macOS, the first time Array reads the volume. Array has no
  code for this.
- **On deny:** the project cannot load, like a missing root. Recovery: System
  Settings › Privacy & Security › Files and Folders › Array.
- **Relaunch:** live.

### Screen Recording

- **Feature:** none in the prod app. Only programs run inside Array tiles
  (agents' `screencapture`, screen-recording tools) need it, and they are
  charged to Array.
- **Asked:** by macOS, the first time such a program captures.
- **Relaunch:** macOS itself tells the user Array must quit and reopen, and
  offers "Quit & Reopen". Array has no capture of its own to detect.
- **QA:** check legs that take window stills (`CGWindowListCreateImage`) need
  Screen Recording for whatever app launched them. Launched from an agent in
  prod Array, they count against prod Array.

### Accessibility and Input Monitoring

- **Feature:** none. Array's only global event monitors watch mouse clicks to
  dismiss its own popovers (`ChoicePopoverController`, `ProcessesPanel`),
  which needs no permission. Array never posts events to other apps.
- Programs in tiles that synthesise input (`cliclick`, the QA setup) ask for
  Accessibility as Array. Accessibility grants are live for new processes.

### Automation (Apple Events)

- **Feature:** formerly "Open Terminal at …" on location menus, which drove
  Terminal through `osascript`. Since this sweep it opens the folder with
  Terminal directly (`NSWorkspace.open(_:withApplicationAt:)`, the same as
  `open -a Terminal <dir>`). That needs no permission, and a failure beeps
  instead of doing nothing. Witness: `--location-action-surface-check`.
- Programs in tiles that run `osascript` are charged to Array. Array has no
  `NSAppleEventsUsageDescription` and no
  `com.apple.security.automation.apple-events` entitlement. A probe app built
  the same way (hardened runtime, no usage string, no entitlement) ran
  `osascript` against Finder successfully. So the missing keys did not block a
  child process in that test, and they were not added. Unverified: the exact
  prompt wording a child sees on a clean Mac.

### Camera

- **Feature:** none. Array has no camera entitlement or usage string, so a web
  page in a browser tile asking for the camera, or a program in a tile using
  it, is refused. Nobody has asked for this.

### Local Network

- **Feature:** the Debug-menu pairing listener (`LocalPairingEndpointListener`,
  binds `0.0.0.0`) used only for companion pairing tests. The workspace MCP
  host binds `127.0.0.1`, which is not the local network. Browser tiles
  visiting a LAN address trigger the system's Local Network prompt for Array.
- No `NSLocalNetworkUsageDescription`; macOS shows its generic text.

### Bluetooth, Location, Contacts, Calendars, Photos, Full Disk Access

Not used. Array needs no Full Disk Access.

### iCloud

`Sources/ContinuumRevived/ContinuumRevived.entitlements` lists CloudKit
containers for companion sync, which is gated off in the alpha. The signed prod
bundle carries only `com.apple.security.device.audio-input`.

## Gaps left open

1. Notifications denied: no in-app hint. Low impact: the Dock badge and the
   in-app attention still show.
2. Screen Recording relaunch is left to macOS's own "Quit & Reopen". Array
   could detect it only by capturing, which it does not do.
3. The usage strings a terminal host might want (camera, Apple Events) are
   absent; see Automation above for why they were not added blind.

## Rules for new code

- Ask at the moment of use, never at launch or in a boot path.
- On a denial, say what to fix and give a one-click route to the System
  Settings pane (`x-apple.systempreferences:com.apple.preference.security?Privacy_<Pane>`).
  A plain retry after a denial is a dead button, because macOS will not ask
  again.
- Every permission path needs a QA seam that keeps checks away from the real
  TCC call, and a witness for the denial path.
- Never `tccutil reset` Dylan's bundle ids (`dev.arrayapp.macos`,
  `dev.arrayapp.macos.dev`). Mint your own bundle id to test a prompt.
- Update this file and, for notifications,
  [notification paths](notification-paths.md) in the same change.
