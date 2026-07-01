# Dock toggle keybind & width persistence

## What this delivers

After this ticket, the workspace sidebar dock has a real, conflict-guarded keyboard
shortcut that can be invoked from anywhere in the app, and its width and visibility are
correctly persisted across launches. The keybind is user-configurable through the
Keybindings section of Settings: it appears as a named row, and a built-in conflict check
refuses to let a user or developer accidentally land it on a known system or daemon chord.
A first-run user sees the dock visible at 280 pt; after dragging the divider to 340 pt and
quitting, they come back to exactly 340 pt. Pressing the toggle keybind collapses it;
pressing it again restores it at 340 pt.

## How it fits

The sidebar dock itself — the `WorkspaceSidebarView` rendered in an `NSSplitView` — is
already built and already wired to `WorkspaceSidebarConfig` for both its visible state and
its width. `WorkspaceSidebarConfig.resolveVisible`, `resolveWidth`, `setVisible`, and
`setWidth` are all live at `Sources/ContinuumRevivedCore/WorkspaceSidebarConfig.swift:12–33`.
`splitViewDidResizeSubviews` already calls `setWidth` when the divider moves
(`ContinuumApp.swift:4598–4604`), and `applyWorkspaceSidebarVisibility` reads `resolveWidth`
when re-showing the pane (`ContinuumApp.swift:4567–4577`). The toggle action is already
declared in `CommandRegistry` under the id `"view.toggleWorkspaceSidebar"` and in
`LaunchPaletteAction` as `.toggleWorkspaceSidebar`, and the menu item already calls
`toggleWorkspaceSidebarFromMenu` — but the menu item has an empty `keyEquivalent` (line
2064), so the only way to trigger the toggle today is through the palette or the menu. No
keyboard shortcut is registered, no chord appears in `ShortcutCatalog`, and no conflict
check covers it.

This ticket closes that gap. It unblocks the live-status wiring ticket (which renders real
observer data in the dock) by ensuring the dock has stable, trustworthy show/hide semantics
before any live data flows through it.

## The approach

Assign the sidebar toggle the chord `⌘⇧S` (Command-Shift-S, key code 1 with `.command`
and `.shift` modifiers). This chord is clear of all entries in `KnownChordConflicts.all`
and clear of every existing Continuum global and nav-mode binding — verified by the
conflict-check harness that already runs in `ContinuumRevivedCoreChecks`.

