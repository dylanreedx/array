# 73 · Phase 1: the app fixes filming found

Written 2026-10-16. Source: `.worktrees/film-harness` (Array 0.7.25 `809bc17d` plus
~3,300 uncommitted lines in 59 files) and `which-tab-r0/footage/pin-failed-output.patch`.
Target: bench `.worktrees/film-fixes`, branch `array/film-fixes`, cut from
`origin/array/integration` at `2186dab4`. Nothing is merged or pushed.

## How the film-harness diff splits

**Harness (phase 2, left out of this branch).** Everything that only exists for a
film run:
- `Sources/ContinuumRevived/App/Film/` (whole directory), `film/`, `scripts/film-capture.sh`
- `scripts/make-app-bundle.sh` (`--bundle-id`, "Array Film")
- the `--film` / `--film-scene-check` plumbing in `ContinuumApp.swift` (scene staging,
  frozen catalogue, dark appearance, `FilmAgentRunner` as `makeRunner`, `parkWindow`,
  no `NSApp.activate`, no pi extension install, `runFilm`, the `film*` accessors)
- `FilmScene.isRequested` gates in `GhosttyTerminalRuntime` (film config file),
  `BrowserEngineContext` (`FilmWebFreeze`), `ChoicePopoverController`, `SettingsPanel`
  (`FilmPanelHost`), `AgentSoundSystem` (recorded sounds, film-clock badges),
  `CanvasNSView` (`FilmMenuHost`, `filmNavigationCamera`), `AppDelegate.filmRevealCamera`,
  `WorkspaceAPIService.filmRevealCamera`
- the clock seams `AgentElapsedClock` and `AgentTranscriptClock` and every `Date()` /
  `systemUptime` swapped for them (header, compact status, inbox clock and rows,
  `recordManagedActivity`, supervisor `now`)
- QA seams only the director uses: `AgentSupervisor.qaObserve`, `qaDeliverSubagentEvent`,
  `AgentTranscriptListView.qaPresentedToolTitle(forProviderItemID:)`,
  `filmComposerTextView`, `filmActionButton`, `filmURLField`, `filmHistoryHeaderCell`,
  `filmRowCell`, `filmTickElapsedClock`
- harness-only scene keys (`streamHz`, `settleToolDetails`, …) live in `Film/` and `film/`

**App fixes** are the rows below. Each landed as its own commit with its witness.
**Witness-only** pieces are listed with the fix they guard.

## The fixes

Status column: what `origin/array/integration` (`2186dab4`) did with it, checked by running
the witness there (RED), not by reading.

