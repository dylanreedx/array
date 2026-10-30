# Native canvas, capture and collaborator attention

29 October 2026. Implementation research only. No product code, live canvas edits, app launches, Git mutations or runtime checks were performed. Paths describe the current working tree and may include unrelated uncommitted work.

## Feasibility and recommendation

The existing native canvas can support structured sharing, but a project zone is not a collaboration document. Reuse the current selection, geometry conversion, viewport and token components. Add a separate shared-area scene owner whose objects refer to publishing sources rather than reassigning local project/zone ownership.

Recommended initial shape: one **shared area with area-local geometry**, displayed in each participant's personal canvas through a local anchor or opened in a dedicated shared-workspace scene. Geometry inside the area is jointly arranged; each participant's area anchor and camera are local. Publishing an existing zone or a selected rectangle initializes that area without moving source tiles or copying executor ownership. Participants, including the publisher, subsequently arrange the shared projection. A geometry edit in that projection does not unexpectedly move the original tiles on the publisher's personal canvas.

This choice needs an explicit UX decision: “share zone” could alternatively convert the source zone's arrangement into the shared authority. That requires a more invasive conversion and persistence contract. The first shape preserves current local state and still gives both collaborators an actual shared canvas. Avoid silently treating both geometries as independent authorities.

## Concrete current seams

| Source | Existing behavior and implication |
| --- | --- |
| `Sources/ContinuumRevived/Canvas/CanvasTileSelection.swift:252` | `selectedWorldTiles()` converts selected model frames to WORLD and ignores collapsed-zone children. Its snapshots are a good capture input, but selection only describes available installed tiles. Share-zone/workspace enumeration must use document/controller coverage, not just live views. |
| `Sources/ContinuumRevivedCore/TileSelectionGeometry.swift` | Immutable WORLD-frame snapshot, group bounds, translations and minimum-size-aware resizing. Use actual model geometry, not hover presentation frames or screenshot bounds. |
| `Sources/ContinuumRevived/Canvas/CanvasSelectionHover.swift` | Selection lift and temporary spacing affect presentation only. Captured geometry must not include that temporary pose. |
| `Sources/ContinuumRevived/Canvas/CanvasNSView.swift:6815` | `ZoneLayer` holds project-local tile frames; `setZones` keeps every document zone visible even below hydration tier. Model B owns zone geometry/chrome/gestures. Shared areas cannot become a competing zone-chrome owner. |
| `Sources/ContinuumRevived/Canvas/CanvasNSView.swift:7260` | `tilesInWorldFrames` is a model-boundary conversion. Capture must obtain world geometry from the owning layer, then subtract the shared-area origin exactly once. |
| `Sources/ContinuumRevived/Canvas/CanvasNSView.swift:7319` | `canvasStateForPersistence` merges installed coverage over persisted project tiles. A shared geometry update must not replace project canvas tiles or erase unhydrated members. |
| `Sources/ContinuumRevived/Canvas/CanvasNSView.swift:7475` | `installProjectTile` requires explicit target-zone placement and valid layer ownership. It is not a generic remote-view installer. |
| `Sources/ContinuumRevived/Canvas/CanvasNSView.swift:7539` | `materializeProjectTile` restores without re-tidying. Equivalent projection hydration needs to avoid layout changes and source writes. |
| `Sources/ContinuumRevived/App/WorkspaceRuntime.swift:584` | `setActiveZone` intentionally refuses projectless/group zones; the active controller owns local project creation. A shared group must not arm unrelated local creation. |
| `Sources/ContinuumRevived/App/ContinuumApp.swift:20593` | `makeHydratedTileView`, Phase B and `retireOrphanedRuntimes` are production hydration/lifecycle seams. A remote agent reference must not take the local managed-agent constructor path and mint a second runner. |
| `Sources/ContinuumRevived/Canvas/CanvasCameraDriver.swift` | One input driver coalesces camera events and cancels flights on real local navigation. Follow must compose with this owner, not introduce a timer writing a second viewport. |
| `Sources/ContinuumRevived/Canvas/CanvasNSView.swift:3999` | User camera callback is distinguished from programmatic viewport updates. Follow updates must not pretend to be local input or repeatedly bump `interactionGeneration`. |
| `Sources/ContinuumRevived/Canvas/AgentComposer/ChoiceButton.swift` | Shared styled choice control; reuse for share scope/role/content mode and actions rather than introducing stock menus. |
| `Sources/ContinuumRevived/App/UIProbeAppearance.swift` | New token owners require adopted/sweep surfaces and owner-scoped legal values. Native share UI, cursor labels and hover cards need light/dark rendered inspection. |