The chord is wired as an app-level `NSMenuItem` keyboard equivalent (updating the existing
menu item's `keyEquivalent` and `keyEquivalentModifierMask`) rather than as a
`ReservedShortcut` in `FocusModel`, because the sidebar toggle is a view command (not a
navigation or focus primitive) and is scoped to the app's key-event chain, not the tile
focus model. It lives alongside the existing palette, settings, and focus-mode reserved
shortcuts in the "global" layer of `ShortcutCatalog`, listed as non-configurable in this
phase (the rebind infrastructure for global-layer commands beyond the nav leader is a future
phase; the catalog row is present and truthful).

`WorkspaceSidebarConfig` needs no changes: its keys, defaults, clamping, and read/write
API are already correct and complete.

Two entries are added to `SettingsSchema.sections()`, inside a new `"activity"` section
that will grow as the dock gains live-status wiring. For now, two fields:

- A `.toggle` bound to `WorkspaceSidebarConfig.visibleKey` / default `true`, labelled
  "Show Activity Dock".
- A `.text` bound to `WorkspaceSidebarConfig.widthKey` / default `"280"`, labelled
  "Activity Dock Width (pt)".

The conflict check in `ContinuumRevivedCoreChecks` is extended to audit the new default
chord against `KnownChordConflicts.all`, just like the existing reserved-global and
tile-action audits.

## Where it lives

**`Sources/ContinuumRevivedCore/WorkspaceSidebarConfig.swift`** — no changes needed;
`visibleKey`, `widthKey`, `defaultVisible`, `defaultWidth`, `minWidth`, `maxWidth`,
`resolveVisible`, `setVisible`, `resolveWidth`, `setWidth`, `clampedWidth` are all present
and correct (lines 1–33).

**`Sources/ContinuumRevivedCore/ShortcutCatalog.swift`** — `globalEntries(navKeymap:)`
(line 62): add one `ShortcutCatalogEntry` for the sidebar toggle after the existing
entries. The entry's `chordDisplay` is the static string `"⌘⇧S"`, `configurable` is
`false`, `editTarget` is `nil`. This makes the row appear in the Keybindings settings Guide
alongside the other globals.

**`Sources/ContinuumRevivedCore/SettingsSchema.swift`** — `sections()` (line 12): append a
new `SettingsSection` with `id: "activity"`, `title: "Activity"`,
`iconSystemName: "sidebar.left"`, containing the two fields described above.

**`Sources/ContinuumRevived/App/ContinuumApp.swift`** — three surgical edits:

1. `buildViewMenu` (around line 2064): change the `NSMenuItem` for "Show Workspace Sidebar"
   to set `keyEquivalent: "S"` and `keyEquivalentModifierMask: [.command, .shift]`. This
   is the live dispatch path — the OS routes `⌘⇧S` through the menu item to
   `toggleWorkspaceSidebarFromMenu`, which already calls `toggleWorkspaceSidebar`.

2. `buildViewMenuExpectations` (around line 2102): update the matching assertion to expect
   `keyEquivalent: "S"` so the menu self-check stays green.

3. No changes to `toggleWorkspaceSidebar`, `setWorkspaceSidebarVisible`,
   `applyWorkspaceSidebarVisibility`, `splitViewDidResizeSubviews`, or
   `makeWorkspaceContentView` — the full toggle-and-persist logic is already correct.

**`Sources/ContinuumRevivedCoreChecks/main.swift`** — inside the
`KeybindConflictChecks: defaults avoid known system / daemon chords` block (around line
3437): add the sidebar chord `KeyChord(keyCode: 1, modifiers: [.command, .shift])` to the
audited list with label `"global.toggleWorkspaceSidebar"`.

## Implementation breadcrumbs

```swift
// ShortcutCatalog.swift — globalEntries(navKeymap:), after the leader entry
entries.append(ShortcutCatalogEntry(
    id: "global.toggleWorkspaceSidebar",
    label: "Show Activity Dock",
    chordDisplay: "⌘⇧S",
    layer: .global,
    configurable: false
))
```

```swift
// SettingsSchema.swift — append inside sections() after the last existing SettingsSection
SettingsSection(
    id: "activity",
    title: "Activity",
    iconSystemName: "sidebar.left",
    fields: [
        .toggle(
            key: WorkspaceSidebarConfig.visibleKey,
            label: "Show Activity Dock",
            default: WorkspaceSidebarConfig.defaultVisible
        ),
        .text(
            key: WorkspaceSidebarConfig.widthKey,
            label: "Activity Dock Width (pt)",
            default: String(Int(WorkspaceSidebarConfig.defaultWidth))
        ),
    ]
)
```

```swift
// ContinuumApp.swift — buildViewMenu, updating the existing NSMenuItem
let sidebarItem = NSMenuItem(
    title: "Show Workspace Sidebar",
    action: #selector(AppDelegate.toggleWorkspaceSidebarFromMenu(_:)),
    keyEquivalent: "S"           // was ""
)
sidebarItem.keyEquivalentModifierMask = [.command, .shift]
viewMenu.addItem(sidebarItem)
```

```swift
// ContinuumRevivedCoreChecks/main.swift — KeybindConflictChecks block, appended
auditNoKnownConflict(
    KeyChord(keyCode: 1, modifiers: [.command, .shift]),
    "global.toggleWorkspaceSidebar"
)
// Positive anchor: confirm ⌘⇧S is clear (regression guard)
expect(
    KnownChordConflicts.conflict(for: KeyChord(keyCode: 1, modifiers: [.command, .shift])) == nil,
    "sidebar toggle ⌘⇧S must be free of known conflicts"
)
```

The `intra-scope uniqueness` check that already runs in `ContinuumRevivedCoreChecks` (line
3462) will automatically catch any future collision with another global-layer entry, since
it iterates `ShortcutCatalog.entries()` — no additional work needed there.

## How we test it

### Logic (pure Core checks)

In `ContinuumRevivedCoreChecks`:

1. **Conflict audit passes.** The existing `auditNoKnownConflict` loop now covers the
   sidebar chord. The test fails the build if `KnownChordConflicts.conflict(for:
   KeyChord(keyCode: 1, modifiers: [.command, .shift]))` is non-nil.

2. **Catalog entry is present and unique.** The existing intra-scope uniqueness check
   (`assertUniqueChords` over the global layer) will fail if any other global entry claims
   `"⌘⇧S"`. A targeted assertion also confirms the new entry exists: `ShortcutCatalog
   .entries().contains { $0.id == "global.toggleWorkspaceSidebar" }`.

3. **Config round-trips correctly.** Using an isolated `UserDefaults` suite (pattern
   already used by `KeybindConflictChecks`):
   - Empty defaults → `resolveVisible()` returns `true`; `resolveWidth()` returns `280.0`.
   - `setVisible(false)` → `resolveVisible()` returns `false`.
   - `setWidth(350)` → `resolveWidth()` returns `350.0` (within clamp); `setWidth(100)`
     → `resolveWidth()` returns `220.0` (clamp floor); `setWidth(500)` → `resolveWidth()`
     returns `420.0` (clamp ceiling).
   These are pure calls with no AppKit dependencies — they belong in
   `ContinuumRevivedCoreChecks` alongside the existing `FocusBorderConfigChecks`.

4. **Settings schema contains the activity section.** Assert
   `SettingsSchema.sections().contains { $0.id == "activity" }` and that its fields
   include entries with keys `WorkspaceSidebarConfig.visibleKey` and
   `WorkspaceSidebarConfig.widthKey`.

### Backend (real-path integration)

Extend the existing `runWorkspaceSidebarActionsSelfCheck` (or add a sibling check wired
under `--sidebar-toggle-check`) to drive the real toggle path:

1. Construct the sidebar and split view as the self-check already does (the check already
   builds an `AppDelegate`-like harness with a real `NSSplitView`).
2. Call `setWorkspaceSidebarVisible(true)` and assert `sidebar.isHidden == false` and
   `splitView.position(ofDividerAt: 0)` is within ±1 pt of `resolveWidth()`.
3. Call `setWorkspaceSidebarVisible(false)` and assert `sidebar.isHidden == true` and
   position is 0.
4. Set width to 340 via `WorkspaceSidebarConfig.setWidth(340)`, call
   `setWorkspaceSidebarVisible(true)`, and assert the split position is within ±1 pt of
   340.
5. Simulate a divider drag by calling `splitViewDidResizeSubviews` with a notification
   whose object is the split view after manually setting `sidebar.frame.size.width = 360`,
   and assert `resolveWidth()` returns `360.0`.

Write the measured values to a manifest at `qa-runs/<timestamp>/sidebar-toggle/manifest.json`
containing `visibleAfterShow`, `positionAfterShow`, `visibleAfterHide`, `positionAfterHide`,
`widthAfterDividerMove` — never just `{passed: true}`.

### UX (visual gate + dogfood snippet)

**Visual gate.** Add a `ComponentLab` entry (alongside the existing self-check cards in
`ComponentLab.runSelfCheck()`) that renders the `WorkspaceSidebarView` in a 280×600 pt
frame over an opaque dark backdrop, calls `cacheDisplay`, and asserts
`!VisualSnapshot.metrics(of: view).isBlank`. The sidebar is pure AppKit (an
`NSOutlineView` source-list), so `cacheDisplay` composites it correctly. Write the PNG to
`qa-runs/<timestamp>/sidebar-toggle/sidebar-view.png`.

**Dogfood snippet.** Open the app. The Activity Dock is visible on the left. Press
`⌘⇧S` — the dock collapses instantly and the canvas fills the window. Press `⌘⇧S`
again — the dock returns at exactly the width it had before (default 280 pt on a fresh
install). Drag the divider to roughly 340 pt — the width HUD (if enabled) shows ~340;
release the drag. Quit the app and relaunch. Open the app again — the dock is visible and
its divider sits at 340 pt. Open Settings (`⌘,`) → navigate to the "Activity" section →
toggle "Show Activity Dock" off → the dock collapses. Toggle it back on. Change "Activity
Dock Width (pt)" to `320` → quit and relaunch → dock opens at 320 pt.

## Execution mode

**Supervised.** The logic and backend checks are fully automatable and will pass without
human eyes, but the final acceptance criterion is the dogfood snippet above: a human must
confirm that `⌘⇧S` dispatches correctly in a running app, that the divider position
survives a quit-relaunch cycle, and that the Settings entry drives real layout. The
visual gate confirms the sidebar renders non-blank AppKit content, but it cannot confirm
that the divider animation is smooth or that the correct width is restored — those require
a real-app run.

## Done when

- [ ] Pressing `⌘⇧S` in a running app toggles the Activity Dock (collapses if visible,
  restores if hidden) without any other effect.
- [ ] The width set by dragging the divider is restored exactly (within 1 pt) on the next
  launch, including after a quit triggered immediately after dragging.
- [ ] `WorkspaceSidebarConfig.resolveWidth()` clamps any persisted value to
  `[220, 420]` — confirmed by the Core round-trip check.
- [ ] `ShortcutCatalog.entries()` contains an entry with `id == "global.toggleWorkspaceSidebar"`
  and `chordDisplay == "⌘⇧S"`, and the intra-scope uniqueness check is green.
- [ ] The `KeybindConflictChecks` block in `ContinuumRevivedCoreChecks` covers `⌘⇧S` and
  passes (no collision with known system or daemon chords).
- [ ] Settings → Activity section is present, renders both fields, and writing to "Activity
  Dock Width (pt)" changes `resolveWidth()` on the next call (round-trip confirmed by
  the Core check; live effect confirmed by dogfood).
