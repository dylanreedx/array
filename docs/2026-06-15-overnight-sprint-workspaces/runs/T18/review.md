# T18 Review — Per-zone nav keybind + zone-jump in the leader

**Reviewer:** Opus 4.8 (adversarial, read-only)
**Branch:** overnight/workspaces-zones (uncommitted)
**Verdict:** PASS WITH RISKS

## Summary
The implementation matches the spec closely. The app check `--leader-zone-jump-check`
drives the REAL leader input path (synth `.flagsChanged`/`.keyDown` →
`handleFlagsChanged`/`handleHotkey` → `handleLeaderKey`) and asserts the observable
viewport, not a direct jump-fn call. I re-ran every check and empirically proved RED.
One real (low-severity) correctness defect found in the `resolve` validator
(operator precedence). Two design calls need a human sign-off.

## Bypass audit (#1 gate) — PASS
The check is NOT a bypass. Evidence:
- Assertion 3 synthesizes `keyDown("1", 18, [.option])` through `app.handleHotkey` →
  `handleLeaderKey` and asserts `vpEqual(canvas.viewport, expectedA)` where
  `expectedA = CanvasEngine.fit(worldRect:(0,0,300,200), viewportSize:800×600)`.
  It never calls `fitZoneToViewport`/`setViewport` to produce the result.
- I REMOVED the zone-jump branch from `handleLeaderKey` (ContinuumApp.swift:2106-2113),
  rebuilt, and re-ran: the check went RED exactly as the spec predicts —
  `FAIL: assertion 3: '1' must fit-jump to zA; got (0.0,0.0,1.0) want (-16.666…,-25.0,2.4)`.
  Restored the file (diff back to +245). This proves the asserted viewport comes from
  the real handler, not the check.
- Hand-derived expectedA independently: zoom = min((800-80)/300,(600-80)/200) = min(2.4,2.6)
  = 2.4; origin = (150 - 400/2.4, 100 - 300/2.4) = (-16.67, -25.0). Matches. Initial
  viewport (0,0,1) differs → the move is non-trivial, not a coincidental equality.
- Core table §0 is the real path for the pure `zoneJumpLabels` fn; I re-derived §0.2 and
  §0.3 by hand (see "Right reason" below) — values are intentional, not coincidental.

## Right reason — PASS
- §0.2 (`configuredKeys=["q",nil,nil]`): takenKeys={"q"}, availableOrdinals=["1".."9"],
  z1→"q", z2→"1", z3→"2". Matches the assertion. The auto pool is NOT offset by the
  configured "q" (it's a letter, not in the digit pool) — assertion text is correct.
- §0.3 (`configuredKeys=["1",nil,nil]`, ordinal=["1","2","3"]): takenKeys={"1"},
  availableOrdinals=["2","3"], z1→"1", z2→"2", z3→"3", no dupes. The auto-skip is real.
- Verified would-go-RED: app assertion 3 confirmed RED above; Core §0.1 would have been
  the builder's RED point (the builder reported the app check went RED on assertion 2
  with empty assignments before the canvas resolver was wired).

## Scope — PASS
- 6 files, 426 insertions / 1 deletion. The single deletion is the `NavKeymap.init`
  signature line, replaced to append `leaderZoneOrdinalKeys` with a default — surgical;
  all call sites keep compiling (build is green).
- Do-NOT-touch list respected: `leaderJumpAssignments`, `leaderJumpTarget(forLabel:)`,
  `centerOnTile`, `drawTileLabels` are unchanged (grep confirms no +/- on those fns).
  The zone branch is ADDED before the unchanged tile branch (ContinuumApp.swift:2106).
- Guard ordering correct per spec step 5: Esc (2096) → arrow (2101) → zone (2108) →
  tile (2114). Esc and arrow guards precede the zone branch.
- No co-author footer in code; work uncommitted (correct for review).
- Configurable bits wired: default "123456789", `leaderZoneOrdinalKeysDefaultsKey`,
  `resolve`/`persist`, `leaderZoneOrdinalAlphabet` accessor, SettingsSchema `.text`
  field (key = `NavKeymap.leaderZoneOrdinalKeysDefaultsKey`, matches what `resolve`
  reads). Alphabet not hardcoded in canvas/app — pushed from `navKeymap` in
  `activateLeader()` (2074) and read via the `leaderZoneOrdinalAlphabet` stored prop.

