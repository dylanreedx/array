# Stream 3: creation sizing and placement

Date: 2026-11-09. Branch: array/aln-spawn-sizing (local, not pushed).
Base: 0bb5fb19 (the shared `TileGeometry.shapeRule`).

## What changed

A new tile now starts in the shape tidy gives it.
In an auto-layout zone with room, it is sized to fit that room.
The zone does not grow and its neighbours are not pushed.

Commits:
- 5bd1326c feat(spawn): start each tile in its tidy shape and fit the zone room
- 8ae82646 test(spawn): witness tile shape and zone fit through real spawn routes

## Sizes, before and after

| Kind | Before | Ratio | After | Ratio | Rule |
|---|---|---|---|---|---|
| browser | 1024x640 | 1.60 | 1024x576 | 16:9 | aspect 16:9 |
| terminal | 900x584 (100x28 cells) | 1.54 | 720x804 (80x39 cells) | 0.896 | band 0.6-0.9 |
| managedAgent, sharedAgent | 640x520 | 1.23 | 576x640 | 0.90 | band 0.6-1.0 |

Every other kind was already inside its rule and is unchanged.
sharedTile keeps 640x520 (rule `.keep`); it used to share the agent preset.

Terminal: 80 columns is the floor from the brief.
At 80 columns, 39 rows is the fewest that stays at or under 0.9.
That is 804pt tall, so it no longer fits a 1000x700 view at zoom 1.
The old 100x28 comment cared about that; it cannot hold with this rule.
Area: browser -10%, terminal +10%, agent +11%.

## Fitting the zone's room

`TileGeometry.spawnFitSizes(for:)`: default, then 7/8, then 3/4.
Every step keeps the ratio, so it stays in the rule.
Eighths keep the browser exactly 16:9 (896x504, 768x432).
Steps below the kind's minimum are dropped.
Terminals and `.keep` kinds offer only their default (shrinking costs columns).

`TileSpawnPlacement.roomFit`: the first size with a free slot wholly
inside the zone's content rect. It uses the fan-out's own slots and
ranking, restricted to in-room slots. An empty zone centres the tile on
the focus, clamped into the room. If nothing fits it returns nil, and
the old placement runs at the default size (the zone grows, as before).

`makeProjectTilePlacement(... fitting: kind)` calls it only for an
automatic placement in an auto-layout zone at the kind's default size.
Explicit points, drops, anchored (`beside`) frames, helper sizes and
pinned settles are untouched.

## Creation paths surveyed

Size source is `TileGeometry.preset(for:).defaultSize` via
`CanvasEngine.defaultFrame(for:)` unless noted.

- Terminal: `TileSpawner.spawnTerminal` -> makeProjectTilePlacement. Fits.
- Browser, palette or toolbar: `spawnBrowserImpl`. Fits when unanchored.
  Anchored opens use `anchoredFrame` at the default size (new shape, no fit).
- Browser, target-blank child: `spawnBrowserForNewWindow`, explicit point beside the opener.
- Agent browser: `spawnAgentBrowser`, anchored to the agent.
- Browser inspector: explicit point right of its browser.
- Managed agent: `spawnManagedAgent` / `ForExistingAgent`. Fits when no size is given.
- Helper beside lead: `AppDelegate.spawnPlacementBesideParent`. Under
  auto layout it is the lead's width and half its height, at an explicit point.
- Workspace API delegation: `WorkspaceAPIService+Delegation` uses
  `visibleSpawnSlot` at the agent default, then an explicit point. Camera preserve.
- `attachTile(toAgent:beside:)`: explicit point right of the tile.
- Note, board (automatic), diff review, run artifacts, file tree: fit.
- File open: automatic opens fit. Anchored and dropped opens keep the default.
- Drag-drop file opens and `openDocument(.at(point))`: explicit point.
- iOS preview, shared agent/portal/tile: default only (`.keep` or explicit).
- Boot `installInitial*` walk: restores persisted frames. Not a creation.
- `resizeFocusedTile(to:)`: scales the default, so it picks up the new shapes.

## Checks (offscreen, disposable app support, isolated tmux namespace)

Final code, all exit 0:
--spawn-sizing-check (new), --spawn-framing-check,
--spawn-live-framing-check, --spawn-placement-check,
--zone-arming-check, --auto-layout-fanout-app-check,
--workspace-api-open-check, --canvas-undo-check,
--spawn-arrange-commit-check, --zone-spawn-containment-check,
--note-file-tile-spawn-check, --palette-browser-spawn-check,
--agent-browser-spawn-check, --floating-toolbar-agent-spawn-check,
--managed-agent-model-spawn-check, --flat-spawn-migration-check,
--zone-spawner-coverage-check, --spawn-focus-policy-check,
--refused-spawn-teardown-check, --agent-spawn-limit-check,
--workspace-api-grants-check.
Matrix inventory check: exit 0 (C locale; only the new leg added).
Skipped: --workspace-api-agent-camera-check (it takes the screen).

Fan-out shape: six ⌘K agents with the camera following made a
2328x1168 zone (aspect 1.99), inside the leg's bounds.

ContinuumRevivedCoreChecks: exit 1, twice, on one unrelated line:
"just-under-cap safe rows must remain useful within 100ms: 0.110s".
That times HMAC secret scanning in AgentToolDetailStore in a debug build.
Load average was 18-27 with other helpers building. No file I changed is
on that path. The new shape-rule and roomFit sections passed.

## The new witness: --spawn-sizing-check

Real ghostty context, so it is registered beside
--spawn-arrange-commit-check, below `ghostty_init()`.
It mounts WorkspaceInvariantsFixture, draws a zone and homes it on a
project (`beginProvisionalZone` + Home picker), with auto layout on.

- Roomy zone 2800x1200: ⌘K browser, a shell terminal via
  `spawnTerminal(profileId:)`, then a ⌘K agent. Each WORLD frame is in its
  rule, at its default size, inside the zone's world rect, and the zone
  did not grow.
- Snug zone, content 900x520: a ⌘K browser lands at 896x504, inside the
  zone, and the zone did not grow.

Teeth: with the room fit disabled it fails (exit 1):
"roomy managedAgent: a zone with room grew from 2800x1200 to 2800x1560".
The fan-out picked a slot below the zone while 864pt beside the browser was free.
The old defaults also fail its shape assertions.

## Tried and rejected

- Scaling by 0.9/0.8: 1024x576 x 0.9 = 922x518 is not exactly 16:9. Eighths are.
- Closing a gap narrower than the tile against the zone edge, for the first
  tile in an empty zone. It made rooms contiguous, but it broke the "renders
  centred where you look" contract (--spawn-placement-check). Removed;
  the empty-zone tile stays centred on the focus.
- Putting the witness inside --spawn-framing-check: that leg runs before
  `ghostty_init()`, and a terminal spawn there segfaults in ghostty_config_new.

## For the lead

1. Helpers break the agent band. Under auto layout a helper is its lead's
   width and half its height: 576x316, ratio 1.82 (640x256, 2.5, before).
   Tidy will push it into 0.6-1.0. Choices: a helper exception in
   shapeRule, or square half-height helpers (316x316 is below the 320
   minimum width). I left it alone because it is the .plans/107 model B.
2. Terminal 0.9 cap with 80 columns forces 804pt tall. A 1.0 cap would
   allow 80x35 (720x724).
3. Changed fixtures: ZoneSpawnContainmentChecks' zone is now 2360 wide
   (was 2600) so three 576-wide agents still fill it. CoreChecks' preset
   table has the new sizes.
