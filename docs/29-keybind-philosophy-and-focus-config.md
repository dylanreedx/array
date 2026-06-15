# Keybind Philosophy, Focus-Border Config & Settings/Keybind Test Suite — Design

Status: written 2026-06-15 before a compaction, to preserve intent. After the
focus-scope primitive (docs/27) + extensible settings system (docs/24) + the
marching-ants focus border (commit e1d4609) landed, Dylan raised three threads:
(1) make the focus border configurable, (2) a settings+keybind test suite that
grows with the surface, (3) a keybind-design philosophy — plus a real conflict
to fix. This doc records the WHY so implementation survives the context reset.

## 1. Focus border must be configurable (extensible / toggleable / color)

**Shipped (855df84):** `FocusBorderConfig` (Core) resolves enabled/color/gap/
speed from `continuum.focusBorder.*` UserDefaults; the overlay reads it; an
**Appearance** settings section exposes a toggle, a named-palette color choice,
and gap/speed fields; changes apply live via the settings-changed notification.

Original design notes below. Current: `FocusBorderOverlayView` (CanvasNSView) —
a click-through canvas overlay outside the focused tile; constants in code:
`gap = 8`, `lineWidth = 1.5`, dash `[6,4]`, `controlAccentColor @ 0.7`,
`animationDuration = 2.5`.

Goal: surface it through the docs/24 `SettingsSchema` so it's toggleable and
themeable, and structure it so adding a knob is trivial:
- **Enabled** toggle (default on).
- **Color** (default = system accent; later: a small palette or hex).
- Likely **gap** and **march speed** as fields too.
- Read config via a UserDefaults-backed resolver (mirror `ZoneChromeFeature` /
  `NavKeymap.resolve`) instead of hardcoded statics, so the overlay reacts to
  settings live and a new knob is one `SettingsField` + one resolver line.

Follow-up (not now): evaluate how the border reads at **more zoomed-out**
states. It's screen-space constant (overlay sized to the tile's screen frame +
gap), so it should hold — but confirm the feel. Current border is "good enough
to lock in."

## 2. Keybind design philosophy (the core intent)

