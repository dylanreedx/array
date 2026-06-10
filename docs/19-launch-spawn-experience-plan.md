# Launch & Spawn Experience — Implementation Plan

Tickets: DD-004 (palette browser row), DD-007 (delete-confirm default),
DD-009 (spawn placement), DD-010 (empty state), DD-017 (default URL),
DD-101 (Open URL…).
Authored: 2026-06-10 against `main` @ `fdae439`.

Theme: the first five minutes. Every ticket here is something Dylan hit in
his first session. Smaller, mostly independent fixes — good warm-up slices
before or alongside `docs/17`. Branch `feat/spawn-experience`; each numbered
section below is one reviewed commit unless noted.

## 1. DD-007 — delete confirmation must not destroy on Return

File: `Sources/ContinuumRevived/App/ContinuumApp.swift` `deleteTile`
(~442-464).

Change the NSAlert so Cancel is the Return-default and Delete is explicit:

```swift
alert.addButton(withTitle: "Cancel")          // first → Return default
let del = alert.addButton(withTitle: "Delete")
del.hasDestructiveAction = true
del.keyEquivalent = ""                        // click or arrow+space only
if alert.runModal() != .alertSecondButtonReturn { return }
```

Also assign Escape to Cancel (`buttons[0].keyEquivalent = "\u{1b}"` is
implicit for Cancel-titled buttons — verify, don't assume).

Deterministic check is impractical for `runModal`; instead extract the
decision into `DeleteConfirmPolicy` (it already owns policy) — add
`alertConfiguration(for kind:) -> (message: String, informative: String,
destructiveIndex: Int, defaultIsCancel: Bool)` and unit-test THAT in
CoreChecks; the AppKit layer just renders it. Manual verification: close a
terminal tile, press Return → tile survives; click Delete → tile dies.

While here, chase the one observed unconfirmed browser close (docs/16
DD-007 note): add a `fputs` audit line on every `deleteTile` entry/exit with
kind + confirmed/skipped (kept permanently — cheap and diagnostic) and
manually close a browser tile to verify the confirm appears.

## 2. DD-004 + DD-101 + DD-017 — palette browser actions & default URL

Files: `Sources/ContinuumRevivedCore/LaunchPaletteModel.swift`,
`Sources/ContinuumRevived/App/LaunchProfilePalette.swift`,
`Sources/ContinuumRevived/App/ContinuumApp.swift` (`performPaletteAction`),
`Sources/ContinuumRevived/App/TileSpawner.swift` (`spawnBrowser`).

Model (pure, test in PaletteChecks):
- `LaunchPaletteAction` gains `case newBrowser` and
  `case openURL(String)`.
- Row building: "New Browser" appears with the other action rows.
  `openURL` is a DYNAMIC row: when the current search text parses as a URL
  or domain-ish token (`example.com`, `localhost:3000`, `https://…`), append
  a row `Open "<text>"…`. Parser lives in the model:
  `LaunchPaletteModel.urlCandidate(from query: String) -> String?` —
  normalize scheme (`https://` default; keep `http://` for localhost/IPs).
  Unit-test the table: `"example.com"` → `https://example.com`,
  `"localhost:3000"` → `http://localhost:3000`, `"note"` → nil,
  `"  "` → nil, `"https://a.b/c?d"` passthrough.
- Selection routing in `performPaletteAction`: `.newBrowser` →
  `spawnBrowser(url: defaultURL)`, `.openURL(let u)` → `spawnBrowser(url: u)`.

Default URL (DD-017): `TileSpawner.spawnBrowser` currently hardcodes
`http://localhost:3000/`. Change default to `about:blank`; with the focus
workstream landed, a blank spawn focuses the URL field (docs/17 Phase 4
already specifies this split: blank → URL field, with-URL → content). Make
the old behavior reachable: read `continuum.defaultBrowserURL` from
UserDefaults (same pattern as `DeleteConfirmPolicy`, including the
documented-domain caveat until DD-013 lands — document the working
`defaults write` incantation for the UNBUNDLED binary in the code comment:
domain `continuum-revived`).

Checks: extend `ContinuumRevivedPaletteChecks` for rows/filter/urlCandidate;
new `--palette-browser-spawn-check`: drive the palette model selection seam →
assert a browser tile + runtime exist and (if docs/17 landed) URL field is
firstResponder for the blank case.

## 3. DD-009 — spawn placement (stop stacking tiles)

Files: `Sources/ContinuumRevivedCore/CanvasEngine.swift` (pure logic),
`Sources/ContinuumRevived/App/TileSpawner.swift` (call site).

Pure function in CanvasEngine (unit-testable, no AppKit):

```swift
/// First-fit placement: scan candidate origins inside the visible viewport
/// (row-major, 32pt grid step) for the first rect of `size` that does not
/// intersect any existing tile frame inflated by 16pt margin. Falls back to
/// cascade (+24,+24 from last tile) when the viewport is saturated.
static func placementFrame(
    size: CGSize,
    viewport: CanvasViewport,
    visibleSize: CGSize,
    existing: [TileFrame]
) -> TileFrame
```

CoreChecks table: empty canvas → centered-ish first slot; one tile at slot 1
→ second placement does not intersect; saturated viewport → cascade offsets
applied and result stays within ±1 viewport of visible area; determinism
(same inputs → same frame).

Wire: every `TileSpawner.spawn*` that currently uses a fixed default origin
calls `placementFrame` with the live viewport from `canvasView` (TileSpawner
already holds canvasView). Boot-restore paths DO NOT re-place (persisted
frames are authoritative).

Check: `--spawn-placement-check` — spawn 4 tiles via spawner seams, assert
pairwise non-intersection of their frames.

## 4. DD-010 — empty state redesign

File: `Sources/ContinuumRevived/Canvas/CanvasEmptyStateNSView.swift` (rework
in place; keep the `CanvasEmptyStateActions` seam — `ContinuumApp` wiring
unchanged or minimally extended).

Content (top to bottom, centered column, max width ~420pt):
1. Wordmark line: `CONTINUUM` — monospaced 22pt semibold, white 0.85, with
   the active project name under it (13pt, white 0.5): `~/code/myproject`.
   (Project name needs a new optional `projectName/projectPath` property set
   from ContinuumApp at configure time.)
2. Primary hint, the single most important line:
   `⌘K  open the command palette` rendered prominently (15pt, white 0.8,
   with ⌘K in a bordered keycap-style box — NSAttributedString or a small
   keycap NSView, keep it simple).
3. The four existing action buttons, relabeled with their shortcuts:
   `New Claude Terminal ⌘1` · `New Shell ⌘2` · `New Browser ⌘3` ·
   `Open in Editor ⌘4` (match actual hotkey mapping in
   `installHotkeyMonitor` — VERIFY the numbers against the code, do not
   trust this doc).
4. Footer (11pt, white 0.35): `notes, files, and projects live in ⌘K`.

Visual: keep the tool-surface aesthetic (docs/05 §visual design): no colors,
no imagery, generous spacing (24pt between groups). No layout constants in
ContinuumApp — all inside the view.

Recent-projects rows are NOT in scope here — they belong to the picker/
switcher (docs/18 A3/C2); add a TODO comment referencing docs/18.

Verification: manual screenshot review (this is a visual change; attach
before/after to the PR). Deterministic: extend smoke `empty-canvas` flow
assertion that the empty state view exists with ≥4 buttons and the keycap
hint string — `--empty-canvas` QA flow already boots an empty project
(reuse `CanvasEmptyStateNSView` accessibility: set
`setAccessibilityIdentifier("ContinuumEmptyState")` and assert from the
flow/check).

## 5. Sweep commit — docs

Update `docs/12-ux-exploration-backlog.md` (close UX-003/005 if the
DD-016 retest confirms; annotate UX-001/002/004 with current status),
`docs/14` rank rows for #13 (fixed here) and #15/#16 pointers to docs/17,
and tick the corresponding DD rows in `docs/16-daily-driver-backlog.md`.

## Order & dependencies

1 (delete default — 30 min, do first, it's a data-loss bug) → 3 (placement —
pure-logic heavy, no UI risk) → 2 (palette browser/url — coordinates with
docs/17 Phase 4 on focus behavior; if 17 unlanded, spawn focuses nothing and
that's acceptable, leave a `// broker:` marker) → 4 (empty state — visual,
independent) → 5 (docs sweep).

## Acceptance (workstream exit)

Return on a delete confirm never destroys · "New Browser" and `Open
"<url>"…` work from ⌘K with sane URL normalization · four consecutive spawns
don't overlap · empty state communicates identity + ⌘K + shortcuts (screenshot
reviewed) · default browser spawn is no longer hardcoded localhost:3000 ·
new checks (`--palette-browser-spawn-check`, `--spawn-placement-check`,
placement/url-candidate CoreChecks/PaletteChecks) green in the matrix.
