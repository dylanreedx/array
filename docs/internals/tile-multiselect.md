# Tile selection and group transforms

Status: implementation prepared for local landing on `array/integration` for
0.7.31; not released. Dylan explicitly authorized direct-checkout work after this session's
read-only `.git` sandbox prevented worktree creation. Do not stage unrelated
changes. The release owner must review this change together with concurrent
agent-reference dragging and file-preview work.

## Interaction contract

- Shift-click a tile's header (excluding controls and the resize ring) toggles
  its membership in the selection. A previously focused tile seeds the set.
- Drag a selected header to translate the selection rigidly. Three screen
  points distinguish movement from a click. Clicking a selected header retains
  the group; clicking an unselected header selects that tile.
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
keeps its project and source zone membership during a group transform. Group
drop is manual placement: no implicit transfer across projects/zones, no
single-tile swap/insert/settle solver, and no independent member snapping.
This policy applies with automatic layout enabled or disabled. Later explicit
Tidy operations can rearrange the result. Existing single-tile gestures keep
their existing snapping, transfer, and automatic-layout behavior.

Group movement/resizing does not resize zone containers. A selected member can
extend outside its original zone; it retains the source membership. Collective
drop adoption, group snapping, and resizing zone envelopes are follow-up design
work rather than accidental per-member behavior.

## Implementation ownership

- `CanvasTileSelection.swift`: one canvas-owned ephemeral selection and gesture
  session; shared viewport-sized overlay; only outer handles consume hit tests.
- `TileSelectionGeometry.swift`: pure immutable WORLD-frame snapshot, rigid
  translation, affine resize, kind minimums, validation; O(selected tiles).
- `TileNSView`: three forwarding hooks after camera-pan classification. Native
  content and title controls do not enter group gesture tracking.
- `CanvasNSView.applySelectionFrames`: stage all zone-local conversions before
  changing any model, apply all frames, then one changed-tile presentation pass.
  It never calls `updateTile` once per member or invokes the single-tile solver.
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

Selection/group geometry owns ordinary selected headers and outer handles.
Agent-reference dragging must retain an explicit separate handle/intent, and a
group transform must never mint or deliver a reference payload. Preserve the
small selection forwarding hooks when integrating header/reference gestures.
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
