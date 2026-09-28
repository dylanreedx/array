# s8 — Tile frame persistence paths (inline report from agent)

## Writers
| Writer | file:line | Space | Conversion |
|---|---|---|---|
| ZoneRuntimeController.flushCanvasSaveOffMain/flushCanvasSave | ZoneRuntimeController.swift:679,735 (canvasStateToPersist:658) | WORLD | canvasView.canvasStateForPersistence → tilesInWorldFrames(forProjectId:) |
| TileSpawner.persistProjectCanvas | TileSpawner.swift:2415 | WORLD | same (zoneLayer case) or raw canvasView.canvasState (flat case) |
| ContinuumApp.persistLayoutTransaction (project half) | ContinuumApp.swift:14695-14722 | WORLD (transaction.tileFrames verbatim) | none needed (captureGeometry→worldFrame) |
| ContinuumApp.persistLayoutTransaction (ambient half) | ContinuumApp.swift:14686-14695 | WORLD into document.ambientTiles | none — previously double-converted (WS2 F2, fixed) |
| WorkspaceRuntime.commitZonePlacement/persistMovedZone | WorkspaceRuntime.swift:107-113, ContinuumApp.swift:14619-14650 | zone origin/size only | N/A |
| WorkspaceRuntime.commitClosedZone | WorkspaceRuntime.swift:143 | removes zone, clears zoneId | none |
| WorkspaceRuntime._addProjectZone | WorkspaceRuntime.swift:~900 | reads WORLD from disk → LOCAL in-memory only | worldToZoneLocal |

## Readers
| Reader | file:line | Space |
|---|---|---|
| installInitial* boot walk | ContinuumApp.swift:16193-16252 | WORLD untouched |
| WorkspaceRuntime.install(into:) → memberTiles | WorkspaceRuntime.swift:705-731 | WORLD→LOCAL using zone.origin from mountableZones (document rect) |
| switchWorkspace hydration | WorkspaceRuntime.swift:1552-1581 | identical |
| makeAmbientZoneLayer | WorkspaceRuntime.swift:935-954 | WORLD ambientTiles → LOCAL via zone.origin |
| CanvasEngine.resolveZoneMembership | ZoneMembershipRepair.swift:51 | WORLD only, never moves, only re-stamps zoneId |

## Conversions
- CanvasEngine.zoneLocalToWorld/worldToZoneLocal (CanvasEngine.swift:41-64) exact inverses.
- worldToZoneLocalPreservingWorld (CanvasEngine.swift:84) ULP-safe for passive tiles during zone move.
- Read side uses the document's ZonePlacement origin (mountableZones). Write side (tilesInWorldFrames, CanvasNSView.swift:6600) uses live ZoneLayer.placement.origin, kept in sync with liveZones atomically by applyLayoutTransaction (CanvasNSView.swift:600-730; resolvedZonePlacements staged before stagedLayerFrames; committed together :712-724; exactRebaseOriginIfPossible rejects whole transaction otherwise).

## Suspects (ranked)
1. HISTORICAL, FIXED: WS2 F2 double conversion in persistLayoutTransaction (ContinuumApp.swift:14648-14722), guarded by --ambient-tile-frame-space-check. Comment says this path is wired from applicationDidFinishLaunching, "the one place no self-check can reach" → re-verify the witness drives production mount, not a checks-only hookup (hazard 9 M1.10 pattern).
2. HISTORICAL, FIXED: M1.10 unreachable install(into:). Re-confirm --workspace-scene-owner-check drives mountWorkspaceSceneAtBoot and persistLayoutTransaction's onLayoutCommitted hookup is production.
3. Debounce vs sync flush ordering (ZoneRuntimeController.swift:669-701 vs 735-745): serial canvasSaveQueue; detachUI (:416-424) nils canvasView after flushMountedWorkspaceState→flushAll→flushPendingSaves in switchWorkspace (WorkspaceRuntime.swift:1493). No drop window found, but only code order enforces it.
4. mergeProjectTilesForPersistence "cover, then replace" (CanvasPersistenceMerge.swift:33): tile below live tier preserved with LAST-PERSISTED frame — by design.

## Witnesses
--ambient-tile-frame-space-check (2 commit/remount cycles), --canvas-persistence-model-check, --zone-save-isolation-check, --workspace-runtime-install-check, --zone-runtime-duplication-check, --jelly-auto-layout-check.

Verdict: no live asymmetry found by static read. If tiles still shift, confirm the WS2 F2 witness really drives the production boot path.
