# T18 — Per-zone nav keybind + zone-jump in the leader

One-line: a zone's `navKey` (from T01) is its jump key in the hold-`⌥` leader — press it and the
viewport pans/fits to that zone; zones without a configured key get an auto ordinal (1–9), and the
precedence against tile-jump labels in the same leader session is defined and checked.

Status: todo
Tag: overnight
Depends on: T01 (`ZonePlacement.navKey`) · Blocks: —

## Goal
Make each zone individually keybindable from the leader. While `⌥` is held, pressing a zone's
nav-key jumps (pans/fits the viewport) to that zone. This is the keyboard-fast complement to the
sidebar click-to-jump (T16) and the ⌘K zone rows (T17): the same `ZonePlacement.navKey` the sidebar
edits drives a leader jump here. A zone with `navKey == nil` is reachable by an auto-assigned ordinal
(`1`–`9` in `navZoneRenderModels` order), exactly mirroring how visible tiles get auto labels in the
jump HUD today.

## Exact scope — files & symbols
- **`Sources/ContinuumRevivedCore/NavKeymap.swift`** — add a pure, deterministic zone-nav-label
  assignment + a UserDefaults-backed auto-ordinal alphabet:
  - `public var leaderZoneOrdinalKeys: String` (default `"123456789"`), its `…DefaultsKey`, its
    `resolve`/`persist` wiring (mirror `leaderLabelKeys` exactly — lowercase, ASCII, no dupes,
    non-empty validation + `warn`), and a `leaderZoneOrdinalAlphabet: [String]` computed accessor.
  - `public static func zoneJumpLabels(zoneIds:configuredKeys:ordinalAlphabet:tileLabels:) -> [(zoneId: UUID, key: String)]`
    — the single source of truth for which key jumps to which zone. Pure. (Exact signature below.)
- **`Sources/ContinuumRevived/Canvas/CanvasNSView.swift`** — add the canvas-side resolver that pairs
  `navZoneRenderModels` (in order) with `zoneJumpLabels`, reading each zone's `placement.navKey`:
  - `func leaderZoneJumpAssignments() -> [(zoneId: UUID, key: String)]`
  - `func leaderZoneJumpTarget(forKey key: String) -> UUID?` (returns the zone for a pressed key, or
    nil). Both read `leaderZoneOrdinalAlphabet` (pushed in alongside `leaderLabelAlphabet`) and the
    *current* tile-jump labels via the existing `leaderJumpAssignments()` so the conflict-guard is
    computed against the live session.
  - Add `var leaderZoneOrdinalAlphabet: [String] = NavKeymap.default.leaderZoneOrdinalAlphabet`
    (mirror the existing `leaderLabelAlphabet` stored prop at line ~80).
- **`Sources/ContinuumRevived/App/ContinuumApp.swift`**
  - In `activateLeader()` (~:1976), push `canvasView?.leaderZoneOrdinalAlphabet =
    navKeymap.leaderZoneOrdinalAlphabet` right beside the existing
    `canvasView?.leaderLabelAlphabet = navKeymap.leaderLabelAlphabet` line.
  - In `handleLeaderKey(_:)` (~:2000), add the zone-jump branch (placement + precedence below).
  - Add a `static func runLeaderZoneJumpSelfCheck() throws -> URL` mirroring
    `runLeaderJumpSelfCheck()` (~:5950).
  - Register `--leader-zone-jump-check` in the `CommandLine.arguments` dispatch (mirror the
    `--leader-jump-check` block at ~:218).
- **`Sources/ContinuumRevivedCore/SettingsSchema.swift`** — append one `.text` field for
  `leaderZoneOrdinalKeys` in the existing `navigation` section (mirror the `Jump Label Keys` field).
- **`scripts/run-matrix.sh`** — register `--leader-zone-jump-check` (after `--leader-jump-check`,
  ~:81).
- **`Sources/ContinuumRevivedCoreChecks/main.swift`** — add a Core table for `zoneJumpLabels`
  precedence/auto-ordinal/override (pure assignment table; see check §0).

