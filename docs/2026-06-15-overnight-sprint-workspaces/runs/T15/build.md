# T15 Build Report — Sidebar view-model

## Summary

Pure TDD run: stub → RED → GREEN. Created `Sources/ContinuumRevivedCore/SidebarTree.swift` with all four types and the full builder, appended the 11-assertion "Sidebar view-model" `do{}` block to `ContinuumRevivedCoreChecks/main.swift`. No other files touched.

## Files touched

- `Sources/ContinuumRevivedCore/SidebarTree.swift` — new (78 lines): `SidebarZoneRow`, `SidebarWorkspaceRow`, `SidebarTree`, `SidebarTreeBuilder.build(registry:documents:)`
- `Sources/ContinuumRevivedCoreChecks/main.swift` — +177 lines: "Sidebar view-model" `do{}` block with all 11 assertions

## git diff --stat

```
 Sources/ContinuumRevivedCoreChecks/main.swift | 177 ++++++++++++++++++++++++++
 1 file changed, 177 insertions(+)
```
(SidebarTree.swift is untracked — new file not yet staged — so git diff --stat shows only the modified file. The full changeset is 2 files: +78 new + 177 appended.)

## RED output (assertion 1, stub returning empty tree)

```
FAIL: sidebar tree: expected 4 workspace rows, got 0
```

Confirmed: the check failed on assertion 1 ("expected 4 workspace rows, got 0") before implementation. The stub `build` returned `SidebarTree(workspaces: [])`.

Note: Initial fixture used invalid UUID strings containing hex chars X, Y, G which caused a `fatalError` crash before reaching assertion 1. Fixed the fixture UUIDs to valid hex (AAAAAAAA…, BBBBBBBB…, CCCCCCCC… prefixes) so the check reached the assertion RED properly.

## GREEN output

```
ContinuumRevivedCoreChecks passed
```

All 11 assertions pass after implementing `SidebarTreeBuilder.build`.

## Fast matrix result

```
Fast matrix passed.
```

All checks green; no regressions.

## Deviations from spec

None. The implementation follows the spec exactly:
- `registry.workspaces` array order drives top-level rows (assertion 1 trap avoided — never iterates `documents` dict for ordering)
- z-order sort uses `Dictionary(uniqueKeysWithValues: document.zoneZOrder.enumerated().map { ($0.element, $0.offset) })` with `?? Int.min` and `zoneId.uuidString` ascending tiebreak
- Project zone name backfill: `registry.projects.first(where: { $0.id == projectId })?.name ?? ""`
- Group zone name: `placement.name` verbatim
- Missing document → `zones: []`, no crash
- Empty registry → empty tree

The only minor execution deviation: fixture UUIDs in the check used invalid hex chars (X, Y, G not valid in UUID hex strings), causing a `fatalError` on optional unwrap before reaching assertion 1. Corrected by using all-hex UUID prefixes. This is a fixture-writing detail, not a spec deviation — the assertion values and IDs still satisfy all spec requirements.

## Acceptance criteria self-assessment

- [x] `SidebarTree.swift` adds `SidebarTree` / `SidebarWorkspaceRow` / `SidebarZoneRow` / `SidebarTreeBuilder.build(registry:documents:)`; all `Equatable, Sendable`; no AppKit import.
- [x] Top-level rows mirror `registry.workspaces` order and names (assertions 1–2).
- [x] Zone children sort by `zoneZOrder` then `zoneId.uuidString` (assertions 3, 8).
- [x] Project zone name is backfilled from the registry; group zone uses its stored name; unresolved project id falls back to `""` (assertions 4, 5, 7).
- [x] color / navKey / collapsed / projectId pass through per zone (assertion 6).
- [x] Missing document => empty children, no crash; empty registry => empty tree; build is deterministic (assertions 9, 10, 11).
- [x] No AppKit/runtime/`switchWorkspace`/`scripts` files touched; no new app check registered; no new `UserDefaults`/`SettingsSchema` entry.
- [x] Core checks + fast matrix green; commit message has no co-author footer (no commit made per instructions — left in working tree for reviewer + orchestrator).