| # | Symptom the user sees | Cause, in plain words | Files | Witness | On integration | Commit |
|---|---|---|---|---|---|---|
| 1 | A failed command's output (Order export) lands below the fold, then "Jump to latest" | The detail refresh scrolled to the end before the taller failed row was laid out | `AgentTranscriptListView` | `--tool-detail-check` `runFailedOutputKeepsTailPinnedCheck` | still broken | `e542b4bd` |
| 2 | Typing `localhost:3000` in the address bar loads nothing; `example.com` loads about:blank | "localhost" parsed as a URL scheme; a bare host had no scheme | `BrowserTileNSView` | `--browser-url-focus-check` | still broken | `a19763c5` |
| 3 | File tree tile raises mid-layout when zooming with a mouse attached | Auto-hiding horizontal scroller toggled on a sub-pixel width mismatch, a layout loop | `FileTreeTileNSView` | `--file-tree-hardening-check` `runZoomedLegacyScrollerSelfCheck` | still broken | `a22158dd` |
| 4 | Dropping a card on an agent tile that overlaps the board moves the card instead | `agentTile(under:)` refused every point inside the board's bounds | `BoardDragController` | `--board-task-workflow-check` (`BoardTaskDropChecks`) | still broken | `269a0e91` |
| 5 | An agent that assigns a card to itself gets a task chip in its own composer | The post-commit sync staged a chip for any assignee, the acting agent included | `BoardRuntime`, `WorkspaceAPIService+Board`, `ContinuumApp` | `--workspace-api-board-check` `runComposerHandoff` | still broken | `362f92f4` |
| 6 | A sent board task prints `boardId` / `cardId` / `observedRevision` in the user's bubble | The projection printed the agent's envelope verbatim | `AgentBlock` (`.taskReference`), `BoardTaskContent` (`BoardTaskPromptEnvelope`), `AgentTranscriptProjection`, new `TaskReferenceRenderer`, registry/copy/card/reducer/corpus | CoreChecks `--board-task-transcript-check` (also inside `--board-model-check`), `--transcript-rhythm-check` | still broken | `5cad569e` |
| 6b | (witness) A task-only send must keep a user turn on claude, codex and pi | No separate fix: guarded by #6 | `BoardTaskSendChecks`, `qaPressSendForChecks` | `--agent-supervisor-check` | RED with #6's recognition disabled | `0bf84bf5` |
| 7 | Tool rows read "Mcp claude ai atlassian searchjiraissuesusingjql", every board change "Updated the board" | Nothing recognised MCP spellings or Array's own workspace tools; `jql`/`q`/issue keys never crossed the whitelists; the board reply carried ids only | new `MCPToolName`, `ArrayWorkspaceTool`; `AgentToolKind`, `AgentToolDetailStore`, claude/pi translators, `BoardApplyResult`, `WorkspaceAPIService+Board`, `ToolCallRenderer` | CoreChecks `--agent-tool-detail-store-check` (`runArrayWorkspaceToolRowChecks`) | still broken | `0caf369d` |
| 8 | Board cards appear, vanish and teleport when an agent changes the board | No change animation outside a local drag | `KanbanTileNSView`, `KanbanColumnView`, `BoardDragController` | `--board-interaction-check` `runChangeAnimationChecks` | still missing | `58103d0b` |
| 9 | After drawing a zone, the first ⌘K tile lands in the previously armed zone | Integration fixed the document half differently (`setActiveZone` + `ensureZoneLayer`), but armed before the layer existed, so the canvas stayed on the old zone | `WorkspaceRuntime.commitCreatedZone` | `--zone-arming-check` §8 | **partly fixed, canvas still wrong** | `2e5fd28e` |
| 10 | Every board is "New Board" | No naming rule | `ContinuumApp.newBoardTitle` | `--zone-arming-check` §8 | still missing | `d6407b8f` |
| 11 | Under auto layout a ⌘K tile lands on a sibling, or the zone grows across its neighbour | Three causes: the settle ran before the spawn was saved and integration's layout commit refuses unsaved tiles (new since 0.7.25: settle silently rolled back for every spawn but the agent's); the settle had no mover; the zone grew toward the camera-driven placement | `CanvasAutoLayoutEngine` (`grow`, `pushPeers`), `CanvasNSView.arrangeAutoLayoutAfterSpawn`/`installProjectTile`, `TileSpawner.persistSpawnedTile` | `--zone-arming-check` §9, §10 | still broken (worse than on the bench) | `750eedb7` |
| 12 | Closing a tile leaves a hole in an auto-layout zone | `removeTile` ran no layout | `CanvasNSView.closeTile`, `deleteTile` | `--zone-arming-check` §11 | still broken | `529c3300` |
| 13 | The "All set?" nudge almost never shows, blinks, and leaves the tile on the canvas | Hidden by any unread row, 30 s on/off phase, settle instead of close | `AgentInbox96CellView`, `AgentInboxView` | `--agent-inbox-check` section M | still broken | `0235a44e` |
| 14 | The sidebar hover card says where an agent lives, not what it is doing | No status or last line | `AgentSupervisor.latestAssistantLine`, `AgentInboxView`, `InboxHoverCard` | `--agent-inbox-check` `runAgentInboxHoverGlanceCheck` | still missing | `aad89098` |
| 15 | Hold-⌥ letters are all accent blue | No state in the overlay | `CanvasNSView`, `ContinuumApp.leaderJumpBadgeAccent` | `--leader-zone-jump-check` (and `--leader-jump-visible-indicators-check`) | still missing | `46fe8d69` |
| 16 | Every jump cuts the camera in one frame | No navigation flight | new `CameraFlight`; `CanvasCameraDriver.fly`; `CanvasNSView.navigateViewport`; nine jump sites in `ContinuumApp` | `--canvas-zoom-momentum-check` `runNavigationFlight` | still missing | `349963fb` |
| 17 | Pairing page, phone prompt, session end reasons, picker title and pairing alert still say Continuum | Copy not renamed (integration renamed the notification and the folder-grant alert only) | `LocalPairingEndpoint`, `CompanionFreshness`, `CanvasMirrorPresentation`, `ManagedAgentSessionRecord`, `ProjectPickerPanel`, `continuum-spawn-agent.ts` (+ prior hash), `ContinuumApp` | CoreChecks `--local-pairing-endpoint-check` (+ new `runUserFacingBrandCopyCheck`) | partly fixed | `492e6d01` |
| 18 | A file opened beside an agent is ~35 columns wide | Default file tile 320 x 480 | `TileGeometry`, preset and placement expectations | CoreChecks default run (preset table), `--spawn-placement-check` | still 320 x 480 | `b44f107b` |

