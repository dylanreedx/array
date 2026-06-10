# Project Lifecycle — Implementation Plan

Tickets: DD-005 (root resolution), DD-006 (single instance), DD-100 (project
switcher), DD-013 (app bundle — final phase).
Authored: 2026-06-10 against `main` @ `fdae439`.

This workstream turns "a binary that opens whatever directory it woke up in"
into "an app that knows its projects." It is the daily-driver unlock: Dylan's
goal is to stop dedicating a macOS Desktop per project; that requires fast,
trustworthy switching between registered projects inside one window.

## Current state (read before coding)

- Root resolution: `ContinuumApp.swift` `resolveProjectRoot(smokeTest:)`
  (~line 1052): env `CONTINUUM_PROJECT_ROOT` → smoke temp dir → **cwd
  fallback** (the DD-005 bug; from Finder cwd is `/`).
- Registry: `Sources/ContinuumRevivedCore/` has `RegistryStore` with a
  central `registry.json` under Application Support (see
  `docs/03-data-model-and-storage.md` §registry). It records known projects
  but nothing reads it at boot and there is no UI.
- One window, one canvas, per ADR-0003. Project switch = swap the canvas and
  all runtimes in place (the heavy part of Phase C below).
- `windowWillClose` already implements ordered teardown (flush saves → mark
  descriptors → terminate browser → terminate terminal → engine shutdown);
  ADR-0018 documents the ordering. Project switch must reuse this path, not
  reinvent it.

## Phase A — root resolution + project lock (DD-005, DD-006)

Branch `feat/project-lifecycle`. One commit per lettered phase.

### A1. Resolution order

New behavior in `resolveProjectRoot` (extract into a testable
`ProjectRootResolver` in Core; keep the AppKit-free part pure):

1. `CONTINUUM_PROJECT_ROOT` env (unchanged — QA depends on it).
2. Smoke-test temp dir (unchanged).
3. Registry `lastOpenedProjectId` → its recorded path, IF the path still
   exists AND contains-or-can-create `.continuum-revived/`.
4. Otherwise: NO root. Boot reaches the picker (A3) instead of loading a
   project. **Never cwd.**

Registry model change (`RegistryStore`): add `lastOpenedProjectId: UUID?` and
`lastOpenedAt: Date` per project entry. Bump handled by the existing
schema-version gate (ADR-0012 future-version rules apply — additive field, no
version bump needed if decoding tolerates absence; verify with a round-trip
test in CoreChecks).

CoreChecks additions: resolver table tests — env wins; missing-path registry
entry skipped; empty registry → `.needsPicker`.

### A2. Single-instance lock

Mechanism: `O_EXLCK`-style lock via `flock(2)` on
`.continuum-revived/lock` (open + `flock(LOCK_EX|LOCK_NB)`). Holds for app
lifetime; OS releases on crash (no stale-lock cleanup needed — this is why
flock beats a pid file).

- Acquire in `applicationDidFinishLaunching` immediately after root
  resolution, before any store reads.
- On failure: NSAlert "This project is already open in another Continuum
  window." with [Open Anyway (read-only is NOT offered — too complex), Quit,
  Choose Another Project]. "Open Anyway" exists because flock can't tell a
  same-user second window from a genuinely stuck process the user understands
  better than we do; document the risk in the alert body.
- New check `--project-lock-check`: acquire lock on a temp root, `fork/exec`
  a helper invocation (`continuum-revived --project-lock-probe <root>` that
  exits 0 if it COULD acquire, 1 if locked), assert child sees locked; release;
  assert child sees unlocked.

### A3. Minimal picker (unblocks A1's "no root" branch)

Not the full switcher — a modal panel at boot when resolution yields nothing:
- List registry projects (name + path, most-recent first).
- "Open Folder…" → NSOpenPanel → registers the folder in the registry and
  opens it.
- Selecting a project sets `lastOpenedProjectId` and proceeds with the normal
  boot path.
Implementation: simple NSPanel + NSTableView in
`Sources/ContinuumRevived/App/ProjectPickerPanel.swift`; reuse the palette's
visual language (dark, monospaced).

Manual verification (cannot be a deterministic check — NSOpenPanel): record a
manual test transcript in the PR. Deterministic part:
`--project-picker-resolution-check` exercises resolver → `.needsPicker` and
picker-model selection logic (extract list/sort/select into a pure model
`ProjectPickerModel` in Core, test that).

## Phase B — registry hygiene

- Write-through: every successful boot upserts {id, name (folder basename),
  path, lastOpenedAt} and sets `lastOpenedProjectId`.
- Prune: entries whose path no longer exists are marked `missing: true` (not
  silently dropped); picker renders them dimmed with "locate…" (re-pick path
  via NSOpenPanel) — keeps user data recoverable after a volume unmount.
- CoreChecks: upsert/prune round-trips.

## Phase C — in-app project switching (DD-100 core)