## Matrix — PASS
- `swift run ContinuumRevivedCoreChecks` → "ContinuumRevivedCoreChecks passed" (7 T18
  assertions included).
- `--leader-zone-jump-check` → passed (manifest written).
- `--leader-jump-check` standalone → passed (tile path NOT regressed).
- `./scripts/run-matrix.sh --fast` → "Fast matrix passed." `git diff --check` clean.

## Defects (real, but low-severity)
1. **`resolve` validator operator-precedence bug** —
   `Sources/ContinuumRevivedCore/NavKeymap.swift:278`:
   `cleaned.allSatisfy({ $0.isASCII && $0.isLetter || $0.isNumber })`
   `&&` binds tighter than `||`, so this parses as
   `($0.isASCII && $0.isLetter) || $0.isNumber`. A non-ASCII numeral (`.isNumber==true`,
   `.isASCII==false` — e.g. `²`, `½`, Arabic-Indic `٢`, Roman `Ⅻ`) is ACCEPTED, contrary
   to the spec's "all ASCII alphanumeric" (spec line 74). Verified empirically: all four
   chars pass the current expression but fail the intended `$0.isASCII && ($0.isLetter || $0.isNumber)`.
   Severity: LOW — a normal `charactersIgnoringModifiers` keypress never produces these,
   so a leader jump can't be keyed to them; this is validation hygiene, not a functional
   break, and the Core §0.7 invalid-value tests (dup "11", empty "") don't exercise it.
   Fix: add parens → `$0.isASCII && ($0.isLetter || $0.isNumber)` (mirror the
   `leaderLabelKeys` block's single-conjunction shape at :270).

## Risks (named, not blockers)
- **Assertion 7 hardcodes tile7b→label "s"** (ContinuumApp.swift around the
  `keyDown("s", 1)`): the check asserts labels are non-empty but does not assert
  tile7b specifically receives "s" before pressing it. It passes today (deterministic
  labeler), but if `TileArrangement.jumpLabels` ordering changes, this asserts on the
  wrong tile. Pre-asserting `tileLabels7.contains((tile7b,"s"))` (as assertion 5 does
  for its collision) would harden it.
- **Release-⌥-no-snap-back not explicitly asserted.** The spec (Disarm semantics) asked
  to "assert if it's cheap." The zone branch calls `disarmLeader()` BEFORE `setViewport`,
  and `setViewport` is a persistent state change, so a subsequent ⌥-release is a no-op
  on an already-closed modal — snap-back is structurally impossible. Not asserted, but
  low risk.
- **`charactersIgnoringModifiers` carries the key, not keyCode.** The zone resolver keys
  off `event.charactersIgnoringModifiers` (lowercased), not keyCode. The synthesized
  events set both consistently, and this matches the existing tile branch — but a real
  non-US keyboard layout where the digit row produces non-ASCII glyphs would not match
  the digit ordinals. Pre-existing pattern shared with tile-jump; flagging for awareness.

## Needs human (design calls the builder followed per spec)
- **Jump target = zone-fit, NOT last-active-tile** (spec gotcha, NEEDS-HUMAN). The model
  has no per-zone lastActiveTile, so T18 fits the whole zone via `fitZoneToViewport`.
  If Dylan wants the jump to land on a zone's last-focused tile, that needs a new
  per-zone `lastActiveTileId` (a T01 follow-on). Confirm zone-fit is the desired target.
- **Precedence design call: configured zone navKey beats a colliding tile label; auto
  ordinals skip live tile labels.** With disjoint defaults (zones=digits, tiles=letters)
  collisions never occur in practice; the rule only bites under user rebinding. If Dylan
  prefers tile-labels-win, the branch order in `handleLeaderKey` and assertion 5 must flip.
- **Zone-jump HUD badge not drawn.** Spec marks the visual badge as out-of-scope /
  morning polish; the check covers assignment + jump behavior only. The leader HUD does
  not visually show which key jumps which zone — a human visual gate is needed before
  this feels complete to a user.

## Unverified
- I did not visually run the app; the leader HUD's zone-key rendering (or absence) was
  not eyeballed — only the programmatic assignment/jump path.
- The SettingsSchema panel was not opened in the live app; I confirmed the schema entry
  compiles and `--settings-panel-check` (fast matrix) passes, but did not see the new
  "Zone Jump Ordinal Keys" field rendered.
