# COL-21 native slice — keyboard, Reduce Motion, budgets, census

30 October 2026. Bench `.worktrees/mp-gate`, branch `array/col-native-budgets`,
based on `array/collaboration-finish` at `e17d0a52`. Not merged; the integrator
merges it.

Commits:

- `4bdfca62` feat(collaboration): reach every shared control by keyboard
- `d155204b` test(collaboration): witness keyboard parity, Reduce Motion and budgets
- `8eb9231d` test(appearance): census every collaboration view on one surface list
- `7eaa7c20` test(collaboration): witness that the cursor overlay coalesces repaints

Every witness runs inside `--collaboration-native-check` (three new stages),
except the census of colours, which is the existing `--ui-probe-check` now
reading the shared surface list. No leg was added.
`gate-new-witnesses.log` holds the 47 new PASS lines from the gate run.

## 1. Keyboard parity (CollaborationAccessibilityChecks)

Every key is a real `NSEvent` through `NSApp.sendEvent` into the production
window controllers, parked off-screen by the check-focus guard; the app is
never activated. Focus is read back from the window.

- **Shared scene** (production `SharedAreaWindowController`): opens on the
  canvas; Tab in the canvas selects objects, arrows pan, Control-Tab leaves.
  Tab walks canvas → Objects → Workspace → History → Endorse → entry reader →
  draft; Shift-Tab walks it back exactly. Every visible enabled control is in
  the loop (generic check, so a control added later and left out fails).
  By keys alone: choose the agreement (Objects), Endorse it, create a
  discussion (Workspace), type a message, Tab to Post, send it, Follow the
  teammate and Stop following (Workspace).
- **Hub**: opens on the account menu; choosing "Connect another account" by
  keys; Tab walks menu → URL → enrollment code → device → Connect; typing
  reaches the URL field.
- **Capture review**: opens on the tile list; Tab walks tile → mode → content
  → Refresh → Cancel (Share is disabled until something is opted in); mode
  chosen by keys.
- **Handoff**: opens on the recipient; every enabled control is in the loop,
  agreement before prompt; Tab leaves the prompt without inserting a tab;
  timing chosen by keys.

Defects this found and fixed:

1. Tab did nothing on Array's menu and action buttons in these windows: those
   controls pass Tab up the responder chain and nothing handled it. Each
   collaboration root view now moves through an explicit focus order
   (`CollaborationKeyLoop`).
2. Shift-Tab went the wrong way: AppKit's previous-key-view is one
   back-pointer, rewritten by each text view's scroll view. Both directions
   now walk the stored order.
3. Multi-line text views swallowed Tab. Tab/Shift-Tab now move focus;
   Option-Tab still inserts a tab.
4. Focus fell to the window when the focused control disabled itself (Post
   after sending, Endorse after endorsing), so Tab reached nothing. Refreshes
   now move focus on to the next stop.
5. Follow had no keyboard path. The Workspace menu now lists Follow / Stop
   following for each teammate sharing a view.

One environment step: after a menu closes, the check re-keys the parent
window, because with the app active AppKit does that itself and a check never
activates the app. Focus returning to the menu button is still asserted.

## 2. Reduce Motion

Follow now glides the camera over 12 frames, or jumps in one frame when
Reduce Motion is on. The setting is injected (`SharedAreaSceneView.reduceMotion`)
so both are witnessed on any Mac: on — follow and tracked moves land in one
frame; off — follow starts a glide, lands exactly on the teammate's view, with
no private camera writes. The follow witness from COL-18 pins the instant path.
Follow is the only animated shared transition; there are no others to cover.

## 3. Budgets on the production mount (CollaborationBudgetChecks)

`CollaborationWorkCensus` swizzles `NSView.layout` and `didAddSubview:` and
counts by class inside the measured window, so views other workers add are
counted with no registration. Also counted: overlay and content paints, store
writes (`StoreFileWriter`), the five transcript measurement counters, the
executor census and authority operations.

