# 86 — Multi-workspace sidebar filter

Started 2026-10-26. Bench: `.worktrees/workspace-filter`, branch
`array/workspace-filter` (from `aea42886`, 0.7.31).

## What Dylan approved

The sidebar's single scope dropdown becomes a checklist: pick any set of
workspaces whose agents the sidebar shows. Approved from the review sheet
(`--workspace-filter-sheet-check`, `qa-runs/workspace-filter-sheet/sheet.png`):

- Popover rows: pinned `This workspace` / `All agents` / `This Mac`, then one
  row per workspace (checkbox, colour dot, "N agents · K needs you", attention
  dot), then `Unplaced` (headless agents). Hover shows an `Only` pill and `…`.
  Toggling keeps the popover open. Option-click = Only.
- Hover peek: hovering a workspace row dims every other workspace's cards.
- With more than one workspace visible, each card gets a 3pt bar in its
  workspace colour at the sidebar's leading edge, and the button shows
  overlapping colour dots before its label.
- Labels: `This workspace`, `Array + Film`, `3 workspaces`, `All but Film`,
  `All agents`.
- Projects are NOT checkable (Dylan: "nah"). Workspaces get their own colour
  (Dylan: "yeah"). Clicking another workspace's agent switches workspace
  (Dylan: "yes") — already true for agents with a tile
  (`revealTileFromInbox`).

## Semantics

Include vs exclude is inferred from where you start. Unchecking from `All`
makes an EXCLUDE set (new workspaces appear). Checking from `This workspace`
makes an INCLUDE set (new workspaces stay hidden). `This workspace` is a live
member of an include set: it follows workspace switches. A workspace that is
in the set only because it is the current one shows a faint "following" check.

`.currentWorkspace` and `.all` keep their old storage values; every other set
is `workspaces:include:` / `workspaces:exclude:` plus tokens.

## Steps

1. Model (AgentUI `InboxWorkspaceFilter`, Core `WorkspaceEntry.colour`).
2. Shared component: `ChoiceListView` checklist presentation.
3. Sidebar integration, peek, marks, button dots, colour drill-in, host save.
4. Motion: survivors slide, label crossfade, peek fade. Film it.
5. Witness driving the real inbox, registered in the matrix.

## Status (2026-10-26, end of first session)

All five steps are built, uncommitted on `array/workspace-filter`.

- Model: `InboxWorkspaceFilter` + `InboxScopeMenu` (AgentUI), witnessed by
  `runInboxWorkspaceFilterChecks` (AgentUIChecks; teeth-tested by breaking the
  follow rule). `WorkspaceEntry.colour` / `resolvedColour` /
  `Registry.setWorkspaceColour` (Core), witnessed in CoreChecks beside rename.
- Component: `ChoiceListPresentation.checklist` — `ChoiceItem.check/swatch/
  trailing/attention/separatorBefore/keepsOpen/accessories`, in-place row
  refresh, `ChoicePopoverController.update(items:)`, `ChoiceButton.
  leadingSwatches` + title crossfade. A checklist panel FOLLOWS its trigger's
  resize (deferred a turn, left edge held) instead of dismissing on
  `anchorMoved` — the toggle resizes the trigger, and the old rule closed the
  popover on every click.
- Sidebar: `AgentInboxView` builds the checklist, peek (`setPeekAlpha` on cell
  CONTENTS — the cell's own opacity belongs to the row motion), edge marks
  (`AgentInbox96CellView.workspaceMarkColour`, only when the drawn list spans
  more than one workspace), colour drill-in behind `…`, host save in
  `setWorkspaceColour(workspaceId:colour:)`.
- Motion: `setScope` applies incrementally (`applyScopeIncrementally` — remove
  the rows that left, insert the arrivals, keep every surviving cell; a filter
  never reorders). Survivors slide as LIVE cells (`slideSurvivors`, a layer
  translation in the table's flipped space — filmed, the other sign rose into
  place); arrivals fade up and departures fade out through the existing row
  motion. Only departing rows are photographed.
- Perf, measured with `--film` (20 toggles after warm-up, load ~4): a toggle was
  ~45–50ms release before the incremental apply because every scope change
  rebuilt every card, and the first photographed reflow added ~30ms (half of a
  toggle was photographs). Now ~18–24ms release with or without motion; debug
  matches release, so what remains is AppKit layout of the arriving cells.
- Witness: `--workspace-filter-sheet-check` (in the matrix) drives the real
  popover through choose/accessory paths and writes the review sheet;
  `--film` adds window-server strips and a 20-toggle timing.

Existing checks updated on purpose: `--agent-inbox-check` (menu gains
`Unplaced`; workspaces now precede projects), `--sidebar-ux-check` and
`--workspace-management-polish-check` (the dash row became a real divider).

`--sidebar-screenshot-check` fails with a 0.63pt directory-icon offset at the
untouched release commit `aea42886` too (verified in a clean worktree) —
pre-existing, not this work.

Open: a workspace id left in a stored include set after the workspace is
deleted titles as "Workspace"; no pruning yet. The `--film` mode hung twice when
it was the first launch in a batch and never reproduced standalone; the plain
sheet check (the matrix leg) never hung.
