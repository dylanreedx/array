# 0.7.21 — overnight fix list (2026-09-21)

Dylan listed seven items before bed and asked for a release prepared for his
review through an isolated preview build. He says "go" in the morning if it
passes. **Nothing is published until he does.**

Shipped state at start: 0.7.20 build 71. This candidate is **0.7.21 build 72**.

Work was done on `array/0721-nightly`, merged from five benches off
`array/integration` at `2cec73ff`.

## The seven items

| # | Request | Status |
|---|---|---|
| 1 | Can't delete a workspace | Fixed — `array/0721-wsdelete` |
| 2 | Zone close "Delete Tiles" doesn't delete the tiles | Fixed — this bench |
| 3 | Claude should offer explicit model ids, not "latest" | Done — `array/0721-models` |
| 4 | Remove Anthropic options from Pi | Done — `array/0721-models` |
| 5 | Transcript line height too tight | Done — carried from `array/0721-transcript` |
| 6 | Agent tile selects truncate with space available | Fixed — `array/0721-selects` |
| 7 | Subagent nesting in the sidebar reads ambiguously | Redesigned — `array/0721-subagents` |

## What each one actually was

**1 — workspace delete.** Six of seven candidate failure modes were reachable.
The two that produce the reported symptom: the top bar's Delete button kept
`NSButton.isEnabled`'s default `true` before its first successful model load,
while `buildWorkspaceTopBarModel()` threw whenever the current workspace's
`canvas.json` was unreadable and `reloadWorkspaceTopBar()` only logged it — so
`currentWorkspaceId` stayed nil, the button looked live, and the click fell out
of a bare guard, permanently. Separately the registry was saved BEFORE
`switchWorkspace`, so a throw there reported "Delete workspace failed" over a
workspace already gone from `registry.json`, skipping `deleteDocument()`. The
delete is now atomic: everything that can fail runs before the commit. The
last-workspace rule is kept but now explains itself instead of silently greying
out.

**Finding worth keeping:** `--workspace-management-polish-check`, the existing
witness for the entire delete path, **was never a matrix leg**. Neither was
`--workspace-switch-polish-check`. That is why these survived. Both are
registered now.

**2 — zone delete tiles.** `closeZone` computed its member list from the flat
`canvasState.tiles`, which is empty for a hydrated zone because its tiles live
in a `ZoneLayer`. `memberIds` was empty, the delete loop never ran, nothing was
deleted. Hazard 9, one model further out. Members now route through
`deleteTile(id:)` — the same path the tile's own close button uses — so runtime
teardown happens exactly once. `deleteTile`'s own lookup also had to widen from
`projectTiles()` (ACTIVE zone only) to `allWorkspaceTiles()`. Deleted tiles now
leave the WorkspaceDocument through a real removal instead of
`setTiles([], forZone:)`, which is a membership write that only clears `zoneId`
and kept every deleted tile to rehydrate as ambient.

**The existing witness was green through all of it** because its fixture was
built from `CanvasState(tiles:)` — the flat model production does not use here.
It gained a layer-backed leg with a positive control.

**3/4 — models.** Claude now offers 11 explicit ids, newest first, no aliases
and no "latest" in any label: opus-5, fable-5-1, fable-5, sonnet-5, opus-4-8,
opus-4-7, opus-4-6, sonnet-4-6, opus-4-5, sonnet-4-5, haiku-4-5. Ids are
verbatim from the installed CLIs, per non-negotiable #5. The `claude --help`
alias scrape is deleted rather than mapped, so the live path can no longer
reintroduce an alias. `AgentModelConfig.defaultModel` is now
`anthropic/claude-opus-5`. Pi excludes anthropic through a named
`PiCatalogPolicy` applied at production's only writer of pi's live options.
Records already persisted on an anthropic Pi model are grandfathered and still
run; Array simply stopped offering that choice.

**Finding worth keeping:** the existing model checks were registered in
CoreChecks *past* the seed-1 pin that exits, so **they had never run in a real
matrix run.** The new policy section is registered near the top.

**5 — line height.** Body prose carried no paragraph style at all, so leading
was AppKit's default for 13pt text. It now has an explicit 18pt pitch that
scales with page zoom. Renderer-local, so `Metrics` reservation arithmetic is
untouched and code blocks and command output keep their own measurement.

**6 — selects.** Measured RED before any change: a popover row needed 179.0pt
and was drawn in 174.5pt inside a 218.0pt panel. The panel sized itself with
50pt of chrome while its rows lay out with 54pt, so it was 4–10pt too narrow
for its own titles at every width. Also real: `rebuildChoices()` never marked
needs-layout, so a catalogue refresh installed longer titles without re-running
the fit decision. Not real: the trigger's `+4pt` cell-padding guess — the cell
inset measures ~0.008pt, and the trigger drew clean at every zoom before any
change.

Same defect family, found by the gate and fixed here: the compact status row's
phase label was given 44.5pt for 45.0pt of text on a 1200pt row.
`--ui-geometry-check` carried that red and **was not in `MATRIX_KNOWN_RED`**, so
the gate had a real failing leg nobody owned.

**7 — subagent nesting.** The inbox is a flat table that draws a hierarchy, and
nesting was expressed ONLY by a 16pt leading inset on otherwise identical
unfilled cards. Nothing closed a group, so the next top-level agent read as a
child. It keeps the flat table; `InboxSort` emits a pre-order walk, so one
lookahead at the next row's depth answers every grouping question. Adds a tree
connector in the indent gutters, moves the disclosure triangle out of the text
column (clearance to a deeper title went from 2.0pt to at least 8pt), gives the
last row of a group room below it, and indents the "N more" remainder row,
which was pinned flat at the leading edge.

## Known gaps, for the morning

- **UI baselines legitimately move** (`chrome.sidebar*`, `chrome.agentInbox*`):
  triangle x, new connector ink, taller group-end rows. **No baseline was
  regenerated and `CONTINUUM_UPDATE_BASELINES` was never set.** That is a human
  decision.
- **Expand/collapse animation not done**, deliberately: a fold changes the row
  count and the list drops every index on a shape change, and the cheap alpha
  fade would make rows invisible to several checks that read alphas on a runloop
  a self-check never spins.
- **Nobody has looked at pixels.** Whether the 0.5pt hairline reads in Dark Aqua
  at 220pt, whether 4pt is the right group-end room, and whether the 4–10pt
  popover shortfall is *the* thing in the screenshots — all need eyes.
- **CoreChecks' arm64 seed-1 byte pin** remains the documented KNOWN-RED.
- Unreviewed 0.7.21 work in `array/0721-naming`, `array/0721-drag-overlay` and
  `array/0721-transcript` was deliberately NOT folded in, so the review surface
  is exactly these seven items. Patch B of the transcript bench (the line pitch)
  was carried over; its Patch A (a Component Lab state chooser) was not.
