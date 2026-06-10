# Daily-Driver Backlog

Status: authored 2026-06-10 from a live exploration session (screenshots + AX
driving + code reading) on `main` @ `fdae439`, cross-referenced against
`docs/14-platform-bug-bash-backlog.md` and `docs/12-ux-exploration-backlog.md`.
This is the **ranked source of truth** for getting Continuum Revived to the
point where Dylan uses it daily instead of macOS Desktops.

How to use this doc (implementing agents):

- Tickets are `DD-NNN`. Work them top-down within a priority band unless a plan
  doc says otherwise. Three workstreams have dedicated implementation plans:
  - `docs/17-focus-input-routing-plan.md` — DD-001, DD-002, DD-003, DD-008
  - `docs/18-project-lifecycle-plan.md` — DD-005, DD-006, DD-013
  - `docs/19-launch-spawn-experience-plan.md` — DD-004, DD-007, DD-009, DD-010
- Branch from `main` (`feat/<ticket-or-workstream>`), one reviewed slice per
  ticket or coherent ticket group, merge back fast. Never commit to `main`
  directly except docs.
- Every slice must keep the full check matrix green (see
  `docs/15-repo-audit-2026-06-10.md` §5) and SHOULD add a deterministic
  self-check for the behavior it fixes. The matrix is the contract; if your fix
  can't be checked deterministically, say so explicitly in the PR/commit body.
- Reproduction notes below assume: build with `swift build`, launch with
  `CONTINUUM_PROJECT_ROOT=$(mktemp -d) CONTINUUM_APP_SUPPORT=$(mktemp -d)
  .build/debug/continuum-revived`.

Legend: **[P0]** blocks daily-driver adoption · **[P1]** painful but survivable
· **[P2]** quality/polish · **[F]** feature gap.

---

## P0 — input & focus (the systemic cluster)

These three tickets share one root cause: there is no central owner of "who has
keyboard focus and why." The focus-broker design already exists at
`docs/superpowers/specs/2026-05-09-focus-broker-design.md`. Implement them
together via `docs/17-focus-input-routing-plan.md`, not as three patches.

### DD-001 [P0] Cmd-K palette does not capture keyboard focus over a browser tile

- **Evidence (2026-06-10, live):** with a browser tile focused, Cmd-K opened
  the palette, but typed characters went into the WKWebView page (search field
  stayed empty, no filtering). Return then activated the palette's highlighted
  default row, spawning an unintended Shell terminal whose prompt contained the
  leaked keystrokes.
- **Repro:** spawn browser (empty-state button) → click page body → Cmd-K →
  type `note` → observe: search field empty, palette unfiltered; press Return →
  Shell tile spawns.
- **Suspected code:** `LaunchProfilePalette.show(near:profiles:)`
  (`Sources/ContinuumRevived/App/LaunchProfilePalette.swift`) makes the search
  field first responder once, but WKWebView re-claims or the makeFirstResponder
  silently fails when web content holds focus. Palette key handling relies on
  the field being first responder; there is no key-event interception while the
  palette is visible.
- **Acceptance:** with palette visible, ALL keystrokes route to the palette
  regardless of which tile was focused before; covered by a new
  `--palette-captures-keys-over-browser-check` (seed browser tile → focus web
  content → show palette → dispatch key events → assert search text updated and
  web view received nothing).

### DD-002 [P0] Clicking a note body does not focus its editor; typing is lost

- **Evidence (live):** clicked dead-center of a note tile's text area (AX
  geometry confirmed the point was inside), typed a sentence — nothing rendered,
  note `.md` on disk stayed empty. Forcing focus via Accessibility
  (`set focused of text area to true`) made typing work and persist, so the
  NSTextView is editable and styled correctly — the click→firstResponder path
  is what's broken.
