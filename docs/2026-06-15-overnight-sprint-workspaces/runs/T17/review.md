# T17 Review — ⌘K zone rows (jump-to-zone, create-zone)

Reviewer: adversarial / independent. Branch `overnight/workspaces-zones`, uncommitted.
Verdict: **PASS WITH RISKS** (committable; named risks below need a human ruling, not a code fix).

## 1. Bypass audit (#1 gate) — PASS

The app check `--palette-zone-check` drives the REAL handler
`app.performPaletteAction(.jumpToZone(...))` / `.performPaletteAction(.createZone)`
(ContinuumApp.swift:7836 / :7891) inside an open `.palette` modal, then asserts
OBSERVABLE state (canvas viewport, `navSelectedZoneIdForQA`, `focusBroker.activeSurface`
after a real `closeModal`, and the on-disk `WorkspaceDocument` re-`load()`ed from disk).

I re-ran the check myself: GREEN.
I then PROVED RED by stubbing BOTH production fns empty
(`jumpToZoneFromPalette`/`createGroupZoneFromPalette`), rebuilding, and re-running:
```
FAIL: palette jump-to-zone: viewport must fit zone B; got (0.0,0.0,1.0)
      want (1287.80...,-29.26...,1.3666...)
EXIT=1
```
I restored the exact original text (diff stat back to 264+/2-, no REVIEWER-STUB markers),
rebuilt, re-ran: GREEN. The check is NOT a stub-bypass.

Create-zone is on-disk: production resolves `appSupport =
registryStore.registryFile.deletingLastPathComponent()` (RegistryStore.swift:17 puts
`registry.json` directly in appSupport, so parent == appSupport), then
`WorkspaceStore(workspaceId:, applicationSupportDirectory: appSupport)` → same
`appSupport/workspaces/<W>/canvas.json` the check writes/reads. Assertion 9 re-`load()`s
from disk AFTER the action (proves the save flushed via `WorkspaceDocumentSaveController`).

## 2. Right reason — PASS

Hand-derived viewport for zone B (origin (1400,0), 800×600), viewport 1400×900:
availW=1320, availH=820, zX=1.65, zY=820/600=1.36667, zoom=min=1.36667. The check's
`expectedViewport` is computed by the SAME `CanvasEngine.fit` the production
`fitZoneToViewport` (CanvasNSView.swift:504-511) uses, reading `zoneWorldFrame(placement)`
= (1400,0,800,600). Manifest emitted zoom=1.3666666666666667 — matches my derivation, not
a stale hardcoded number.

`createdZoneOrigin.x = 1400` = firstZone.size.width(1280) + gap(120). Matches.

Focus-survival (assertion 5) is load-bearing: `jumpToZoneFromPalette` enters
`.tile(tileId)` with `.tileSpawned` (ContinuumApp.swift:2958). FocusBroker sets
`tileSpawnedDuringModal=true` only for a `.tileSpawned` request while a modal snapshot
exists (FocusBroker.swift:62-63), and `closeModal` skips the snapshot restore iff that
flag is set (FocusBroker.swift:112-116). With the stub (no `.tileSpawned`), the snapshot
`.canvas` is restored and assertion 5 goes RED. Confirmed by the stub run.

## 3. Scope — PASS (with config-coverage caveat in Risks)

- `appendGroupZone` (WorkspaceDocument.swift:92-118) is a faithful mirror of
  `appendProjectZone` (projectId:nil, name:). ZonePlacement init order matches T01's
  shape (zoneId, projectId, origin, size, color, collapsed, hydrationPolicy, name, navKey).
- Do-NOT-touch list respected: `addProjectZone` untouched (verified in diff), no
  leader zone-jump (`jumpToZoneByOrder`/`fitNavZone`/`jumpToZoneOrdinal`) edits, no
  sidebar files in the diff, tile-jump rows mirrored not refactored.
- Configurable-first present: `DefaultGroupZoneName` resolver
  (userDefaultsKey/fallback/.resolve()), SettingsSchema `.text` General field, and the
  key added to the CoreChecks settings-key conflict guard (main.swift:4252, inside a
  Set-subset + uniqueness guard). Production reads `.resolve()` (ContinuumApp.swift:2994),
  NOT a hardcoded "Zone".
- No co-author footer concern (nothing committed; review is read-only).

## 4. Matrix — PASS

`./scripts/run-matrix.sh --fast` → "Fast matrix passed." (run twice: once as-shipped,
once after my stub/restore round-trip). `git diff --check` clean.

## 5. Domain / edge probes

- Unknown-zone no-op (assertion 6): guard rejects a zone not in
  `navZoneRenderModels` — viewport + activeSurface unchanged. Verified.
