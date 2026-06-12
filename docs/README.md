# continuum-revived Docs

For current onboarding, start at the repository root:

- [../README.md](../README.md) - 5-minute product, setup, build, verification, bundle, QA, and canonical-link orientation.
- [../CONTRIBUTING.md](../CONTRIBUTING.md) - current Linear workflow and evidence/reviewer rules for humans and agents.

This folder contains both current contracts and historical planning material. Treat `docs/20-product-vision.md` and `docs/21-agent-workflow.md` as current; early phase plans are useful context but may describe already-completed or superseded implementation paths.

## Historical Phase 0 planning

These docs capture product reverse-engineering, architecture, storage design, UX rules, risk management, and phased implementation planning from before app scaffolding. Read in order when you need background:

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

## Current contracts and later working docs

For implementing agents picking up current work, use Linear as the backlog source of truth and start with these references:

- `20-product-vision.md` - current product north star and conflict resolver.
- `21-agent-workflow.md` - binding Linear/ticket workflow and honesty rules.
- `22-linear-master-overnight-workflow.md` - coordinator/reviewer workflow.
- `15-repo-audit-2026-06-10.md` - historical repo audit; useful for context, but verify any branch/workflow facts against current root docs and Linear.
- `16-daily-driver-backlog.md` - historical DD backlog snapshot; not the current source of truth while Linear is active.
- `17-focus-input-routing-plan.md` - implementation plan: focus broker, palette key capture, click-to-focus, spawn focus.
- `18-project-lifecycle-plan.md` - implementation plan: project root resolution, single-instance lock, project switcher, .app bundle.
- `19-launch-spawn-experience-plan.md` - implementation plan: delete-confirm default, palette browser/URL actions, spawn placement, empty state.
- `10`-`14` - QA harness, agent platform plan, UX backlog, observability loop, platform bug backlog.

