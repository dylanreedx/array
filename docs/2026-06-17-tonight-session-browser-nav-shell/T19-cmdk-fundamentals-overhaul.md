# T19 — Cmd-K fundamentals overhaul

Status: draft
Tag: tonight [palette] [command-center] [habit]
Depends on: workspace runtime switch wiring for switch actions

## Goal
Make `Cmd-K` the clean universal control surface for Continuum: recent actions, switching, jumping, creating, and commands. Workspace switching is a critical use case, but this ticket is broader than workspaces.

`Cmd-K` should feel habit-forming, practical, and polished — not like a debug list of every possible row.

## Simplified mental model
`Cmd-K` has five simple buckets:

```text
RECENT
SWITCH
JUMP
CREATE
COMMAND
```

- **Recent** — what I am likely to do again.
- **Switch** — change workspace/session.
- **Jump** — move within the current or target workspace: zone/tile.
- **Create** — make a browser/shell/note/zone/workspace.
- **Command** — view/settings/actions like toggle sidebar, fit canvas, open settings.

## Core behavior
- Empty query shows **Recent** first.
- Typed query shows ranked results across all buckets.
- Section labels provide the verb, so row titles stay concise.
- No submenus for now; keep interaction flat and fast.
- Dangerous/destructive actions are confirmation-gated and excluded from default recents.

## Desired empty-query shape

```text
RECENT
  Selectus
    Workspace · QR review
  Browser Work
    Zone · 3 tiles
  Shell — tests running
    Terminal · continuum-revived · main
  New Browser
  Toggle Sidebar

SWITCH
  Continuum Revived                         Current
  Falcon Platform

CREATE
  Browser                                   ⌘3
  Shell                                     ⌘1
  Note
  Zone

COMMAND
  Fit Canvas
  Settings
```

## Desired typed-query behavior
Examples:

```text
"sel"       → Selectus under SWITCH/RECENT
"browser"   → Browser Work under JUMP, Browser under CREATE, browser tile rows
"side"      → Toggle Sidebar under COMMAND
"shell"     → shell tile under JUMP, Shell under CREATE
"rename"    → rename tile/zone/workspace commands
"localhost" → browser tile with that URL
```

## Row anatomy
Every row should have the same conceptual shape:

```text
[icon] title                         accessory/status/shortcut
       subtitle/context
```

Examples:

```text
SWITCH
  ● Selectus                          ⚠
    Workspace · QR review

JUMP
  ◆ Browser Work                      B
    Zone · 3 tiles

  ▣ Shell — tests running
    Terminal · continuum-revived · main

CREATE
  ＋ Browser                           ⌘3
    Create

COMMAND
  ⌘ Toggle Sidebar
    View
```

## Workspace switching requirements
Workspace switching remains the forcing function for this overhaul:

- `Cmd-K`, type workspace name, Enter switches.
- Row title should be the workspace/session name, not verbose phrasing.
- Current workspace is marked as `Current` but not over-prioritized when switching away.
- Recent workspaces rank high.
- Switch uses the in-process path, not relaunch-feeling behavior.
- Destination camera/viewport/focus restore.
- Palette closes cleanly after switch.

## Recents requirements
A recent is an action/result, not just a static command.

Can be recent:
- switch to workspace;
- jump to zone/tile;
- create browser/shell/note;
- toggle sidebar;
- open settings;
- focus browser URL;
- fit canvas.

Rules:
- Cap visible recents, likely 5–7.
- Deduplicate by action identity.
- Rank by last used and use count.
- Drop/hide recents whose target no longer exists.
- Do not show destructive actions as recents by default.
- Failed/canceled actions do not record recents.

## Ranking rules
For empty query:
1. recent safe actions;
2. current workspace context jumps;
3. create basics;
4. core commands.

For typed query:
1. exact/prefix match;
2. recent usage boost;
3. current context boost;
4. section/category relevance;
5. fuzzy match.

## Scope
- Audit existing palette rows and command/action sources.
- Define/adjust a unified palette row model if needed: section, title, subtitle, icon, accessory, action, keywords, availability.
- Add/clean section grouping: Recent, Switch, Jump, Create, Command.
- Add recents model and persistence if not already available.
- Improve row titles/subtitles/accessories.
- Improve search ranking.
- Ensure action execution records recents and restores focus correctly.
- Defer heavy visual redesign if needed, but the model should support a polished UI.

