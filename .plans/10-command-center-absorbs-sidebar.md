# ⌘K absorbs the sidebar, then the sidebar goes

Snapshot: 2026-08-11, `array/integration` after 0.4.3 + Codex rehydration.

Goal: one floating command center, no persistent sidebar. The sidebar cannot
simply be deleted — it is the only surface for two capabilities, and one of
them strands data.

## Why this is not a delete

`workspaceSidebarView?.agentInbox` — the agent inbox is a CHILD of
`WorkspaceSidebarView`, and History lives inside the inbox. Removing the
sidebar removes the live agent list AND History.

Capability audit (sidebar vs ⌘K today):

| Sidebar can | ⌘K |
|---|---|
| navigate workspaces/projects/zones | ✅ `switchWorkspace`, `switchProject`, `jumpToZone` |
| rename workspace | ✅ `renameWorkspace` |
| delete workspace | ✅ `deleteWorkspace` |
| create workspace | ✅ `LaunchPaletteAction.newWorkspace` — "Workspace / Create a spatial workspace", Create category, default-visible. (An earlier pass reported this missing by grepping `createWorkspace`; the action is named `newWorkspace`.) |
| live agent list / Needs You | ⚠️ only agents that still have a canvas tile |
| **History (closed agents)** | ❌ structurally impossible |

The blocker: ⌘K's agent rows come from
`jumpTiles: canvas.navigationTileSnapshots()` (ContinuumApp.swift:4322) —
tiles ON THE CANVAS. A closed agent has no tile; that is what closing does.
So deleting the sidebar today means: close a tile → the agent parks into
History → History no longer exists and ⌘K cannot see it → the agent, its
transcript and its worktree are unreachable forever. That is strictly worse
than the 0.4.0 bug where a tile-less agent had an unclickable sidebar row.

## Reuse points (already exist — do not re-derive)

- **The History rule.** `InboxSort.InboxSection.history` in
  `Sources/ContinuumRevivedAgentUI/InboxSort.swift` — "Closed agents, behind a
  counted header of their own — the tile is gone but the record, the transcript
  and the worktree are not, so opening one brings the agent back". Section is
  derived from the row's lifecycle at `now`. Feed the palette from THIS, so the
  palette and the inbox cannot disagree about what History means.
- **Reopen.** `agentSupervisor.reopen(agentID:)`, ContinuumApp.swift:7837,
  under the comment "Out of History: reopening a closed agent is asking for it
  back". Already witnessed: a check asserts reopening gives the agent a tile
  again and does not mint a second record.
- **Create workspace.** `createWorkspaceFromChrome()`, already wired to
  `sidebar.onCreateWorkspace`.

## Steps

1. **History in ⌘K.**
   - Core: `HistoryAgentRow` (agent id, display name, model/subtitle, ended-at);
     `LaunchPaletteRow.historyAgent(_)`; `CommandCenterCategory.history =
     "History"`, ordered LAST (it is the block you go looking for, never one
     that displaces a row you did not ask for — same reasoning as the inbox's
     collapsed header).
   - App: build the rows from inbox rows whose `InboxSection == .history`; pass
     through `makeRows`/`palette.show`.
   - Dispatch `.historyAgent` → `reopen(agentID:)` then focus the new tile,
     mirroring ContinuumApp.swift:7833-7837.
   - Verify: `--command-center-check` covers presentation/search/ordering and
     that a closed agent is reachable; an app leg proves reopening FROM ⌘K
     yields a tile and does not mint a second record.
2. ~~Create Workspace in ⌘K.~~ Already shipped as
   `LaunchPaletteAction.newWorkspace`. Nothing to do.
3. **Remove the sidebar.** Drop `splitView.addSubview(sidebar)`, the
   `WorkspaceSidebarView` mount, View ▸ Show Workspace Sidebar (⌘S), and the
   visibility plumbing. Re-home `agentInbox` or retire it with History+Needs You
   now in ⌘K.
   - Two existing witnesses assert the sidebar exists and must be retired
     DELIBERATELY, not deleted quietly:
     `--workspace-sidebar-default-visible-check` (ContinuumApp.swift:1486) and
     the "workspace sidebar toggle should be command-palette discoverable"
     assertion (~:8447). Also `sidebarRollups`, `visibleDisplayNamesForQA`, and
     the ui-probe census entry for `WorkspaceSidebarView`.
   - Verify: full matrix, and `--ui-probe-check` (removing a `TokenThemed`
     owner changes the census as surely as adding one).

## BLOCKER found while starting step 3 (2026-08-11)

Step 1 shipped History (`.archived`) — but `.archived` is not the only
tile-less lifecycle, so step 3 is NOT yet safe.

`AgentInventory` unions "`AgentRecord`-backed agents, tiled or headless", and
`AgentInboxRowBuilder.title(for:)` states the locked decision outright:
"`displayName` belongs to the `AgentRecord` and survives the tile being closed
(the agent is the entity), so a headless agent still has a name."

So an agent can have NO TILE without being closed:

| lifecycle | has a tile? | reachable in ⌘K today |
|---|---|---|
| `.archived` (History) | no | ✅ shipped in step 1 |
| `.active`, headless | no | ❌ not in `jumpTiles`, not in History |
| `.snoozed` (shelf) | may be headless | ❌ |
| `.settled` | may be headless | ❌ |

`jumpTiles: canvas.navigationTileSnapshots()` covers only agents WITH a canvas
tile, so removing the inbox view strands the other three lifecycles exactly the
way it would have stranded closed agents.

**Before step 3:** generalize the step-1 source from "closed agents" to "every
agent with no canvas tile", categorized by section — `.archived` → History,
attention-needing → Needs You, otherwise → Agents & Tiles. The membership
question stays `InboxSort.section(for:now:)`; only the filter widens from
`== .history` to "has no tile". Rename the row type accordingly
(`HistoryAgentPaletteRow` → a tile-less-agent row) and keep the agent-id
dispatch identity, which is already correct for all four cases.

Do NOT delete the sidebar until a witness proves a headless working agent, a
snoozed agent and a settled agent are all reachable from ⌘K.

## Order matters

Step 3 must not land before 1 and 2 are green, or the intermediate build
strands closed agents.
