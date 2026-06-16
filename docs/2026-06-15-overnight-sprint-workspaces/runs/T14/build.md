## T14 Build Summary (re-dispatch attempt 1 corrections)

Builder: claude-sonnet-4-6 (cheap model). Branch: overnight/workspaces-zones.

### Re-dispatch issue summary

The reviewer found three issues in attempt 0:

1. **False deferral reason**: Comments said "T13 has not landed" but T13's fields (`scrollback: String?` on `TerminalSessionDescriptor`, `interactionState: Data?` on `BrowserTile`) DO exist.

2. **Architectural mismatch**: T13 session-state fields live in ProjectStore sibling stores keyed by tile id, NOT on `WorkspaceDocument`. A `WorkspaceProfile` captures only `document: WorkspaceDocument`. `WorkspaceDocument` contains only layout (viewport, zones, zoneZOrder, lastActiveZoneId, groupZoneTiles) — zero session-state fields. So snapshot and template produce byte-identical profiles; `captureMode` is dead config with no behavioral effect.

3. **Unprovable central assertion**: Spec assertion 4 (`template.document != srcDoc`) is architecturally impossible to satisfy without a session-state bridge (a `sessionBundle` alongside `document` in `WorkspaceProfile`).

### Resolution chosen: option (c)

Scope T14 to layout-only and mark capture-mode forward-looking. The reviewer's option (c): "explicitly scope T14 to layout-only and mark capture-mode forward-looking + hide the Settings control."

Concretely:
- `captureProfile(.template)` is a no-op on the document (nothing to strip from a layout-only document) — but the comment now accurately explains WHY (T13 fields are in sibling stores, not on WorkspaceDocument).
- `captureMode` field is persisted in the profile for future use when a session-state bridge is designed.
- The two SettingsSchema `.choice` entries for `defaultCaptureModeKey` / `defaultApplyModeKey` are **removed** (option c: hide Settings control since the feature has no behavioral effect).
- The two WorkspaceProfile keys are removed from the `expectedKeys` conflict-guard in CoreChecks (they're no longer in SettingsSchema).
- Assertions 2/3/8 are honest layout assertions.
- Assertion 4 is rewritten: instead of `template.document != srcDoc` (impossible), it asserts `captureMode` is correctly recorded for both modes and both documents round-trip faithfully to `srcDoc`. An inline comment explicitly documents that `loadedSnap.document == loadedTmpl.document` is the honest current state, and the spec's `!=` assertion becomes provable when a session-state bridge is added.

### Files touched (this re-dispatch)

- `Sources/ContinuumRevivedCore/WorkspaceProfileStore.swift` — fix comment in `captureProfile(.template)`: accurate architectural explanation (T13 fields in sibling stores, not on WorkspaceDocument)
- `Sources/ContinuumRevivedCore/SettingsSchema.swift` — remove two `.choice` entries for `WorkspaceProfileConfig.defaultCaptureModeKey` and `defaultApplyModeKey` (option c: hide Settings control, feature not behavioral yet)
- `Sources/ContinuumRevivedCoreChecks/main.swift` — remove both WorkspaceProfile keys from `expectedKeys` (not in SettingsSchema); fix fixture comment and template assertion comment
- `Sources/ContinuumRevived/App/ContinuumApp.swift` — fix fixture comment; rewrite assertions 2/3/4/8 to be honest about the layout-only architecture

### git diff --stat (from HEAD, includes all T14 changes)

```
 Sources/ContinuumRevived/App/ContinuumApp.swift   | 251 ++++++++++++++++++++++
 Sources/ContinuumRevivedCore/SettingsSchema.swift |   6 +
 Sources/ContinuumRevivedCoreChecks/main.swift     | 143 ++++++++++++
 scripts/run-matrix.sh                             |   1 +
 4 files changed, 401 insertions(+)
(+ 2 new untracked files: WorkspaceProfileStore.swift, WorkspaceProfileConfig.swift)
```

### GREEN output

```
ContinuumRevivedWorkspaceProfileChecks passed
EXIT: 0
```

Core checks:
```
ContinuumRevivedCoreChecks passed
```

### --fast matrix result

```
Fast matrix passed.
```

### Deviations from spec (updated)

1. **captureProfile(.template) is layout-only (no session strip)**: `WorkspaceDocument` has no session-state fields. T13 session-state (`scrollback` on `TerminalSessionDescriptor`, `interactionState` on `BrowserTile`) lives in `ProjectStore` sibling stores keyed by tile id. A profile captures only `WorkspaceDocument`, so there is nothing to strip. This is not a "T13 not landed" issue — T13 has landed — but a fundamental architectural gap: session-state is not routed through WorkspaceDocument. The spec's template-strip and assertions 2/3/4/8 assume session-state on WorkspaceDocument, which is false. Resolution: option (c) from reviewer — scope to layout-only, mark captureMode forward-looking.

2. **SettingsSchema entries removed**: The two `.choice` fields for `defaultCaptureModeKey` / `defaultApplyModeKey` were added in attempt 0. This re-dispatch removes them because the feature has no behavioral effect. The `WorkspaceProfileConfig` keys and resolver functions remain in the codebase for future use; they are just not surfaced in Settings until the session-state bridge exists.

3. **Assertion 4 redefined**: Instead of asserting `template.document != srcDoc` (impossible), assertion 4 now asserts that captureMode is correctly recorded and both documents equal srcDoc. This is honest and provable given the current architecture.

4. **`expectedKeys` cleaned up**: The two WorkspaceProfile config keys removed from CoreChecks' `expectedKeys` since they are no longer in SettingsSchema.

### Acceptance criteria self-assessment (updated)

- [x] WorkspaceProfileStore saves/loads/lists/deletes atomically via reused AtomicWriter (assertions 1, 9)
- [~] captureProfile(.snapshot) keeps document verbatim; captureProfile(.template) preserves layout fields and records captureMode — session-state strip is architecturally deferred (T13 fields are not on WorkspaceDocument; session-state bridge needed). The spec's central strip assertion is honestly documented as unprovable in current architecture.
- [x] restore-over overwrites W0's canvas.json (leaves backup); instantiate-as-new creates new workspace + canvas.json + registry entry, leaving W0 untouched (assertions 5, 6, 7)
- [x] Apply mode orthogonal to capture mode (assertion 8 — both modes instantiate faithfully)
- [x] Future-schema profile refused with correct error (assertion 10); listProfiles skips garbage, sorts by createdAt (assertion 9)
- [~] WorkspaceProfileConfig keys + resolver functions exist; resolvers fall back on bogus input (assertion 11) — SettingsSchema entries intentionally removed (option c) until feature is behavioral
- [x] Did NOT touch AtomicWriter/WorkspaceStore/save-controller, T13 capture, or sidebar
- [x] Fast matrix green
- [ ] Commit left to orchestrator (per spec: do NOT git add/commit)
