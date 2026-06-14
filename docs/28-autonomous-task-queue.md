# Autonomous Task Queue — focus-scope + settings batch

Local replacement for Linear's Todo pool (Linear hit its free issue limit). This
file + git ARE the loop's state. Pick the first `TODO` task whose deps are all
`DONE`; do it; flip it to `DONE` with the commit SHA; repeat. Order is already
dependency-sorted. Specs: docs/27 (focus-scope primitive), docs/24 (extensible
settings), docs/25 (polish). Doctrine: `verification-doctrine` — a check that
can pass while the user-facing path is dead is the WRONG check.

## Rules for whoever works this (agent or loop master)

- ONE task per unit. Read the referenced spec section before coding.
- VERIFY = `./scripts/run-matrix.sh` green **plus** the task's named check, which
  must drive the REAL path (through the monitor, at boundary conditions), never a
  bypass. New chrome ships a Tier-1 `VisualSnapshot` non-degenerate assertion
  (docs/26). Artifact values measured, never constants.
- `[pure]` = Core only, fully loop-safe. `[appkit]` = compiles + matrix + named
  self-check + Tier-1 visual; **`DOGFOOD`** tag = also needs Dylan's morning
  real-app pass (feel/correctness automation can't judge) — mark it done when
  the automated bar is met, but list it under "Morning dogfood checklist".
- Commit `type(scope): summary`, no AI footers, `git push origin main` after green.
- Behavior-neutral steps; each ends matrix-green. Don't weaken/delete checks.

## Foundation — `[pure]`, fully loop-safe

### F1 — TileAction + TileActionCatalog + FocusDispatch (docs/27 §Architecture, staging 1)
- **Status: DONE (84a285f)** · deps: none
- New Core: `TileAction.swift` (`TileAction`, `TileSizePreset`, `TileChord` — reuse
  `KeyChord` if it exists), `TileActionCatalog.swift` (`actions(for: TileKind) ->
  [TileChord: TileAction]`, defaults in code, override via `continuum.tileKeymap.*`),
  `FocusDispatch.swift` (`resolve(chord, scope, focusedKind, catalog) -> Resolution`
  with inviolable globals ⌘K/leader/⌘Q/⌘,).
- **Check:** add `FocusDispatchChecks` to `ContinuumRevivedCoreChecks` — exhaustive
  `(chord × scope × kind) → Resolution`; inviolable-always-global; tile-claims-win
  in tile scope; passthrough for unclaimed; catalog default/override round-trip.
  `swift run ContinuumRevivedCoreChecks` + matrix green.

### F2 — NavKeymap write path + TileActionCatalog persist (docs/24 S1)
- **Status: DONE (f6caa3f)** · deps: F1
- `NavKeymap.persist(to:)` (inverse of `resolve`); broaden `KeyChord` display/parse;
  `TileActionCatalog` write path.
- **Check:** extend `NavKeymapChecks` — `resolve(persist(map)) == map`, chord display
  round-trip. matrix green.

### F3 — ShortcutCatalog (docs/24 S2)
- **Status: DONE (f65c366)** · deps: F1, F2
- `ShortcutCatalog`: every binding (globals + nav + tile actions) with chord, label,
  configurable y/n. Single source for the Guide.
- **Check:** catalog-exhaustiveness — covers each `ReservedShortcut`, each `NavKeymap`
  field, each `TileActionCatalog` entry. matrix green.

### F4 — SettingsSchema engine (docs/24 S3)
- **Status: DONE (7707ce7)** · deps: F3 · **FOUNDATION COMPLETE (F1–F4)**
- `SettingsField` (`.toggle/.text/.choice/.shortcuts`), `SettingsSection`,
  `SettingsSchema.sections()`.
- **Check:** `SettingsSchemaChecks` — every field key/default round-trips through
  UserDefaults; existing prefs represented (`DefaultBrowserURL`, `DeleteConfirmPolicy`,
  `ZoneChromeFeature`, `continuum.tileGap`); no duplicate keys. matrix green.

## App wiring — `[appkit]`, me-gated

**RE-SEQUENCED 2026-06-14:** Dylan's priority is a usable settings page with his
prefs by morning. That does NOT need the focus-scope refactor — `⌘,` already
classifies as `.settings` (F1) and reaches `handleReservedShortcut`, so opening
the panel is a one-line wiring. So the order is now **A6 → A7** (settings, high
value + additive/lower-risk) **then A1 → A2 → A3 → A4 → A5** (focus-scope
hot-path, riskier, dogfood-dependent) **then P1–P3**. A6 wires `⌘,` minimally;
A2 later replaces that with the unified `FocusDispatch`. A6 includes editable
General fields (toggle/text/choice) so it's usable on its own; A7 adds the
keybind chord-capture editor.

### A1 — FocusBroker.enterScope funnel + close scope drift (docs/27 staging 2) · DOGFOOD
- **Status: DONE (a05f026)** · deps: F1 · scope now authoritative (background→.canvas,
  content-click lockstep); 7 focus checks green + new --focus-scope-dispatch-check.
- **NEXT ORDER: A5 (border, additive, only needs A1) → then A2 → A3 → A4** (the
  dispatch migration + executors; A2 removes the P0 guard so it's gated hardest).
- Single `enterScope(_:reason:)`; route ALL interactions through it: title bar, tile
  body / web content / note / terminal, canvas background, nav-mode commit, spawn/close.
  Keep `lastActiveTileId` in lockstep. Generalize the P0 responder-walk.
- **Check:** new `--focus-scope-dispatch-check` — clicks incl. web content + canvas
  background set `activeSurface` correctly; assert scope transitions. matrix green.

### A2 — monitor → FocusDispatch.resolve; remove P0 guard (docs/27 staging 3) · DOGFOOD
- **Status: DONE (4f5605a)** · deps: F1, A1 · P0 doubly-preserved; 11 checks green;
  new `--reserved-dispatch-check`. executeTileAction is a passthrough stub (A3/A4 fill it).
- Replace `handleReservedShortcut` body with `resolve → execute`; delete the P0
  special-case browser guard (absorbed). `--browser-url-focus-check` still green.

### A3 — sizing + positioning executors (docs/27 staging 4) · DOGFOOD
- **Status: TODO** · deps: F1, A2
- `⌘⌃1/2/3/0` size presets (TileGeometry); `⌃⌥`/`⌃⌥⌘` arrows nudge/throw
  (wire the landed `TileArrangement` math). Add `--tile-keyboard-action-check`.

### A4 — browser + note executors (docs/27 staging 5) · DOGFOOD
- **Status: TODO** · deps: A2
- Browser ⌘F/⌘L/⌘R/⌘[/⌘]; note ⌘E export (save panel). Extend browser self-check.

### A5 — marching-ants focus border (docs/27 staging 6) · DOGFOOD
- **Status: DONE (3647acf)** · deps: A1
- `CAShapeLayer` dashed stroke + infinite `lineDashPhase` anim on scope tile;
  screen-space constant; installed on focus, removed on blur.
- **Check:** assert layer+animation install/remove on scope change; `VisualSnapshot`
  with dash phase frozen (non-degenerate). matrix green.

### A6 — generic settings NSPanel + ⌘, open (docs/24 S4) · DOGFOOD
- **Status: DONE (df3f167)** · deps: F3, F4 (A2 dep relaxed; ⌘, wired minimally)
- Gated: matrix green incl. `--settings-panel-check` (sections==schema, per-type
  controls, toggle→UserDefaults round-trip, non-blank offscreen render); 4 focus
  checks + menu-contract stay green. General fields editable + live; Keybindings
  tab read-only (A7 adds editing). Live screenshot skipped (would touch real
  workspace / needs screen-rec perms) — visual confirmation is on the checklist.
- NSPanel from `ProjectPickerPanel`: sidebar of sections + type-driven detail pane.
  `⌘,` inviolable → `openModal(.settings)` from any scope; `Settings…` menu item.
- **Check:** `--settings-panel-check` — installs/tears down; ⌘, opens; rendered
  sections == schema; Tier-1 visual snapshot non-degenerate. matrix green.

### A7 — field renderers + chord capture + General section (docs/24 S5) · DOGFOOD
- **Status: DONE (72d1e2f)** · deps: F2, F4, A6 · **SETTINGS PAGE COMPLETE (A6+A7)**
- Gated: matrix green incl. `--keybind-edit-check` (nav/leader/tile rebind +
  reset + inviolable-collision rejection); `--settings-panel-check` + 4 focus
  checks stay green. `KeybindEditor` (pure routing) reviewed. General editing
  (A6) untouched.
- Type renderers (toggle/text/choice/shortcuts); fresh chord-capture view; live apply
  (persist + refresh live keymaps, no relaunch); wire General to the existing prefs.
- **Check:** `--keybind-edit-check` — capture → UserDefaults → broker reflects new
  binding → hint updates; General toggles persist. matrix green.

## Polish — `[appkit]`, if time (docs/25 P1)

### P1 — resize corner band · DOGFOOD
- **Status: TODO** · deps: none
- Give corners a larger detection band; extend `--tile-world-bounds-check` to
  `.bottom/.top/.bottomLeft/.bottomRight/.topLeft/.topRight` at zoom 0.5/1/2.

### P2 — drag-grab screen-space floor · DOGFOOD
- **Status: TODO** · deps: none
- Floor the title-bar move-grab in screen space (`max(24, minPx/zoom)`,
  TileNSView ~:170/:17); mirror in `resetCursorRects`.

### P3 — browser find match count
- **Status: TODO** · deps: A4
- Surface `WKFindResult` ("3 of 12" / not found) instead of discarding it.

## Known flaky (handle, don't trust blindly)
- **`HarnessRunControl` check in CoreChecks** intermittently crashes with
  `HarnessRunControlError.missingControlFile` (Trace/BPT trap) — a race in its
  temp-git setup, NOT caused by queue work. Seen once during F2 gate, green on
  re-run. The gate re-runs the matrix on this signature. Hardening it is a
  follow-up (P4) — important because an unattended Codex loop would false-STOP.

## Morning dogfood checklist (Dylan)
_(filled in as DOGFOOD tasks land — what to eyeball when you're back)_
- **Settings (A6):** press `⌘,` → panel opens; `⌘,` again closes; `Settings…`
  menu item works. General tab: flip Zone Chrome / change delete-confirm / edit
  default URL / tile gap → quit & relaunch → values persisted. Keybindings tab:
  shows the full shortcut guide (Global / Nav Mode / per tile kind). Does the
  panel look right (dark/monospaced, readable, sized ok)?
- **Keybind editing (A7):** in the Keybindings tab, click Edit on a binding →
  press a new chord → it shows the new chord + applies live (try a nav-mode key
  or the leader); Reset restores default; binding `⌘K`/`⌘,` is refused.
- **Focus border (A5):** click a tile → a subtle dashed "marching ants" border
  animates around it; click another tile → border moves; click empty canvas →
  border clears. Does it read well at different zoom levels? Too subtle/loud?