The existing contract in `docs/internals/tile-multiselect.md` is useful behavior evidence from the earlier program; it is not verification of any new sharing code.

## Capture contract

1. Invoke an explicit capture mode, or start from the current multi-selection.
2. Respect current camera-pan precedence and native text selection; do not silently repurpose an existing background gesture.
3. For a dragged rectangle, recommend fully enclosed tile frames as the initial set, followed by a clear membership preview and explicit correction. A partial overlap must not unexpectedly publish a private terminal.
4. Snapshot stable source identities, actual model frames and content-sharing capabilities. Capture unsupported content as an explicit unsupported row, not a blank/silent omission.
5. Normalize relative positions against one chosen area origin. Preserve size, ordering and grouping; do not persist temporary selection-lift presentation.
6. Review what becomes live, frozen, omitted or unavailable. Geometry selection does not authorize arbitrary file/terminal contents.
7. Commit a bounded, revisioned manifest through the collaboration owner. The local source project and its `.array/canvas.json` stay unchanged unless a separate explicit local layout action occurs.
8. Add/remove shared membership explicitly after creation. Moving a tile across a border must not automatically publish it. Closing a view, unsharing an object and stopping its runtime are different actions.

Sharing an entire zone/workspace must enumerate the actual document and persisted coverage, including below-live-tier members. If ownership cannot resolve safely, show unavailable content and require a narrower scope rather than assuming the visible subset is complete.

## Shared arrangement and source ownership

Shared geometry should be an atomic object-frame operation carrying area/object identity, base revision, author and stable request identity. Local drags can preview immediately, but only acknowledged operations become durable shared layout. Remote authoritative updates arriving during a local drag require a documented resolution: defer preview until gesture ends, then submit against the new base or surface a conflict. Never splice coordinate components from two drags into an accidental frame.

Group move/resize should be one shared operation so the retained layout cannot split across partial delivery. Undo should produce a new authorized inverse operation conditioned on what remains applicable; restoring a stale full snapshot can erase someone else's newer move.

No local automatic-layout solver should privately push unrelated shared members differently on each machine. Either the shared authority computes a deterministic placement operation including affected members, or shared geometry uses explicit positioning until that solver path is agreed. Local canvas placement around the embedded area's anchor can remain a separate local concern.

Shared views need their own presentation identity distinct from source tile identity and source agent identity. The same source can be referenced in several shared areas without owning multiple processes. Snapshot/remote-only rendering must retain host-unavailable state and must not fall back to a local CLI or active project. Adding new persisted/API-editable fields requires the `WorkspaceAPIExposure` classification rule; define that contract with the domain/API work.

## Presence, follow and hover integration

Presence should name area identity plus area-local pointer/selection/viewport. Convert through the participant's local anchor and viewport at render time. This makes cursors agree even if participants place the shared area at different world origins. Outside a common area, show selected-object attention rather than misleading world-coordinate cursors.

Use one bounded overlay and a participant/object index, not one retained native view per pointer event. Presence is ephemeral, rate-limited/coalesced, sequence-aware and expires independently from durable geometry. Cursor motion must not trigger tile content layout, canvas persistence or hydration churn.

Expose **Go to participant** and **Follow participant** separately. Follow is opt-in, visibly indicated, and ends on local pan/zoom/navigation, target departure, area access loss or shared area closure. Programmatic follow updates must not publish a feedback loop or arm the remote participant's project. Reconcile hydration through normal camera-settle ownership, not per presence packet.

Dylan's requested live token hover card attaches to the cursor label with an equivalent avatar/focus target for offscreen cursors and keyboard use. The card should have a stable inspection anchor and no permanently visible token overlay. It reads the usage projection provided by telemetry work; hovering must not scan every transcript or start an inference request.

## Alternatives and dependencies

