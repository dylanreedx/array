# T16 — Zone navigation scale/readability policy + fit-zone framing

Status: implementation-ready bounded slice
Tag: tonight [zones] [navigation] [camera]
Depends on: T06, T07
Related: T08 previous zone navigation

## Goal
Make zone navigation and canvas scale feel coherent by defining initial readability bands and ensuring zone jumps use the same camera framing model as tile jumps.

This ticket is **not** a full minimap/semantic-zoom implementation. It is the bounded first slice that gives agents clear constants and a deterministic zone-fit path.

## Implementation decisions
No open UX questions for the overnight agent:

1. Use `CanvasViewport { x, y, zoom }` as the camera model.
2. Define initial readability bands in code as policy constants.
3. Zone jump frames zone bounds with overview zoom, not raw anchor panning.
4. Tile jump aims for readable/detail zoom; zone jump aims for overview/context zoom.
5. Far zoom may show labels/chrome only; do not make editing claims below readable thresholds.
6. Minimap/global overview is deferred to follow-up; do not build it here.
7. Visible zoom percentage UI is optional; if not implemented, create/follow a separate ticket and do not make checks depend on it.

## Code seams
Likely files/symbols:

- `Sources/ContinuumRevivedCore/ReadabilityPolicy.swift` — new pure policy suggested
- `Sources/ContinuumRevivedCore/CameraFraming.swift` — from/with T07 if present
- `Sources/ContinuumRevivedCore/CanvasEngine.swift`
  - `fit(...)`
  - `zoneWorldFrame(...)`
  - zone bounds helpers
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift`
  - `fitZoneToViewport(zoneId:)`
  - `navZoneRenderModels`
  - leader zone assignment paths
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
  - `jumpToZoneFromPalette`
  - `jumpToZoneByOrder` / ordinal zone jumps
- `Sources/ContinuumRevivedCore/LaunchPaletteModel.swift`
  - jump-to-zone rows

## Readability policy defaults
Add a pure policy with initial bands:

```swift
public enum ReadabilityBand: Equatable, Sendable {
    case overviewLabelOnly
    case readableSummary
    case editableDetail
}
```

Default thresholds:

| Target kind | overviewLabelOnly | readableSummary | editableDetail |
|---|---:|---:|---:|
| zone | 0.10..<0.35 | 0.35..<0.80 | n/a |
| note | 0.10..<0.60 | 0.60..<0.85 | 0.85... |
| browser | 0.10..<0.70 | 0.70..<0.90 | 0.90... |
| terminal | 0.10..<0.85 | 0.85..<0.95 | 0.95... |
| file/file-tree/diff/other | 0.10..<0.70 | 0.70..<0.90 | 0.90... |

Editing/typing affordance rule:
- terminal/browser/note editing is considered reliable only in `.editableDetail`;
- `.readableSummary` may show content/title but should not be treated as ideal active editing scale;
- `.overviewLabelOnly` should emphasize titles/zones/labels, not content detail.

## Zone framing policy
Defaults:

```text
zonePaddingScreenPx = 96
zoneMinOverviewZoom = 0.20
zoneMaxOverviewZoom = 0.80
```

Rules:
- fit the zone bounds with padding;
- clamp zoom to `zoneMinOverviewZoom ... zoneMaxOverviewZoom`;
- prefer stored `ZonePlacement` world frame for first implementation unless an existing adaptive zone bounds helper is already production-used for chrome/member bounds;
- if zone has a known last-focused tile and command is previous-zone from T08, T08 may frame that tile instead; normal zone jump frames the zone overview.

## Working-view definitions
Initial practical definitions for docs/checks:

```text
Overview view: zone labels and tile titles are useful; detailed editing is not expected.
Working view: 1–4 main tiles are readable/usable.
Detail view: one focused tile is editable/interactive.
```

Do not attempt to enforce a max tile count in code in this ticket. Use these definitions to guide framing tests and follow-up UX dogfood.

## Acceptance criteria
- [ ] `ReadabilityPolicy` exists with default bands for zone/note/browser/terminal/other.
- [ ] Policy tests prove band classification at representative zooms.
- [ ] Zone jump uses camera fit/framing with padding and zoom clamp.
- [ ] Zone jump does not merely select a zone or pan to an anchor.
- [ ] Leader zone jump and palette zone jump use the same framing path or explicitly share a helper.
- [ ] Minimap/semantic zoom/global overview are explicitly deferred, not partially implemented.
- [ ] If zoom percentage UI is deferred, follow-up is recorded and checks do not depend on it.

## Nightly QA contract

### Required checks
Pure/Core:

```text
ReadabilityPolicy table in ContinuumRevivedCoreChecks
Zone fit/framing table in ContinuumRevivedCoreChecks
```

App flag:

```text
--zone-framing-readability-check
```

The app check should:
- create at least two zones with tiles;
- invoke zone jump through real leader/palette path if practical;
- assert final viewport contains zone bounds with padding or within expected aspect-ratio adjustment;
- assert final zoom is within zone overview clamp;
- assert tile detail editing is not claimed at overview zoom;
- write artifact manifest.

### Required artifact

```text
qa-runs/<timestamp>/zone-framing-readability/manifest.json
```

Minimum fields:

```json
{
  "check": "zone-framing-readability",
  "zoneId": "...",
  "zoneBounds": {"x":0,"y":0,"w":2200,"h":1200},
  "startViewport": {"x":0,"y":0,"zoom":1.0},
  "finalViewport": {"x":-120,"y":-80,"zoom":0.55},
  "zonePaddingScreenPx": 96,
  "zoneZoomClamp": {"min":0.2,"max":0.8},
  "finalZoomBand": "readableSummary",
  "containsZoneBounds": true,
  "semanticZoomDeferred": true,
  "minimapDeferred": true
}
```

### Stop conditions
Do not mark Done if:
- readability thresholds are left as open questions;
- zone jump only selects a zone without camera framing;
- leader/palette zone paths diverge without explanation;
- minimap/semantic zoom scope creeps into this ticket;
- checks assert only pure policy but not production zone jump when implementation claims zone navigation behavior.

## Verification commands

```bash
swift build
swift run ContinuumRevivedCoreChecks
swift run ContinuumRevivedPaletteChecks
CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived --zone-framing-readability-check
./scripts/run-matrix.sh --fast
```

## Follow-up tickets explicitly deferred
- Semantic zoom rendering: collapse tiles to labels/cards at far zoom.
- Minimap/global overview.
- Visible zoom percentage/current camera mode UI.
- Empirical dogfood tuning of readability thresholds.
