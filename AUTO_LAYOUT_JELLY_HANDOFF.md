# Auto Layout Jelly — Rejected Implementation Handoff

## Read this first

This branch is **not approved and should not be integrated as-is**.

Dylan's final evaluation of the interaction was that it was incorrect and felt substantially worse than the original canvas behavior. In particular, tile swapping still did not behave like a simple location exchange. I repeatedly treated narrow automated end-state checks as proof of acceptable interaction feel; that was a serious validation error.

The next agent should regard the entire interactive solver integration as experimental. Do not infer product acceptance from green tests or from the prior assistant's statements that a behavior was "fixed."

## Repository state

- Isolated worktree: `/Users/dylan/array-worktrees/auto-layout-jelly`
- Branch: `array/auto-layout-jelly`
- Current HEAD before this handoff document: `a39d4da0d28240ac4b13b3ec7985c23046bfa80c`
- Feature branch merge-base: `d0aef13a6b377ebda84fac5f6b93269b0df64ec2`
- Current `array/integration` HEAD: `9fb128489506a41db039cb16d91acf92629822a0`
- The feature branch has **not** been rebased onto the current integration HEAD.
- The integration worktree is `/Users/dylan/Documents/personal/Array` and already contains extensive unrelated uncommitted work. It was not modified by this implementation. Do not copy from it, clean it, stash it, or rebase it.
- The feature worktree was clean before adding this handoff file.

An isolated preview is currently running from:

`/Users/dylan/array-worktrees/auto-layout-jelly/qa-runs/jelly-manual-20260821T021111Z/Array.app`

It uses only disposable state:

- Project: `/tmp/array-jelly-manual-project.gsyeRP`
- App support: `/tmp/array-jelly-manual-support.XD9KRe`
- tmux namespace: `/tmp/array-jelly-manual-tmux.VJEEEU`

The disposable project was altered by manual drag testing and is not a pristine fixture.

## Dylan's intended behavior

The important requirements expressed during implementation were:

1. Auto layout is on by default, but an absent preference on upgrade must not immediately rearrange existing layouts.
2. Tiles inside a zone are aware of and interact with one another, especially during resize.
3. Resize pressure order is: restore/compress configured gaps, shrink neighboring tiles down to their existing tile-kind minimums, and only then grow the zone.
4. Collision direction is asymmetric: tiles may cross/intersect a zone boundary so they can be adopted; a moved or resized zone must not pass through outside or inside tiles.
5. Adding a new zone member must resize/repack the zone so the member remains contained.
6. Moving a middle tile horizontally onto a left tile should simply exchange their locations. It must not resist, escape the zone, jump diagonally, or send either tile toward a corner.
7. Expanding space should restore the configured gap without restoring a stale historical composition.
8. Freeform canvas feel must remain primary. Auto layout should provide local pressure and spatial awareness, not continuously reinterpret the composition.

The current branch does not satisfy item 6, and Dylan reported a broad regression in the overall interaction feel.

## Commit inventory

Commits after the merge-base, in order:

1. `a16afff Add deterministic jelly auto layout solver`
   - Introduces `CanvasAutoLayoutEngine`, layout scene types, packing, collision propagation, and core geometry checks.
2. `f7df4b2 Persist zone auto layout overrides`
   - Adds `ZoneAutoLayoutMode`, schema v6 migration, spatial operation support, and sync persistence.
3. `18eb384 Integrate jelly layout with canvas gestures`
   - Adds canvas scene adaptation, in-memory preview transactions, gesture integration, and commit plumbing.
4. `9bb6d39 Add auto layout settings and tidy UX`
   - Adds global preferences, activation behavior, zone override menu, and Tidy commands.
5. `8be0e5a Harden jelly layout interactions and validation`
   - Adds interaction checks, alignment/breakaway work, transaction and performance validation.
6. `d966e18 Make layout commits durable across stores`
   - Adds cross-store save/rollback behavior and runtime update ordering.
7. `ea09b3c Allow direct tile drops into jelly zones`
   - Makes the zone/tile collision rule asymmetric and permits direct tile adoption.
8. `0d830a1 Transfer in-zone resize pressure between tiles`
   - Adds neighbor shrinking down to tile minimums before zone expansion.
9. `25fc858 Grow zones for spawned tiles and swap occupied slots`
   - Combines two unrelated changes: spawn containment/zone growth and the first incorrect swap implementation.