- [ ] The `ComponentLab` visual gate for the sidebar view writes a non-blank PNG.
- [ ] The real-path backend check writes a manifest with all five measured fields and
  passes without any `{passed:true}` shortcut.
- [ ] The menu self-check (`buildViewMenuExpectations`) is green with `keyEquivalent: "S"`.

## Depends on / unblocks

This ticket depends only on the dock itself being rendered — `WorkspaceSidebarView`,
the `NSSplitView` layout, and `WorkspaceSidebarConfig` are all already present and
correct. No upstream ticket from the distributed-canvas arc is a prerequisite.

It unblocks the live-status wiring ticket (which connects real observer data to the
sidebar tree) by giving that ticket a stable, well-tested toggle contract to build on top
of. Without a conflict-guarded keybind and reliable width restoration, the live-status
work would be shipping onto a shaky foundation.

## Watch out for

**The most dangerous failure mode: restoring width onto a hidden divider.** When the dock
is hidden, `applyWorkspaceSidebarVisibility` sets the divider position to 0.
`splitViewDidResizeSubviews` fires during that programmatic move and calls `setWidth(0)`,
which `clampedWidth` would floor to `220` — corrupting the stored width. The existing code
guards this correctly at `ContinuumApp.swift:4598–4603` with `guard !sidebar.isHidden`,
but confirm this guard holds after your changes. The real-path check step 5 (simulate a
divider drag while visible) is the regression anchor; also add a negative check that
calling `setWorkspaceSidebarVisible(false)` does *not* change `resolveWidth()`.