### Do NOT touch / out of scope
- **The tile-jump leader path** — `leaderJumpAssignments()`, `leaderJumpTarget(forLabel:)`,
  `centerOnTile`, `drawTileLabels`, the arrow/snap branch, Esc. Reuse, do not edit. The existing
  `--leader-jump-check` must stay green untouched.
- **⌘K zone rows** = T17. **Sidebar navKey editor UI** = T16 (this task only *reads* the persisted
  `navKey`; it does not build the editor). **Drawing zone badges in the leader HUD** is out of scope
  for the check (the assignment + jump behavior is the checkable surface; the visual badge is a
  morning polish item — note it, don't build the draw call here unless trivial and behind the HUD's
  existing `drawTileLabels` peer).
- Do NOT add a per-zone `lastActiveTile` to the model (see gotchas — NEEDS-HUMAN).

## Data / API changes
On `NavKeymap` (additive, mirrors `leaderLabelKeys`):
```swift
public var leaderZoneOrdinalKeys: String          // default "123456789"
public static let leaderZoneOrdinalKeysDefaultsKey = "continuum.keymap.leaderZoneOrdinalKeys"
public var leaderZoneOrdinalAlphabet: [String] { leaderZoneOrdinalKeys.map(String.init) }
```
- `init(... leaderZoneOrdinalKeys: String = "123456789" ...)` — append the param with its default so
  every existing call site (only `NavKeymap.default` constructs it positionally) keeps compiling.
- `default`: pass `leaderZoneOrdinalKeys: "123456789"`.
- `resolve(defaults:warn:)`: read `string("leaderZoneOrdinalKeys")`, accept iff non-empty, all ASCII
  alphanumeric, no duplicate chars; else `warn` + keep default (mirror the `leaderLabelKeys` block at
  :255–262 — but allow digits, not just letters).
- `persist(to:)`: write `leaderZoneOrdinalKeys` to its key (mirror :288).

Pure assignment fn (the single source of truth):
```swift
/// Deterministic key→zone assignment for the leader zone-jump.
/// - configuredKeys: each zone's explicit navKey in render order (nil = auto).
/// - ordinalAlphabet: the auto-ordinal pool (e.g. ["1".."9"]), consumed in order.
/// - tileLabels: the tile-jump labels live THIS session (the conflict set).
/// Precedence (defined here, asserted by the Core table + the app check):
///   1. A zone's CONFIGURED navKey always wins for THAT zone, even if a tile
///      also carries that label this session — the tile loses the key while the
///      zone owns it (zone navKeys are intentional/explicit; tile labels are
///      auto/ephemeral). The app check asserts the zone wins.
///   2. AUTO ordinals skip any key already taken by (a) a configured zone navKey
///      or (b) a live tile label, so an auto-assigned zone never silently
///      shadows a tile jump. With the disjoint defaults (zones=digits,
///      tiles=letters) no skip happens; the skip only matters under rebinding.
///   3. A zone whose configured navKey is empty/blank is treated as auto.
/// Returns assignments in the input zone order; zones that get no key are omitted.
public static func zoneJumpLabels(
    zoneIds: [UUID],
    configuredKeys: [String?],          // parallel to zoneIds
    ordinalAlphabet: [String],
    tileLabels: Set<String>
) -> [(zoneId: UUID, key: String)]
```
(Keys are compared case-insensitively via the existing `normalizedNavKey` lowercasing convention.)

No change to `ZonePlacement` here — `navKey` already exists from T01.

## The check, written FIRST (spec-as-test)

### §0 — Core assignment table (`ContinuumRevivedCoreChecks/main.swift`)
Pure round-trip / derivation table for `zoneJumpLabels` (this is the *real path* for the pure fn).
Three zone ids `z1,z2,z3` (fixed UUIDs). Assert, each value hand-derivable:
1. **All auto, no tile collision:** `configuredKeys=[nil,nil,nil]`, `ordinal=["1".."9"]`,
   `tileLabels=[]` → `[(z1,"1"),(z2,"2"),(z3,"3")]` (order preserved, ordinals consumed in order).