**Mental model (Dylan's framing):** Continuum is foreground software you
knowingly run — *almost a desktop replacement* — but focused on development. On
the real desktop you do many things with many shortcuts and global tools; in
Continuum you're focused on dev. So Continuum's dev keybinds should be **easy,
serviceable, FEW and SHALLOW combinations** — not deep `⌃⌥⌘`-chords — WITHOUT
conflicting with general desktop / global workflows.

**Why shallow is safe here (the key technical distinction):**
- Continuum's shortcuts are **app-scoped** — they fire only when Continuum is
  frontmost (a local `NSEvent` monitor), NOT system-global hotkeys. So shallow
  chords inside Continuum don't pollute the global namespace.
- The real conflict surface is therefore narrow:
  (a) **macOS system shortcuts** (⌘Q, ⌘Tab, ⌘Space, screenshot chords, Mission
      Control) — never claim these.
  (b) **Third-party GLOBAL hotkey daemons** — Rectangle, Alfred, Raycast,
      window managers — which register SYSTEM-WIDE hotkeys that preempt even
      Continuum's app-scoped keys. **This is the Rectangle problem (§3).**
- **Leverage the focus-scope primitive (docs/27).** Scopes (canvas /
  focused-tile / nav-mode modal) disambiguate intent, so SHALLOW keys can do a
  lot *within a scope* (bare keys in nav-mode; single-modifier chords in a
  focused tile). "Few combinations" is achieved by SCOPING, not by stacking
  modifiers.

**Principles for default keybinds:**
- Prefer **scope + shallow** over deep chords. Bare / single-modifier keys
  inside a known scope beat global `⌃⌥⌘` chords.
- Never claim macOS system shortcuts.
- Avoid chords claimed by common **global hotkey daemons** (Rectangle's
  `⌃⌥`-arrows, etc.). Keep a known-conflicts list (§4).
- Keep a small **inviolable global** set only: ⌘K palette, the Nav leader,
  ⌘, settings, ⌘Q (system). Everything else is scope-local.
- Route richer actions through **modal scopes** (nav-mode) or a leader sequence
  so the base-chord count stays low.
- Everything **rebindable** via the docs/24 editor — defaults are good starting
  points, not law.

## 3. RESOLVED — Rectangle conflict fixed; nudge dropped, throw re-homed

A3 (commit a6f1007) shipped tile positioning as `⌃⌥`-arrows (nudge) +
`⌃⌥⌘`-arrows (throw), described as "Rectangle-style muscle memory." But
**Rectangle USES `⌃⌥`-arrows as global hotkeys**, so they preempted Continuum
and silently didn't fire when Rectangle is installed — and they were exactly
the "deep chord" the philosophy argues against.

**Fixed (commit 9eb5953):** per Dylan, nudge was dropped entirely — **throw is
now the single directional move primitive** (paired, eventually, with magnetic
drag-snapping for the good feel). Throw re-homed from `⌃⌥⌘`-arrows to
**`⌘⌃`-arrows** — a shallow 2-modifier focused-tile chord, a sibling of the
`⌘⌃`-digit resize presets. Rectangle uses `⌃⌥` (not `⌘⌃`); macOS reserves
`⌃`-arrows (Spaces) but not `⌘⌃`-arrows; `⌘`-combos route to the app so tile
content is never shadowed. The audit lives in code now: `KnownChordConflicts`
(curated macOS + Rectangle chords) + `KeybindConflictChecks` fail the build if
any default lands on a conflict. Resize `⌘⌃`-digits, browser/note `⌘`-letters,
and globals `⌘K`/`⌘,`/`⌘1-4` were all audited clear.

**Open finding — the nav leader `⌃Space`** collides with the macOS "Select
previous input source" shortcut. Left as-is for now (single-input-source users
see no conflict, it's rebindable, and changing it is muscle-memory disruptive);
it is the one **allowlisted** default in the conflict-guard. Decide later
whether to keep it, rebind the leader, or disable the macOS shortcut.

## 4. Settings + keybinding test suite (grows with the surface)

Goal: as settings and keybinds grow — *especially* keybinds — a suite ensures
functionality, behavior, no conflicts, and no regressions, not just existence.
Layers (some exist, some to build):
- **Exhaustiveness (exists):** `ShortcutCatalogChecks` (every binding appears in
  the catalog/guide), `SettingsSchemaChecks` (every pref round-trips through
  UserDefaults; every existing pref represented).
- **Behavior (grow this):** per binding, assert the ACTION resolves AND fires in
  the right scope (extend the `FocusDispatch.resolve` table + the
  `--*-action-check`s to cover every binding); per setting, assert the field
  drives the real resolver end-to-end (generalize the zone-chrome end-to-end
  assertion to every field).
- **Conflict guard (NEW):** a data-driven check that (i) no two bindings in the
  same scope share a chord, and (ii) no DEFAULT chord lands on the
  known-conflicts list (macOS system + global-daemon chords like Rectangle's
  `⌃⌥`-arrows). Fails the build if a default regresses onto a conflict.
- **UI (exists):** `--settings-panel-check`, `--keybind-edit-check`.

**Convention (extends docs/24 + the verification-doctrine):** every new setting
or keybind ships, in the same change: its catalog/schema entry, a behavior
assertion, and — if it has a default chord — a conflict-guard entry.

## 5. Post-compact tasks — DONE

1. **Rectangle conflict (§3) — done (9eb5953):** dropped nudge, re-homed throw
   to `⌘⌃`-arrows; added `KnownChordConflicts` + an executable audit.
2. **Focus-border config (§1) — done (855df84):** `FocusBorderConfig` resolver
   (enabled/color/gap/speed) + an Appearance settings section; the overlay reads
   it and re-applies live on the settings-changed notification.
3. **Test suite (§4) — done:** `FocusBorderConfigChecks` (round-trip +
   invalid-input fallbacks), extended `SettingsSchemaChecks`, and
   `KeybindConflictChecks` (no default on `KnownChordConflicts` + intra-scope
   chord uniqueness, leader allowlisted). Convention adopted: ship the
   catalog/schema entry + a behavior assertion + a conflict-guard entry together.

**Still open:** the `⌃Space` leader finding (§3); magnetic drag-snapping to pair
with throw (§3); evaluate the focus border at more zoomed-out states (§1).

## Key files
`TileActionCatalog.swift` (defaults — the Rectangle conflict) · `FocusDispatch.swift`
(resolution + inviolable set) · `ShortcutCatalog.swift` (catalog/guide) ·
`SettingsSchema.swift`/`SettingsField.swift` (settings) · `FocusBorderOverlayView`
in `CanvasNSView.swift` (border constants → config) · `NavKeymap.swift` (nav-mode
+ leader) · `ContinuumRevivedCoreChecks/main.swift` (the *Checks). Related:
docs/24 (settings), docs/27 (focus-scope), docs/28 (the completed queue),
memory `verification-doctrine`.
