# Settings / Configure Page + Keybind Editor — Plan

Status: design 2026-06-14. Goal: a Settings/Guide surface where a user can
SEE every shortcut, SEE what the app can do, and EDIT keybinds — with real
persistence and live reload. Backs the long-standing DD-018 ("settings have
no surface"). No Linear ticket yet (issue-limit); this doc is the backlog.

## Current state (audited)

**Two key layers.** (1) Global reserved chords via a pre-dispatch local
`NSEvent` monitor → `handleHotkey` (ContinuumApp.swift:1535). (2) Nav-mode
single keys, live only while nav mode is open → `handleNavModeKey` (~:1702).

### Layer 1 — global reserved (always live)
| Chord | Action | Defined |
|---|---|---|
| Cmd-F | Toggle Focus Mode | FocusModel.swift:75 / dispatch :1948 |
| Cmd-K | Launch palette | :76 / :1955 |
| Cmd-1/2/3/4 | Spawn claude / shell / browser / nvim | :77-80 / :1958-1969 (profile map hardcoded) |
| Leader (default Ctrl-Space) | Open/close Nav Mode | NavKeymap.swift:45 / FocusModel:70 |
| Cmd-Backspace | Delete active tile (canvas focused) | :1679 (hardcoded) |
| Escape | Close focus/nav mode | :1638/:1703 |

### Layer 2 — nav mode (modal)
h/j/k/l move · n/p next/prev zone · z zone picker · w workspace picker ·
a agent cycle · A needs-attention · f focus mode · x delete · 1-9 zone ordinal ·
0 fit all · Tab/Shift-Tab zone · Return focus+exit · Esc/leader exit.
(NavKeymap.swift:44-49 defaults; handlers ContinuumApp.swift:1702-1786.)

### Menu accelerators (CON-113)
Cmd-H, Cmd-Opt-H, Cmd-Q, Cmd-Z/Shift-Z, Cmd-X/C/V, Cmd-A. **No Cmd-, /
Preferences.** No Cmd-0 or Cmd-\ globals (zoom is gesture-only; "0=fit" is
nav-mode-only). `TileArrangement.nudge/throwDestination` exist in Core but are
NOT bound to any key yet.

### How configurable today (CON-67, Done)
- `NavKeymap` (Core) holds leader + 12 nav bindings; `NavKeymap.resolve(defaults:)`
  reads overrides from UserDefaults prefix **`continuum.keymap.`**; invalid →
  default + stderr warn; partial maps merge. Wired at boot (:822-823).
- **Gaps:** leader parsing accepts only `space`/`g`; global Cmd-K/F/1-4 are
  hardcoded in `ReservedShortcut.classify` (NOT in the keymap); nav 1-9/0/Tab/
  Return are hardcoded; **no write path** (set via `defaults write` only); **no
  live reload** (resolve runs once at boot); **no UI**.

### Settings scaffolding
- No settings window exists. `FocusModalKind.settings` / `FocusSurfaceID.settings`
  are declared but UNUSED — a ready seam (`focusBroker.openModal(.settings)`).
- `ProjectPickerPanel.swift` (NSPanel + NSTableView + filter, dark/monospaced,
  keyboard-first, runModal) is the cleanest template to copy.
- `LaunchProfilePalette.handleKeyEvent` is search-text oriented and REJECTS
  modifier chords — do NOT reuse for chord capture; write a fresh capture view.

## Build plan

Tag [pure] = loop-buildable + CoreChecks; [appkit] = needs real-app verify.

| # | Step | Size | Tag | Check |
|---|------|------|-----|-------|
| K1 | Core: keymap **write path** (`NavKeymap.persist(to:)`, inverse of resolve) + broaden chord model (`KeyChord` with displayString + more keys for leader) | M | [pure] | extend `NavKeymapChecks`: round-trip `resolve(persist(map))==map`, chord display |
| K2 | Core: `ShortcutCatalog` — every binding (global + nav + hardcoded) with chord, action label, configurable y/n. Single source for the guide. | S | [pure] | new catalog-exhaustiveness check (covers each ReservedShortcut + NavKeymap field) |
| K3 | AppKit: Settings/Guide **NSPanel shell** (copy ProjectPickerPanel) — two sections: **Guide** (read-only ShortcutCatalog table) + **Keybindings** (editable list). `Settings…` menu item (Cmd-,) in installMainMenu (:620); open via `focusBroker.openModal(.settings)`. | M | [appkit] | new `--settings-panel-check`: installs/tears down once; Cmd-, menu item present; guide rows == catalog count |
| K4 | AppKit: **chord-capture field** (fresh NSView overriding keyDown/performKeyEquivalent → KeyChord) + apply: `persist` (K1) + live update `navKeymap`/`focusBroker.navKeymap` (:822-823) + refresh nav hint line. Live reload, no relaunch. | M | [appkit] | new `--keybind-edit-check`: capture → lands in UserDefaults → broker reflects new leader → hint line updates |
| K5 | (optional) Make global Cmd-K/F/1-4 remappable: data-drive `ReservedShortcut.classify` from a keymap table so the editor can rebind them too. | S | [pure] | extend classify check |

Sequence: K1→K2 [pure, loop] then K3→K4 [appkit, me-verified]. K5 optional.

## Page design (what the user sees)

A keyboard-first panel (dark/monospaced, matches palette/picker), two tabs:
- **Guide** — grouped read-only list of every shortcut + a short "what this
  does" line; the onboarding/reference surface.
- **Keybindings** — editable rows (action · current chord · default); click a
  row → "press new chord" capture → apply live; "reset to default" per row.
Reuse: NavKeymap model (K1), ShortcutCatalog (K2), the dead `.settings` modal
kind, FocusBroker modal snapshot/restore, ProjectPickerPanel layout.

## Key files
FocusModel.swift (:5-18 settings seam, :60-83 classify) · NavKeymap.swift
(model + resolve; add persist + catalog) · ContinuumApp.swift (:620 menu,
:822-823 keymap wiring, :1955-1969 hardcoded dispatch) · ProjectPickerPanel.swift
(template) · FocusBroker.swift (:77-90 modal, :116 keymap-threaded classify) ·
ContinuumRevivedCoreChecks/main.swift (NavKeymapChecks ~:282) · docs/16 DD-018.