## Non-goals
- No nested submenu system yet.
- No global Mission Control overview.
- No full settings/keybinding editor overhaul.
- No destructive action shortcuts without confirmation.
- No attempt to solve sidebar/top bar rendering here.

## Acceptance criteria
- [ ] Empty `Cmd-K` shows useful Recent rows first.
- [ ] Rows are grouped into Recent / Switch / Jump / Create / Command.
- [ ] Row titles are concise; context moves to subtitle/accessory.
- [ ] Typed queries rank expected results highly for workspace, tile, zone, create, and command cases.
- [ ] Successful safe actions record recents.
- [ ] Failed/canceled/destructive actions do not become default recents.
- [ ] Workspace switching from palette is smooth, in-process, and restores camera/focus.
- [ ] Palette closes cleanly and focus recovers after action execution.

## Verification
- Core/palette checks for section grouping, row construction, search/ranking, recents dedupe, and missing-target cleanup.
- App check or manual transcript for real workspace switch path and focus restoration.
- Human dogfood: use only `Cmd-K` for switching/jumping/creating for a session and note what feels missing.

## TDD sketch
Palette row grouping:

```swift
let rows = LaunchPaletteModel.makeRows(
    context: .fixture(
        workspaces: workspaceSummaries,
        zones: zoneSummaries,
        tiles: tileSummaries,
        recentActions: recentActions,
        currentWorkspaceId: continuum,
        focusedTileId: shellTile
    ),
    query: ""
)

expect(rows.sections.map(\.kind).prefix(5) == [.recent, .switch, .jump, .create, .command], "empty query uses simplified sections")
expect(rows.section(.recent).count <= 7, "visible recents are capped")
expect(rows.section(.switch).contains(where: { $0.title == "Continuum Revived" && $0.accessory == "Current" }), "current workspace is marked")
```

Typed query ranking:

```swift
let sel = LaunchPaletteModel.makeRows(context: fixture, query: "sel")
expect(sel.first?.title == "Selectus", "workspace name query ranks workspace first")
expect(sel.first?.action == .switchWorkspace(selectus), "workspace row dispatches switch action")

let browser = LaunchPaletteModel.makeRows(context: fixture, query: "browser")
expect(browser.prefix(3).contains(where: { $0.action == .newBrowser }), "browser query includes create browser near top")
expect(browser.prefix(3).contains(where: { $0.action == .jumpToZone(browserWorkZone) || $0.action == .jumpToTile(browserTile) }), "browser query includes relevant jump target near top")

let side = LaunchPaletteModel.makeRows(context: fixture, query: "side")
expect(side.first?.action == .toggleSidebar, "side query finds Toggle Sidebar")
```

Recents model:

```swift
var store = RecentCommandStore(maxVisible: 7)
store.record(.switchWorkspace(selectus), now: t1)
store.record(.jumpToTile(shellTile), now: t2)
store.record(.switchWorkspace(selectus), now: t3)
store.record(.deleteWorkspace(old), now: t4, outcome: .requiresConfirmation)

let recents = store.visibleRecents(existingTargets: [.workspace(selectus), .tile(shellTile)])
expect(recents.first?.action == .switchWorkspace(selectus), "repeated recent switch ranks first")
expect(recents.filter { $0.action == .switchWorkspace(selectus) }.count == 1, "recents dedupe by action identity")
expect(!recents.contains(where: { $0.action == .deleteWorkspace(old) }), "destructive action is excluded from default recents")
```

Missing target cleanup:

```swift
store.record(.jumpToTile(deletedTile), now: t5)
let cleaned = store.visibleRecents(existingTargets: [.workspace(selectus), .tile(shellTile)])
expect(!cleaned.contains(where: { $0.action == .jumpToTile(deletedTile) }), "missing tile recent is hidden")
```

Execution/focus seam:

```swift
let app = FakePaletteActionHost()
try app.performPaletteAction(.switchWorkspace(selectus))
expect(app.calls == [.closePalette, .switchWorkspaceInProcess(selectus), .restoreFocus, .recordRecent(.switchWorkspace(selectus))], "workspace switch uses in-process path, restores focus, records recent")
expect(!app.calls.contains(.relaunch), "palette workspace switch does not relaunch")
```
