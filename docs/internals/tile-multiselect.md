# Tile selection and group transforms

Status: preview approved by Dylan on 2026-10-28. Prepared on
`array/integration` for inclusion in the next release after the other features
are ready. No release version/build number is assigned by this change.

## Next-release handoff

Suggested release note: “Selecting multiple tiles now gives them a subtle lift
and breathing room. Drag groups with the same snapping and automatic layout as
individual tiles, including neighbour pushes and one-step undo.”

The scoped change contains the selection presentation, shared outline geometry,
collective placement, production-mounted witnesses and this document. There are
no new dependencies, settings, file formats or migrations. Selection lift and
spacing are temporary; real moves/resizes use the existing geometry transaction
and persistence paths. Groups retain source project/zone ownership.

Verified: RED-before/GREEN-after `scripts/run-matrix.sh --tile-selection` (all
4 legs reported), plus rebuilt-binary `--focus-border-check` and
`--canvas-pointer-path-check`. The extended app witness covers hover and visible
hit-testing, magnetic destinations, neighbour pushes, cancellation, undo/redo,
failed-save rollback and remount. Light/dark renders were inspected and the
isolated signed dev preview was launched and approved. Local evidence:
`qa-runs/selection-hover-placement/`; preview:
`~/array-scratch/apps/Array Selection Preview.app`.

Before publishing the combined release, run the full release matrix and bundle
verification from `RELEASE.md`; optimized performance profiling remains unrun.
Do not commit local QA stores, preview bundles, or generated release artifacts.

## Interaction contract

- Shift-click a tile's header (excluding controls and the resize ring) toggles
  its membership in the selection. A previously focused tile seeds the set.
- Drag a selected header to translate the selection rigidly. Three screen
  points distinguish movement from a click. Clicking a selected header without
  moving collapses the selection to that tile and focuses it, as any title-bar
  click does; clicking an unselected header selects that tile. (0.7.31 kept the
  group and skipped focus, so after one Shift-select no title-bar click
  focused anything. `--canvas-pointer-path-check` drives that click through
  the real window and focus monitor.)
- One outline per tile. A single selected tile draws nothing extra: the focus
  ants already mark it. A group's members get rings in the ants' own colour,
  gap, radius and dash (`FocusBorderOverlayView.ringRadius`), except the member
  already wearing the ants or the attention ring. (0.7.31 drew a second, solid
  ring on every selected tile at a fixed 8pt radius, so a clicked tile wore two
  outlines that never lined up.)
- An idle multi-selection lifts 4 screen points and opens a small temporary
  gutter using the same 0.11s ease-out motion as layout pushes. Separation is
  capped at 12 screen points per axis; heavily overlapping arrangements retain
  clipped outlines rather than jumping apart. Actual view origins follow the
  pose, so controls and focus hit-testing follow the visible tiles. Tile model
  frames and native content bounds stay unchanged. Reduce Motion settles
  immediately. The pose returns to rest at the drag threshold and clears when
  deselected; it never becomes the baseline for persistence, snapping or Undo.
- Outline clearance adapts in screen space. Exposed edges keep the configured
  gap; facing edges share the available space with a 2pt gutter. Touching bodies
  inset their facing outlines slightly. When bodies overlap, the lower tile's
  outline is clipped behind the higher tile's outline, preserving a clear gutter.
  Focus, attention and selected-member outlines use the same resolution, with
  stacking resolved by `(zPosition, id)`. Selection and camera changes never move
  or persist tile bodies. Only currently outlined tiles participate; ordinary
  unselected bodies are not collision obstacles. Group handle bounds stay fixed
  relative to the original tile arrangement, independent of adaptive clearance.
- One outer selection rectangle has eight resize handles. Edges scale one axis;
  corners scale both independently. The opposite edge/corner stays fixed. Tile
  frames and gaps scale; native text/browser/terminal content reflows at its new
  logical size. Content is never stretched as an image. A common scale stops
  shrinking when the first tile reaches its kind-specific minimum size.
- A member's own resize ring selects and resizes that tile individually.
- Native content retains Shift-click text selection and its own controls.
  An ordinary body mouse-up collapses the canvas selection to that tile.