- **Repro:** palette → New Note → click inside the note body → type → no text.
- **Suspected code:** interaction between `TileNSView.hitTest/mouseDown`
  (`Sources/ContinuumRevived/Canvas/TileNSView.swift:112-136`), the
  window-level `.leftMouseUp` bring-to-front monitor
  (`ContinuumApp.installTileFocusMonitor`), and `markActive` reordering. Caveat:
  repro used synthetic AX clicks; FIRST confirm with a human/manual click, then
  bisect (disable the mouseUp monitor; disable markActive; test raw NSTextView
  in a bare tile).
- **Acceptance:** click in note body → caret visible, typing renders and
  persists. New `--note-click-focus-check` (synthesize mouseDown/mouseUp via
  `NSApplication.sendEvent` on the note body → assert
  `window.firstResponder === noteView.textView`).

### DD-003 [P0] New Note (and other spawns) leave focus in the wrong place

- **Evidence (live):** spawning a note from the palette left first responder
  on the palette-restore target, not the new editor; typed text vanished.
  Handoff notes flagged this as known-unproven; now proven.
- **Design decision needed (documented in plan):** spawn-from-palette should
  focus the NEW tile's primary input (note editor, terminal surface, browser
  URL field for a blank browser) — palette focus-restore must yield when the
  selected action creates a focusable surface.
- **Acceptance:** New Note via palette → typing immediately lands in the
  editor. Extend `--note-file-tile-spawn-check` or add
  `--spawn-focus-policy-check` asserting firstResponder after each spawn kind.

### DD-008 [P0] Global Cmd-hotkeys steal browser/terminal-native shortcuts (docs/14 #15)

- Carried from docs/14 (still open, re-confirmed by reading
  `installHotkeyMonitor`): Cmd-1..4 fire app-wide even when a web form or
  terminal TUI needs them. Belongs to the same broker workstream: hotkey
  dispatch should consult focus context.
- **Acceptance:** Cmd-1..4 spawn only when no tile content claims the chord;
  typing Cmd-1 inside a focused web input does not spawn a terminal.

## P0 — first-run & lifecycle

### DD-005 [P0] Project root falls back to cwd — Finder/Dock launches are broken

- **Evidence (code):** `ContinuumApp.swift:1052-1062` — without
  `CONTINUUM_PROJECT_ROOT`, root = `FileManager.currentDirectoryPath`. From
  Finder/Dock that is `/`; from Xcode it's DerivedData. The app silently
  creates/reads `.continuum-revived/` wherever it woke up. This is almost
  certainly a contributor to "splash screen completely broken" reports —
  different launch contexts show different (empty/wrong) projects.
- **Fix direction:** see `docs/18-project-lifecycle-plan.md` — resolution order
  becomes: env override → registry last-opened (validated) → project picker.
- **Acceptance:** launching with no env and no registry shows a project picker
  (never silently uses cwd); `--project-root-resolution-check` covers the
  matrix of env/registry/no-state cases.

### DD-006 [P0] No single-instance guard — two instances corrupt shared state

- **Evidence (live):** ran two instances against the same project root
  simultaneously (Cmd-Q race during testing). Both write `canvas.json`,
  `notes/*`, sessions. AtomicWriter prevents torn files but not lost updates.
- **Acceptance:** second launch against a locked project either activates the
  existing instance (preferred; see plan) or refuses with a clear message.
  Covered by `--project-lock-check` (acquire lock, spawn child process
  attempting same root, assert refusal).

## P0 — spawn & destroy ergonomics

### DD-004 [P0] Cmd-K palette has no Browser entry

- **Evidence (code + live):** `LaunchPaletteAction`
  (`Sources/ContinuumRevivedCore/LaunchPaletteModel.swift:4-6`) has only
  newNote/openFile/openFileTree; screenshot confirms no browser row. Browser is
  reachable only via Cmd-3 or the empty-state button — Dylan hit this wall
  immediately.
- **Fix:** `newBrowser` action row (+ `Open URL…` variant accepting typed input
  — see `docs/19-launch-spawn-experience-plan.md`).
