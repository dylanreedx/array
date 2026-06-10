# continuum-revived Docs

This folder is Phase 0 for `continuum-revived`: product reverse-engineering, architecture, storage design, UX rules, risk management, and phased implementation planning before app scaffolding.

Read in order:

1. `00-product-reverse-engineering.md` - what Maestri, Nyx, and Continuum teach us.
2. `01-mvp-value-loop.md` - the fastest useful daily-driver loop.
3. `02-architecture.md` - native macOS subsystem boundaries.
4. `03-data-model-and-storage.md` - project-local storage and central registry.
5. `04-terminal-ghostty-plan.md` - Ghostty integration strategy and hard gate.
6. `05-canvas-and-ux.md` - Project Spaces, canvas behavior, groups, and UX rules.
7. `06-browser-code-file-surfaces.md` - WKWebView, Neovim, editors, file tree, notes.
8. `07-phased-build-plan.md` - implementation phases and exit criteria.
9. `08-risk-register.md` - known risks and mitigations.
10. `09-decisions.md` - append-only ADR-style decision log.

Core decision: build a native macOS app with Ghostty-backed terminal tiles, WKWebView browser tiles, project-local state, and Project Spaces navigation. Agent-to-agent messaging waits until the core loop is reliable.

## Working docs (post-Phase-6)

For implementing agents picking up current work, start here instead:

- `15-repo-audit-2026-06-10.md` - repo/branch rules and the verification matrix every change must keep green.
- `16-daily-driver-backlog.md` - **the ranked ticket list (DD-NNN)**; source of truth for what to work on.
- `17-focus-input-routing-plan.md` - implementation plan: focus broker, palette key capture, click-to-focus, spawn focus.
- `18-project-lifecycle-plan.md` - implementation plan: project root resolution, single-instance lock, project switcher, .app bundle.
- `19-launch-spawn-experience-plan.md` - implementation plan: delete-confirm default, palette browser/URL actions, spawn placement, empty state.
- `10`-`14` - QA harness, agent platform plan, UX backlog, observability loop, platform bug backlog (cross-referenced from 16).