10. `a39d4da Keep tile swaps on the drag axis`
    - Attempts to correct the first swap implementation. Dylan rejected this behavior too.

The aggregate diff from the merge-base is roughly 1,759 insertions across 20 files. Do not cherry-pick the branch wholesale without a fresh interaction review.

## The rejected swap implementations

### First attempt: `25fc858`

Code is in `Sources/ContinuumRevivedCore/CanvasAutoLayoutEngine.swift`.

The solver detected a target when the requested active tile's center entered another member's rectangle. It then assigned the target's origin to the active tile and the active tile's original origin to the displaced tile. The result was subsequently fed into the general `pack` function.

Why it was wrong:

- General packing could reinterpret unequal tile dimensions or small vertical differences as a different lane.
- The result could jump diagonally or toward a corner.
- There was no explicit gesture-level swap state or hysteresis.
- A final-frame equality assertion did not test the trajectory or resistance experienced during the drag.

### Second attempt: `a39d4da`

The current `applySlotSwapIfTargeted` starts near line 227 of `CanvasAutoLayoutEngine.swift`.

It currently:

- Chooses horizontal versus vertical from the dominant total drag vector.
- Requires at least 50% overlap on the orthogonal axis.
- Triggers only after the active center crosses the candidate center.
- Reconstructs the pair along the selected axis while preserving their prior gap.
- Bypasses the general packer only if the reconstructed pair validates.
- Falls back to the ordinary packer if it does not validate.

Why this is still not a simple location swap and should be removed or redesigned:

- For unequal sizes, it does **not** exchange the two original locations. It rebuilds pair geometry and can place the displaced tile somewhere other than the active tile's old position.
- The threshold creates an abrupt discontinuity during a continuous drag.
- Dominant-axis selection can change as the pointer vector changes.
- If pair validation fails, execution falls back into the same general packer that caused the diagonal/corner behavior.
- Validation uses zero gap against untouched tiles rather than the configured gap.
- There is no latched candidate, hysteresis, insertion marker, or stable swap state for the duration of the gesture.
- The 50% lane-overlap heuristic embeds an unvalidated idea of what a row/column is on a freeform canvas.
- The automated check observes only the final mouse-up geometry, not intermediate pointer lag, snapping, oscillation, or visual continuity.

Recommended immediate action: revert `a39d4da`, then remove the swap portions of `25fc858` while retaining the independently useful spawn containment changes only if they survive fresh review.

## Spawn changes entangled with the first swap commit

`25fc858` also contains changes that are separate from swapping:

- `TileSpawner.swift` assigns a newly spawned flat managed-agent tile to the active zone and calls `arrangeAutoLayoutAfterSpawn`.
- `CanvasNSView.installProjectTile` calls `arrangeAutoLayoutAfterSpawn` for ZoneLayer-backed project tiles.
- `CanvasNSView.arrangeAutoLayoutAfterSpawn` captures a scene, expands the zone to contain members, tidies, commits, and calls `canvasDidChange`.
- `CanvasNSView.expandZoneToContainMembers` grows zone bounds around member world frames with header/padding allowances.

These changes addressed a reported regression where adding a third member did not resize the zone. They passed targeted spawn checks, but they are coupled to immediate solving and may still contribute to the degraded overall feel. Review them independently rather than assuming they are correct.

## Main implementation surfaces

