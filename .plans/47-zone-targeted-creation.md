# 47 — Zone-targeted creation

Landed 2026-08-23 on `array/integration`. Found by hand-driving the isolated
M1 build; nothing here was caught by the 178 green legs that preceded it.

## The report

> We have a zone created. I create a tile. It should use the zone's project home
> directory. I make a new zone. I make a new tile in that new zone. It should use
> that zone's project home directory. But right now, it is still using the
> previous one. And even when I do change it, the next tile, the third tile I
> make is still that first project home directory.

## The cause — one fact, two symptoms

`CanvasNSView.activeProjectZoneId` is the only input to the `.zone` candidate in
`resolvedCreationScope` (`ContinuumApp.swift:13519-13523`). It was written in
exactly four places — `WorkspaceRuntime.install`, `switchWorkspace`, the
`openDocument` repoint, and the onboarding starter. **No user action wrote it.**

- `_addProjectZone` set `document.lastActiveZoneId` (so `activeController` and
  the spawner followed) and installed the layer, but never called
  `setActiveProjectZone`. The controller moved; the canvas did not. That is
  symptom one, and it means the *store* a tile persisted into and the *zone* it
  appeared in came from different answers.
- `mouseDown` (`CanvasNSView.swift:4738-4791`) touched neither. Nor did pan/zoom.
- Symptom two is the same fact plus precedence. `CreationScopeResolver` resolves
  `explicit → zone → focusedAgent → recentExplicit` (`DirectoryScope.swift:144`).
  An explicit pick persists as `lastExplicitCreationScope`, entering as
  `.recentExplicit` — **below** `.zone`. `explicitCreationScopeOverride` is
  `defer`-cleared in the same synchronous scope. So a stale armed zone did not
  merely win once; it overruled the user's own correction on every later spawn.

## What shipped

**T1 — one funnel.** `WorkspaceRuntime.setActiveZone(_:reason:)` is now the only
writer of "which zone do new tiles go into". It writes `lastActiveZoneId` AND
`canvasView.setActiveProjectZone`, re-attaches the UI only when the *project*
changed, and persists — synchronously for a deliberate act, on the autosave
debounce for an ambient one. A group zone, an unknown zone or nil is refused and
**leaves the current arming untouched**: arming a project-less zone makes
`activeController` nil, which disarms creation entirely — a worse failure than
landing in the wrong place.

