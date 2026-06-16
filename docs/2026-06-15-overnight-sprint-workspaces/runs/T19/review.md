# T19 review (re-dispatch 2) — on-canvas drag-create + move-zone gesture

Reviewer: adversarial, read-only. Branch `overnight/workspaces-zones`, uncommitted working
tree (833 insertions across 6 files + untracked ZoneGestureConfig.swift). All source was
restored to the builder's diff after every experiment; final tree verified == builder's diff.

## Verdict: PASS WITH RISKS

Committable. The check drives the real AppKit mouse path and goes RED when the gesture is
stubbed; all named risks are visual/feel items the check cannot see (correct for a `[morning]`
task) plus one render-model live-staleness concern Dylan must eyeball before marking Done.

---

## 1. Bypass audit (#1 gate) — PASS

The check synthesizes real `NSEvent`s (`.leftMouseDown/.leftMouseDragged/.leftMouseUp`) and
dispatches them through `canvas.mouseDown/mouseDragged/mouseUp`. No `createZone(...)` /
`moveZone(...)` executor is called directly. `onZoneCreated`/`onZoneMoved` only fire from
inside the `.creating`/`.movingZone` arms of the overridden `mouseUp`, which only run if
`mouseDown` set `zoneGesture` accordingly.

**I re-ran the check myself: GREEN** (`ContinuumRevivedZoneCreateGestureChecks passed`).

**I performed my own independent bypass test on the PRIMARY path** (not relying on the
builder's reported stubs): I commented out `zoneGesture = .creating(originScreen: point)` in
`CanvasNSView.mouseDown` (CanvasNSView.swift:973), rebuilt, re-ran →
`FAIL: assertion 2: exactly one zone created; got 0`. Reverted, rebuilt, GREEN again. The
create path is genuinely recognition-driven, not a bypass.

Builder's other two RED proofs are consistent with the code (defect-A `_zoneId`→`zoneId`
revert fires 7b; defect-C `pendingMovedPlacement` stub fires C1).

Persistence is a real disk round-trip: assertion 7 builds a temp `WorkspaceStore`, wires
`onZoneCreated` to the same load/append/save logic as `AppDelegate.persistCreatedGroupZone`,
replays the drag, reloads from disk, asserts one on-disk zone with the right geometry. A no-op
callback leaves the store empty → RED. Not a tautology.

## 2. Right reason — PASS (two values re-derived by hand)

- **Assertion 6 (zoom 0.5, non-origin viewport — the bug-magnet).** `screenToWorld(p,vp) =
  (p.x/zoom + vp.x, p.y/zoom + vp.y)`. aw = sw((100,100),vp(200,100,0.5)) = (400,300). bw =
  sw((300,300)) = (800,700). origin = min = (400,300); size = (|800-400|, |700-300|) =
  (400,400). Matches the asserted `(400,300)`/`(400,400)`. Confirms screen→world (not raw
  screen px) is committed.
- **Assertion 11 (adaptive bounds after move).** After move origin (380,250): member world
  frames t1=(400,290,160,120), t2=(580,290,160,120). Union → (400,290,340,120). With P=24,
  H=34: (400-24, 290-24-34, 340+48, 120+48+34) = (376,232,388,202). Matches
  `CanvasEngine.zoneBounds` (CanvasEngine.swift:92) exactly. The assertion reads the **real**
  T11 constants `ZoneBoundsConfig.defaultPadding` and `ZoneChromeNSView.headerHeight`, not
  hardcoded literals.

`CanvasEngine.zone(_:draggedByScreenDelta:)` mirrors shipped `tile(_:draggedByScreenDelta:)`
(divide screen delta by zoom; caller pre-negates dy). dy-sign handled (assertion 9: downward
drag → origin.y 200→250). Tiles ride via origin shift only: `_layoutLayerTile`
(CanvasNSView.swift:1309) reads `tile.frame` and sets the *view* frame; never mutates stored
`tile.frame`. Assertion 10 checks BOTH halves (stored zone-local unchanged AND screen shifted).

## 3. Scope — PASS

Touched files == spec's named set. Verified via `git diff`:
- **No T05/T11 API modified.** `upsertZoneLayer`, `setZonePlacement`, `removeZoneLayer`,
  `zoneLayerChromeFrame`, `zoneBounds` are all pre-existing (T05/T11 already landed — the
  spec's NEEDS-HUMAN notes claiming they're "not yet written" are STALE). T19 adds only
  `_zoneId(at:)`, `_zoneHeaderZoneId(at:)`, the `ZoneGesture` state, the gesture handlers,
  `qaZoneLayerPlacement`, and the check.
- **`ZoneChromeNSView.hitTest` still returns `nil`** (CanvasNSView.swift:3869); classification
  is at the canvas layer via `_zoneHeaderZoneId`. `multi-zone-render-check` stayed green.
