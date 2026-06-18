# T22 — Defer global overview / Mission Control

Status: draft / decision record
Tag: tonight [workspace] [product]
Depends on: —

## Decision
Do **not** build a separate global overview / Mission Control surface yet.

Instead prioritize:
1. `Cmd-K` fundamentals for workspace switching.
2. Top session bar for compact cross-session awareness.
3. Sidebar workspace glimpse for current/nearby context.

## Rationale
A full overview may be useful later, but building it now risks guessing before daily use reveals what information is actually needed. The top session bar + sidebar should provide enough cross-workspace visibility to dogfood and learn.

## What to learn first
- Is a top session bar enough to notice active/needs-attention sessions?
- Does the sidebar get too crowded when showing other workspaces?
- Do users want thumbnails/previews, or just names/status?
- How often do users need to compare all workspaces at once?
- What status signals are genuinely actionable?

## Revisit trigger
Create a global overview only if one of these becomes true:
- user cannot find active agents/sessions from top bar/sidebar;
- sidebar becomes too overloaded with cross-workspace data;
- there is a recurring need to triage many workspaces at once;
- visual previews/thumbnails become necessary for orientation.

## Acceptance criteria
- [ ] Product docs explicitly mark overview as deferred.
- [ ] T19–T21 do not accidentally expand into full overview scope.
- [ ] Follow-up learning questions are captured after dogfooding top bar/sidebar.

## TDD sketch
Scope guard as a lightweight product check.

```swift
let roadmap = WorkspaceNavigationRoadmap.current
expect(roadmap.includes(.cmdKWorkspaceSwitching))
expect(roadmap.includes(.topSessionBar))
expect(roadmap.includes(.sidebarWorkspaceGlimpse))
expect(!roadmap.includes(.globalMissionControlOverview), "global overview remains deferred")
```
