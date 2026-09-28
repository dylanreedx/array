# Zone <-> Project Home binding — investigation

## Model summary

A zone's project binding is `ZonePlacement.projectId: UUID?` (+ optional
`homeRelativePath`), defined in
`Sources/ContinuumRevivedCore/WorkspaceDocument.swift:326` (as a computed
`ZoneScope` at :374). It is a field on the ZONE, not the reverse — there is no
`zoneId` stored on a `Project`/`ProjectEntry`. `projectId == nil` means either
a legacy "needs project" zone (`ZoneScope.needsProject`) or a **group zone**
(`appendGroupZone`, WorkspaceDocument.swift:220-245) which is deliberately
project-less and renders from the flat, project-less `ambientTiles` register
instead of a project's own canvas.

The project itself is a separate record, `ProjectEntry` in
`Sources/ContinuumRevivedCore/Registry.swift`, holding `rootPath`, `name`,
`missing: Bool`, and — the ownership link — `workspaceId: UUID?`. A zone names
a project by UUID only; resolving that UUID to a directory path/name always
goes through the **Registry**, never through anything stored on the zone
itself.

So there are really three cooperating records:
- `ZonePlacement.projectId` (in a `WorkspaceDocument`) — "this zone is for
  project X."
- `ProjectEntry.workspaceId` + `WorkspaceEntry.projectIds` (in `Registry`) —
  "project X belongs to workspace W" (exclusive ownership, enforced by
  `Registry.exclusiveWorkspaceOwner(of:)`, Registry.swift ~155-230).
- `ProjectEntry.rootPath`/`name` (also in `Registry`) — what actually gets
  displayed in the zone header.

**The zone can hold a perfectly intact `projectId` while the app still fails
to show the directory**, because display and scene-membership both require a
second, independent lookup into the Registry that can silently miss.

## Stores table