The hard part: tearing down project A's runtimes and booting project B without
quitting. Reuse, do not duplicate, the `windowWillClose` teardown and the
boot-loop install path.

### C1. Extract `closeProject()` and `openProject(root:)`

Refactor `applicationDidFinishLaunching`'s project-boot body (store loads,
canvas creation, boot-loop tile install, save-debounce wiring — the big block
starting ~line 180) into `openProject(root: URL)`; refactor
`windowWillClose`'s teardown body into `closeProject()` minus the
window/app-termination specifics. This refactor must be behavior-neutral:
full matrix green with zero check changes before C2 starts. (Reviewer: treat
any check diff in C1 as a defect.)

Trap inventory for the extraction (each currently lives in AppDelegate state
and must reset between projects): `runtimes`, `browserRuntimes`, `noteViews`,
`fileTreeViews`, debounce timers (canvas/browser/note/fileTree saves — cancel
and flush on close), hotkey/scroll/magnify/mouseUp monitors (keep — they're
window-scoped not project-scoped), `tileSpawner`, `profilePalette` (rebuild;
its rows cache profile resolution), focus broker registrations (unregister
all tile surfaces; keep canvas? No — canvas is recreated: unregister all),
GhosttyKit app instance (KEEP alive across switches — engine init is
expensive and global; only surfaces die), browser engine context (per-project
storage isolation — check `BrowserEngineContext` ownership of the website
data store; if it's project-scoped, recreate it).

### C2. Switch entry points

- Palette: project rows. `LaunchPaletteModel` gains a `switchProject(UUID)`
  action kind; rows sourced from the registry (most recent 5 + filter on
  type-ahead, prefixed "project:" or shown in a section — model-level concern,
  keep `LaunchPaletteModel` pure and unit-tested in PaletteChecks).
- `Cmd-O` → picker panel (same panel as A3, now invocable any time).
- Window title: `"<project name> — Continuum"` (today it's the process name;
  trivial, do it here).
- Switch sequence: `closeProject()` → lock release(A) → resolve/lock(B) →
  `openProject(B)` → broker recovery focus to canvas.

### C3. Checks

- `--project-switch-check`: temp roots A and B; seed a note tile in A and a
  browser snapshot in B (reuse smoke seeding helpers); boot A → assert A's
  note installed → invoke switch to B programmatically → assert A's
  runtimes/views are gone (`runtimes.isEmpty`, note view deallocated — weak
  ref probe), B's tiles installed, lock A released (probe acquires), lock B
  held, registry `lastOpenedProjectId == B`.
- Relaunch leg: after switch, persistence files of A intact (note body
  unchanged on disk) — guards against teardown clobbering the previous
  project's state.

## Phase D — .app bundle (DD-013)

Last because everything above works unbundled, and bundling changes paths.

- SwiftPM stays the build system; add `scripts/make-app-bundle.sh` that
  assembles `ContinuumRevived.app/Contents/{MacOS,Resources,Info.plist}` from
  the release build + `GhosttyKit.xcframework` slices, per the distribution
  notes already in `docs/07-phased-build-plan.md` Phase 7.
- Info.plist: `CFBundleIdentifier = com.continuum.revived` (this makes the
  documented `defaults write com.continuum.revived …` knobs actually work —
  today they target a dead domain), `LSMinimumSystemVersion`, icon.
- Icon: placeholder monochrome glyph is fine; add `Resources/AppIcon.icns`.
- App menu: proper main menu (About/Quit/Edit-copy-paste — note views need
  the Edit menu for Cmd-C/V to work when bundled; verify cut/copy/paste in
  notes and the URL field post-bundle).
- Verify: smoke test still passes when run FROM the bundle binary
  (`ContinuumRevived.app/Contents/MacOS/continuum-revived`), defaults knob
  round-trips (`defaults write com.continuum.revived
  continuum.deleteConfirmPolicy never` → close a terminal tile → no confirm).
- DD-014 (stray strip windows) checkpoint: while in here, count
  CGWindowList-owned windows after one terminal spawn and file a finding with
  whatever the audit shows (suspected GhosttyKit per-surface artifacts).

## Sequencing & dependencies

A (resolution+lock+min-picker) → B (registry hygiene) → C (switching) → D
(bundle). A alone fixes the two P0s and is independently shippable. C depends
on the focus-broker workstream's teardown hooks (docs/17 Phase 6) only
loosely — coordinate: if 17 hasn't landed, C uses the existing direct focus
calls and leaves `// broker:` markers.

## Acceptance (workstream exit)

Launching from Finder with no env opens the last project or the picker —
never `/` · second instance on the same project is refused/redirected ·
switch between two registered projects in <2s without quitting, with A's
state intact on disk and B's restored · registry survives missing paths ·
(Phase D) bundled .app passes the smoke test and the defaults domain works ·
new checks `--project-lock-check`, `--project-switch-check`,
resolver/picker-model CoreChecks in the matrix.