**T2 — four triggers, last wins.** Creating a zone, focusing a tile in one
(`.userClick` only — a `.recovery`/`.appActivated` restore must not fight
`switchWorkspace`'s own arming), clicking a zone, and the camera settling over
one. Camera arming is a new pure `CanvasEngine.cameraArmedZone` — the topmost
project-backed zone containing the **viewport centre**, deliberately not
"nearest", which would arm a zone thousands of points off screen the moment the
camera crossed open canvas. It rides `reconcileHydration`, already debounced
behind a viewport-delta gate: one O(zones) pass per settle, never per frame.
`nil` means *no answer*, never *disarm*.

**T3 — an explicit pick arms.** Rather than re-ranking `CreationScopeResolver`
(whose precedence is deliberately locked), the pick now arms the chosen
project's zone, so `.zone` and the explicit choice agree and the conflict cannot
arise. The zone's own Home is left alone; a one-off subfolder pick applies to
that spawn, and a zone's default Home changes through "Change Home…".

**T4 — frame and install agree.** `spawnManagedAgent`, the terminal and the file
tree framed against `activeProjectZonePlacement` while installing into
`creationScope?.zoneId`. Those could not disagree while the scope could only name
the armed zone. Notes and browsers ignored the scope outright. All five now
thread one `targetZoneId` through placement, sibling selection, z-order and
install.

**T4 also exposed a real defect, and this is the one worth remembering.**
`appendProjectZone` parks a new zone at `maxX + gap` — off to the right of
everything, nowhere near the camera. Once framing correctly targeted that zone,
the first tile created in a freshly added project framed at zone-local
**(-4340, 400)**: 4340pt *outside* its own zone, because "where the camera is
looking" is meaningless in a zone the camera cannot see. Auto-layout then grew
the zone across the whole canvas to reach it, swallowing the others. Fixed by
clamping the zone-local viewport: when the visible rect does not overlap the
target zone, the zone's own origin is used. Unreachable before T4.

**T5 — the armed zone is visible.** It had no visual representation at all;
`setActiveProjectZone` was pure routing. Survivable while the answer only changed
at scene mount, not once clicking, focusing and panning re-point it. The armed
zone's chrome draws a heavier stroke and header using its **own** accent — no new
colour literal, no new `TokenThemed` surface for the ui-probe census. The
palette's `filesystemCreationPreview` already named the destination and already
read the resolver; it had been accurately reporting a wrong answer.

**T6 — one-click zone Home.** `chooseProjectRow` always advanced into
`showFolders`, an N-level recursive drill-down. A project row now confirms at its
root (matching the `recent:` rows, which already did); the drill-down survives
behind an opt-in "Choose a subfolder…" row and remains the destination of the
zone header's "Change Home…". `.isHiddenKey` was fetched and never used, so
`.git`, `.build` and `.array` were offered as Home candidates — now filtered.

## Witnesses

- `--zone-arming-check` (`ZoneArmingChecks.swift`). Drives
  `mountWorkspaceSceneAtBoot`, never `install(into:)`. Teeth-verified: reverting
  created-arming, focus-arming, camera-arming, the group-zone guard, the armed
  accent, and the T4 clamp each turns it red with a distinct message.
- `runCameraArmedZoneChecks` in CoreChecks — containment, z-order, group zones,
  zoom, degenerate inputs, inclusive boundary.

The T4 assertion is **world geometry**, not the zone stamp. A stamp-only
assertion stays green through the exact frame/install split it exists to catch.

`onZoneActivated` is wired inside `mountWorkspaceSceneAtBoot`, not in the
surrounding `applicationDidFinishLaunching` block, specifically so the witness
drives the same assignment production does — the M1.10 trap that let seven
tickets pass against code the app never executed.

## Round two — what hand-driving found that the first witness did not

Reported: agent tiles still landed in the first zone with the camera fully
centred on the new one, and a brand-new agent still used the original home
directory. Four causes, one of them introduced by round one.

1. **Camera arming read the wrong geometry (mine).** `cameraArmedZone` was given
   `document.zonesInZOrder`, but a zone is DRAWN from `liveZones`, and the two
   diverge — auto-layout grows a zone through `onZoneMoved`, updating the
   rendered placement while the document lags. One was observed at
   `(656,0,5644x824)` with the document still saying `(5020,0,1280x720)` while
   debugging the T4 clamp, and the significance was missed. Containment was
   therefore tested against a rectangle the user cannot see. Now reads
   `CanvasNSView.renderedZonesInZOrder`.

2. **The first-zone magnet.** `resolvedCreationScope` fell through to
   `canvasView.activeZone` — the BOOT zone — whenever `activeProjectZonePlacement`
   was nil, which is whenever the armed zone has no installed layer: always at
   boot, and for any zone below the live hydration tier. Creation silently
   reverted to the first project in the workspace. The `.zone` candidate now
   consults `document.lastActiveZoneId` before that fallback. Whether a zone is
   hydrated is a rendering detail and must not decide which project a tile
   belongs to.

3. **The agent's Home, cause one.** `wireManagedAgentTile` read the memoized
   creation scope off the ACTIVE controller's spawner; a scoped spawn records it
   on the SCOPE's project's spawner. Across a project boundary the lookup
   returned nil and the agent fell back to the plain active-project path.
   `WorkspaceRuntime.managedAgentCreationScope(tileId:)` now searches every live
   spawner.

4. **The agent's Home, cause two, and the nastier one.**
   `attachActiveControllerUI` builds a FRESH `TileSpawner` for every live
   controller whenever the active project changes — which, after T2, is every
   click, focus and camera settle. `managedAgentCreationScopes` and
   `managedAgentLaunchSelections` live on the spawner instance, and
   `wireManagedAgentTile` reads them LATER than the spawn records them. So
   re-arming between spawn and wire discarded them. `makeSpawner` now carries
   them forward via `adoptManagedAgentMemos(from:)`. These memos describe TILES,
   which outlive any spawner.

**The witness had the same blind spot as the code, twice.** It called
`runtime.onViewportChanged()` directly — proving the method works and saying
nothing about whether a pan reaches it — and `canvas.delegate` is assigned in
`applicationDidFinishLaunching`, outside the mount seam, so the leg never had
one. It now pans through the real chain (`setViewport` -> `canvasDidChange` ->
the viewport-delta gate -> `onViewportChanged`) and adds cases 1-4 above. All
teeth-verified.

**The rule this cost a second round to relearn:** driving the production *entry
point* is not enough if the assertion still reads a model the user cannot see.
`document` is the authority for WHICH zone is armed; `liveZones` is the authority
for WHERE that zone is. Ask each the question it can answer.

## Round three — "the spawn location is still random"

One cause, and a direct regression from T4.

`makeProjectTilePlacement` resolved its target through
`CanvasNSView.zonePlacement(for:)`, which falls back to `allZonePlacements()` —
zones present in the document but with **no installed layer**. So it produced a
ZONE-LOCAL frame; `installProjectTile` then found no layer, fell back to the flat
model, and stored that frame as WORLD. Every tile was displaced by exactly its
zone's origin, and since zones have different origins the displacement differed
each time. Witnessed: the boot zone armed at `(600,200)` with the camera centred
on it put the tile at `(130,150)`.

Before T4 nothing passed a `targetZoneId`, so framing always fell through to
`activeProjectZonePlacement` — layer-only, and nil at boot. The flat path was
correct *by accident*. Making framing follow the target zone lost the accident.

**T4's rule was too weak as originally written.** "Frame and install must agree
on the ZONE" is insufficient; they must agree on the **MODEL**, because the two
models use different coordinate spaces. Framing now uses
`CanvasNSView.installedZonePlacement(for:)`, which returns a placement only when
a layer actually owns the zone — the same condition `installProjectTile`
branches on.

## The pattern across all three rounds

Every round had the same shape: a witness that asserted against a model the user
cannot see.

1. Camera arming asserted against `document` geometry; the screen draws
   `liveZones`.
2. The creation scope asserted a layer existed; the armed zone is a document
   fact.
3. Placement asserted a zone existed; the frame space depends on whether a LAYER
   exists.

Driving the production entry point — the M1.10 rule — is necessary and was
satisfied every time. It is not sufficient. **Assert on the geometry that
reaches the screen, in the space it is stored in.** The leg now checks world
frames on both branches, layer and flat.

## Left open

- The layer's `ZonePlacement` and the document's can diverge when auto-layout
  grows a zone (`onZoneMoved` updates `liveZones`, not always the document).
  Observed while debugging T4; not caused by it, and not fixed here.
- `growZoneToFitMembers` (`CanvasNSView.swift:1355`) still reads the flat
  `canvasState.tiles` and compares WORLD frames against a zone that may be
  layer-owned. `autoLayoutScene()` is the model-correct source and is what the
  enabled auto-layout path uses; this fallback branch was not migrated.
- `appendProjectZone` parking a new zone at `maxX + gap` rather than near the
  camera. The T4 clamp makes it harmless, not good.
- `.plans/46` item 5c.2 — a subfolder Home breaking repo-root-relative paths.

---

# 48 — Connector geometry, agent-opened file placement, zone growth

Same session, reported from the same preview. Recorded here rather than in a new
file because the causes are continuous with rounds 1–3.

## T7 — a zone grows when a tile lands in it

Only `installProjectTile`'s LAYER branch grew its zone, and only through
`arrangeAutoLayoutAfterSpawn`, which is gated on auto-layout being enabled. The
FLAT model — which is what the boot project uses — never grew at all, so a
spawned tile sat outside its zone until someone dragged it. New
`CanvasNSView.growZone(_:toInclude:)` is unconditional and runs on both branches,
skipped only while hydration replays a persisted scene.

**Growing can move the ORIGIN, and a layer holds zone-local frames**, so every
local frame is compensated by the same delta — otherwise expanding a zone
up-left drags every tile in it. Teeth-verified: without compensation the anchor
tile moved from `(5120,100)` to `(4596,-358)`.

The first version of the flat-growth assertion had **no teeth**: the fixture
centred the camera in the zone, so the tile landed inside and nothing had to
grow. The camera now sits on the zone's bottom-right corner so the tile
straddles the edge.

## T8 — the connector painted at `worldOrigin + W`

`updateDocumentRelationshipOverlay` set `overlay.frame = worldPlane.bounds` and
then fed segments **raw `worldPlane`-space view frames**. `worldPlane` implements
pan as `setBoundsOrigin(worldOrigin)`, so its `bounds.origin` IS the camera's
world position while the overlay's own stays `(0,0)`. Everything painted
displaced by exactly the camera pan, growing with distance from the world origin
and clipped away entirely once it left the plane.

Not a model error — zone-layer tile views are children of `worldPlane` and
already carry world frames. Two neighbours in the same file get it right
(`agentLineageOverlay`, the focus border); this one did not. Fixed with
`convert(_:from:)`, matching them.

**Why it survived.** The only coverage builds its canvas at `viewport (0,0)`,
where the offset is exactly zero, and the geometry test feeds `route(for:)`
hand-made rects with no canvas at all. The new `--relationship-geometry-check`
runs at a panned camera and a zoom ≠ 1; teeth-verified as displaced by exactly
`(4000,2900)` while the zero-viewport case stayed green.

## T9 — an agent-opened file landed nowhere

`spawnFileImpl` resolved its anchor by scanning
`targetZoneId.flatMap { tiles(inZone: $0) } ?? projectTiles()`. `tiles(inZone:)`
returns nil when the target zone has **no installed layer**, so `siblings`
silently became the ACTIVE zone's tiles, which cannot contain the opening agent.
With the anchor "not found", both fallbacks were wrong:

- **`:2225` omitted `targetZoneId`** — the last such call site in the file, and
  one T4 missed. The frame came out zone-local to the ACTIVE zone and was then
  installed into the target's.
- **`:2234` stamped `zoneId: anchor?.zoneId`** — nil, producing a tile belonging
  to no zone at all. The field store held exactly that: `notes.md` at world
  `(1246,-851)`, `zoneId: nil`, unreachable by every zone gesture.

Now: the anchor is resolved by identity from a new
`CanvasNSView.allTilesInWorldFrames()`, the anchored rect is computed in WORLD
and converted **once**, into the space of the model `installProjectTile` will
actually use (`installedZonePlacement(for:)`), and `zoneId` falls back to
`targetZoneId`. An explicit `.at(point)` now beats the anchor — `openDocument`
sets both and the anchor used to win, discarding where the user dropped.

## T10 — repair what is already on disk

`resolveZoneMembership` ran only from `install(into:)` and `switchWorkspace`;
boot renders the flat scene and calls neither, so a nil or foreign stamp survived
every launch. `mountWorkspaceSceneAtBoot` now runs it.

**Ordering is load-bearing.** `canvasState` is a value-type snapshot taken before
the mount, and the `installInitial*` walk installs from THAT — so a repair
applied before the walk was immediately overwritten by each install re-stamping
from the stale copy. It runs after the walk, so the live state carries the repair
into the `saveCanvas` on the next line.

Stamp-only: the rule never moves a tile, so the three agent tiles stamped with
another project's zone are re-owned but stay exactly where they are drawn.

## The pattern, now five for five

Every defect in `.plans/47` and `48` is a witness asserting against a model the
user cannot see: document geometry vs rendered geometry; layer presence vs the
document's armed zone; zone existence vs frame space; a camera at the origin vs
a camera anywhere real; a fixture where the assertion could not fail.

Driving the production entry point is necessary and was satisfied every time.
**Assert on what reaches the screen, in the space it is stored in, from a
fixture where the wrong answer would differ.**
