# Phased Build Plan

## Goal

Build `continuum-revived` in phases that each prove a real product risk and produce a working slice. Do not scaffold broad UI before Ghostty terminal viability is proven.

## Phase 0: Product Deconstruction

Status: documentation phase.

Goal:

Understand the value loops of Maestri, Nyx, and Continuum so the new app builds the right thing first.

Deliverables:

- `docs/00-product-reverse-engineering.md`
- `docs/01-mvp-value-loop.md`
- `docs/02-architecture.md`
- `docs/03-data-model-and-storage.md`
- `docs/04-terminal-ghostty-plan.md`
- `docs/05-canvas-and-ux.md`
- `docs/06-browser-code-file-surfaces.md`
- `docs/07-phased-build-plan.md`
- `docs/08-risk-register.md`
- `docs/09-decisions.md`

Exit criteria:

- Docs identify core value, workflow multipliers, differentiators, and scope traps.
- MVP loop is clear.
- Ghostty gate is explicit.
- Storage model is decision-complete.
- Implementation can begin without asking what app to build.

## Phase 1: Native Skeleton And Ghostty Spike

Goal:

Prove that a native Swift macOS app can host a Ghostty-backed terminal tile that is good enough for the product foundation.

Deliverables:

- Swift app project.
- Basic app window.
- Minimal app shell.
- One host view for terminal surface.
- `TerminalEngine` adapter boundary.
- Ghostty/libghostty integration spike.
- One shell profile.
- Spawn/resize/input/output/close proof.

Implementation notes:

- Keep UI ugly and minimal.
- Do not build project browser, canvas polish, browser tiles, notes, or settings yet.
- Read local `ghostty-src` if needed.
- Treat this phase as a product kill-switch: if terminal quality is wrong, stop.

Tests:

- Manual terminal spawn test.
- Manual keyboard input test.
- Manual resize test.
- Manual close/cleanup test.
- Small automated tests around launch profile command resolution if possible.

Exit criteria:

- Shell runs in Ghostty surface.
- Terminal renders correctly.
- Keyboard input works.
- Resize works.
- Process exit is observed.
- Surface cleanup does not crash.
- Decision recorded in `docs/09-decisions.md`.

## Phase 2: Project Spaces And Persistence

Goal:

Build the workspace/project foundation and project-local persistence before broad surface work.

Deliverables:

- Domain models.
- Central registry.
- Project-local `.continuum-revived/` folder.
- `project.json`.
- `canvas.json`.
- `sessions/*.json`.
- Atomic write helper.
- Backup restore helper.
- Migration shell.
- Basic project switcher.

Implementation notes:

- One project equals one canvas.
- Central registry indexes projects but does not own project canvas truth.
- Process descriptors are persisted; live handles are not.
- Use coalesced writes for canvas changes.

Tests:

- Registry round trip.
- Project creation writes expected files.
- Canvas round trip.
- Session descriptor round trip.
- Atomic write preserves previous file on failure.
- Backup restore chooses newest valid backup.
- Unknown future schema version does not silently overwrite.

Exit criteria:

- Create project.
- Relaunch app.
- Project appears in switcher.
- Empty canvas restores.
- Terminal descriptor persists even if process is not resumed.

## Phase 3: Canvas MVP

Goal:

Build the freeform project canvas enough to arrange real work surfaces.

Deliverables:

- Canvas coordinate system.
- Viewport pan/zoom.
- Tile insertion.
- Tile selection.
- Drag.
- Resize.
- Z-order.
- Basic groups.
- Persisted viewport/tile frames.
- Context menu or command palette add flow.

Implementation notes:

- CanvasEngine owns geometry and hit testing.
- Runtime surfaces are hosted inside tile frames through adapters.
- Keep spatial index outside reactive UI state.
- Avoid grid-only layouts.

Tests:

- Coordinate conversion.
- Zoom around point.
- Hit testing.
- Drag frame updates.
- Resize clamps minimum sizes.
- Z-order persists.
- Group bounds.
- Restore tile frames after relaunch.

Exit criteria:

- User can place at least three descriptor tiles.
- User can pan/zoom smoothly.
- User can drag/resize tiles.
- Layout persists across relaunch.
- Active tile visual state is clear.

## Phase 4: Launch Profiles And Daily Terminal Flow

Goal:

Make the app useful for real agent/coding terminal workflows.

Deliverables:

- Built-in launch profiles.
- Tool detection.
- Profile picker.
- Spawn terminal tile from profile.
- Per-project cwd defaults.
- Missing command UI.
- Restart exited session.
- Tile title/status.
- Basic settings for profile overrides.

Built-in profiles:

- Shell.
- Claude Code.
- Codex Review.
- Neovim.
- Custom Command.

Detection:

- `claude`
- `codex`
- `nvim`
- `cursor`
- `code`
- `zed`
- `xed`

Tests:

- Detect available command.
- Missing command marks profile unavailable.
- Profile resolves cwd to project root.
- Terminal tile stores launch profile metadata.
- Exited session can restart from descriptor.

Exit criteria:

- User can run Claude, Codex, shell, and Neovim if installed.
- Missing tools are clear, not broken.
- Layout and descriptors restore.
- Restart works for exited sessions.

## Phase 5: Native Browser Tiles

Goal:

Add browser previews as first-class canvas surfaces for local development.

Deliverables:

- `BrowserEngine`.
- WKWebView tile hosting.
- URL bar.
- Back/forward/reload.
- Loading state.
- Navigation error state.
- URL/title persistence.
- Browser focus integration.
- Localhost-friendly defaults.

Implementation notes:

- Browser surfaces are native views with explicit focus ownership.
- Automation and element picker are deferred.
- Model supports future storage groups.

Tests:

- Create browser tile.
- Navigate to URL.
- Persist URL.
- Restore descriptor.
- Focus browser then command palette.
- URL field Escape reverts.

Exit criteria:

- Browser tile can show local dev server.
- Browser tile can be arranged on canvas.
- URL restores on relaunch.
- Browser does not trap app shortcuts.

## Phase 6: Files, Notes, And Editor Handoff

Goal:

Add context surfaces that make the canvas feel like a project workspace rather than terminal wallpaper.

Deliverables:

- Preferred external editor setting.
- Open project in editor command.
- File tree tile.
- Async file scanning.
- Markdown note tile.
- Notes stored as `.md`.
- Dropped external note references if practical.

Implementation notes:

- File scanning must be backgrounded.
- Avoid indexing huge dependency folders by default.
- Native code editor is deferred.
- Notes are plain files, not database rows.

Tests:

- Editor command detection.
- Open project command builds expected process invocation.
- File tree ignores heavy folders.
- File tree scan does not block UI.
- Note creates markdown file.
- Note tile persists path/frame.

Exit criteria:

- User can open project in preferred editor.
- User can view project files without freezing.
- User can create a markdown note on canvas.
- File/note state restores.

## Phase 7: Polish Toward Daily Driver

Goal:

Harden the app until it can be used daily on real work.

Deliverables:

- Command palette.
- Better project switcher.
- Focus recovery.
- First responder tests.
- Crash/session recovery UI.
- Settings polish.
- Profile editor.
- Empty states.
- Performance tuning.
- Visual polish.

Tests:

- Repeated focus transitions.
- Repeated quit/relaunch.
- 20 live tiles.
- 100 descriptor tiles.
- Browser/terminal mixed focus.
- Project switching under load.

Exit criteria:

- Stable enough for daily use.
- No known data-loss bugs.
- No recurring focus traps.
- Performance acceptable with realistic projects.

## Phase 8: Post-MVP Differentiators

Goal:

Build distinctive agent-orchestration features only after the core workspace is stable.

Candidate work:

- Agent-to-agent PTY ask bus.
- Browser element picker to agent.
- Diff/review tile.
- Focus mode.
- Activity lenses/floors.
- Minimap.
- Routines.
- On-device companion.
- SSH/remote profiles.
- Portal automation CLI.

Rules:

- Each differentiator gets its own spec.
- Do not backfill product risk into MVP.
- Do not implement agent-to-agent messaging before launch profiles and session lifecycle are reliable.

## Suggested Commit Rhythm

Once implementation starts:

- Commit docs first.
- Commit project skeleton separately.
- Commit Ghostty spike separately.
- Commit domain models separately.
- Commit persistence separately.
- Commit canvas interactions in small slices.
- Commit each launch profile feature separately.
- Commit browser tile after navigation and focus tests pass.

## Implementation Readiness Checklist

Before app scaffolding:

- Docs are reviewed.
- Ghostty source/API path is inspected.
- Bundle ID/name chosen.
- Minimum macOS version chosen.
- Swift package/project style chosen.
- Test target strategy chosen.
- User confirms no Tauri/React reuse except conceptual lessons.

