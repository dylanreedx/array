# Multi-Controller Runtime — Implementation Plan (the zone keystone)

Status: design session 2026-06-14. The prerequisite that unblocks parked
CON-53 (workspace switch), CON-51 (zone hydration gate), CON-50 (per-zone
lock). Decision record: ADR-0026 (docs/09). Authored against `main` after the
E4 extraction + E5/E6 renderer landed.

## Problem

The app is **single-live-controller**: `ContinuumApp.zoneRuntimeController:
ZoneRuntimeController?` (ContinuumApp.swift:801), one instance at boot. CON-48
landed the multi-zone *renderer* (immutable `ZoneRenderModel`s) but only ONE
zone's tiles are live — the rest are header rectangles. `addProjectZone`
(~:2366) persists a placement but spins up no runtime. Switching is
relaunch-only (`switch*AndRelaunch` → `relaunchApplication`). `CanvasNSView`
holds `let activeZone` / `let zoneRenderModels` — not swappable in place.

Per-tile hydrate/dehydrate ALREADY works on a single controller
(`ZoneRuntimeController.setTier`/`dehydrate`/`hydrateToLive`). What's missing
is **N controllers + a swappable canvas + cross-zone orchestration**.

## Target architecture

`AppDelegate` keeps the app/window shell (NSWindow, the 4 global NSEvent
monitors, the one FocusBroker, shared Ghostty/Browser engines, RegistryStore —
per ADR-0024). Its single `zoneRuntimeController` field becomes a single
`workspaceRuntime: WorkspaceRuntime`.

- **WorkspaceRuntime** (new, @MainActor, App target) — the orchestrator:
  owns the active `WorkspaceDocument`, a `ZoneRuntimeRegistry`, the global
  `BrowserRuntimeBudget`, and a `ZoneHydrationOrchestrator`. API:
  `switchWorkspace(to:)`, `addZone(projectId:)`, `removeZone(zoneId:)`,
  `onViewportChanged()`, `retryLock(zoneId:)`, `flushAll()`, `closeAll()`.
- **ZoneRuntimeRegistry** — `[projectId: ControllerBox]`, ref-counted. One
  `ZoneRuntimeController` **per projectId**, reused when a project appears in
  multiple workspaces (a project = one lock fd / one PTY set / one WKWebView
  set, so it can only hydrate once). `acquire`/`release` create-if-missing /
  close-at-zero.
- **ZoneRuntimeController (×N)** — existing class, near-unchanged; one per
  project, each with its own `TileSpawner`.
- **CanvasNSView (mutable)** — refactored from one tile set + one `activeZone`
  to N `ZoneLayer`s `{placement, renderModel, tiles, tileViews, chrome}` with
  in-place `setZones/upsertZoneLayer/removeZoneLayer/setZonePlacement`.
  `layoutTile`/`tileId(at:)` operate per-layer (CanvasEngine stays pure).
- **ZoneHydrationOrchestrator** (pure) — `[placement]+viewport+visibleSize+
  focusedZone+budget → [zoneId: tier]`, wrapping the existing pure
  `CanvasEngine.hydrationTier(...)` then layering the global LRU budget
  (generalize `enforceBrowserRuntimeBudget` from tile-level to zone+tile).

## Decisions (defaulted to the conservative choice; veto in ADR-0026)

- **D1 — Identity = projectId; one zone per project per workspace.**
  `appendProjectZone` already de-dupes; keep it. Avoids two live WKWebView
  sets for one repo. (No "duplicate zone" feature.)
- **D2 — Z-order per-zone within zone painting** (`zoneZOrder` back-to-front;
  tiles reorder only within their zone). Preserves persisted per-project
  zIndex semantics that `--zindex-relaunch-hit-test-check` guards.
- **D3 — Budget caps WKWebViews only in v1.** PTYs stay live while their zone
  is Live; a cross-zone PTY budget is a follow-up. Matches what exists.
- **D4 — On switch, offscreen shared-project zones demote to Snapshot**
  (honor the orchestrator plan, not always-warm). Bounds resource use.