- **Acceptance:** palette lists "New Browser"; selecting it spawns a browser
  tile and focuses its URL field; `ContinuumRevivedPaletteChecks` extended to
  cover row presence/filter/selection; `--palette-browser-spawn-check`.

### DD-007 [P0] Delete confirmation defaults to Delete on Return

- **Evidence (live):** `deleteTile` (`ContinuumApp.swift:442-464`) adds
  "Delete" as the first (Return-default) NSAlert button. During palette
  testing a stray Return destroyed a live terminal. Destructive default +
  Return-key collision with palette/typing flows is a data-loss footgun.
- **Fix:** make Cancel the default (first button "Cancel" or set
  `alert.buttons[1].keyEquivalent = "\r"` appropriately; Delete reachable via
  Cmd-Delete or explicit click; consider `hasDestructiveAction`).
- **Acceptance:** Return on the confirm dialog cancels; deletion requires
  explicit affirmative action. Also investigate the one observed unconfirmed
  browser close (single occurrence, likely a queued modal interaction — verify
  confirm fires for browser kind under `.runtimes` policy).

### DD-009 [P0] New tiles spawn stacked on top of each other (docs/14 #13)

- **Evidence (live):** browser then terminal spawned overlapping at nearly the
  same default position. First-five-minutes experience reads as broken.
- **Fix direction:** spawn placement = "first free slot" scan in viewport space
  (see `docs/19`), not a fixed origin.
- **Acceptance:** spawning N tiles in a row yields non-overlapping frames while
  space allows; `--spawn-placement-check` asserts pairwise non-overlap for 4
  consecutive spawns.

## P1

### DD-010 [P1] Empty state is bare and does not orient the user

- Four unlabeled buttons centered on black; no app identity, no "⌘K" hint, no
  recent projects. Redesign specified in `docs/19`. (User-reported as "splash
  screen completely broken"; combined with DD-005 the first-run is genuinely
  disorienting.)

### DD-011 [P1] Persisted viewport/tile frames trusted without validation (docs/14 #14)

- A saved viewport far from all tiles renders a black void at launch — the
  other contributor to "broken splash." Sanitize at load: clamp zoom, recenter
  viewport to tile bounding box if disjoint. Acceptance:
  `--viewport-sanitize-check` seeding a pathological viewport.

### DD-012 [P1] Unbounded hotkey spawning (docs/14 #16)

- Holding Cmd-1 can spawn unlimited PTYs. Debounce/cap (e.g., refuse while a
  spawn from the same chord is <300ms old). `--spawn-rate-limit-check`.

### DD-013 [P1] App is not a real .app bundle

- No bundle id / Info.plist / icon: generic folder icon in alerts, binary name
  in menu bar, AND the documented
  `defaults write com.continuum.revived continuum.deleteConfirmPolicy …` knobs
  target a domain the unbundled binary never reads (defaults go to the
  process-name domain). Plan in `docs/18` (bundling section); distribution
  notes already in `docs/07` Phase 7.

### DD-014 [P1] Process owns 8 stray windows besides the main one

- **Evidence (live):** `CGWindowListCopyWindowInfo` shows four 1800×39 windows
  at (0,0) and four 1920×30 at (-1920,-504) owned by the process. Likely
  GhosttyKit artifacts (one per spawned surface?). Audit: reproduce with a
  single terminal spawn, count windows before/after; check GhosttyKit surface
  creation flags. Risk: Mission Control clutter, focus oddities, memory.

### DD-015 [P1] File-tree bugs from docs/14 (#9–#12, #20), now actionable

- #9 large-scan perf (O(n²) queue, no caps), #10 search hides matches under
  collapsed ancestors, #11 search lost on quick close, #12 missing sidecar
  silently restores wrong root, #20 git probe hang/memory. Treat as one
  file-tree hardening slice; #10 has the most user impact (search appears
  broken). BUG-010 from the old triage equals #10.