| Data | Store | File | Channel-split? |
|---|---|---|---|
| `ZonePlacement.projectId`/`homeRelativePath` (the zone's own binding) | `WorkspaceDocument.zones` | `WorkspaceStore` under `<app support>/…` (`WorkspaceRuntime.swift:1425-1447`, keyed by workspace UUID) | **Yes** — lives under `registryStore.registryFile.deletingLastPathComponent()`, i.e. Application Support, which the prod/dev channel split covers (CLAUDE.md non-negotiable #1) |
| `ambientTiles` (project-less tiles for group zones) | Same `WorkspaceDocument` | Same file as above | Yes (same file) |
| `ProjectEntry.rootPath/name/missing/workspaceId` (what resolves the UUID to a path) | `Registry` | `registry.json` in Application Support (`RegistryStore.swift`) | Yes |
| A project's own canvas/tiles/notes (`ambientTiles`-equivalent per-project data, NOT the zone chrome) | `ProjectStore` | `<project root>/.array/` | **No** — shared across channels (hazard 9/10) |
| `lastExplicitCreationScope` (recent-project convenience for the picker) | Same `WorkspaceDocument` | Same app-support file | Yes |

Net: the zone's binding to a project (the thing hazard asks about) is
**entirely an app-support, channel-split artifact**. Only the *contents* of
that project (its own tiles/canvas) live in the shared `.array/`. A zone
binding cannot be "fought over" between a prod and a dev install the way
hazard 9/10 describes for `.array/` — instead, prod and dev simply have
**two completely independent zone/project registries**, so a zone created
in one channel is invisible (not merely mismatched) in the other. That's a
distinct hazard from #10, worth flagging explicitly since the ticket asked
about it.

## Writers table

| Writer | What it updates | Persists via |
|---|---|---|
| `presentProjectHomePicker` → `onConfirm` (ContinuumApp.swift:14872-14935) | Registry ownership (`assignProject`) THEN `canvasView.commitProvisionalZone`/`setZoneScope` (zone.projectId) | Registry saved directly (`registryStore.save`); zone change flows to `onZoneCreated`/`onZoneMoved` callback |
| `CanvasNSView.commitProvisionalZone` (CanvasNSView.swift:977) | `liveZones[i].projectId/homeRelativePath` in memory | Calls `onZoneCreated?(placement)` — no direct disk write itself |
| `CanvasNSView.setZoneScope` (CanvasNSView.swift:1016) | Same, for an *existing* zone | Calls `onZoneMoved?(placement)` (reusing the move-persist path) |
| `ContinuumApp.persistCreatedGroupZone`/`onZoneCreated` handler → `WorkspaceRuntime.commitCreatedZone` (WorkspaceRuntime.swift:115-131) | Appends the zone to `document.zones`, asserts/assigns Registry ownership first, throws `alreadyOwned` if another workspace owns the project | `persistWorkspaceDocument()` → synchronous `flush(through:)` |
| `onZoneMoved` handler → `ContinuumApp.persistMovedZone` → `WorkspaceRuntime.commitZonePlacement` (WorkspaceRuntime.swift:108-113) | Replaces `document.zones[index]` wholesale (includes `projectId`) | Same synchronous flush |
| `addProjectZone` (ContinuumApp.swift:15340) / `WorkspaceRuntime.addZone(projectId:)` | Registry `assignProject` THEN zone creation | Registry save + `commitCreatedZone` |
| `ensureZoneForActiveProject`/`ensureZone(forProject:controller:)` (WorkspaceRuntime.swift:586-613) | **Creates a brand-new zone** for a project if none exists in `document.zones` for it | `try? persistWorkspaceDocument()` (errors swallowed) |
| `registerProjectUsingOpenPanel` (ContinuumApp.swift:14985-15012) | Registry `upsertProject` + `assignProject` (project registration only, no zone) | `registryStore.save` |

All the zone-binding writers above are already hardened with explicit
ownership checks and inline comments describing a prior version of exactly
this bug (see "Existing witnesses" below) — i.e. the obvious naive races have
already been fixed once.

## Rebuilders table

| Rebuild path | Zone-membership rule applied | Effect on binding |
|---|---|---|
| `mountWorkspaceSceneAtBoot` (ContinuumApp.swift:16090), persisted-workspace branch | Calls `WorkspaceRuntime.install(into:appRegistry:)` | Filters through `mountableZones` (below) before mounting |
| `mountWorkspaceSceneAtBoot`, **synthetic/flat branch** (`persistedWorkspaceRegistry == nil`, ContinuumApp.swift:16165-16168) | `runtime.ensureZoneForActiveProject(controller:)` | Taken when `runtime.workspaceId` is **not found in `registry.workspaces`** at boot. Does not read the persisted document's existing zone set at all for scene purposes — it drives the legacy flat/compat scene and *mints* a zone for the active project if one isn't already in `document.zones`. This is the "boot-only compatibility" path the M1.10 notes in CLAUDE.md hazard 9 describe. |
| `WorkspaceRuntime.install(into:appRegistry:)` (WorkspaceRuntime.swift:654 →`mountableZones` at :677) | `zone.projectId == nil` → always mountable (ambient/group zone). Else: `registry.exclusiveWorkspaceOwner(of: projectId) == workspaceId` | **A zone whose project is not exclusively owned by *this* workspace is silently dropped from the mounted scene.** Comment at :1670-1675 confirms intent: "document stays byte-for-byte semantically complete, while the mounted scene contains only … zones whose project declares this workspace as its owner." So the on-disk binding survives, but the zone visually vanishes (not "reverts" — disappears) until ownership is fixed. |
| `WorkspaceRuntime.switchWorkspace(to:)` (WorkspaceRuntime.swift:1466) | Same `mountableZones` filter against the TARGET document + registry | Same drop rule, applied on every workspace switch |
| `validateProjectOwnership` (WorkspaceRuntime.swift:1652) | Throws if any zone's project isn't exclusively owned by `workspaceId` | Used defensively elsewhere; a stricter cousin of `mountableZones` |
| Header label: `zoneScopeLabel(_:)` (ContinuumApp.swift:14795-14803) | `registry.projects.first(where: { $0.id == projectId })` — if not found, returns `"Needs Project"` regardless of whether `zone.projectId` is actually set | **This is the most literal match for "zone no longer shows that directory."** The zone's own `projectId` can be 100% intact and the label still reverts to "Needs Project" if the Registry lookup misses (project entry deleted, registry reset, or — see channel split above — a different registry.json entirely). |

## Suspect paths ranked (file:line)

1. **`zoneScopeLabel` registry-miss fallback** —
   `Sources/ContinuumRevived/App/ContinuumApp.swift:14795-14803`. Silently
   renders "Needs Project" whenever `registry.projects` doesn't contain the
   zone's `projectId`, with no distinction between "truly unbound" and
   "bound, but Registry lookup failed/missing/wrong-channel". Cheapest
   explanation for "zone no longer shows that directory" while the
   underlying document is untouched.

2. **`WorkspaceRuntime.mountableZones` / `install(into:)`** —
   `Sources/ContinuumRevived/App/WorkspaceRuntime.swift:1677-1685` (filter),
   `:654-664` (call site in `install`), and `:1466-1520` (call site in
   `switchWorkspace`). Any zone whose project's Registry `workspaceId`
   ownership doesn't match the CURRENT workspace is excluded from the
   mounted scene outright — "switching workspaces… the zone no longer shows
   that directory" matches this precisely if ownership assignment for that
   project ever lagged, was never made (e.g., a very old zone, or a zone
   whose project was registered through a code path that didn't call
   `assignProject`), or a registry write for the assignment failed/was lost.

3. **Boot's synthetic/flat fallback when the workspace isn't in the
   registry** — `Sources/ContinuumRevived/App/ContinuumApp.swift:16097-16101`
   (`persistedWorkspaceRegistry` computed only if
   `loaded.workspaces.contains(where: { $0.id == runtime.workspaceId })`) and
   `:16165-16168` (`ensureZoneForActiveProject`, which can mint a *new* zone
   for the active project rather than reusing the persisted one). If
   `registry.json` and the workspace's `WorkspaceDocument` file ever get out
   of sync (e.g. `registry.json` save failed/raced independently of the
   `WorkspaceStore` save — they are two separate files with two separate
   save paths, see Stores table), a quit/reopen could boot the compatibility
   scene instead of the real persisted document — "quitting and reopening
   the app the binding is gone" matches this shape. `ensureZone` at
   `WorkspaceRuntime.swift:591-613` also swallows persistence errors
   (`try? persistWorkspaceDocument()`).

4. **Channel split applied to `WorkspaceDocument`, not just Registry** —
   `WorkspaceRuntime.swift:1425-1434` (`loadWorkspaceDocument`/
   `saveWorkspaceDocument` both derive their directory from
   `registryStore.registryFile.deletingLastPathComponent()`, i.e.
   Application Support). If Dylan is alternating between the prod app and a
   dev build (`~/Desktop/Array Dev.app`) while investigating or during a
   release, the two channels have **entirely separate `WorkspaceDocument`s**
   for what looks like "the same workspace" to a user, and zones/bindings
   created in one are simply absent in the other. Not covered by hazard 9/10
   (which is specifically about the shared `.array/`), but is the same
   *class* of channel-identity confusion CLAUDE.md non-negotiable #1 warns
   about, applied to a store that isn't `.array/`.

5. **`Registry.exclusiveWorkspaceOwner`/`assignProject` throwing paths in
   `mountableZones`** — `Registry.swift` ~155-230. `mountableZones` itself
   is written with `try registry.exclusiveWorkspaceOwner(of: projectId) ==
   workspaceId` — note this is inside `.filter`, and `exclusiveWorkspaceOwner`
   can `throw` (`unknownProject`, `duplicateMembership`, `ownerMismatch`). A
   thrown error from inside `.filter`'s closure propagates out of the whole
   `mountableZones` call, which propagates out of `install`/`switchWorkspace`
   entirely — i.e. a single corrupt/duplicate project membership anywhere in
   the registry could fail the ENTIRE mount, not just that one zone. Lower
   probability (would likely present as a boot crash/error rather than a
   quietly-reverted binding) but worth a targeted witness if not already
   covered.

## Existing witnesses

Already-hardened (each carries an inline comment describing a prior, now-fixed
version of this exact defect class):

- `--zone-unacquired-project-check` (`ZoneUnacquiredProjectChecks.swift`) —
  WS9: a zone whose project wasn't live at boot must still create into its
  OWN project; documents the acquire/reconcile/spawner-fallback defect chain.
- `--workspace-switch-check`, `--workspace-boot-persistence-check`,
  `--workspace-scene-owner-check`, `--workspace-runtime-install-check` —
  cover `switchWorkspace`/`install(into:)` plumbing generally.
- `--zone-registry-refcount-check`, `--add-zone-check`,
  `--zone-project-session-naming-check` — adjacent zone/project wiring.
- Inline comment at `ContinuumApp.swift:14886-14893` (picker `onConfirm`)
  explicitly describes and fixes an earlier version of "the zone was durable
  but filtered as foreign, so switching away and back looked exactly like
  data loss" — i.e. this EXACT user-visible symptom has been chased and
  fixed once already for the picker-confirm path specifically. That strongly
  suggests the *current* recurrence is coming from a different writer/path
  than the picker (candidates 2 and 3 above are prime suspects: paths that
  don't go through `commitCreatedZone`'s ownership-assignment guard, or the
  boot compatibility fallback).
- No dedicated witness found for: `zoneScopeLabel`'s registry-miss fallback
  distinguishing "unbound" from "lookup failed" (#1), or for the boot
  synthetic-path divergence when `registry.workspaces` and a workspace's own
  `WorkspaceDocument` file disagree (#3). These look like the gaps worth a
  new `--*-check`.
