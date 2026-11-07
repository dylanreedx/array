# Live spawn framing starvation

Base: array/spawn-preview, 1f61b1ac. Debug binary only. Installed preview and production bundles untouched; no push.

## Cause and RED

The camera driver starts settled (true). Residency does not set its settled state. Actual camera input or a navigation flight sets it false. When its native display link is suspended (occluded/offscreen window), the real timer backstop must finish the flight.

The backstop set flightStart = now - flight.duration, then called stepFlight(at: now). Floating-point cancellation at the large system uptime rounded the resulting elapsed time just BELOW duration. The camera reached nearly its destination, but the flight stayed active. Every backstop retry repeated the same arithmetic and refreshed lastActivityTime; the driver never settled. scheduleSpawnFrame then retried forever because isCameraInMotion remained true.

Strengthened --spawn-framing-check reproduced this before changing production code. It used a real key NSWindow, the actual native camera driver/link/backstop, and Command-K opened, typed and dismissed through NSApp.sendEvent. Flight selection was forced on because the QA focus guard parks windows offscreen; camera time, driver stepping, link state and settlement were not mocked during this case. No forced settle was called after starting the live-case flight. After three seconds:

`live palette spawn did not finish reveal: viewport=(24000,24000,0.39999999999999997), destination=(24000,24000,0.4), motion=true, settled=false, geometry=false`

The broker already identified the new tile, so palette snapshot restoration was not the cause of this RED. The destination snapshot existed and workspace identity stayed valid. The failure was the unfinished camera flight starving the deferred reveal.

## Fix

The stalled-link backstop now commits flight.to exactly, clears the flight, and lets the next quiet interval settle. It no longer reconstructs the final elapsed time by subtracting duration.

Spawn retries also have an independent 1.5-second monotonic deadline from the FIRST queued spawn. Continuing bursts cannot reset it. Before that deadline, camera/geometry motion and a briefly missing navigation snapshot can defer; afterward the reveal/focus attempt proceeds. Workspace switches still discard old work. Immediate and deferred focus retain the tileSpawned reason, which suppresses palette broker snapshot restoration.

## Why the old witness missed it

The old runner set navigationFlightOverrideForQA=false, manually settled its pan, and primarily compared navigationViewport (which reports the flight TARGET) with sidebar framing. It did not establish that the real camera arrived or that the actual first responder belonged to the created tile after dismissal.

The strengthened shared runner now enables a real flight for the key-window palette case, waits through the natural link/backstop lifecycle, and asserts the presented viewport, broker tile scope, an actual first responder inside the spawned note, and a settled driver with no flight left active. Both --spawn-framing-check and newly registered --spawn-live-framing-check run that strengthened runner. The latter is an explicit matrix entry for the live lifecycle regression, not a different simulation.

## User-route audit

| Route | Production path to focusSpawnedTile |
| --- | --- |
| Command-K Agent | performPaletteAction → spawnManagedAgentFromPalette → wireManagedAgentTile → focusSpawnedTile |
| Command-K Terminal | performPaletteAction → spawnTerminalFromProfile → installSpawnedTerminal → focusSpawnedTile |
| Command-K Note | performPaletteAction → spawnNoteFromPalette → focusSpawnedTile |
| Command-K Board | performPaletteAction → spawnBoardFromPalette → focusSpawnedTile |
| Command-K Browser | performPaletteAction → spawnBrowserDefault → focusSpawnedTile |
| Toolbar harness | handleFloatingToolbarSelection(.agentHarness) → spawnManagedAgentForHarness → focusSpawnedTile |
| Toolbar palette/profile choices | performPaletteAction / spawnTerminalFromProfile → same paths above |
| Menu Agent/Terminal/Note/Board/Browser | createAgentFromMenu / createTerminalFromMenu / createNoteFromMenu / createBoardFromMenu / createBrowserFromMenu → same paths above |
| New Agent Here | location-menu creation → wireManagedAgentTile → focusSpawnedTile |

No listed user route had lost its call to the focus funnel. FocusBroker marks tileSpawned during a modal and skips the old snapshot on close. The palette also checks whether its responder still owns focus before restoring the previous responder. The new deferred reveal repeats tile focus after dismissal. A navigation snapshot is synchronous for an installed, noncollapsed layer; missing snapshots now receive bounded retries rather than being silently dropped. mountEpoch changes occur at mount/install or workspace switch, not every residency tick; this RED had no switch.

## Final checks

Baseline and fixed debug builds: exit 0. Strengthened runner RED before the fix, exit 1; final runs below all exit 0:

- --spawn-live-framing-check
- --spawn-framing-check
- --spawn-placement-check
- --zone-arming-check
- --auto-layout-fanout-app-check

Evidence: qa-runs/spawn-live-framing/ (ignored bench-local logs). App legs unset ARRAY_AGENT_ID/TMUX/TMUX_PANE; use TERM=xterm-256color, stdin /dev/null, isolated app support, and disposable tmux namespaces whose socket paths are verified. The inherited managed-agent marker is retained. No full matrix or CoreChecks run was requested for this scoped fix. git diff --check passes.
