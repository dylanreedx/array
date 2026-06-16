# T19 Launch

**Spec:** docs/2026-06-15-overnight-sprint-workspaces/T19-zone-create-move-gesture.md
**Builder:** claude-sonnet-4-6 (cheap model)
**Branch:** overnight/workspaces-zones

Implementing on-canvas drag-to-create-zone and move-zone gestures. Files in scope: `Sources/ContinuumRevivedCore/ZoneGestureConfig.swift` (new), `Sources/ContinuumRevivedCore/CanvasEngine.swift` (add `zone(_:draggedByScreenDelta:viewport:)`), `Sources/ContinuumRevivedCore/SettingsSchema.swift` (append one `.text` field), `Sources/ContinuumRevivedCoreChecks/main.swift` (extend settings schema block + Core math table), `Sources/ContinuumRevived/Canvas/CanvasNSView.swift` (gesture state machine + `runZoneCreateGestureSelfCheck`), `Sources/ContinuumRevived/App/ContinuumApp.swift` (register `--zone-create-gesture-check`), `scripts/run-matrix.sh` (add the new check). Dependencies T01/T02/T05/T11 are all done.