## RED → GREEN evidence

Where a witness needs a type the fix introduces, the RED build stubbed exactly that
reference (marked `RED-RUN STUB`) and nothing else; the stubs are not in any commit.

1. RED `failed output pin: after the output opened the reader is 260.0 pt above the end; the failed row ends at 1636.0, the viewport at 1388.0` → GREEN `ContinuumRevivedToolDetailChecks passed: 32`.
2. RED `Return on "localhost:3000" must navigate to http://localhost:3000, got localhost:3000` → GREEN `ContinuumRevivedBrowserURLFocusChecks passed`.
3. RED `file tree showed a horizontal scroller at 11 of 401 zooms, e.g. ["0.202 (clip 462.87 of 480.20)", …]` → GREEN `ContinuumRevivedFileTreeHardeningChecks passed`.
4. RED `a card carried onto an agent tile that overlaps the board targets the agent` → GREEN `board-task-drop: PASS releasing it there assigns the task and moves no card`.
5. RED `handoff: an agent assigning a task to ITSELF … stages no chip in its own composer (got Optional(4B5A85A3-…))` → GREEN `ContinuumRevivedWorkspaceAPIBoardChecks passed`.
6. RED (parser section stubbed) `task transcript (live send): the user's turn still carries 'boardId' — the raw task envelope reached the document` → GREEN `Board task transcript checks passed …`; `--transcript-rhythm-check` passes with the task card drawn and no ids.
6b. RED (recognition disabled) `task-only send/Claude Code: no task turn before the reply; entries [assistant:[paragraph], user:[paragraph], assistant:[paragraph]]` → GREEN `a task-only board send kept its task turn above the reply for Claude Code, Codex, Pi`.
7. RED 70+ rows, e.g. `claude Atlassian search: row reads "Mcp claude ai atlassian searchjiraissuesusingjql", want "Atlassian · Search Jira issues using JQL"`, `board move: row reads "Mcp array workspace array board apply", want "Moved “Dark mode for the shop” to Doing"` → GREEN `Agent tool detail store checks passed`.
8. RED `a card created outside a drag attaches the entrance animation` (+5) → GREEN all `board-interaction: PASS`.
9. RED `unplaced project: the CANVAS must arm the zone just drawn … Got Optional(…067A11)` → GREEN §8.
10. RED `a board made in the zone named "Elm site" must take that name; got Optional("New Board")` → GREEN §8.
11. RED §9 `camera framing the zone: after the second agent, the zone (1403.0, 1010.0) 2144.0x810.0 grew across the neighbouring zone (600.0, 1000.0) 900.0x280.0`; §10 `Roots grew to (600.0, 200.0) 1344.0x700.0 across its neighbour (1700.0, 260.0) 900.0x700.0` → GREEN both.
12. RED §11 `archive: the zone kept the hole the closed tile left — the members are not one gap-contact cluster` → GREEN §11.
13. RED `a finished agent read 6 minutes ago must ask to be closed, beside an UNREAD Done row and a working one` → GREEN `ContinuumRevivedAgentInboxChecks passed`.
14. RED `hover glance: a working agent's card must say Working and for how long — it said [Drag fixer, Glance, project, …]` → GREEN `hover card: status (Working · elapsed / Needs attention / Done) and the newest assistant line, truncated in-card`.
15. RED `leader badge tint: a finished, unseen agent's letter must be the sidebar's Done mint — got nil` → GREEN `leader badges: Done mint and approval amber matching the sidebar, accent otherwise, mint gone once read`.
16. RED `a jump must not CUT: … got CanvasViewport(x: 350.58…, y: -403.52…, zoom: 0.85)` → GREEN `ContinuumRevivedCanvasZoomMomentumChecks passed`.
17. RED `Ticket81 endpoint: camera landing page is human-readable`, then `user-facing copy must say Array, not Continuum: [Connect to your Continuum instance ×3, Cancelled because Continuum restarted…, …quit…]` → GREEN `LocalPairingEndpointChecks passed`.
18. RED `file default size expected (640.0, 560.0), got (320.0, 480.0)` and `--spawn-placement-check … got (x:352.0, y:260.0, 320.0x480.0)` → GREEN `ContinuumRevivedSpawnPlacementChecks passed` (CoreChecks preset table: matrix).

