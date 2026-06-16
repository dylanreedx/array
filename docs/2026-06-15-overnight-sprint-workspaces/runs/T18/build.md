## T18 Build Summary

**Model:** claude-sonnet-4-6 (cheap builder)
**Branch:** overnight/workspaces-zones

### Files touched

- `Sources/ContinuumRevivedCore/NavKeymap.swift` — added `leaderZoneOrdinalKeys` field (default "123456789"), `leaderZoneOrdinalKeysDefaultsKey`, `leaderZoneOrdinalAlphabet` computed accessor, `leaderZoneOrdinalKeys` param in `init`, default in `NavKeymap.default`, `resolve` block (same rules as `leaderLabelKeys` but allows digits+letters), `persist` line, and the `zoneJumpLabels` static method.
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift` — added `leaderZoneOrdinalAlphabet` stored prop (mirroring `leaderLabelAlphabet`), `leaderZoneJumpAssignments()`, and `leaderZoneJumpTarget(forKey:)`.
- `Sources/ContinuumRevived/App/ContinuumApp.swift` — pushed `leaderZoneOrdinalAlphabet` in `activateLeader()`, added zone-jump branch before tile-jump in `handleLeaderKey`, added `runLeaderZoneJumpSelfCheck()` static fn (245 lines), registered `--leader-zone-jump-check` in CommandLine dispatch.
- `Sources/ContinuumRevivedCore/SettingsSchema.swift` — appended `leaderZoneOrdinalKeys` `.text` field in navigation section.
- `scripts/run-matrix.sh` — registered `--leader-zone-jump-check` after `--leader-jump-check`.
- `Sources/ContinuumRevivedCoreChecks/main.swift` — added Core table for `zoneJumpLabels` (7 assertions, all hand-derivable).

### git diff --stat

```
Sources/ContinuumRevived/App/ContinuumApp.swift    | 245 +++++++++++++++++++++
Sources/ContinuumRevived/Canvas/CanvasNSView.swift |  26 +++
Sources/ContinuumRevivedCore/NavKeymap.swift       |  80 ++++++-
Sources/ContinuumRevivedCore/SettingsSchema.swift  |   5 +
Sources/ContinuumRevivedCoreChecks/main.swift      |  70 ++++++
scripts/run-matrix.sh                              |   1 +
6 files changed, 426 insertions(+), 1 deletion(-)
```

### RED output

Before `leaderZoneJumpAssignments` and `leaderZoneJumpTarget` were added to CanvasNSView, the app check (`runLeaderZoneJumpSelfCheck`) would not compile (the symbols don't exist). After adding the CanvasNSView stubs (returning `[]`/`nil`) the check compiled and assertion 2 failed on the value:

```
FAIL: assertion 2: zA must be assigned auto ordinal '1'
```

Core check assertion 1 passed immediately because `zoneJumpLabels` was added as a full implementation (not a stub), going directly GREEN on the Core table. The app check went RED on assertion 2 (empty assignments) until `zoneJumpLabels` wired through `leaderZoneJumpAssignments`.

### GREEN output (app check)

```
ContinuumRevivedLeaderZoneJumpChecks passed: .../qa-runs/2026-06-16T125638Z/leader-zone-jump/manifest.json
```

### --fast matrix result

```
Fast matrix passed.
```

All checks including `--leader-jump-check` (tile path regression) and `--leader-zone-jump-check` passed.

### Deviations from spec

None. All 8 app assertions and 7 Core-table assertions are present. The zone-jump branch is inserted before the tile branch (after Esc and arrow guards) per spec step 5. The `leaderZoneOrdinalAlphabet` is pushed in `activateLeader()` alongside `leaderLabelAlphabet` so the check opens the leader through the real path and the alphabets are set by the real wiring.

### Self-assessment against acceptance criteria

- [x] `--leader-zone-jump-check` drives leader via synth `.flagsChanged`/`.keyDown` → `handleFlagsChanged`/`handleHotkey`/`handleLeaderKey`; viewport asserted via `vpEqual`, never by calling `fitZoneToViewport` directly.
- [x] All 8 app assertions + 7 Core-table assertions pass; each expected value is derived from `CanvasEngine.fit` or `NavKeymap.zoneJumpLabels` (not hand-rounded).
- [x] Auto-ordinal assignment (nil navKey → "1"/"2") proven in assertion 3; configured navKey override proven in assertion 4.
- [x] Precedence: assertion 5 builds a canvas where tile label "a" collides with zone navKey "a", presses "a" through the real handler, and confirms the zone-fit viewport (not tile-center).
- [x] `leaderZoneOrdinalKeys` configurable: UserDefaults default "123456789" + resolve/persist round-trip (Core §0.7) + SettingsSchema entry + invalid-value rejection (dup and empty) with warn.
- [x] `--leader-jump-check` unchanged and still green.
- [x] Fast matrix green.
