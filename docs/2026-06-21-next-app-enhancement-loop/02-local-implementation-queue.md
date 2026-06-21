# Local implementation queue — inspector and workspace UX

Status: active queue for autonomous loop

Rules:
- Work one item per iteration.
- Commit exactly one logical unit per completed item.
- Update this queue item from `[ ]` to `[x]` only after implementation, artifact, and checks pass.
- Write a run audit note for each item under the overnight run directory if available.
- Prefer product-path evidence over pure core checks.
- If an item is blocked by product ambiguity or WebKit/private API limits, stop that item with a precise handoff and move only if safe.
- Do not implement arbitrary JS eval, source editing, generic connected tiles, or Safari private Web Inspector embedding.

## Inspector epic

- [x] I01 — Browser Inspector Tile shell and persistence
  Source ticket: `T01-browser-inspector-tile-shell.md`.
  Required output: inspector tile linked to browser tile, auto-deletes when browser tile is deleted, persisted relationship/panel, artifact.

- [x] I02 — Browser Inspector DOM tree snapshot and element highlight
  Source ticket: `T02-browser-inspector-dom-tree.md`.
  Required output: real WKWebView DOM snapshot, bounded tree, selected element temporary highlight, artifact.

- [x] I03 — Browser Inspector console log bridge
  Source ticket: `T03-browser-inspector-console.md`.
  Required output: display-only console logs from real WKWebView message handler, no eval, artifact.

- [x] I04 — Browser Inspector computed styles panel
  Source ticket: `T04-browser-inspector-styles.md`.
  Required output: selected-node computed style whitelist, read-only, artifact.

- [x] I05 — Browser Inspector Network-lite log
  Source ticket: `T05-browser-inspector-network-lite.md`.
  Required output: honest navigation/download/child-open event log; no fake HTTP methods/status; artifact.

- [x] I06 — Inspector/browser link lifecycle
  Source ticket: `T06-browser-inspector-link-lifecycle.md`.
  Required output: duplicate prevention, reveal browser, delete lifecycle, restart-preserved link, artifact.

- [ ] I07 — Palette/menu actions for in-app inspector
  Source ticket: `T07-browser-inspector-action-palette.md`.
  Required output: discoverable browser inspector actions and settings copy, artifact.

## Workspace UX epic

- [ ] W01 — Workspace sidebar shell
  Source ticket: `W01-workspace-sidebar-shell.md`.
  Required output: persistent left dock, all workspaces visible, current expanded, width/visibility persistence, artifact.

- [ ] W02 — Sidebar row actions
  Source ticket: `W02-workspace-sidebar-row-actions.md`.
  Required output: row click switch/focus/reveal using existing navigation paths, artifact.

- [ ] W03 — Sidebar live updates and agent status glyphs
  Source ticket: `W03-workspace-sidebar-live-status.md`.
  Required output: tile/zone/workspace updates and existing status rollups in sidebar, artifact.

- [ ] W04 — Workspace top bar/current identity
  Source ticket: `W04-workspace-top-bar.md`.
  Required output: top workspace identity/counts/save-state-if-real/actions, artifact.

- [ ] W05 — Workspace create/rename/delete polish
  Source ticket: `W05-workspace-create-rename-delete-polish.md`.
  Required output: create/rename/delete UX with validation/confirmation/last-workspace protection, artifact.

- [ ] W06 — Workspace switch transition and restore polish
  Source ticket: `W06-workspace-switch-transition-restore.md`.
  Required output: save departing viewport/focus, restore target viewport/focus/fallback, transition label, artifact.

- [ ] W07 — Workspace overview/search command
  Source ticket: `W07-workspace-overview-search.md`.
  Required output: palette overview rows for workspace/zone/tile using sidebar action path, artifact.

## Final audits

- [ ] F01 — Inspector final audit and dogfood recommendation
  Source ticket: `T10-final-audit-and-dogfood.md`.
  Required output: keep/fix/revert recommendation for I01–I07 with artifacts and manual gaps.

- [ ] F02 — Workspace UX final audit and dogfood recommendation
  Source ticket: `W08-workspace-final-audit-dogfood.md`.
  Required output: keep/fix/revert recommendation for W01–W07 with artifacts and manual gaps.