## Not ported, and why

- **⌘-clicking a just-revealed sidebar row does not add it to the selection** and
  **archiving a parent leaves its subagents' rows** (P2D.6): found while filming, but the
  bench only worked around them in the take. There is no fix to port.
- **The film-only nudge timing** (`recordManagedActivity` on the film clock) is harness:
  in production `AgentElapsedClock.now()` is `Date()`.

Plus `814438bc chore(matrix): report the pairing and brand copy witness`: the bare
CoreChecks run stops at its KNOWN-RED pin before the pairing checks, so #17's witness
runs as its own leg (`--local-pairing-endpoint-check`), recorded in the inventory.

## Matrix

`CONTINUUM_SKIP_UI_BASELINES=1 scripts/run-matrix.sh` on `array/film-fixes` at
`b44f107b` (2026-10-16):

- **281 legs run** (integration's last full run: 281).
- **KNOWN-RED, expected (10):** `swift run ContinuumRevivedCoreChecks`, `--nav-mode-check`,
  `--empty-workspace-creation-check`, `--palette-captures-keys-over-browser-check`,
  `--note-click-focus-check`, `--agent-tile-click-focus-check`, `--perf-budget-zoom-check`,
  `--file-tile-zoom-check`, `--perf-budget-gesture-transition-check`,
  `--perf-budget-magnify-slope-check`. None passed unexpectedly.
- **Real failures (1):** `scripts/capture-cli-fixtures.sh check`: "missing context meter
  capture for claude 2.1.302". The host's claude CLI moved to 2.1.302 and the repo has no
  capture for it. Identical on a clean integration build; not caused by this branch.
- **270 passed**, including every new witness above (each one's line is in the log).
- The bare CoreChecks run (KNOWN-RED) reached and passed the file-size preset (#18),
  the board task transcript (#6) and the tool rows (#7), then stopped at its pre-existing
  dependencies-guard failure, as on integration.

The pairing leg was added after this run; it passes on its own, and
`scripts/check-matrix-inventory.sh` and both program checks pass with it.
