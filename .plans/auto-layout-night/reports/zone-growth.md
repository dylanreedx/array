# Tidy versus neighbouring zones

Date: 2026-11-09. Branch: array/aln-zone-growth (local, not pushed).
Base: array/auto-layout-night d1eef7e2.

## Finding and fix

What was wrong: a tidy that grew a zone left it lying over the zone it
grew into. Seen through production: zone G (900x420, four 400x300 notes)
tidied to 900x558.9 over zone N 40pt below it; zone W (a browser inspector
wider than its 500pt zone) tidied to 568 wide over zone E 40pt to its
right. Both with auto layout on and off.

Why: `CanvasTidyPacker` can grow a zone, but `CanvasAutoLayoutEngine.solve`
resolves outer collisions only for a zone being moved (`activeZone`), and a
tidy has none, so `resolveOuterCollisions` returned at its first guard.

Fix (26386bfa): `CanvasNSView.tidyAutoLayout` now calls
`pushPeersOfZonesGrown(since:)` after the pack. Each zone that grew, in
reading order (top, then left), runs the existing
`CanvasAutoLayoutEngine.pushPeers(ofGrownZone:from:)`, the rule spawn growth
already uses:
- neighbouring zones move clear as rigid bodies with their members;
- bare tiles move clear and are never adopted;
- a peer the zone touched before and reaches no deeper into stays put;
- a zone that shrank pushes nothing and pulls nothing.
A grown zone's "before" is its pre-tidy size at its current origin, so a
push it took from a zone above does not count as its own growth. The push
is inside the tidy's one geometry edit: one undo, one scoped save. No
engine change: the engine's tidy internals belong to the tidy stream.

## Witness: --tidy-zone-neighbours-check

Mounted workspace (WorkspaceInvariantsFixture), each zone its own project
owned by the workspace, the saved camera framing the scene so every zone is
live. Entries: the zone header's own context menu (its "Tidy Zone Now" item,
sent through NSApp.sendAction) and the palette's Tidy Canvas.

1. Growth, auto layout on and off: G grows in height into N, W grows in
   width into E. After: no two zones overlap; the neighbour keeps its size
   and moves as a rigid body with its tiles; no tile changes zone; every
   tile's WORLD frame and every zone placement on disk match the screen.
   Undo restores both zones and the neighbour's tiles; redo pushes again.
2. Tidy Canvas over six 1000x400 zones, three columns 100pt apart, two
   rows 20pt apart, alternating cramped (six 400x300 notes) and roomy (one
   note): 3 zones grow and 3 shrink. No overlaps, every zone filled edge to
   edge (members span the content rect within 0.1pt), no tile overlaps,
   disk matches. Two identical workspaces tidy to identical frames, and a
   second Tidy Canvas changes nothing.
3. Shrink: an oversized 2400x1600 zone with one note shrinks; its right
   and lower neighbours and their tiles do not move.
4. Bare tiles: bare project tiles exist only on array/bare-tiles, so the
   rule is asserted on the engine call the fix uses: a grown zone pushes a
   bare tile clear below it, never stamps it, and leaves its own member.
5. Auto layout off: case 1 runs in both modes.

Teeth, with the push disabled: case 1 fails 6 checks (both modes, both
growth axes) and the grid fails 4 (grid00 436.7 tall over grid10 at
y = 420, and grid02 over grid12).

## Checks (offscreen, isolated app support and TMUX_TMPDIR)

All exit 0 on the final tree: tidy-zone-neighbours, and the regression set
subagent-tile-zone, leader-jump, tile-reveal-work, agent-local-file-link,
canvas-zoom-momentum, spawn-placement, spawn-sizing, auto-layout-fanout-app,
zone-arming, canvas-undo, layout-commit-scope; plus auto-layout-tidy-latency,
jelly-auto-layout, layout-commit-truth, spawn-arrange-commit, zone-layer-move,
zone-move-unified, workspace-scene-owner, tile-insert-slide.

Registered in run-matrix.sh after --layout-commit-scope-check; inventory
regenerated in the C locale (only this leg added).

## Commits

- d8c170d3 test(auto-layout): witness tidy growing a zone into its neighbours (red)
- 26386bfa fix(auto-layout): push neighbours clear of a zone a tidy grew
- c6f00541 test(auto-layout): make the tidy grid grow into its neighbours
- f361bd80 test(auto-layout): register the tidy neighbours leg in the matrix
- 47a82e5c test(auto-layout): cover undo and redo of a tidy that pushed a neighbour

## Rejected

- Fixing it in the engine (passing each grown zone as `activeZone` to
  `resolveOuterCollisions` inside `solve`): the same push, but in the tidy
  stream's engine internals, and without `pushPeers`' rule that a peer the
  zone already touched and reaches no deeper into is left alone.
- 12 notes in 1000x800 for the grid's cramped zones: the packer shrank the
  tiles instead of growing the zone, so the grid proved nothing.