- Cmd/Space camera pan takes precedence over tile selection and outer handles.
- Background click clears selection. Escape during a gesture restores the
  complete baseline; a second Escape clears selection. Deactivation, removal,
  and replacing installed zone layers cancel an active group transaction.
  Collapsing a zone removes its hidden members from the selection.
- Selection is ephemeral and separate from FocusBroker, keyboard focus,
  persisted last-active tile, and the armed creation zone. Shift-select/group
  gestures put the canvas in the responder chain without focusing composers.

## Zone and automatic-layout policy

Selection can span installed workspace tiles and project stores. Each tile
keeps its project and source zone membership during a group transform.
Magnetic placement treats the selection's rest-frame envelope as one object,
excludes every selected member from snap candidates, and uses the existing
acquire/release hysteresis and configured gap. The ghost is the exact collective
drop destination. Drag Snapping still applies when automatic layout is disabled.

With automatic layout enabled, a temporary envelope per source zone goes
through the existing solver. Residents use the existing push and slot behaviour;
selected members keep their sizes and relative arrangement. A single-zone group
can latch to a swap/insertion slot collectively. Multi-zone groups keep a common
requested translation and source membership rather than independently latching
their zone subsets. Envelopes conservatively reserve the spaces between group
members. Selected tiles follow the pointer directly while displaced neighbours
use the existing motion. Drop settling/containment and any displaced neighbours
are captured in the same persistence/Undo transaction. Escape restores the whole
baseline, including bystanders and zone geometry.

## Implementation ownership

- `CanvasTileSelection.swift`: one canvas-owned ephemeral selection and gesture
  session; shared viewport-sized overlay; only outer handles consume hit tests.
- `TileOutlineGeometry.swift`: pure screen-space edge clearance and z-ordered
  clipping; cached for unchanged outlined members. Pairwise work is O(K²) in
  outlined tiles, not the canvas population. No per-frame animation callback or
  native content measurement is added.
- `TileSelectionGeometry.swift`: pure immutable WORLD-frame snapshot, rigid
  translation, affine resize, kind minimums, validation; O(selected tiles).
- `TileNSView`: three forwarding hooks after camera-pan classification. Native
  content and title controls do not enter group gesture tracking.
- `CanvasSelectionHover.swift`: cached, bounded idle selection pose and finite
  compositor motion; updates origins only, never native content sizes.
- `TileSelectionPlacement.swift`: per-zone rigid envelopes over the existing
  solver, expanded back to real members before applying/persisting.
- `CanvasNSView.applySelectionFrames`: stage zone-local conversions, solve the
  group, and apply one transaction. It never calls `updateTile` per member.
- `AppDelegate.installTileFocusMonitor`: pre-dispatch mouse-up routing yields
  while the selection owner is tracking. Bringing a view forward on mouse-down
  must remain forbidden: reparenting breaks AppKit drag tracking.
- Existing geometry transactions provide one persistence/undo commit and
  complete rollback on failed saves. WORLD frames are persisted through the
  existing multi-project writer; no selection fields or file-format changes.

Coordinates are derived from the original pointer and geometry snapshot, not
accumulated event deltas. Each frame crosses from WORLD into its owning
ZoneLayer's LOCAL space only at the model boundary. Unchanged frame/bounds
writes are skipped. Moving a tile changes its origin without resizing content.
The overlay occupies the viewport, avoiding a giant backing surface when
selection spans widely separated tiles. Camera updates transform cached
selection rectangles without scanning the installed tile population.

Staging the batch and the current canvas presentation pass each scan installed
models once. During a gesture, the overlay uses the already-computed selected
frames without allocating world records for unselected tiles. This is O(N + K),
not O(K × N); indexed dirty-model presentation is a separate optimization.
Native content reflow during group resizing still needs representative profiling.

## Coexistence with agent-reference dragging

Dylan asked this agent to notify the agent directly below it. The workspace API
identified that tile as `97807C1C-6C70-454A-B956-8E61BB32ABCB`, agent
`5D4DA05C-71F5-489E-97C6-48B71758B403` (“Plan agent tile drag references”).
The coordination message was delivered, preserving camera/focus/selection.
Later build/completion follow-ups were refused because that agent was mid-turn;
Array does not queue or interrupt a running agent for this operation. This
document is the durable completion handoff; the initial notification succeeded.

