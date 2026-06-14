# Focused-Tile Scope Primitive — Design Spec

Status: design 2026-06-14 (brainstormed with Dylan). A foundational primitive:
make **focus scope** a first-class, reliable, visible, and extensible concept,
so tile-local keybind actions (resize, reposition, browser find, note export)
dispatch cleanly instead of via the ad-hoc `canHandleReservedShortcut` bool.
Subsumes and cleans up the P0 Cmd+F fix (852c1db). Feeds docs/24 (keybind
editor) and uses docs/26 (visual gate). Verification per `verification-doctrine`.

## Problem

The app has no real notion of "what scope am I in." Two overlapping values
drift: `FocusBroker.activeSurface` (drives reserved-shortcut routing) and
`CanvasState.lastActiveTileId` (drives z-order/visual). Focus is registered
only on **title-bar** clicks (`TileNSView.mouseUp`), so clicking *into* a tile's
content (WKWebView, note, terminal) leaves `activeSurface` stale — that was the
Cmd+F grey-screen root cause. Tile-local shortcuts are a single `Bool`
(`canHandleReservedShortcut`), only the browser uses it (`.focusMode`), it's
not data-driven, not testable as a unit, and invisible to the settings catalog.

## Decisions (resolved in brainstorming)

- **D1 — Single focused state, chords-only.** No separate "engaged/editing"
  state. Every tile action is a modifier chord, so it never collides with text
  entry. Bare-key arrangement/nav stays in Nav Mode.
- **D2 — Scope follows the last action.** The current scope is whatever you
  last interacted with: click canvas background → `.canvas`; click/enter a tile
  (including its content) → `.tile(id)`. One authoritative value.
- **D3 — Tile wins, with an inviolable global set.** A focused tile's chord
  claim beats the global binding (⌘F → browser find), EXCEPT a hardcoded
  inviolable set (⌘K palette, Nav leader, ⌘Q, ⌘,) that is always global so the
  user can never trap themselves.
- **D4 — Reuse, don't duplicate.** Scope IS `FocusBroker.activeSurface`
  (`FocusSurfaceID`); no competing state object. Decision logic is pure Core.

## Architecture

### Scope = authoritative `activeSurface`
Route every focus-affecting interaction through one funnel:

    FocusBroker.enterScope(_ scope: FocusSurfaceID, reason: FocusRequest)

so the scope is always accurate. The gaps today (which are the bugs):

| Interaction | Sets scope to | Today |
|---|---|---|
| Click tile title bar | `.tile(id)` | works |
| Click tile body / web content / note / terminal | `.tile(id)` | **missing (P0 drift)** |
| Click canvas background | `.canvas` | missing |
| Nav Mode → Return on tile | `.tile(id)` | via markActive |
| Spawn / close tile | new tile / `.canvas` | partial |

`lastActiveTileId` (visual/z-order) stays but is kept in lockstep through the
same funnel. The P0 responder-walk (`TileNSView.enclosingTileId`) becomes the
general scope-resolution mechanism, not a browser special-case.

### Catalog + dispatch (pure Core)
- **`TileActionCatalog`** — `actions(for: TileKind) -> [TileChord: TileAction]`.
  Defaults in code, overridable from `continuum.tileKeymap.*` UserDefaults
  (same pattern as `NavKeymap`). Becomes editable/visible rows in the docs/24
  keybind editor.
- **`FocusDispatch.resolve(chord, scope, focusedKind, catalog) -> Resolution`**
  — the single decision function:
  1. `chord ∈ inviolableGlobals` → `.global` (always).
  2. `scope == .tile(id)` and catalog(kind) claims `chord` → `.tileAction(action)`.
  3. canvas/global chord → `.global`.
  4. else → `.passThrough` (responder chain / typing).

The monitor (`handleReservedShortcut`) becomes `resolve → execute`, replacing
the scattered `if canHandleReservedShortcut` checks.

**Settings via `⌘,`:** `⌘,` is in the inviolable set, so it opens
`.modal(.settings)` from any scope. The extensible settings system (docs/24) is
the surface that edits this primitive's `TileActionCatalog` alongside globals
and `NavKeymap` — one unified, extensible binding model.

## Actions in v1 (YAGNI; catalog makes more trivial later)

Universal (any focused tile), chords chosen to never collide with typing:
- **Sizing — `⌘⌃1/2/3`** → `compact / default / large` presets, derived from
  `TileGeometry.preset(for:kind)`; **`⌘⌃0`** → `fillViewport`.
- **Positioning — `⌃⌥←↑↓→`** nudge, **`⌃⌥⌘←↑↓→`** throw-to-neighbor, backed by
  the existing pure `TileArrangement.nudge/throwDestination/snapAdjustment`
  (Core math already landed, currently unwired). Rectangle-style muscle memory.

