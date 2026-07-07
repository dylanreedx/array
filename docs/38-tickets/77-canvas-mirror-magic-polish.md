# Canvas mirror magic polish — make iPhone feel like a live desktop mirror

Status: **pending after rewritten 75/76, 2026-07-07.** This is the UX/quality layer after ticket 75's paired desktop publisher and ticket 76's dogfood kit. Do **not** polish against an unpaired/same-iCloud substrate. With `80-companion-offline-freshness.md` landed, this ticket should treat `Live`, `Syncing`, `Stale`, `Mac asleep/offline`, and `Unpaired` as first-class mirror states.

## Product goal

The iPhone Canvas tab should feel like a trustworthy mirror into the desktop Continuum canvas:

- same workspace;
- same zones and tiles;
- same relative layout and z-order;
- agent status dots on the same tiles;
- obvious freshness/connection state;
- smooth remote-change updates;
- no scary empty state when desktop has content.

The test Dylan should be able to do: move a tile on the Mac, glance at the phone, and feel like the phone is looking at the same work surface.

## Problem statement

Night-3 delivered the iOS Canvas view/editor, but it was deliberately scoped to build/prove the wire path, not the full magic mirror experience. Likely morning dogfood frictions:

- phone opens at an unhelpful zoom/viewport;
- synced desktop canvas is technically present but off-screen;
- empty state does not distinguish "desktop empty" from "sync not connected";
- workspace name/active workspace may not match what Dylan expects;
- remote changes appear abruptly or not at all until manual foreground/fetch;
- observer scope vs operator scope is unclear;
- phone edits may fail because pairing/operator scope is not finished;
- agent status dots may not visually tie the Agents list to Canvas tiles;
- no obvious timestamp says whether the phone is stale.

## What this delivers

A polished iOS mirror experience for the synced canvas:

- Canvas cold-start frames the synced desktop workspace automatically.
- Phone shows the active workspace name and `last synced` freshness.
- Non-empty desktop canvas never renders as a blank phone canvas because of bad viewport defaults.
- Remote desktop changes animate or visibly update within the honest CloudKit cadence.
- Agent status dots on tiles match the Agents tab status rows.
- Read-only/operator state is obvious and not confused with sync failure.
- A guided empty/error state tells Dylan exactly what is missing: no desktop publisher, no canvas, iCloud unavailable, stale data, or observer scope.

## Scope

### In scope

1. **Initial framing / fit-all**
   - On first materialized spatial snapshot, compute a fit-all viewport for all zones/tiles.
   - If only a single tile exists, center it at readable zoom.
   - Preserve user pan/zoom after manual interaction; do not keep snapping the user away.
   - Add a visible `Fit` button that re-runs the framing.

2. **Workspace identity**
   - Display the synced workspace name in the Canvas toolbar.
   - If v1 spatial sync lacks full workspace metadata, show an honest fallback: `Synced canvas` / `Active desktop workspace`.
   - Do not show a stale/incorrect workspace name from local iOS state.

3. **Freshness and connection state**
   - Show `Live`, `Syncing…`, `Stale as of HH:MM`, or `Offline` based on transport/supervisor signals.
   - Track last spatial snapshot/event timestamp separately from last activity timestamp.
   - If no data has arrived, say `Waiting for desktop canvas` instead of a generic empty state.

4. **Status overlay parity**
   - Join `ActivityLogSnapshot.byTile` to `CanvasSceneTile.tileId`.
   - Render status dot/pill colors consistently with `AgentsBoardProjection` tokens.
   - Tapping a status dot or tile can open the agent detail where available.

5. **Remote change feedback**
   - Animate tile frame changes when they arrive from desktop.
   - Flash or shimmer a tile briefly when a remote update lands.
   - For iPhone-originated edits, show pending state until ack/rebroadcast or failure.

6. **Read-only/operator clarity**
   - Observer scope: lock badge + `View only` label; drag gestures disabled.
   - Operator debug override: clear `Operator` badge so Dylan knows edits should work.
   - Failed phone edit: toast includes reason class (`scope`, `network`, `conflict`, `desktop rejected`) where known.

7. **Deep-link from Agents to Canvas**
   - `Show on canvas` should switch tabs, center the exact tile, and visibly highlight it.
   - If the tile is not in the spatial snapshot yet, show `Tile not synced to canvas yet` rather than silently doing nothing.

