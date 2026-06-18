# T20 — Top session bar

Status: draft
Tag: tonight [workspace] [session-bar] [observability]
Depends on: T19

## Goal
Add a compact top session bar that gives a constant glimpse of active/recent workspaces and enables one-click switching.

## Product role
The top session bar answers: **“Where can I go?”**

It is not a dashboard and not a full overview. It should feel closer to tmux sessions, browser tabs, or a compact workspace rail.

## Shape
Example:

```text
[ Continuum Revived ●2 ] [ Selectus ⚠1 ] [ Falcon ✓ ]        + New
```

Each chip shows:
- workspace/session name;
- active/current state;
- small status glyph/count;
- optional stale/done/needs-attention state;
- click target for switching.

## Scope
- Build a pure `SessionBarModel` from registry/workspace summaries.
- Render compact AppKit top bar above or integrated with canvas chrome.
- Click chip → same in-process switch as T19.
- Keep current workspace visually obvious.
- Support overflow if many workspaces exist.

## Non-goals
- No full Mission Control overview.
- No deep tile tree in the top bar.
- No heavy live previews.
- No complex drag/reorder unless trivial.

## Acceptance criteria
- [ ] Shows current workspace and recent workspaces.
- [ ] Current workspace is visually distinct.
- [ ] One-click chip switches workspace using the same action path as `Cmd-K`.
- [ ] Status glyph summarizes workspace state without noisy text.
- [ ] Bar handles more workspaces than fit via overflow/menu/scroll.
- [ ] Top bar does not consume excessive vertical space.

## Verification
- Pure model checks for ordering/current/status/overflow.
- AppKit check or manual transcript for click → switch.
- Visual dogfood: top bar remains useful with 3, 8, and 20 workspaces.

## TDD sketch
Model first.

```swift
let model = SessionBarModel.build(
    workspaces: summaries,
    currentWorkspaceId: continuum,
    maxVisible: 4
)

expect(model.visible.first?.id == continuum, "current workspace is always visible")
expect(model.visible.contains(where: { $0.id == selectus }), "recent workspace is visible")
expect(model.rows[id: continuum]?.isCurrent == true, "current chip marked")
expect(model.rows[id: selectus]?.statusGlyph == .needsAttention(count: 1), "status glyph summarizes workspace")
expect(model.overflow.count == summaries.count - 4, "extra workspaces go to overflow")
```

Click action:

```swift
let actions = SessionBarActionResolver.resolveClick(rowId: selectus)
expect(actions == [.switchWorkspace(selectus)], "session chip switches workspace")
```
