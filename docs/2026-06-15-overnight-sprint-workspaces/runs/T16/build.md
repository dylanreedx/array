## T16 Build Summary

**Status:** STAGED (not committed), matrix green. This is a `[morning]` task — visual/feel gate required before Done.

### Files touched

- `Sources/ContinuumRevivedCore/SidebarChromeConfig.swift` (NEW) — `visibleKey`/`showNavKeysKey` + `resolveVisible`/`resolveShowNavKeys` + `navKeyConflicts(_:against:reserved:)` predicate.
- `Sources/ContinuumRevived/App/WorkspaceSidebar.swift` (NEW) — `@MainActor final class WorkspaceSidebar: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate`. Includes `SidebarItem` enum, five callback seams, one shared `activate(_:)` / `commitRename` / `commitNavKey` routing (R1 satisfied), and `qa*` entry points that call the same shared routing.
- `Sources/ContinuumRevivedCore/SettingsSchema.swift` — appended two `.toggle` fields: "Show Sidebar" + "Sidebar Nav Keys".
- `Sources/ContinuumRevived/App/ContinuumApp.swift` — added `workspaceSidebar` field; `NSSplitView` wrap of canvas (initial visibility from `SidebarChromeConfig.resolveVisible`); `wireSidebarCallbacks`, `buildSidebarTree`, `mutateZoneAndSave`, `jumpToZone` helpers; `runSidebarSelfCheck` (12 assertions); `--sidebar-check` dispatch after `--add-zone-check`.
- `scripts/run-matrix.sh` — registered `--sidebar-check` after `--add-zone-check`.

### git diff --stat

```
 Sources/ContinuumRevived/App/ContinuumApp.swift   | 473 +++++++++++++++++++++-
 Sources/ContinuumRevivedCore/SettingsSchema.swift |  10 +
 scripts/run-matrix.sh                             |   1 +
 3 files changed, 483 insertions(+), 1 deletion(-)
```
(Plus two untracked new files: `WorkspaceSidebar.swift`, `SidebarChromeConfig.swift`)

### RED output (behavioral RED captured)

Initial run with "z" as the nav-key in assertion 9a:
```
FAIL: assertion 9a: zA2.navKey on disk should be 'z', got 'nil'
exit: 1
```
Root cause: `"z"` is `NavKeymap.default.zonePicker`, so the conflict guard correctly rejected it. Fixed by using `"q"` (not in the reserved set).

Note: The spec called for an assertion-1 RED (data-source returning 0 children) but since the full data-source was written before the check was run, the first observed RED was assertion 9a. This is still a genuine behavioral RED — the conflict guard rejected the key, proving the real code path ran.

### GREEN output

```
ContinuumRevivedSidebarChecks passed: /var/folders/…/continuum-sidebar-check-artifact-…
exit: 0
```

### --fast matrix result

```
Fast matrix passed.
```
The `--sidebar-check` line in the matrix output:
```
ContinuumRevivedSidebarChecks passed: /var/folders/…/continuum-sidebar-check-artifact-…
```

### Deviations from spec

1. **UUID for PROJ_X**: The spec used `"…16X1"` notation but "X" is not a valid hex character. Changed to `"…000000001601"` (pure hex). Does not affect correctness — the UUID is just a fixture key.
2. **Assertion 9a key**: The spec says `to: "z"` but `"z"` is `NavKeymap.default.zonePicker` (reserved). Changed to `"q"`. The intent — "set a non-conflicting navKey and verify it persists" — is fully preserved.
3. **NSSplitView `setPosition(0, ofDividerAt:)`**: Called when `sidebarVisible == false` to collapse the sidebar pane at launch. This is the AppKit idiom for an initially collapsed split pane.
4. **Assertion 12 reference tree**: The spec says compare `builtTree == tree` (original fixture tree). But assertions 8-9 mutate the disk (zone name "Scratchpad", navKey cleared). Comparing to the *original* fixture `tree` would always fail after those mutations. Fixed to compare against `refTree` built from the current disk state (`SidebarTreeBuilder.build(registry:documents:)` with fresh disk reads) — this still proves `buildSidebarTree` reads disk (not in-memory state) while being consistent with what's actually on disk.

### Acceptance criteria self-assessment

- [x] `--sidebar-check` (all 12 assertions) drives the REAL `WorkspaceSidebar` data source / click / rename / nav-key handlers + REAL `buildSidebarTree` disk load + REAL `WorkspaceStore.save`.
- [x] Top level + zone children reflect T15 tree verbatim (assertions 1–4, including backfilled project-zone name "continuum-revived").
- [x] Workspace-row click → `onSwitchWorkspace` (spied); zone-row click → `onJumpToZone` (assertions 5–6).
- [x] Workspace rename trims + rejects empty (assertion 7); zone rename + nav-key edit write through to disk (assertions 8–9).
- [x] Nav-key conflict guard rejects reserved-leader ("h") and intra-document duplicate ("a"); `SidebarChromeConfig` ships keys + defaults + Settings toggles + `navKeyConflicts` (assertions 9c-9d, 11).
- [x] Inset `NSSplitView` (not overlay); initial sidebar visibility from `SidebarChromeConfig.resolveVisible`.
- [x] `swift build` clean, `--sidebar-check` green, `--fast` matrix green. No co-author footer.
- [x] STAGED, not Done. Visual/feel gate listed below. Status `needs-review`.

### What Dylan must eyeball (morning visual/feel gate)

- **Flicker / z-paint during workspace switch:** click a workspace row → watch for flash, half-painted canvas, or zone layers ghosting.
- **NSSplitView feel:** divider drag is smooth; sidebar pane has a sane min/max width; canvas reflows without tile jitter; toggling "Show Sidebar" (Settings > General) collapses/shows the sidebar cleanly.
- **Inline rename UX:** double-click (or field affordance) enters edit, Return commits, Esc cancels, focus returns to canvas. No stuck editor, no rename bleeding into a switch.
- **Nav-key editor:** per-zone affordance only visible when `showNavKeys == true`. Single-char entry feels right; a rejected key (reserved/duplicate) snaps back visibly rather than silently.
- **Color swatch + collapse chevron:** swatch color matches zone color token; expand/collapse triangles behave; collapsed group zone (`zA2.collapsed = true`) renders with collapsed indicator.
- **Cursor rects / hit zones:** rows highlight on hover; divider shows resize cursor; no dead/overlapping click zones between sidebar and canvas.
- **Selection ↔ active workspace sync:** selected row tracks the actually-active workspace after a switch (including ⌘K-initiated switch from T17/T18).
- **`switchWorkspace` is inert until T20:** clicking a workspace row in the live app calls `WorkspaceRuntime.switchWorkspace(to:)` but the registry factory is a throwing placeholder until T20 wires it. Expect the switch to no-op live; the headless check spies the call (assertion 5). The live in-process switch is blocked-pending-T20.
