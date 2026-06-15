# Keybind Philosophy, Focus-Border Config & Settings/Keybind Test Suite — Design

Status: written 2026-06-15 before a compaction, to preserve intent. After the
focus-scope primitive (docs/27) + extensible settings system (docs/24) + the
marching-ants focus border (commit e1d4609) landed, Dylan raised three threads:
(1) make the focus border configurable, (2) a settings+keybind test suite that
grows with the surface, (3) a keybind-design philosophy — plus a real conflict
to fix. This doc records the WHY so implementation survives the context reset.

## 1. Focus border must be configurable (extensible / toggleable / color)

Current: `FocusBorderOverlayView` (CanvasNSView) — a click-through canvas
overlay outside the focused tile; constants in code: `gap = 8`, `lineWidth =
1.5`, dash `[6,4]`, `controlAccentColor @ 0.7`, `animationDuration = 2.5`.

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

## 3. KNOWN ISSUE — A3 positioning defaults collide with Rectangle

A3 (commit a6f1007) shipped tile positioning as `⌃⌥`-arrows (nudge) +
`⌃⌥⌘`-arrows (throw), described as "Rectangle-style muscle memory." But
**Rectangle USES `⌃⌥`-arrows as global hotkeys**, so they preempt Continuum and
these defaults silently don't fire when Rectangle is installed. They're also
exactly the "deep chord" the philosophy argues against.

**Fix (first post-compact task):** re-home tile move/throw per §2. Candidate
direction — move tile move/throw into the **nav-mode modal scope** (it's an
explicit mode, frontmost-only, so bare or single-modifier keys there can't
collide with global daemons), or a leader sequence; keep rebindable. Also
audit the resize presets (`⌘⌃`-digits) and any other default against the
known-conflicts list (note `⌃`-digits are macOS Spaces switching; verify
`⌘⌃`-digits are clear). Update the `TileActionCatalog` defaults +
`ShortcutCatalog` accordingly.

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

## 5. Immediate post-compact tasks (ordered)

1. **Fix the Rectangle conflict (§3):** re-home tile move/throw off `⌃⌥`-arrows;
   audit all defaults against the known-conflicts list.
2. **Focus-border config (§1):** enabled + color (+ gap/speed) `SettingsField`s
   + a resolver the overlay reads; keep it extensible.
3. **Grow the test suite (§4):** behavior assertions per binding + the
   conflict-guard check; adopt the "ship the assertion with the binding"
   convention.

## Key files
`TileActionCatalog.swift` (defaults — the Rectangle conflict) · `FocusDispatch.swift`
(resolution + inviolable set) · `ShortcutCatalog.swift` (catalog/guide) ·
`SettingsSchema.swift`/`SettingsField.swift` (settings) · `FocusBorderOverlayView`
in `CanvasNSView.swift` (border constants → config) · `NavKeymap.swift` (nav-mode
+ leader) · `ContinuumRevivedCoreChecks/main.swift` (the *Checks). Related:
docs/24 (settings), docs/27 (focus-scope), docs/28 (the completed queue),
memory `verification-doctrine`.