2. **Configured override:** `configuredKeys=["q",nil,nil]` → `z1→"q"`, then auto continues `z2→"1"`,
   `z3→"2"` (the auto pool is NOT offset by the configured key; it starts at "1" for the first auto
   zone). Assert `z1`'s key is exactly `"q"`.
3. **Auto skips a configured key:** `configuredKeys=["1",nil,nil]`, `ordinal=["1","2","3"]` →
   `z1→"1"` (configured), `z2→"2"` (auto skips the taken "1"), `z3→"3"`. Assert no two zones share a
   key.
4. **Auto skips a tile label:** `configuredKeys=[nil,nil,nil]`, `ordinal=["a","b","c"]` (rebound to
   letters to force a clash), `tileLabels={"a"}` → `z1→"b"`, `z2→"c"`, `z3` omitted (pool exhausted)
   — proves auto never lands on a live tile label.
5. **Configured beats a tile label (precedence rule 1):** `configuredKeys=["a",nil,nil]`,
   `tileLabels={"a"}` → `z1→"a"` is STILL assigned (the zone owns "a"; the app check confirms the
   pressed "a" jumps the zone, not the tile). Assert `z1→"a"` present.
6. **Blank/empty navKey is auto:** `configuredKeys=["",nil,nil]` behaves identically to `[nil,nil,nil]`.
7. **`NavKeymap` round-trip:** `persist`→`resolve` reconstructs `leaderZoneOrdinalKeys`; an invalid
   value (`"11"` dup, or `""`) is rejected with the default retained.

### §1 — App real-path check `--leader-zone-jump-check` (`runLeaderZoneJumpSelfCheck`)
Registered in `scripts/run-matrix.sh` (after `--leader-jump-check`) AND in the
`CommandLine.arguments` dispatch in `ContinuumApp.swift` (mirror :218). It drives the **REAL** leader
path — synth `.flagsChanged` (`⌥`, keyCode 58) → `handleFlagsChanged`; synth `.keyDown` →
`handleHotkey` → `handleLeaderKey` — and asserts the **observable** viewport/scope, never calling
`jumpToZone…`/`fitZoneToViewport` directly.

**Setup (mirror `runLeaderJumpSelfCheck` :5974–5993).** Build a `CanvasNSView` with **three zones**
via `zoneRenderModels:` (the multi-zone constructor path — see `--multi-zone-render-check` setup at
CanvasNSView ~:1100 for the exact `ZoneRenderModel`/`ZonePlacement` shape). Give them disjoint world
origins/sizes so each has a distinct fit viewport:
- `zA` placement origin (0,0) size (300×200), `navKey: nil`  → auto ordinal "1"
- `zB` placement origin (1000,0) size (300×200), `navKey: nil` → auto ordinal "2"
- `zC` placement origin (0,1000) size (300×200), `navKey: "q"` (configured)
Window 800×600, zoom 1, viewport (0,0,1). Wire `app.canvasView = canvas`, `canvas.focusBroker =
app.focusBroker`, `app.leaderDwell = 0` exactly as the tile check does. Push the alphabets the way
`activateLeader` will (the check opens the leader through the real path, so `activateLeader` pushes
them — do NOT set them by hand; that would bypass the wiring under test).

Pre-derive the expected target viewports with the SAME production helper the jump uses
(`CanvasEngine.fit(worldRect:viewportSize:)` on `CanvasEngine.zoneWorldFrame(placement)`), e.g.
`expectedB = CanvasEngine.fit(worldRect: CGRect(x:1000,y:0,width:300,height:200), viewportSize: 800×600)`.
Use the `vpEqual` tolerance helper from the tile check.

