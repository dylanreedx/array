## T01 Build Summary

**Spec:** T01-zone-model-optional-project-name-navkey.md
**Builder:** claude-sonnet-4-6 (cheap model)
**Branch:** overnight/workspaces-zones

### Files touched
- `Sources/ContinuumRevivedCore/WorkspaceDocument.swift` — bumped `currentSchemaVersion` 1→2; changed `ZonePlacement.projectId` to `UUID?`; added `name: String` and `navKey: String?` fields with defaults; replaced synthesized `Codable` with custom encode/decode for backward compat; updated `appendProjectZone` call site.
- `Sources/ContinuumRevivedCoreChecks/main.swift` — added T01 check block (4 assertions: v2 project-zone round-trip, v2 group-zone round-trip, v1→v2 migration from hand-written JSON, mixed-document round-trip); fixed two check orphans created by the optionality change: `zone.projectId.uuidString` → `zone.projectId?.uuidString`; `"schemaVersion\":1"` → `"schemaVersion\":2"` in the round-trip check.

### git diff --stat
```
Sources/ContinuumRevivedCore/WorkspaceDocument.swift   |  52 +++++++--
Sources/ContinuumRevivedCoreChecks/main.swift          | 116 ++++++++++++++++++++-
2 files changed, 160 insertions(+), 8 deletions(-)
```

### RED output (before implementation)
```
error: extra arguments at positions #8, #9 in call
  (ZonePlacement has no name/navKey params; projectId not optional)
error: 'nil' is not compatible with expected argument type 'UUID'
error: 'nil' requires a contextual type
```

### GREEN output
```
ContinuumRevivedCoreChecks passed
```

### --fast matrix result
```
Fast matrix passed.
```

### Deviations from spec
None. All four T01 assertions implemented exactly as specified. Backward-compat orphan fixes (projectId?.uuidString and schemaVersion string literal) are direct consequences of the optionality change — not refactoring.

### Acceptance criteria self-assessment
- [x] `ZonePlacement.projectId` is `UUID?`; `name: String` + `navKey: String?` added.
- [x] v1 workspace docs decode without error (migration assertion green: name == "", navKey == nil).
- [x] Round-trips for project zone, group zone, mixed doc all green.
- [x] No AppKit / runtime files touched; no global `tile.zoneId` introduced.
- [x] Fast matrix green.
- [ ] Commit not created — left in working tree for reviewer + orchestrator per instructions.
