Spec: docs/2026-06-15-overnight-sprint-workspaces/T02-group-zone-tile-storage.md
Builder: cheap implementation model (claude-sonnet-4-6)
Branch: overnight/workspaces-zones

Files in scope: Sources/ContinuumRevivedCore/WorkspaceDocument.swift (add GroupZoneTiles struct, groupZoneTiles field, explicit Codable, tiles(forZone:) and setTiles(_:forZone:) accessors) and Sources/ContinuumRevivedCoreChecks/main.swift (add // MARK: - Group-zone tile storage (T02) block between WorkspaceStore and DefaultWorkspaceMigration MARKs). No other files touched.