**Assertions (every one hand-derivable):**
1. **Leader opens via the real path:** after `handleFlagsChanged([.option], 58)`,
   `focusBroker.activeSurface == .modal(.leader)` and the HUD overlay is installed
   (`navModeOverlayQASnapshot().isInstalled`). (Proves the synthesized open, not a hand-set flag.)
2. **Auto-ordinal assignment exists:** `canvas.leaderZoneJumpAssignments()` contains `(zA,"1")` and
   `(zB,"2")` and `(zC,"q")`. (Asserts the assignment the keypress will resolve against — derived
   from §0 rules 1–3, with no tile labels yet.)
3. **Auto-ordinal jump pans/fits the zone:** synth `keyDown("1", keyCode 18, mods [.option])` →
   `handleHotkey` → `handleLeaderKey`. Assert `vpEqual(canvas.viewport, expectedA)` where
   `expectedA = fit(zoneWorldFrame(zA))`. Assert the HUD dismissed (`!isInstalled`) and the leader
   modal closed/restored to the prior scope (matching the tile-jump dismiss-after-jump behavior —
   confirm against the chosen disarm semantics in step 4).
4. **Configured navKey overrides / is honored:** re-open the leader (`handleFlagsChanged([.option],
   58)`), synth `keyDown("q", keyCode 12, mods [.option])`. Assert `vpEqual(canvas.viewport,
   expectedC)` — the *configured* key "q" jumped to `zC`, NOT an auto ordinal. (Proves `navKey` is
   read, not ignored in favor of an ordinal.)
