# Settings / Configure Page — Extensible Settings System (+ Keybind Editor)

Status: design 2026-06-14 (re-scoped with Dylan to an *extensible* settings
system, not a keybind-only panel). Goal: a Settings surface, opened by `⌘,`
from any scope, where a user can SEE/EDIT keybinds AND other preferences — and
where a future dev or agent can add a new pref or whole section by appending
one declarative descriptor, no UI work. Backs DD-018 ("settings have no
surface"). Pairs with docs/27 (focus-scope primitive supplies the inviolable
`⌘,` and the `TileActionCatalog`/`ShortcutCatalog`). Verification per
`verification-doctrine`; visual gate per docs/26.

## Current state (audited 2026-06-14)

**Two key layers.** (1) Global reserved chords via a pre-dispatch local
`NSEvent` monitor → `handleHotkey`/`handleReservedShortcut` (ContinuumApp.swift
~:1535/:1921). (2) Nav-mode single keys → `handleNavModeKey` (~:1702).

| Chord | Action | Defined |
|---|---|---|
| Cmd-F | Focus Mode (being migrated to browser-find in tile scope, docs/27) | FocusModel.swift:75 |
| Cmd-K | Launch palette | :76 |
| Cmd-1/2/3/4 | Spawn claude / shell / browser / nvim | :77-80 |
| Leader (Ctrl-Space) | Nav Mode | NavKeymap leader |

- `NavKeymap` (CON-67, Done): leader + 12 nav bindings; `resolve(defaults:)`
  reads `continuum.keymap.*` overrides. **No write path, no live reload, no UI.**
- `FocusModalKind.settings` / `FocusSurfaceID.settings` declared but **UNUSED** —
  a ready seam (`focusBroker.openModal(.settings)`).
- `ProjectPickerPanel.swift` (NSPanel + table + filter, dark/monospaced,
  keyboard-first) = the cleanest template to copy.
- `LaunchProfilePalette.handleKeyEvent` REJECTS modifier chords — do NOT reuse
  for chord capture; write a fresh capture view.
- **No `Settings…` / `⌘,` menu item exists.**
- Existing prefs with NO UI (the DD-018 gap): `DefaultBrowserURL`,
  `DeleteConfirmPolicy`, `ZoneChromeFeature` (now default-on, 22f2c65),
  `continuum.tileGap`.

## Architecture — extensible by construction

**Core — declarative schema (the extensibility engine, pure + testable):**
- `SettingsField` — typed descriptor bound to a UserDefaults key: `.toggle`,
  `.text`, `.choice(options)`, `.shortcuts(catalog)`; carries label, default,
  validation, get/set.
- `SettingsSection { id, title, [SettingsField] }`.
- `SettingsSchema.sections() -> [SettingsSection]` — the ordered registry.
- **Adding a pref = append one `SettingsField`; adding a section = append one
  `SettingsSection`.** No renderer changes. That is the extensibility contract.
- `SettingsSchemaChecks`: every field key/default round-trips through
  UserDefaults; every existing pref is represented; no duplicate keys.

**App — generic renderer (written once):**
- One NSPanel (from `ProjectPickerPanel`): a sidebar of section titles + a
  detail pane that renders fields *generically by type* (toggle→`NSSwitch`,
  text→`NSTextField`, choice→popup, shortcuts→chord-capture editor). New
  sections render automatically — zero per-section UI.
- `⌘,` is an **inviolable global** (docs/27) → `focusBroker.openModal(.settings)`
  from any scope; plus a `Settings…` menu item (installMainMenu ~:620).
- Live apply: writing a field persists to UserDefaults; keybind edits call the
  NavKeymap/`TileActionCatalog` write path + refresh the live keymaps (no relaunch).

**v1 sections:**
- **Keybindings** — Guide (read-only `ShortcutCatalog`: globals + nav + tile
  actions) + editable chord rows (NavKeymap + `TileActionCatalog` write paths).
- **General** — existing hidden prefs as fields: default browser URL (text),
  delete-confirm policy (choice), zone chrome (toggle), tile gap (number).
- *Deferred (append later, no rework): theming/appearance, agent/harness config.*

## Build plan

Tag [pure] = loop/agent-buildable + CoreChecks; [appkit] = real-app verify.

| # | Step | Tag | Check |
|---|------|-----|-------|
| S1 | `NavKeymap.persist` write path (inverse of `resolve`) + `KeyChord` display/parse broadening; `TileActionCatalog` write path (docs/27) | [pure] | extend `NavKeymapChecks`: `resolve(persist(map))==map` |
| S2 | `ShortcutCatalog` — every binding (global + nav + tile) with chord, label, configurable y/n; single source for the Guide | [pure] | catalog-exhaustiveness check |
| S3 | `SettingsField`/`SettingsSection`/`SettingsSchema` + `SettingsSchemaChecks` (the engine) | [pure] | schema round-trip + existing-prefs-represented |
| S4 | Generic NSPanel renderer (sidebar + type-driven detail) + `⌘,` inviolable open + `Settings…` menu | [appkit] | `--settings-panel-check` (installs/tears down; ⌘, opens; sections==schema) + visual snapshot (docs/26) |
| S5 | Field renderers incl. fresh chord-capture view + live apply; wire General section to existing prefs | [appkit] | `--keybind-edit-check` (capture→UserDefaults→broker reflects→hint updates) |

Sequence: S1→S2→S3 [pure, agent/loop] then S4→S5 [appkit, agent-built + me-verified].

## Key files

FocusModel.swift (`.settings` seam, classify) · NavKeymap.swift (add persist) ·
new `SettingsSchema.swift`/`SettingsField.swift` (Core) · `TileActionCatalog`/
`ShortcutCatalog` (docs/27) · ContinuumApp.swift (:620 menu, monitor/dispatch) ·
ProjectPickerPanel.swift (template) · FocusBroker.swift (modal snapshot/restore,
inviolable `⌘,`) · ContinuumRevivedCoreChecks (NavKeymapChecks, new schema
checks) · docs/16 DD-018 · docs/27 (focus-scope primitive) · docs/26 (visual gate).