- **TileNSView + 4 global monitors untouched.** AppDelegate changes are 2 callback wirings +
  2 persist helpers, all in ContinuumApp.swift (on-spec).
- **Configurable-first wired.** `ZoneGestureConfig` (default 24, >0 guard) + SettingsSchema
  `.text` in `general` + Core check `expectedKeys` entry (conflict guard) + resolver
  round-trip (24 / 40 / 0→24 / neg→24). No hardcoded `24` in CanvasNSView.
- Uncommitted → no co-author-footer yet (must stay footer-free on commit).

## 4. Matrix — PASS

`./scripts/run-matrix.sh --fast` → `Fast matrix passed.` (includes the new check + neighbors).
`swift run ContinuumRevivedCoreChecks` → passed. `swift build` clean (pre-existing ghostty
link warnings only). No regression.

> Note: Core-checks output prints `branch change / Switched to branch 'main'` — that is a
> PRE-EXISTING diff-check fixture, NOT a T19 effect. Working branch + uncommitted tree intact.

---

## RISKS (committable, hoisted — eyeball before Done)

1. **Render-model move path leaves `zoneRenderModels` stale.** `zoneRenderModels` is `let`
   (CanvasNSView.swift:68). On the production move path (CanvasNSView.swift:1039) the code
   updates the chrome view `.frame` + `pendingMovedPlacement` + persists, but does NOT update
   `zoneRenderModels[i].placement`. A relayout reading `zoneRenderModels` before the canvas is
   reconstructed from the reloaded doc could snap chrome back to the pre-move origin. Check
   only asserts callback origin (C2), not a post-relayout re-render. EYEBALL: move a group
   zone, then pan/zoom, confirm no snap-back.

2. **Freshly-created empty zone "lands" at 480×320 empty-min, not the marquee rect.** Stored
   placement size is the drag rect (assertion 3 = 400×320, correct), but an empty ZoneLayer
   draws chrome via `zoneBounds` empty-branch → `emptyMinSize` 480×320 (ZoneBoundsConfig.swift:13-15)
   offset to origin. A marquee narrower than 480px will visibly POP wider on release —
   contradicts the spec's "no jump on landing." Check can't see it (asserts stored geometry).
   EYEBALL: drag a small marquee, confirm landed visible size is intentional.

3. **Created zone double-represents (live ZoneLayer + on-disk render model) within a session.**
   Create installs a live ZoneLayer AND persists; next full re-render rebuilds it as a
   render model. Behavior of a relayout between create and reconstruct is unverified. Likely
   benign; eyeball with risk 1.

4. **Assertion 11 reads `ZoneBoundsConfig.defaultPadding` (constant) while the live move uses
   `ZoneBoundsConfig.padding()` (`.standard` resolver).** Coincide only with no override.
   Matrix env is clean so fine, but a dev machine with a custom zone padding in standard
   defaults could diverge. Latent coupling, low risk.

## UNVERIFIED

- Render-model chrome `.frame` mid-drag follow (CanvasNSView.swift:1049-1064) is exercised for
  callback (C1) + origin (C2) but the chrome frame itself is NOT asserted in Setup C (only
  Setup B's ZoneLayer chrome frame is, assertion 11).
- `persistMovedZone`/`persistCreatedGroupZone` ordering end-to-end: both flush synchronously;
  not exercised by an integration test (move's AppDelegate persist seam is unexercised — the
  check wires its own inline persistence for create only).
- `WorkspaceRuntime.install` actually skipping `projectId==nil` group zones (the Setup C
  premise) — asserted by the builder's reasoning, not re-verified in this pass.

## NEEDS-HUMAN (Dylan must eyeball — `[morning]` visual/feel gate; the check can't see these)

1. Create-marquee feel: live rect tracks cursor, click-transparent, no flicker — AND confirm
   the landing jump from risk 2 (marquee → 480×320 empty-min) reads as acceptable.
2. Move feel: zone + tiles move as one rigid group; tiles don't lag/detach; header under cursor.
3. Render-model move re-render (risk 1): move a group zone, pan/zoom, confirm no snap-back.
4. Z-paint/layering during drag + on settle; marquee ghost paints topmost + tears down cleanly.
5. Cursor rects: pointingHand over header, arrow/crosshair over empty canvas; restores cleanly.
6. Threshold feel: 24px feels right; small accidental drag deselects (no tiny zone).
7. Adaptive snap-back after move: border hugs tiles+padding without a visible pop; header above
   the tile union.
8. Overlap (v1 allows it): zone-over-zone just overlaps, no reflow; reads as intentional.
9. Pan/zoom: create + move feel anchored under the cursor at zoom 0.5 / 2.0 and a non-origin pan.

## Disposition

Checks green, real mouse path proven, scope clean, configurable-first wired. Leave
**Status: staged-for-morning** (do NOT mark Done) until Dylan clears the eyeball list —
especially risk 1 (render-model live desync) and risk 2 (empty-zone land jump).