- `Sources/ContinuumRevivedCore/CanvasAutoLayoutEngine.swift`
  - Pure solver, packing, resize pressure, outer collision propagation, and the rejected swap heuristic.
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift`
  - Scene adapter, preview/finish transaction flow, tile and zone gesture hooks, spawn arrangement, UI feedback, and AppKit self-check.
- `Sources/ContinuumRevived/Canvas/TileNSView.swift`
  - Gesture integration additions.
- `Sources/ContinuumRevived/App/TileSpawner.swift`
  - Spawn membership and post-spawn arrangement.
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
  - Preferences, commands, menu wiring, and QA entry points.
- `Sources/ContinuumRevivedCore/WorkspaceDocument.swift`
  - Schema v6 and zone override persistence.
- `Sources/ContinuumRevivedCore/SpatialOp.swift`
  - `setZoneAutoLayoutMode` operation.
- `Sources/ContinuumRevivedCore/CanvasAutoLayoutConfig.swift`
  - Defaults and activation policy resolution.
- `Sources/ContinuumRevivedCoreChecks/main.swift`
  - Geometry, migration, transaction, stress, resize-pressure, spawn, and rejected swap assertions.

## Test history and its limitations

Targeted commands that passed at the current/recent HEAD:

- `swift build --product Array`
- `swift build --product ContinuumRevivedCoreChecks`
- `.build/debug/Array --jelly-auto-layout-check` with disposable project/app-support roots
- `.build/debug/Array --managed-agent-model-spawn-check`
- `.build/debug/Array --spawn-placement-check`
- `.build/debug/Array --note-file-tile-spawn-check`
- `.build/debug/ContinuumRevivedCoreChecks`

The latest core run printed:

- `Jelly auto layout: geometry/migration/config checks passed; 50-entity p95 2.387 ms`
- `ContinuumRevivedCoreChecks passed`

These passes do not validate the interaction feel. The swap check is structurally biased toward the implementation and only asserts final frames.

Both the fast and full matrix logs under `qa-runs/jelly-final/` ended failed with three recorded failures:

- `swift run ContinuumRevivedCoreChecks` — the matrix run failed an isolated tmux I2 production grouped-view check.
- `--tile-surface-residency-check`
- `--terminal-tmux-live-integration-check`

The logs also contain the matrix's documented known-red checks. Do not describe the full matrix as passing.

Logs:

- `qa-runs/jelly-final/matrix-fast-final.log`
- `qa-runs/jelly-final/matrix-full.log`

Targeted AppKit manifests:

- `qa-runs/jelly-auto-layout-6F8E8687-D1C6-4F94-80E3-21A8642DF23B/manifest.json`
- Earlier manifests under `qa-runs/jelly-auto-layout-*`

Manual screenshots:

- `qa-runs/jelly-manual-20260821T021111Z/slot-swap-20260821.png`
- `qa-runs/jelly-manual-20260821T021111Z/horizontal-swap-axis-locked.png`

The screenshots are not proof that the interaction is correct. The second was captured after arranging a favorable same-row case and inspecting only its endpoint. I incorrectly presented it as validation.

## Validation mistakes to avoid repeating

1. I optimized assertions for a geometry endpoint instead of the full drag trajectory.
2. I used contrived equal/same-row fixtures before adding unequal-size coverage.
3. Even after unequal-size coverage, the expected results encoded my invented behavior rather than Dylan's intended feel.
4. I treated a single manual drag and screenshot as representative.
5. I declared fixes before Dylan had tried them.
6. I combined spawn correction and swapping in one commit, making selective rollback harder.
7. I let the solver infer topology during direct manipulation without first defining a stable interaction state machine.

## Suggested next approach

Do not patch the current heuristic again before reproducing the problem with trajectory instrumentation.

A better sequence would be:

1. Disable/remove automatic swapping while retaining ordinary direct dragging, so the canvas returns to a stable baseline.
2. Record requested active frames and every preview result across an actual horizontal drag with three unequal tiles.
3. Define "swap locations" with Dylan using a visible insertion/slot model. In particular, resolve whether location means origin, center, occupied interval, or ordering when sizes differ.
4. Implement swap as an explicit gesture state (`none`, `candidate`, `latched`) outside the generic collision packer.
5. Keep the active tile pointer-responsive throughout. Preview the displaced tile only after a stable threshold; do not mutate topology back and forth on every frame.
6. On a latched swap, supply an explicit pair transaction. Do not feed that transaction through generic nearest-lane packing.
7. Test the entire frame sequence for monotonic axis movement, zero orthogonal movement, no threshold oscillation, no zone escape, and exactly one durable commit on mouse-up.
8. Test equal and unequal tile sizes, slight y-offsets, intervening tiles, insufficient room, zone edges, and reversal back across the threshold.
9. Only after hands-on acceptance should the behavior be described as fixed.

## Safe rollback guidance

- `a39d4da` contains only the second swap attempt and its tests; reverting it returns to the first rejected swap implementation.
- `25fc858` mixes spawn-zone growth with the first rejected swap implementation. Do not revert it wholesale if retaining spawn containment; split or selectively revert its engine/test hunks.
- A clean redesign may be easier from `0d830a1`, then cherry-pick only the spawn-related hunks from `25fc858` after reviewing them.
- No merge, rebase, cherry-pick, or worktree deletion has been performed.