5. **Precedence over a colliding tile label (the conflict-guard):** construct the canvas so a live
   tile would receive label "q" too (focus nothing; add a visible tile whose deterministic label is
   "q" — OR simpler: set the zone navKey to a key the tile labeler will hand out, e.g. make one zone
   `navKey: "a"` and place one visible tile so `leaderJumpAssignments()` yields label "a"). Re-open
   the leader; synth `keyDown` for that key. Assert the **ZONE** is jumped (viewport ==
   `fit(zoneWorldFrame(thatZone))`), **not** the tile centered (`!= centerOnTile`'s viewport). This
   is precedence rule 1 observed through the real handler. (If wiring a colliding-label tile is
   fiddly, assert the equivalent: `leaderZoneJumpTarget(forKey:"a")` returns the zone AND a real
   keypress of "a" moves the viewport to the zone-fit, proving `handleLeaderKey` consults the zone
   resolver before/over the tile resolver per the defined precedence.)
6. **Unmatched key is swallowed, no move:** with the leader open, synth a key that maps to neither a
   zone nor a tile (e.g. `keyDown("Z", keyCode 6, mods [.option])` when no zone/tile owns it). Assert
   `handleHotkey == true` (swallowed), `activeSurface == .modal(.leader)` (still open),
   `vpEqual(canvas.viewport, <unchanged>)`. (Mirrors the tile check's "unmatched key" assertion so
   the new branch doesn't leak or false-trigger.)
7. **Tile-jump still works (no regression of the reused path):** with at least one labeled tile
   present and the leader open, synth that tile's label key and assert it centers the tile
   (`focusBroker.activeSurface == .tile(thatTileId)` + `vpEqual` to `centerOnTile`'s expected
   viewport). (Proves the zone branch was inserted with correct precedence and didn't break the
   tile path; complements the standalone `--leader-jump-check`.)
8. **Esc exits without jumping:** open the leader, synth Esc (keyCode 53) → assert leader closes,
   viewport unchanged, prior scope restored. (Mirror the tile check's Esc assertion to confirm the
   zone branch is ordered after the Esc guard.)

Write the artifact manifest (mirror :6074) with `check: "leader-zone-jump"`, the `path` string
naming the real handler chain, the auto-ordinal map, and the configured-override target.

**RED expectation:** before implementation, assertion 2 fails to compile (no
`leaderZoneJumpAssignments`) → add minimal stubs returning `[]` → assertion 2 fails on the *value*
(empty), then assertions 3–5 fail on the unchanged viewport. Implement to GREEN.

## Implementation steps
1. **(RED)** Add the Core table §0 + the `zoneJumpLabels` signature returning `[]`; run
   `swift run ContinuumRevivedCoreChecks` → fails on assertion 1. Add `--leader-zone-jump-check`
   (registered both places) + `runLeaderZoneJumpSelfCheck` with all 8 assertions, plus the
   `leaderZoneJumpAssignments`/`leaderZoneJumpTarget` stubs (return `[]`/`nil`) so it compiles; run
   it → RED on assertion 2/3.
2. Implement `NavKeymap.leaderZoneOrdinalKeys` (field + default + `resolve` + `persist` + alphabet
   accessor) and the pure `zoneJumpLabels` (precedence rules 1–3). Core table → GREEN.
3. Add `leaderZoneOrdinalAlphabet` stored prop on `CanvasNSView`; implement
   `leaderZoneJumpAssignments()` (zip `navZoneRenderModels` order → `zoneJumpLabels` with
   `configuredKeys = models.map { $0.placement.navKey }`, `ordinalAlphabet = leaderZoneOrdinalAlphabet`,
   `tileLabels = Set(leaderJumpAssignments().map(\.label))`) and `leaderZoneJumpTarget(forKey:)`.
4. Push `leaderZoneOrdinalAlphabet` in `activateLeader()` beside the existing alphabet push.
5. **(GREEN boundary)** In `handleLeaderKey`, after the Esc guard and the arrow-direction guard, and
   **before** the existing tile-label branch, resolve the zone:
   ```swift
   let key = (event.charactersIgnoringModifiers ?? "").lowercased()
   if !key.isEmpty, let zoneId = canvasView?.leaderZoneJumpTarget(forKey: key) {
       disarmLeader()
       if let vp = canvasView?.fitZoneToViewport(zoneId: zoneId) { canvasView?.setViewport(vp) }
       navSelectedZoneId = zoneId
       return true
   }
   ```
   Placing zone-resolution before tile-resolution is what enforces precedence rule 1 (a configured
   zone navKey wins a colliding tile label); the auto-skip in `zoneJumpLabels` guarantees an *auto*
   zone key never equals a live tile label, so the common path is unambiguous.
6. Append the `leaderZoneOrdinalKeys` `.text` field to `SettingsSchema` navigation section.
7. `swift build` → run `--leader-zone-jump-check` GREEN → confirm `--leader-jump-check` still GREEN
   → `./scripts/run-matrix.sh --fast`.

## Acceptance criteria
- [ ] `--leader-zone-jump-check` drives the leader through synth `.flagsChanged`/`.keyDown` →
      `handleFlagsChanged`/`handleHotkey`/`handleLeaderKey` and asserts the observable viewport
      (zone-fit) + scope; no direct call to `fitZoneToViewport`/`jumpToZone…` to produce the result.
- [ ] All 8 app assertions + 7 Core-table assertions pass; each expected value is hand-derivable.
- [ ] Auto-ordinal assignment (navKey == nil → "1".."9") and configured-navKey override both proven.
- [ ] Precedence between zone navKeys and tile-jump labels is defined and asserted (config wins;
      auto skips live tile labels).
- [ ] `leaderZoneOrdinalKeys` is configurable: UserDefaults default `"123456789"` + `resolve`/`persist`
      round-trip + a `SettingsSchema` entry; invalid values rejected with default retained.
- [ ] `--leader-jump-check` unchanged and still green (tile path untouched).
- [ ] Fast matrix green; commit `feat(zones): per-zone leader nav-key jump`.

## Verification commands
```
swift build
swift run ContinuumRevivedCoreChecks
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --leader-zone-jump-check; rm -rf "$P" "$A"
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --leader-jump-check; rm -rf "$P" "$A"
./scripts/run-matrix.sh --fast
```

## Review rubric (adversarial)
- **Bypass audit (critical):** the jump's resulting viewport must come from a synthesized `keyDown`
  flowing through `handleLeaderKey` — NOT from the check calling `fitZoneToViewport`/`setViewport`
  itself. If the check computes the target and calls a jump fn directly, it proves nothing → REWORK.
- **Auto vs configured both exercised:** a check that only tests configured `navKey` (or only auto
  ordinals) is half a check. Assertions 3 (auto) and 4 (configured) must both be present.
- **Precedence actually observed, not just asserted on the resolver:** assertion 5 must press the
  *colliding* key through the real handler and confirm the **zone** moved (viewport == zone-fit), not
  the tile centered. A check that only calls `leaderZoneJumpTarget(forKey:)` and reads its return is
  weaker — it doesn't prove `handleLeaderKey` orders the branches correctly. Prefer the real keypress.
- **No tile-path regression:** assertion 7 (a real tile-label jump still centers the tile) must be
  present, and `--leader-jump-check` must still pass standalone. Confirm the new branch is inserted
  *before* the tile branch but *after* Esc/arrow guards (order matters for both precedence and Esc).
- **Configurable bits:** confirm the default key + `resolve`/`persist` round-trip + Settings entry +
  the invalid-value rejection assertion all exist; the auto-ordinal alphabet is not hardcoded in the
  canvas or app.
- **Determinism:** re-deriving the auto map from `navZoneRenderModels` order must match the check's
  expected `(zA,"1"),(zB,"2")`. If the order is nondeterministic, the assignment is unstable → flag.

## Out of scope / gotchas
- **NEEDS-HUMAN — "jump to its lastActive tile or the zone center":** the brief offers two targets,
  but the model has **no per-zone lastActive-tile**: `WorkspaceDocument` carries only a document-level
  `lastActiveZoneId` (no per-zone tile), and `CanvasState.lastActiveTileId` is a single global. So
  this spec targets the **zone center via `fitZoneToViewport`** (the same target the existing
  `jumpToZoneOrdinal`/`fitNavZone` and the ⌘K zone rows use). If Dylan wants the jump to land on a
  zone's *last-focused tile* instead of fitting the whole zone, that requires a new per-zone
  `lastActiveTileId` field on `ZonePlacement` (a T01 follow-on) and a different target derivation —
  decide before building. Defaulting to zone-fit keeps T18 consistent with every other zone-jump in
  the app and avoids inventing model state.
- **Precedence is a design call, made here:** configured zone navKey beats a colliding tile label
  (rule 1); auto ordinals skip live tile labels (rule 2). With the disjoint defaults (zones = digits
  `1-9`, tiles = letters `asdfghjkl`) collisions never occur in the common case; the rules only bite
  under user rebinding. If Dylan prefers tile-labels-win instead, flip the branch order in step 5 and
  invert assertion 5 — but document it; silent ambiguity is the failure mode.
- **Multi-zone canvas construction:** use the `zoneRenderModels:` constructor (the single-zone
  `activeZone:` path collapses to one zone). Copy the exact `ZoneRenderModel`/`ZonePlacement`
  literals from the `--multi-zone-render-check` setup so the world frames are valid and `navKey` is
  set on the placement.
- **Coordinate trap:** `fitZoneToViewport` fits `CanvasEngine.zoneWorldFrame(placement)` (world units,
  Y-down). Derive the expected viewport with the SAME `CanvasEngine.fit` call, never by hand-rounding
  — copy the helper, mirror the tile check's pre-derivation.
- **Disarm semantics:** match whatever the tile-jump branch does on a successful jump
  (`disarmLeader()` closes the leader modal + hides the HUD). The zone jump does not enter a tile
  scope (`enterScope(.tile…)` is tile-only); it sets `navSelectedZoneId` and moves the viewport.
  Releasing `⌥` after the jump must not snap the viewport back (assert if it's cheap; the tile check's
  step 4 is the template).
- **Stale SourceKit:** new `NavKeymap`/canvas members may squiggle until `swift build`; the build is
  authoritative.