Selection/group geometry owns selected headers within a group and the outer
handles; a group transform never references. A single agent's header drag is
the ordinary live move, and reads as a reference only while the pointer is over
another agent's composer or the middle of its body (`AgentReferenceDrag`). The
explicit "@" handle and the frozen-layout header drag of 0.7.31 are gone.
Native title accessory controls keep hit-test precedence.

## Witnesses and evidence

Until the crash-isolation release is installed, run every build and built
binary through `/tmp/exc-probe/noexc`, including the scoped development gate:
`/tmp/exc-probe/noexc scripts/run-matrix.sh --tile-selection`. See
`.plans/82-release-0731/README.md` for the inherited crash-handler issue.
It rebuilds both products and runs the witnesses through the normal matrix
accounting/isolation, with a final leg summary. The full release matrix remains
required before shipping; the targeted gate does not run iOS or bundle probes.
The scoped path retains the two initial structural program checks, inventory,
and colour hygiene, but skips the unrelated program negative-case suites. The
ordinary full matrix retains those suites and its existing build/check order.
On this restricted session, a temporary `/tmp/array-multiselect-tools/swift`
wrapper adds SwiftPM's `--disable-sandbox` and a cache path under `/tmp` to build
commands. It does not change the enclosing agent sandbox or repository config.

- `--tile-multiselect-check`: production-mounted isolated workspace, real tile
  header events and outer-handle hit testing; shared translation/resize,
  unchanged bystanders, zoom 1 and 0.35, automatic layout on/off, native bounds,
  one-step undo/redo, Escape, failed-save rollback, disk and remount geometry.
  A separate leg spans two projects and three zones, checking source ownership,
  both project stores, deactivation and workspace switching. Light/dark PNGs
  are written to `qa-runs/tile-multiselect/` for visual inspection.
- `--tile-selection-geometry-check` on CoreChecks: all eight handles, fixed
  anchors, unequal/mixed tile minimums, baseline reuse, invalid inputs.
- Both are registered in `scripts/run-matrix.sh`; a real matrix summary must
  report them before this work can be called release-verified.
- The initial behavioral witness was RED before implementation. Log:
  `qa-runs/tile-multiselect/red.log`. Existing single-tile snapping moved only the
  grabbed tile, failing the shared-delta assertion.
- A plain SwiftPM build failed because nested `sandbox-exec` is forbidden in
  this environment. Targeted builds use `swift build --disable-sandbox` plus
  cache paths under `/tmp`; the enclosing agent sandbox remains in force.
- The first implementation build also encountered an over-complex tuple
  expression (split into typed intermediates) and a concurrent edit to
  `ComposerFileReferenceRailView.swift`; retry after source writes settle.
- Review additionally caught deactivation leaving a stale selection gesture,
  cancellation swallowing the next camera pan, and modifier release collapsing
  selection before a pan ended. Gesture reset and pan ownership handle those
  cases; the pointer witness includes cancellation followed by a fresh Cmd-pan.
- Shared build failures have also included in-progress reference-drop methods
  temporarily placed in `FlippedStackView` rather than the agent tile owner.
  Those files remain with the reference-drag agent; no competing fix was made.

Final verification results and any unverified release gates are recorded below
as the implementation is exercised. No production app, live project store,
default tmux server, release version, or UI baseline is modified.

### Verified on 2026-10-24

`scripts/run-matrix.sh --tile-selection` passed with **4 legs reported**:
inventory, colour hygiene, `--tile-selection-geometry-check`, and
`--tile-multiselect-check`. Both products were rebuilt before the witnesses.
The app witness passed at zoom 1.0 and 0.35 with automatic layout off/on, plus
the two-project/three-zone case. It checks one batch per pointer sample, only
two changed views laid out for a two-tile move, no native bounds resize during
movement, and real native bounds resizing through the outer handle.

Additional existing checks passed on that build:

- `--tile-drag-grab-check`
- `--canvas-undo-check`
- `--tile-insert-slide-check`
- `--resize-snap-check`

`git diff --check` and `bash -n scripts/run-matrix.sh` passed. Bench inventory
was run at pickup and completion; no bench was created, removed, or altered by
this work. The normal program self-tests also passed (26 agent-tile negative
cases and 43 sidebar negative cases) during the earlier matrix attempt before
a concurrent reference-check source edit invalidated its build.

