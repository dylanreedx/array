# Program Roadmap — Canvas UX → Workspace UX → Workspace Backend

Status: 2026-06-15. Frames the de-hollowing program after dogfooding revealed
"seams built, interactions hollow." We de-hollow in a deliberate order, **UX-first**,
with **real-path verification** (every check drives the actual input/gesture path,
never an executor bypass — see docs/30's quality bar; this is what caught the
dead-keybind guard the bypass checks missed).

## The three phases

### Phase 1 — Canvas UX (in progress)
The hold-`⌥` leader navigation redesign — **full design + plan in `docs/30`**:
command registry → label-jump + arrow-snap (phantom preview, resize rule C) +
drag magnetization; retire the wonky `⌃Space` toggle.

**Landed:** command registry spine (`CanvasCommand`/`CommandRegistry`, Phase A);
the input-gate fix so `⌘⌃` chords reach the dispatcher again — `handleHotkey`'s
`onlyCommand` gate AND `handleReservedShortcut`'s `guard let shortcut … else
return false` both dropped non-`⌘` chords; resize presets + `⌘⌃`-arrow throw now
fire through the real path (`--input-gate-check`).

**Open / next:** `.flagsChanged` hold-`⌥` detection → label-jump HUD → snap with
phantom preview. **Known feel problem (Dylan, 2026-06-15): the snap/throw
*neighbor logic feels bad.*** Likely root cause in `TileArrangement.throwDestination`:
when no tile orthogonally overlaps in the throw direction it flings the tile to the
edge of the *union of all tiles* (can land far away / unexpectedly); and
"first orthogonal obstacle" may not match the neighbor a human perceives. The
Phase-D rework should reconsider this — probably snap to the **nearest tile in that
direction** (center/edge distance, à la `CanvasEngine.nearestTile`), place
gap-adjacent, never fling to a far union edge — with the phantom preview + candidate
cycling letting the user confirm before commit. Needs a dedicated feel pass.

### Phase 2 — Workspace/zone UX (the interactive shell)
Make zones/workspaces *manipulable*: drag a marquee/area around tiles to **create a
zone**, a **workspace switcher/picker**, zone move/resize, tile↔zone membership.
This is the visible shell; today zones render but are inert (audit: zone create =
disk-only, switch = relaunch, move/resize = no gesture). Some pieces have stale
designs in the old E16 plan (marquee/groups/sidebar/minimap) worth mining.

### Phase 3 — Workspace/zone backend (make it real)
The **multi-controller keystone** — `docs/23` (`WorkspaceRuntime` +
`ZoneRuntimeRegistry` + mutable canvas + in-process `switchWorkspace`). Today there
is ONE `ZoneRuntimeController` and an immutable canvas zone set, which is why every
workspace/zone interaction is hollow.

## Open decision (Dylan)
**Consolidate Phase 2 + Phase 3 into a single workspace/zone sprint (UX + backend
together)?** Argument for: the UX (drag-to-create-zone, switcher) is meaningless
without the backend that makes zones live, and building the UX against a fake model
risks rework — so one sprint that lands a *real* zone end-to-end may beat two. To
decide before starting Phase 2.

## Verification + cadence
Per the established model: Claude orchestrates from the main session, implements
each slice himself (no fire-and-forget delegation — that's what produced the hollow
"Done" tickets), commits per phase with the matrix green + the phase's **real-path**
check + a human dogfood gate for *feel*. Cross-refs: `docs/30` (Phase 1 nav),
`docs/23` (Phase 3 backend), `docs/25` (dogfooding polish backlog), memory
`verification-doctrine`.