- "Create Zone…" is now UNCONDITIONALLY appended (every palette invocation), and matches
  queries "new"/"create"/"zone". Core assertion 2 confirms "new" now includes it. Intended
  per spec (single unconditional Create Zone row).
- Append order guarded: Core assertion 6 proves tile-jump < zone-jump < Create Zone.

## Confirmed defects
None.

## Risks (committable, but a human should rule)

- **[UX change masked by a weakened existing test] nav-z default selection.**
  The `--nav-mode-check` assertion was changed from
  `selectedDisplayNameForQA?.contains("Review Zone") == true` (the *first-selected* row
  after the "zone" prefill is the Review Zone PROJECT) to
  `filteredDisplayNamesForQA.contains { contains("Review Zone") }` (present ANYWHERE).
  This is NOT a test bug — it reflects a real behavior change: after T17, jump-to-zone
  rows AND the unconditional "Create Zone…" row also match the "zone" query and sort
  BEFORE projects in `makeRows`, so pressing nav-z now default-highlights "Create Zone…"
  / a zone-jump row, and Enter would Create/Jump instead of switching to the Review Zone
  project. (`filterRows` preserves `makeRows` order; verified.) The weakened test no
  longer pins what nav-z's default action is. A human must decide if that default-action
  shift is acceptable; if not, this is a real regression to a shipped path (T-prior
  nav-mode keyboard flow). docs/26 verification doctrine flags exactly this:
  weakened-existing-assertion masking a UX change.

- **[Configurable override unproven] DefaultGroupZoneName.resolve().**
  Sibling resolvers (DragMagnetize, ZoneHydrationReconcile, AmbientZoneHome) each get an
  isolated-suite UserDefaults round-trip in CoreChecks proving the OVERRIDE path. The new
  resolver only gets schema-key membership + `newZone.name == DefaultGroupZoneName.resolve()`
  in the create check — and that check never SETS the UserDefaults key, so both sides
  resolve to the empty-default "Zone". The "reads a user override" behavior is never
  exercised by any check. Not mandated by the spec's literal Part A/B check list, but
  MEMORY's configurable-first doctrine implies it. Low blast radius (resolver is 6 lines,
  modeled on DefaultBrowserURL), but unverified.

## Design choices to surface (needsHuman)

- **`.createZone` placement** = `makeRows`-append (spec's default), NOT
  `CommandRegistry.paletteActions()`. Spec marked this NEEDS-HUMAN. Consequence: Create
  Zone is unconditional and lands after zone rows / before workspaces+projects, and shows
  up under "new"/"create"/"zone" queries everywhere.
- **Focus target = option (a)**, but using `zoneRect.intersects(tileRect)` (any overlap),
  not the spec's "tile whose world frame falls INSIDE the zone's world rect" (containment).
  For the check's tile (fully inside B) both agree, so the deviation is untested. A tile
  straddling a zone boundary would match the broader `intersects` predicate — a human
  should confirm "first overlapping tile" is the intended focus target vs "first contained
  tile". Also: an EMPTY zone jump pans only and focus does NOT survive closeModal (per
  option (a)); the check only covers a non-empty zone.
- **`navSelectedZoneIdForQA` QA accessor added** (spec NEEDS-HUMAN: confirm a QA hook on
  `navSelectedZoneId` is acceptable; matches the `searchTextForQA` precedent).
- **`createGroupZoneFromPalette` workspace resolution** is
  `workspaceRuntime?.workspaceId ?? registry.lastActiveWorkspaceId`, and is described as
  mirroring `addProjectZone`'s persistence body — but the REAL `addProjectZone`
  (ContinuumApp.swift:3103) delegates document save to `workspaceRuntime.addZone(...)` and
  does NOT use `WorkspaceStore(...).load()` + `WorkspaceDocumentSaveController`. So the new
  persistence body is net-new code (matching the spec PROSE, not the real fn). The check's
  scenario 2 wires only `registryStore` (no runtime), so it exercises ONLY the
  `lastActiveWorkspaceId` fallback branch — the primary `workspaceRuntime?.workspaceId`
  branch (the real in-app path) is UNVERIFIED.

## Unverified
- The primary `workspaceRuntime?.workspaceId` create-zone branch (only the fallback is
  tested).
- `DefaultGroupZoneName` override-read path (no round-trip test).
- `firstTileInZone` containment-vs-intersects on a boundary-straddling tile (untested).
- Empty-zone jump (pan-only, focus does not survive) — untested per option (a).
- Visual/manual: actual ⌘K palette rendering of the new rows (no screenshot gate run).