Visual inspection of `qa-runs/tile-multiselect/light.png` and `dark.png`
confirmed the selected outlines, outer rectangle, and eight handles render in
both appearances. Selection strokes reuse `FocusBorderOverlayView.lineWidth`.
The compact fixture notes show existing title-accessory crowding; that UI is
outside this feature and was not changed.

Evidence: `qa-runs/tile-multiselect/matrix.log`, `runner-status.json`, the four
regression-check logs, both PNGs, and `red.log`. Intermediate failures exposed
two witness coordinate mistakes: root content hit-testing needs window-base
coordinates, and a low-zoom header press must use the real grab strip below
the screen-sized resize margin. Both were corrected before the green run.

## Release handoff

New feature files:

- `Sources/ContinuumRevived/Canvas/CanvasTileSelection.swift`
- `Sources/ContinuumRevivedCore/TileSelectionGeometry.swift`
- `Sources/ContinuumRevived/App/TileMultiselectChecks.swift`
- `Sources/ContinuumRevivedCoreChecks/TileSelectionGeometryChecks.swift`
- This document.

Integration hunks are in `CanvasNSView.swift`, `TileNSView.swift`,
`App/ContinuumApp.swift`, `ContinuumRevivedCoreChecks/main.swift`,
`scripts/run-matrix.sh`, `docs/38-tickets/90-agent-ux/matrix-inventory.txt`, and
`docs/README.md`. Several already contain unrelated work by other agents:
review/stage the selection hunks rather than committing entire shared files.
Landing uses an own-hunk patch and a reviewed index, as requested by the
0.7.31 release coordinator. No push or release-version change is authorized.
The attempted isolated worktree could not be created.

Before shipping, run the full matrix (including iOS and bundle coverage) and
profile group resizing with representative live agents/terminals/browsers.
The deterministic selection witnesses use real notes/file views and geometry
work counters; they do not establish a hardware frame-time budget for many rich
surfaces. The preview bundle has not been rebuilt or installed.

### Adaptive outline clearance verified on 2026-10-28

The extended production-mounted `--tile-multiselect-check` was RED against the
previous rendering: an 8pt tile gap produced outline bounds overlapping by 8pt
at zoom 1. The rebuilt targeted matrix then passed all 4 reported legs with the
shared outline resolver. It asserts 2pt focus/member clearance at zoom 1/.35,
focus transfer, configured-gap recovery, touching bodies, vertical/diagonal
neighbours, overlapping/nested actual stroke masks, attention ownership/removal,
selection-clear restoration and unchanged tile models/disk during selection and
camera changes. Close, touching, overlapping and nested captures are written to
`qa-runs/tile-multiselect/outline-*.png`; light/dark close and overlap captures
were visually inspected.

Additional rebuilt-binary `--focus-border-check` and
`--canvas-pointer-path-check` both passed. Logs are in
`qa-runs/selection-adaptive/`. One intermediate rebuild refused a check source
modified during compilation; the successful run followed settled source writes.
The full release matrix and optimized performance profiling were not run for
this debug preview. No new animation loop, tile body layout, or geometry
persistence is introduced by adaptive outline drawing.

### Hover and collective placement verified on 2026-10-28

Dylan requested a small lifted/space-separated idle selection and the existing
magnetic/automatic layout behaviour during group drags. The mounted hover
witness was RED against the prior implementation (8pt body gap rather than
18pt). The updated targeted matrix passed all 4 reported legs. Its app leg now
checks 4-screen-point lift and clearance at zoom 1/.35, protruding-edge focus
hit-testing, unchanged model/disk during selection, exact collective magnetic
ghost commit, live resident pushing, Escape restoration and one-step undo/redo.
The existing group resize, failed-save rollback, remount and multi-project
ownership witnesses also passed. Existing pointer/focus checks passed on the
rebuilt binary; light/dark close-selection renders were visually inspected.

One intermediate build was rejected because a concurrent SettingsPanes edit
changed during compilation; rerunning after that edit settled passed. Logs live
in `qa-runs/selection-hover-placement/`. The full release matrix and optimized
performance profiling were not run for this debug preview. Large existing
body overlaps retain outline clipping because idle separation is deliberately
capped. Group envelopes conservatively reserve internal empty space; group
drops retain source ownership rather than transferring projects/zones.