8. **Dogfood visual artifacts**
   - Capture iPhone screenshots for:
     - initial fit-all canvas;
     - tile status overlay;
     - remote desktop move update;
     - observer lock badge;
     - stale/offline state.

### Out of scope

- Implementing the desktop publisher/fetch pump (ticket 75).
- Creating desktop canvas content (ticket 76 dogfood fixture handles setup).
- Full workspace creation/deletion from iPhone.
- Streaming mid-drag frames.
- Pixel-perfect parity with macOS rendering; the phone is a legible replica, not a screenshot stream.

## Implementation notes

### First snapshot framing

Add an iOS-side state machine:

```swift
enum CanvasFramingState {
    case waitingForFirstSnapshot
    case autoFramedFirstSnapshot
    case userControlled
}
```

When `CanvasScene.tiles` or `zones` transitions from empty to non-empty, compute fit-all unless state is already `.userControlled`. Pan/zoom gestures switch to `.userControlled`.

### Staleness model

Track:

- `lastSpatialUpdateAt`
- `lastActivityUpdateAt`
- `connectionState`
- `lastManualRefreshAt`

Render the most conservative state in the toolbar. If spatial is stale but activity is fresh, say `Canvas stale · Agents live`.

### Tile highlight

When `requestCanvasFocus(tileId:)` succeeds:

- switch to Canvas tab;
- center the tile;
- set `highlightedTileId` for ~2 seconds;
- draw a high-contrast ring around that tile.

## Files likely touched

- `ios/Continuum/Sources/ContinuumApp.swift` — Canvas tab framing, freshness UI, status overlays, highlight flow.
- `Sources/ContinuumRevivedCore/CanvasSceneProjection.swift` — only if missing metadata needed by iOS can be added without violating sync purity.
- `Sources/ContinuumRevivedCore/AgentsBoardProjection.swift` — reuse existing status token mapping; avoid duplicate iOS-only status logic.
- `docs/38-tickets/_COMPANION_SPEC.md` — only if morning dogfood revises the canvas UX contract.

## Tests / gates

### Autonomous checks

Add pure checks in Core or iOS-adjacent logic where possible:

1. **Fit-all framing table**
   - Empty scene → no viewport change.
   - One tile → centered readable viewport.
   - Multi-zone scene → all zones/tiles visible with margin.
   - User-controlled state → remote update does not auto-snap.

2. **Freshness label table**
   - no data → `Waiting for desktop canvas`.
   - connected + recent spatial → `Live`.
   - spatial stale + activity recent → `Canvas stale · Agents live`.
   - offline → `Offline — showing data as of HH:MM`.

3. **Status join table**
   - tile with activity status gets matching glyph/color token.
   - tile without activity gets neutral/unknown status.
   - activity for non-spatial tile does not crash and is visible from Agents only.

4. **Show-on-canvas behavior**
   - tile present → tab switch + center + highlight.
   - tile absent → user-visible message.

### Supervised visual gate

On physical iPhone:

1. Fresh launch with a non-empty desktop canvas: phone frames it without manual pinch/pan.
2. Move tile on desktop: phone tile visibly updates.
3. Tap an agent row → `Show on canvas`: tile centers and highlights.
4. Kill/disable desktop publisher: phone shows stale/offline state without blanking.
5. Observer scope: lock badge visible; dragging does not mutate.

Artifacts go under `qa-runs/<timestamp>/canvas-mirror/`.

## Done when

- A non-empty desktop canvas appears on the phone without manual viewport surgery.
- The phone never confuses `waiting for sync`, `desktop canvas empty`, and `stale/offline`.
- Agent status on canvas tiles matches the Agents tab.
- `Show on canvas` feels reliable and visible.
- Remote desktop tile movement is observable on the phone within the ticket-75 CloudKit cadence.
- Screenshots prove the five supervised visual states above.

## Watch out for

- **Do not auto-fit forever.** First snapshot fit is magic; fighting the user's manual pan/zoom is annoying.
- **Do not hide staleness.** A stale mirror is useful only if it says it is stale.
- **Do not invent workspace metadata in iOS.** If the sync payload does not include it yet, use honest fallback labels.
- **Do not make observer scope feel broken.** Disabled gestures need a clear lock/read-only badge.
- **Do not add transcript bodies to make details richer.** Status dots and summaries only.

## Execution mode

**Supervised + needs-substrate.** Most logic is checkable, but the ticket is only valuable if Dylan can physically dogfood the iPhone as a mirror of the desktop canvas.