Kind-specific:
- **Browser** — `⌘F` find (migrated onto this dispatch), `⌘L` focus URL, `⌘R`
  reload, `⌘[ / ⌘]` back/forward.
- **Note** — `⌘E` export body to a file (save panel).

Deferred (not v1): in-app inspector open — `isInspectable` (shipped) lets
Safari's Develop menu attach, but WKWebView has **no public API to open the
inspector programmatically**; revisit as a spike. Terminal/file/diff tile
actions: added later via the catalog.

All chords above are defaults and rebindable through the docs/24 editor.

## Visual — animated marching-ants focus border

A `CAShapeLayer` strokes the focused tile's rounded rect with a dashed pattern
(~`6 on / 4 off`); a `CABasicAnimation` on `lineDashPhase` loops forever so the
dashes march continuously around the perimeter ("rotating infinitely").
- Subtle and slow: low-opacity accent, ~1.5px, ~3–4s per march cycle; tunable.
- **Screen-space constant**: dash sizing + width in the view's backing coords,
  identical at any zoom (never world-scaled — same lesson as the drag-grab fix).
- GPU-composited (zero main-thread cost); exactly one tile focused at a time;
  installed on `enterScope(.tile)`, removed on leave. Composes inside zone chrome.

## Testing (the explicit ask: "good tests for this")

- **Core `FocusDispatchChecks`**: exhaustive `(chord × scope × kind) → Resolution`
  table; inviolable-always-global; tile-claims-win-in-tile-scope; passthrough
  for unclaimed. Scope-transition table (`interaction → resulting scope`).
  Catalog defaults/override round-trip (mirrors `NavKeymapChecks`).
- **App `--focus-scope-dispatch-check`**: drive real clicks — title bar, web
  content, canvas background — through `enterScope`, assert `activeSurface`,
  assert a chord resolves + executes. Absorbs the P0 assertions from
  `--browser-url-focus-check`.
- **Visual**: focus-border snapshot via `VisualSnapshot` (docs/26) with the dash
  phase **frozen** for determinism; assert the border layer + animation install
  on focus and remove on blur (motion itself is not snapshotted).

## File plan

- **Core (new):** `TileAction.swift` (`TileAction`, `TileSizePreset`, `TileChord`
  or reuse the docs/24 `KeyChord`), `TileActionCatalog.swift`, `FocusDispatch.swift`;
  `FocusDispatchChecks` added to `ContinuumRevivedCoreChecks`.
- **App:** `FocusBroker.enterScope(...)` funnel; route all clicks/focus through
  it; replace `handleReservedShortcut` body with `resolve → execute`; **delete
  the P0 special-case guard** (absorbed); marching-ants border in `TileNSView`;
  per-kind executors (browser runtime find/reload/nav, note export, canvas
  resize/nudge/throw). `run-matrix.sh` += `--focus-scope-dispatch-check`.

## Staging (behavior-neutral, each matrix-green; like docs/23)

1. Core `TileAction` + `TileActionCatalog` + `FocusDispatch` + `FocusDispatchChecks` `[pure]`.
2. `FocusBroker.enterScope(...)` funnel; route all interactions; close the
   scope-drift gaps `[appkit]` (`--focus-scope-dispatch-check`).
3. Migrate the monitor to `FocusDispatch.resolve`; remove the P0 guard `[appkit]`.
4. Wire executors: sizing presets + positioning (TileArrangement) `[appkit]`.
5. Wire browser (find/url/reload/nav) + note export executors `[appkit]`.
6. Marching-ants focus border + frozen-phase visual snapshot `[appkit]`.

## Out of scope (v1)

Engaged/editing sub-state; bare-key tile actions; in-app inspector open;
terminal/file/diff tile actions; zone-as-scope (a docs/23 follow-up);
tier-2 baseline diff of the border.

## Key files

`Sources/ContinuumRevivedCore/`: FocusModel.swift (`FocusSurfaceID` = scope),
NavKeymap.swift (catalog override pattern), TileGeometry.swift (sizing presets),
TileArrangement.swift (nudge/throw/snap), new TileAction/TileActionCatalog/
FocusDispatch · `Sources/ContinuumRevived/App/`: FocusBroker.swift (enterScope),
ContinuumApp.swift (handleReservedShortcut → resolve/execute) · `Canvas/`:
TileNSView.swift (enclosingTileId, marching-ants border), BrowserTileNSView.swift,
NoteTileNSView.swift, CanvasNSView.swift (executors). Doctrine:
`verification-doctrine`; visual gate: docs/26; keybind editor: docs/24.
