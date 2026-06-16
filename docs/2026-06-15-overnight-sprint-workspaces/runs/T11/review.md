# T11 Review — Adaptive Zone Bounds (REVIEWER, adversarial)

**Verdict: PASS WITH RISKS** — committable. The task as literally scoped is correct and verified end-to-end; the open item is a coverage gap created by T05 having merged ahead of T11 (the spec's own NEEDS-HUMAN gotcha), not a defect in the delivered code.

Branch: `overnight/workspaces-zones` (uncommitted working tree). Reviewed read-only.

## 1. BYPASS AUDIT (#1 gate) — PASS, proven RED

The Part B check drives the REAL production path and asserts OBSERVABLE drawn state.

- Re-ran both checks myself: Part A (`swift run ContinuumRevivedCoreChecks`) → "ContinuumRevivedCoreChecks passed". Part B (`--zone-adaptive-bounds-check` with mktemp roots) → "ContinuumRevivedZoneAdaptiveBoundsChecks passed", exit 0.
- **RED proof (the load-bearing one):** I removed the single line `layoutZoneChromeViews()` from `updateTile(_:)` (CanvasNSView.swift:254), rebuilt, and re-ran. Result:
  `FAIL: assertion 3: bounds grow after tile 2 moved right: expected ...width: 748.0... got ...width: 448.0...` (exit 1).
  Width stayed at the initial 448 instead of growing to 748 — exactly the spec's predicted RED. Restored the line, rebuilt, green again. Diff stat back to 475/-3.
- The driven path is genuine: synthesized `NSEvent.mouseEvent(.leftMouseDown/.leftMouseDragged/.leftMouseUp)` → `view2.mouseDown/mouseDragged/mouseUp` → `TileNSView.mouseDragged` (TileNSView.swift:275) → `canvas.updateTile(next)` (line 291 for move, line 309 for resize) → `updateTile` → `layoutZoneChromeViews()`. NOT a direct `updateTile`/`zoneBounds` call. The QA reader `qaZoneDrawnWorldBounds` reads the chrome NSView's actual `frame` and inverts the transform — it observes the drawn view, not an internal number.
- Would it pass if stubbed? No. Stubbing the `updateTile→layout` hook fails assertion 3 (proven). Stubbing `zoneBounds` math fails Part A (it compile-failed in the documented RED phase, and the table uses exact `==`).

## 2. RIGHT REASON — PASS (hand-derived)

Re-derived assertion 4 independently: tile1 starts zone-local (40,52,180,170); window dy=+40 → `delta.height = -dy = -40` → `worldDy = -40` → tile1.y = 12. Tile2 (post-assertion-3) at (560,52,180,170). Union = (40,12,700,210). Adaptive: x=40-24=16; y=12-24-34=**-46**; w=700+48=748; h=210+48+34=**292**. Check asserts `(16,-46,748,292)` ✓. Header bottom = -46+34 = -12 = unionMinY(12) − padding(24) ✓. Matches intent, not coincidence. Part A group 1 also re-derived: (76,42,248,232) ✓.

## 3. SCOPE — PASS (within the legacy path), with one gap noted in §6

- `ZoneBoundsConfig.swift` matches the spec byte-for-byte (keys, defaults, guard shape).
- `CanvasEngine.zoneBounds` matches the spec math + re-guards (`max(0,…)`/`max(1,…)`). Empty branch returns (0,0,minW,minH); caller offsets to stored origin (CanvasNSView.swift:149-153). No double-offset, header not double-added (assertion 7 asserts exactly 320).
- Configurable bits wired: default + 3 SettingsSchema `.text` fields in `general` (SettingsSchema.swift:72-74) + guard table (Part A group 7) is the conflict-guard. Verified.
- **Do-NOT-touch respected:** `CanvasEngine.hydrationTier` still uses stored `zoneWorldFrame` (CanvasEngine.swift:142), not `zoneBounds`. `zoneWorldFrame` unchanged. Transforms unchanged. `ZoneChromeNSView` internals: only addition is a `static let headerHeight = 34` (line 3058) alongside the untouched instance `private let headerHeight: CGFloat = 34` (line 3061) that still drives `headerRect` — both 34, consistent.
- Only chrome frame-assignment site in the legacy `zoneChromeViews` path is the adaptive one (line 153); no missed stored-frame site there.
- No co-author footer (nothing committed; build.md / review.md clean).
- Regression fallout handled correctly: `--multi-zone-render-check` updated its `betaSnap.frame` assertion (empty zone, 640×420 → adaptive 480×320 at origin) and kept it EXACT, not weakened (line 1351). `--single-zone-compat-check` does not assert any chrome frame (only tile frames + hit-test), so correctly left untouched. The T05 ZoneLayer self-check asserts only tile frames/hit-test, not chrome frames — also correctly untouched.

## 4. MATRIX — PASS

`./scripts/run-matrix.sh --fast` → "Fast matrix passed." 67 "passed" lines; `--zone-adaptive-bounds-check` is registered (run-matrix.sh:88) and runs green inside the matrix. `--multi-zone-render-check`, `--single-zone-compat-check`, `--zone-adaptive-bounds-check` all green when run individually.

## 5. EDGE-CASE PROBES — PASS

- Header-above-union: asserted by geometry (header bottom == union top − padding) in both Part A group 5 and Part B assertion 4. ✓
- Empty branch: exact 320 not 354, anchored at stored origin (200,100), assertion 7. ✓
- Symmetry: resize +60 then −60 returns to the pre-resize bounds via `expectFrame(postShrinkBounds, preResizeBounds)` (assertion 6) — proves `zoneBounds` is a pure function of current members. ✓ (Builder's documented snap-interference fix — injecting a no-snap UserDefaults suite — is legitimate; it isolates the geometry under test from the drag-magnetize feature, matching `runFocusBorderSelfCheck`'s pattern.)
- Config guard: negative/NaN padding → default, 0 padding accepted, ≤0 min dim → default (Part A group 7). ✓
- No reflow: overlapping zones each keep their own union+padding (assertion 8). ✓

## 6. RISKS / NEEDS-HUMAN

The central item: **T05 has merged ahead of T11, introducing a second, parallel zone-chrome layout path that T11 did not adaptive-ize.** The spec was written assuming T05 had NOT landed and explicitly flagged this as a human decision (T11 spec lines 318-336: "the executor must re-point the three named touch-points onto T05's actual API… Decision needed from a human if T05's shipped shape diverges").

- T05 added `final class ZoneLayer` (CanvasNSView.swift:963) with its own `chrome: ZoneChromeNSView` and layout sites: `_installLayer` (line 1075, creates the chrome but never sets its frame) and `setZonePlacement` (line 1050-1051, sets `chrome.frame` from the **stored `zoneWorldFrame`**, NOT adaptive bounds).
- T11 wired adaptive bounds ONLY into the legacy `activeZone` path (`layoutZoneChromeViews()`). Any zone rendered through the `ZoneLayer` path will draw at the stored rect, contradicting the T11 goal.
- **Why this is a RISK and not CHANGES REQUESTED today:** the `ZoneLayer` mutation API (`setZones`/`upsertZoneLayer`/`setZonePlacement`) has **zero production callers** — its only callers are CanvasNSView's own self-checks (lines 1449, 1505). So the path is dormant; the only live zone chrome today is the legacy path T11 correctly handled. All T11 acceptance criteria as literally written pass.
- **Why a human must look:** when a later task (T19, or workspace-zone wiring) routes real zones through `ZoneLayer`, their chrome will silently render at the stored frame. No check guards the `ZoneLayer` chrome frame (the T05 self-check asserts only tile frames), so a stub of adaptive bounds in that path would pass the matrix — i.e. the gap is invisible to CI. This is precisely the spec's hoisted decision.

Additional risks:
- **R1 (unverified at non-unit zoom):** Both Part B and the spec deliberately use `viewport zoom=1, origin 0`, where `tileScreenFrame` and the `qaZoneDrawnWorldBounds` inverse are identity. So assertion 1 (world bounds) and assertion 2 (screen frame) test essentially the same number, and the inverse-transform correctness of `qaZoneDrawnWorldBounds` at non-unit zoom/non-zero viewport is not exercised by any T11 assertion. The production `tileScreenFrame` IS driven; the QA reader's `/zoom + vp.x` inverse is not independently checked. Low impact (it's a test-only reader), but flagged.
- **R2 (intentional test divergence from spec numbers):** builder used tile height 170 (not the spec's 120) because the spec's derived expected values implied h=150, which is below the `.note` minimum (160) and would clamp the shrink. Documented in build.md and inline. The structural assertions are preserved; only the literal magnitudes differ. Reasonable, but means the Part B expected values were re-derived by the builder rather than copied from the spec — re-derived them myself, they are internally correct.
- **R3 (multi-zone empty fallback today):** in the legacy path, `zoneMemberWorldFrames` returns `[]` for every non-active zone (CanvasNSView.swift:64-67), so a multi-zone canvas would draw all inactive zones at the empty min-size regardless of stored size/members. Spec explicitly defers the group-zone member source to T02/T05; consistent with scope, but worth a human's awareness.

## needsHuman
- Decide whether T11's adaptive bounds must also drive the T05 `ZoneLayer` chrome path (`_installLayer` line 1075 + `setZonePlacement` line 1050) before any task routes real zones through `ZoneLayer`; today that path is dormant (no production caller) and renders at the stored `zoneWorldFrame`. This is the spec's own hoisted T05-divergence decision.
- Morning eyeball (spec line 350): header visual fit — does the title still center in the band now that the band sits above the tiles? Geometry checked, pixels not.