| Traffic | Result |
| --- | --- |
| 200 presence + usage updates in one main-thread turn | apply as 2 frames (the connection keeps the newest), ≤ 1 overlay paint each, last position shown, 0 content paints, 0 layout, 0 views |
| 50 positions assigned to the overlay in one turn | 1 paint, at the last position |
| 50 paced presence updates | ≤ 1 overlay paint each, 0 content paints, 0 layout, 0 views; closed hover paints no card and measures no text while usage advances |
| 20 followed moves | ≤ 1 content paint each, 0 layout, 0 views, 0 private camera writes |
| 20 remote agreement revisions + endorsements | 0 Array views, 90 layout passes (45 + 45: flat), ≤ 6 per event, ≤ 1 content paint each |
| 20 remote moves + posts | 0 views, 20 layout passes (10 + 10), ≤ 1 content paint each |

Every phase: zero transcript measurements, zero canvas saves (no `canvas.json`
write; the source canvas bytes are unchanged), zero executor or model work,
zero usage reports, zero shared operations. Remote document frames write only
the shared cache, at most one write each; presence and follow write nothing.

Defects this found and fixed: each scene refresh reassigned unchanged menus,
labels and buttons, and each reassignment laid the control out again. Presence
frames cost 2 layout passes each; agreement edits cost 10.4 per event. Now 0 and
4.5 — what remains is the reader, two labels and Endorse, which really change.
TextKit 2's own line-fragment views (`_NSTextViewportElementView`) inside the
reader are counted separately and bounded at one per event.

## 4. Appearance census

`CollaborationAppearanceSurfaces.all()` is now the one list both the ui-probe
appearance sweep and token census render: shared scene, scene with the
agreement panel, follow banner with an open card, hub, capture review, capture
drag hint, handoff. The class census fails when a collaboration view class in
Array's image appears visibly on none of them — 9 classes today. Light and dark
renders of all seven are in `renders/`; each was inspected.

## Teeth (`teeth/`)

Each mutation compiled; exact bytes were restored (sha256 match) and rebuilt
before the GREEN run.

| Mutation | RED on | Restored |
| --- | --- | --- |
| Tab handler disabled | Tab never reached Shared objects (stuck on Objects) | GREEN |
| focus restore disabled | focus moves on when Endorse disables | GREEN |
| Reduce Motion ignored | follow centres the view in one step (COL-18 witness, pinned to Reduce Motion) | GREEN |
| agreement buttons reassigned every refresh | burst runs no layout pass (ComposerActionButton: 1) | GREEN |
| overlay repaints on every update | 50 updates in one turn paint once (painted 50) | GREEN |
| follow surface removed | class census: SharedAreaPresenceOverlay on no surface | GREEN |

The overlay mutation first stayed GREEN against the flood budget alone: through
the controller the overlay never sees two updates in one turn. `7eaa7c20` adds
the direct witness that turned it RED.

## Gate

One run of `scripts/run-matrix.sh --collaboration` under the build lock with
`CONTINUUM_SKIP_UI_BASELINES=1`:

```
---- Collaboration matrix (targeted): 10 leg(s) run ----
NOTES (1):
  - --ui-probe-check: App theme surface-cache witness skipped with display-dependent checks; native theme persistence and token checks still run.
FAILED (1):
  - .build/debug/ContinuumRevivedCollaborationServiceChecks
```

10 legs, 9 passed, 1 failed. The native leg (with all 47 new checks), ui-probe
and menu contract passed. The failure is the service backup check
`verification refuses a backup with damaged pages`. It is not from this branch:
the branch changes only `Sources/ContinuumRevived/App/`, which the service checks
do not link, and it fails the same way in two isolated reruns. The check flips
512 bytes at the backup's midpoint; when that lands in an unused page, SQLite's
integrity check has nothing to refuse. Owner: the backup/restore work
(`ef89135e`, `25ed79fe`).

Not exercised: real Keychain, providers, a production relay, the default tmux
server, a normal or preview app launch, and app activation.