**Chord key code.** Key code `1` is the `S` key on a standard QWERTY layout. Verify in
`KnownChordConflicts.all` that no existing entry uses key code 1 with any modifier
combination that could be confused with `[.command, .shift]`. The conflict check will
catch this at build time, but double-check by reading the existing entries before landing.

**Menu `keyEquivalent` case-sensitivity.** `NSMenuItem.keyEquivalent` is case-sensitive:
an uppercase `"S"` with no `.shift` in the mask is different from lowercase `"s"` with
`.shift`. The correct combination for `⌘⇧S` is `keyEquivalent: "S"` (uppercase literal)
with `keyEquivalentModifierMask: [.command, .shift]`. Using lowercase `"s"` with
`.shift` in the mask will display and function differently on some macOS versions. Follow
the uppercase-literal pattern.

**Settings text field for width writes a string, not a Double.** `SettingsField.text`
stores to `UserDefaults` as a `String`. `WorkspaceSidebarConfig.resolveWidth` reads via
`defaults.double(forKey:)`, which returns 0 for a string that doesn't parse as a number.
`clampedWidth(0)` floors to 220 rather than crashing, so the failure mode is silent
width corruption rather than a crash — but the Core round-trip check should assert that a
text-field value of `"320"` round-trips to `320.0` via `resolveWidth`.