- **Dedicated shared workspace first:** simplest coordinate/root ownership and cleaner QA isolation; less immediate “bring this area into my personal canvas.” The scene adapter can later support embedding.
- **Embedded shared area first:** directly matches captured-area sharing; needs explicit hit-testing, clipping, local anchor movement and shared-inner-layout ownership. Use a clear container boundary and mode distinction.
- **Convert existing zone in place:** appealing continuity, but requires explicit source-geometry ownership migration and rollback. Do not claim it is a free extension of `ZoneLayer`.
- **Independent layouts of the same shared objects:** valid personal-view mode, but no meaningful common canvas cursor/follow and less faithful to sharing layout. Not the default recommendation for the user's new direction.

Blocking contracts: shared IDs/membership and ordered geometry operations; per-object publishing capability and remote view projection; local persistence/reference mount model; access checks/revocation events; usage/presence transport. UI experiments can use offline synthetic data before those are production-ready.

## Ticket candidates

### CAN-1 — Capture a structured share manifest from canvas selection, zone or workspace

**Outcome:** a user selects content, reviews the exact member set and relative arrangement, and creates an area manifest without moving source content.

**Implementation seams:** selection WORLD snapshot; document/controller coverage enumeration; explicit capture-mode event routing; shared choice components and content review.

**Acceptance:** mixed project/zone selection retains source owners; nonzero/negative origins normalize correctly; hover lift is excluded; partial overlap preview is correct; capture cancellation changes nothing; below-live-tier zone members are either resolved or explicitly unavailable; unsupported tile types are named; dragging content near a shared boundary does not publish it.

**Witness:** pure geometry/manifest outcomes plus a production-mounted AppKit pointer/selection journey, with both model and persisted source canvases compared before/after. Register a new real leg in the matrix and confirm it reports. New check names must be introduced/registered deliberately, not guessed at execution time.

**Dependencies:** domain manifest and publication policy. **Size:** medium to large, with whole-workspace enumeration broader than selected-live-tile capture.

### CAN-2 — Mount a shared area with jointly arranged projections and local camera/anchor

**Outcome:** two isolated native clients see identical area-local object arrangement while maintaining separate cameras and original source project state.

**Acceptance:** origin-offset participants agree on world-to-area projection; a source agent has exactly one actual runner; mount/remount/revocation creates no local fallback executor; shared group operations are atomic; concurrent drag has a documented outcome; source project `.array` bytes do not change from remote layout; hidden/unhydrated local project tiles survive; closing/unsharing never silently stops the source agent; shared clicks do not accidentally arm an unrelated project.

**Witness:** two-client in-memory authority with temp stores, production scene mount through `mountWorkspaceSceneAtBoot`, source disk/model/chrome assertions, disconnect/remount and failed-save rollback. Assert exact frames against area/world rects, not only membership stamps.

**Dependencies:** domain + persistence + transport + remote projections. **Size:** large; split dedicated shared-scene mount from embedded-container polish if necessary while preserving the same contract.

### CAN-3 — Render contextual presence, reversible following and hover-only usage

**Outcome:** participants can point, find and temporarily follow each other; token usage is inspectable on hover/focus without a permanent overlay.

**Acceptance:** different anchors/zooms render a pointer at the same shared object; local pan/zoom immediately exits follow; mutually following clients do not loop; stale presence expires; no unauthorized object names leak; hover card stays inspectable and disappears appropriately; avatar/keyboard path reveals equivalent usage; repeated pointer packets cause zero content measurements and zero canvas writes; programmatic follow does not bump local interaction generation or arm a project.

**Witness:** injected clock/network traces and production camera input with deterministic work counters; native light/dark render sweep including token owner adoption, Reduce Motion and accessibility targets. Include old camera/matrix gates as regressions once new behavior is implemented.

**Dependencies:** identity/presence/usage projections and CAN-2. **Size:** medium, with telemetry correctness owned by its dedicated workstream.

## Performance and verification limits

Follow `docs/internals/performance.md`, `performance-budgets.md` and `scalability-tdd.md`. Capture can scan selected/document members once at invocation, never per cursor packet. Presence redraw should scale with visible participants; background traffic must not traverse every tile or measure text in `layout()`. Share content must reuse bounded/virtualized transcript and artifact views. Avoid creating a new retained image/window capture per object on every update.

The existing matrix contains actual selection, pointer path, zone-save, workspace-scene-owner and camera-coalescing checks. Those identify regressions to preserve, not proof of collaboration readiness. No builds or tests were run for this memo.
