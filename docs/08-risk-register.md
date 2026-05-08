# Risk Register

## Risk Levels

- High: could block MVP or cause major rework.
- Medium: could slow implementation or create user-visible quality issues.
- Low: manageable with standard testing and iteration.

## Ghostty Embedding

Level: High.

Risk:

Ghostty/libghostty may be difficult to embed cleanly in a custom Swift/AppKit tile surface.

Why it matters:

Terminal quality is the heart of the product. A weak terminal breaks Claude, Codex, Neovim, shells, and the whole reason to use the app.

Mitigation:

- Phase 1 spike before broad scaffolding.
- Adapter boundary around Ghostty.
- Read local `ghostty-src`.
- Record outcome as a decision.
- Pause if MVP terminal requirements fail.

Trigger:

- Cannot spawn/render/input/resize/close a shell reliably.

Response:

- Stop broad app work and solve terminal integration.

## Focus Ownership

Level: High.

Risk:

Terminal and browser surfaces trap keyboard focus or app shortcuts stop working.

Why it matters:

Continuum already exposed this class of issue. Users will abandon the app if command palette, project switching, or escape/recovery randomly fails.

Mitigation:

- Build FocusBroker early.
- Explicit active surface model.
- First responder recovery tests.
- Reserved shortcut policy.
- Browser/terminal adapters participate in focus transitions.

Trigger:

- User cannot reliably leave terminal/browser with keyboard.
- App shortcuts depend on accidental view focus.

Response:

- Treat as architecture bug, not polish.

## Canvas Performance

Level: High.

Risk:

The canvas becomes janky with many live terminal/browser surfaces.

Why it matters:

The product promise is overview. If zoom/pan is slow, users go back to terminal tabs.

Mitigation:

- CanvasEngine owns spatial index.
- Minimal reactive invalidation.
- Measure 20 live tiles and 100 descriptor tiles.
- Defer minimap/fancy rendering until core performance is known.
- Consider offscreen surface throttling after MVP.

Trigger:

- Pan/zoom frame drops with realistic projects.

Response:

- Profile before adding new visual features.

## Persistence Corruption

Level: High.

Risk:

Canvas/session state corrupts or disappears, especially under iCloud sync.

Why it matters:

Restore is a core value loop. Losing layout destroys trust.

Mitigation:

- Atomic writes.
- Parse-before-replace.
- Rolling backups.
- Migration tests.
- Corruption recovery UI.
- Coalesced writes.

Trigger:

- App launch cannot parse project state.
- User loses layout after relaunch.

Response:

- Restore newest valid backup; preserve corrupt file for diagnostics.

## Browser Process Behavior

Level: Medium.

Risk:

WKWebView crash, storage, focus, or navigation behavior differs from assumptions.

Why it matters:

Browser tiles are part of the coding loop, especially local preview.

Mitigation:

- BrowserEngine boundary.
- Per-project storage model.
- Navigation error UI.
- Focus tests.
- Avoid automation until normal browsing is stable.

Trigger:

- Browser traps focus.
- Browser loses URL state.
- Localhost workflows are unreliable.

Response:

- Fix BrowserEngine before adding element picker/automation.

## Project-Local State Conflicts

Level: Medium.

Risk:

Hidden app folder inside projects conflicts with git, collaborators, or cleanup tools.

Why it matters:

Project-local storage is intentional, but not every project should commit app state.

Mitigation:

- Create folder only after user opens/adds project.
- Offer `.gitignore` suggestion.
- Store human-readable files.
- Keep central registry separate.
- Allow project state folder relocation later if necessary.

Trigger:

- User accidentally commits `.continuum-revived/`.

Response:

- Add onboarding prompt and `.gitignore` helper.

## iCloud Quirks

Level: Medium.

Risk:

The target personal directory is under iCloud Drive. Sync/eviction/file coordination may affect state files.

Why it matters:

The new app directory and many personal projects live there.

Mitigation:

- Atomic writes.
- Backups.
- Coalesced writes.
- Detect unavailable files.
- Avoid large scrollback persistence.
- Consider NSFileCoordinator if needed.

Trigger:

- State files vanish, duplicate, or become temporarily unavailable.

Response:

- Show recovery message and avoid overwriting unknown state.

## Native App Scope

Level: Medium.

Risk:

Building native macOS, Ghostty, canvas, browser, profiles, and persistence is large.

Why it matters:

The request is ambitious; phase boundaries prevent sprawl.

Mitigation:

- Hard Ghostty gate.
- No agent-to-agent MVP.
- No native editor MVP.
- No browser automation MVP.
- Each phase has exit criteria.

Trigger:

- Implementation adds features from Phase 8 before Phase 4 works.

Response:

- Stop and return to phased plan.

## Native Code Editor Temptation

Level: Medium.

Risk:

Building a custom editor consumes months and still disappoints Neovim/Cursor/VS Code users.

Why it matters:

The product should orchestrate coding, not replace mature editors first.

Mitigation:

- Neovim profile.
- External editor handoff.
- Native editor deferred.

Trigger:

- MVP tasks include syntax editor/LSP/vim mode work.

Response:

- Move to post-MVP spec unless user explicitly changes product strategy.

## Agent Status Inference

Level: Low to Medium.

Risk:

Trying to infer "working/idle/needs input" from terminal output creates misleading states.

Why it matters:

Wrong agent status is worse than simple running/exited status.

Mitigation:

- MVP statuses are configuring/running/exited/error.
- Best-effort richer statuses only after logs and patterns are observed.

Trigger:

- UI claims agent is done while it is not.

Response:

- Remove or downgrade status inference.

## Public Product Reverse Engineering

Level: Low.

Risk:

Overfitting to Maestri/Nyx public language instead of our own workflow.

Why it matters:

We want our own customizable app, not a clone.

Mitigation:

- Use competitors to classify value, not define implementation.
- Favor our chosen constraints: native macOS, Ghostty, project-local state, project spaces.

Trigger:

- A feature is justified only because a competitor has it.

Response:

- Ask whether it strengthens the MVP value loop.