### DD-016 [P1] Retest UX-001/002/004 from docs/12 against current main

- UX-001 resize handles finicky (stash chrome reworked hit zones — partially
  addressed, needs manual verification), UX-002 default tile sizes/canvas
  scale, UX-004 terminal click-state after defocus. UX-003 (browser form
  typing) and UX-005 (file tile rendering) are believed fixed by the
  url-focus fix and FileTileNSView work — verify and close them in docs/12.

## P2

### DD-017 [P2] Default browser URL hardcoded to `http://localhost:3000/`

- `TileSpawner.spawnBrowser` default. Acceptable dev default, wrong product
  default. Make it a setting; blank-page + focused URL field is the better
  default UX (ties into DD-004's Open URL…). (P2 only because DD-004's URL
  field focus makes it survivable.)

### DD-018 [P2] Settings have no surface

- Delete-confirm policy, default URL, custom launch profile are
  UserDefaults/JSON-only. Minimal settings window or a `continuum://settings`
  palette section. Depends on DD-013 for a stable defaults domain.

### DD-019 [P2] Alert/dialog branding

- NSAlert shows the generic folder icon; menu bar says `continuum-revived`.
  Falls out of DD-013 (bundle + icon + proper app menu).

### DD-020 [P2] Scroll QA proves classification, not scrolling (docs/14 #17–#19)

- QA-harness hardening carried from docs/14: real scroll assertions, two-leg
  relaunch smoke (#19 partially exists now via browser-restore + note/file
  checks; audit and close what's covered), flow pass/fail semantics.

## Features

### DD-100 [F] Project switcher (THE daily-driver feature)

- Registry of projects exists in core (`RegistryStore`) with zero UI. Needed:
  switch project from palette (`Cmd-K → "project: <name>"` rows or Cmd-P),
  recent-projects in empty state, "Open Folder as Project…" (NSOpenPanel),
  window title showing active project. Detailed in `docs/18`.
- This replaces Dylan's per-project macOS Desktops — it is the core value
  proposition. Single window, swap canvas in place (per ADR-0003 one canvas
  per project).

### DD-101 [F] Open URL… palette action

- Type a URL directly into the palette → browser tile at that URL. With DD-004.

### DD-102 [F] Tile groups UI (data model exists), minimap, focus mode

- Deferred Phase-7 items from docs/05; revisit after P0/P1 land. Groups first —
  it amplifies the project-switcher workflow (e.g., "frontend" vs "backend"
  clusters on one canvas).

### DD-103 [F] tmux integration

- Spec exists: `docs/superpowers/specs/2026-05-09-tmux-integration.md`. Not
  scheduled; revisit when terminal workflows mature.

### DD-104 [F] Browser tile polish

- Spec exists: `docs/superpowers/specs/2026-05-09-browser-tile-polish.md`
  (loading states, favicons, title sync). Schedule after DD-004/DD-017.

---

## Verified-working (do not re-fix; protect with the matrix)

Tile chrome incl. close/overflow buttons · terminal delete-confirm flow ·
browser tiles (URL bar, nav, persistence, restore) · note persistence +
relaunch restore (position and content verified live) · z-index ordering and
bring-to-front focus preservation · palette duplicate-root + responder restore
self-checks · FilePreview pre-read size guard · file-tree spawn/boot
persistence · AX exposure of tiles and buttons (keep it — QA depends on it).

## Suggested sequencing

1. `docs/17` focus/input workstream (DD-001/002/003/008) — unblocks everything
   tactile.
2. `docs/19` spawn/destroy ergonomics (DD-004/007/009, fold in DD-017) — the
   palette becomes trustworthy.
3. `docs/18` project lifecycle (DD-005/006, then DD-100, then DD-013) — the
   daily-driver unlock.
4. DD-010/011 first-run polish; then P1 tail and features.
