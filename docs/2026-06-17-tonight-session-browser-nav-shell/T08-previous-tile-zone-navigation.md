# T08 — Previous view, previous tile, and previous zone navigation

Status: implementation-ready
Tag: tonight [navigation] [camera]
Depends on: T07 framing policy

## Goal
Add predictable quick return navigation so users can jump around the canvas without losing orientation.

Primary user outcome:
- jump to a tile/zone;
- press previous-view / previous-tile / previous-zone;
- return to the prior meaningful workspace context.

## Implementation decisions
No open UX questions for the overnight agent:

1. **First implementation uses A↔B toggle semantics for previous tile and previous zone**, not an unbounded stack walk.
2. **Previous view restores exact camera state** from before the last completed programmatic jump when available.
3. **Previous tile toggles between the two most recent distinct focused tiles.**
4. **Previous zone toggles between the two most recent distinct focused zones.** When restoring a zone, restore that zone's last focused tile if available; otherwise frame the zone bounds.
5. **Cancelled transitions do not enter history.**
6. **Hover, transient selection, modal open/close, and palette focus restore do not enter history.**
7. **Deleted/missing targets are skipped.** If no valid prior target exists, leave the camera unchanged and show/log non-disruptive feedback.
8. **Session-only history for first implementation.** Do not persist focus history across app restarts in this ticket.

## Code seams
Likely files/symbols:

- `Sources/ContinuumRevivedCore/FocusHistory.swift` — new pure model suggested
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift`
  - `markActive(tileId:)`
  - `setViewport(_:)`
  - tile resolver methods
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
  - leader jump handling
  - palette jump handling
  - zone jump handling
  - command execution
- `Sources/ContinuumRevivedCore/CanvasCommand.swift` / `CommandRegistry`
- `Sources/ContinuumRevivedCore/NavKeymap.swift`
- `Sources/ContinuumRevivedCore/LaunchPaletteModel.swift`

Use command registry/keymap patterns; do not create a parallel shortcut table.

## Focus history model
Suggested model:

```swift
public enum FocusTarget: Equatable, Sendable {
    case tile(UUID)
    case zone(UUID)
}

public struct CameraSnapshot: Equatable, Sendable {
    public var viewport: CanvasViewport
    public var focusedTileId: UUID?
    public var focusedZoneId: UUID?
}

public enum FocusHistoryEventReason: Equatable, Sendable {
    case directTileActivation
    case completedTileJump
    case completedZoneJump
    case paletteJump
    case previousNavigation
}
```

Suggested session state:

```swift
var recentTiles: DistinctToggleHistory<UUID>
var recentZones: DistinctToggleHistory<UUID>
var lastViewBeforeProgrammaticJump: CameraSnapshot?
var lastFocusedTileByZone: [UUID: UUID]
```

Rules:
- dedupe consecutive identical tile/zone IDs;
- record tile focus on direct tile activation and completed tile jump;
- record zone focus on explicit zone activation/jump;
- update `lastFocusedTileByZone` when a tile in a zone becomes active;
- do not record cancelled transitions;
- do not record hover/selection-only/modals.

## Commands
Add through command registry:

```text
view.previousView
view.previousTile
view.previousZone
```

Palette titles:

```text
Back to Previous View
Go to Previous Tile
Go to Previous Zone
```

Keybind defaults can be `.none` if ambiguous; command palette availability is required. If adding defaults, use existing keymap/settings machinery.

## Acceptance criteria
- [ ] Previous view restores the camera snapshot from before the last completed programmatic jump.
- [ ] Previous tile toggles A↔B between two most recent distinct focused tiles.
- [ ] Previous zone toggles A↔B between two most recent distinct focused zones.
- [ ] Previous zone restores last focused tile in that zone when available; otherwise frames zone bounds.
- [ ] Deleted/missing targets are skipped safely.
- [ ] Hover/selection/modal restore/cancelled transitions do not pollute history.
- [ ] Commands are available in command palette.
- [ ] Pure history model and real-path app checks exist.

## Nightly QA contract

### Required checks
Pure/Core:

```text
FocusHistory table in ContinuumRevivedCoreChecks
```

Palette/Core:

```text
LaunchPaletteModel exposes previous-view/tile/zone rows or CommandRegistry rows as expected
```

App flag:

```text
--previous-focus-navigation-check
```

The app check should:
- create tiles A/B and zones Z1/Z2;
- focus A then B via real activation/jump path;
- invoke previous tile command and assert A is focused/framed;
- invoke previous tile again and assert B is focused/framed;
- activate zones Z1/Z2, invoke previous zone and assert Z1 restored;
- delete/make-unresolvable a previous target and assert skip behavior;
- verify cancelled transition does not enter history.

### Required artifact

```text
qa-runs/<timestamp>/previous-focus-navigation/manifest.json
```

Minimum fields:

```json
{
  "check": "previous-focus-navigation",
  "events": [
    {"reason":"directTileActivation","target":"tile:A"},
    {"reason":"completedTileJump","target":"tile:B"},
    {"reason":"previousNavigation","target":"tile:A"}
  ],
  "previousTileToggleSequence": ["A", "B", "A"],
  "previousZoneToggleSequence": ["Z1", "Z2", "Z1"],
  "deletedTargetsSkipped": true,
  "cancelledTransitionRecorded": false,
  "finalViewportErrorScreenPx": 0.3
}
```

### Stop conditions
Do not mark Done if:
- UX questions remain unresolved in implementation;
- only pure model tests exist and real command/palette path is untested;
- previous command walks an unpredictable stack instead of first-version A↔B toggle;
- hover/modal/cancelled transitions pollute history;
- deleted targets crash or leave ambiguous state.

## Verification commands

```bash
swift build
swift run ContinuumRevivedCoreChecks
swift run ContinuumRevivedPaletteChecks
CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived --previous-focus-navigation-check
./scripts/run-matrix.sh --fast
```