## Behavior-neutral refactor sequence

Each step ends matrix-green. Tag: **[pure]** = loop-friendly; **[appkit]** =
needs real-app verification (rebuild + click). ⚠ = the in-place-swap heart.

| # | Step | Size | Tag | Guarding check |
|---|------|------|-----|----------------|
| S0 | ADR-0026 + this plan | S | [pure] | check-root-docs |
| S1 | `ZoneHydrationOrchestrator` (pure planner) | M | [pure] | new `--zone-hydration-plan-check` |
| S2 | `ZoneRuntimeRegistry` (per-projectId, ref-counted) | M | [pure] | new `--zone-registry-refcount-check` (CON-58 sharing) |
| S3 ⚠ | `CanvasNSView` zone set MUTABLE (`ZoneLayer`, setZones/upsert/remove; per-layer layout+hit-test) | L | [appkit] | `--single-zone-compat-check`, `--multi-zone-render-check`, `--zindex-relaunch-hit-test-check`, `--tile-world-bounds-check` |
| S4 | `WorkspaceRuntime` shell; AppDelegate field → workspaceRuntime + `activeController` proxy (single zone, neutral) | L | [appkit] | full matrix, `--zone-save-isolation-check`, `--focus-broker-activation-check`, smoke |
| S5 | Move `BrowserRuntimeBudget` into WorkspaceRuntime; budget over union of live browser tiles | M | [appkit] | `--browser-lru-budget-check`, smoke |
| S6 | `addZone(projectId:)`: addProjectZone spins up a real controller + layer | M | [appkit] | extend `--add-zone-check`; smoke add-project |
| S7 ⚠ | `switchWorkspace(to:)` in-process (CON-53); replace switch*AndRelaunch; fix createWorkspace to open new canvas | L | [appkit] | extend `--workspace-switch-check`; smoke |
| S8 | Viewport-driven tier transitions (debounced reconcileHydration on pan/zoom) | M | [appkit] | new `--zone-tier-transition-check` |
| S9 | Merge CON-50 lock degradation (registry degradeOnLockFailure; badge; retryLock; orchestrator hard-pins degraded cold) | M | [appkit] | wip `--project-lock-check` assertions |

Loop-buildable unattended: S0/S1/S2. Loop + smoke gate: S5/S6/S8/S9.
**Human real-app verification required: S3 and S7** (subview add/remove +
cursor-rects + focus-broker re-registration during swap = where AppKit
stale-pointer/lost-firstResponder bugs hide).

Unblocks: CON-53 lands at S7, CON-51 across S1/S8, CON-50 at S9.

## Risk

- S4 is the heaviest AppDelegate touch; keep `activeController` proxy so the
  diff is mechanical; do S3 (canvas) and S4 (delegate) as separate commits so
  a regression bisects to one layer.
- The 4 window-scoped monitors stay on AppDelegate (ADR-0024); focus path
  guarded by `--focus-broker-activation-check` + `--note-click-focus-check` +
  `--bring-to-front-focus-check` every step.
- All coordinate transforms stay in `CanvasEngine`; compat + multi-zone-render
  + tile-world-bounds checks are the zone-local↔world guard.
- `--zone-save-isolation-check` must stay green through S4/S6/S7 (per-controller
  dirty-tracking survives multi-zone).

## Key files

ZoneRuntimeController.swift · ContinuumApp.swift (:801 field, :2366
addProjectZone, :2347/:2409 switch*Relaunch, :2932 loadActiveZoneRenderModels,
:780-795 runtime proxies) · CanvasNSView.swift (:61-64 immutable zone fields,
:427 layoutTile, :315 tileId(at:)) · CanvasEngine.swift (hydrationTier :87,
hitTest(zones:) :185, worldFrame) · WorkspaceDocument.swift · TileSpawner.swift
(per-project) · BrowserRuntimeBudget.swift · branch
`wip/con-50-zone-lock-degradation` (the lock seam to merge at S9).
