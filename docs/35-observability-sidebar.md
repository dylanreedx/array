# Observability Sidebar — Seeing Where Everything Is

Status: **seed / direction only, 2026-06-17.** Captures the vision from the
dogfooding/tmux discussion so a later session can elaborate into a full
design + plan (like `docs/34`). Not yet specced; not yet scoped into phases.

## Why (the core pain)

This is feature **#2** of the "durable, observable home" arc (#1 = tmux shell
persistence, `docs/34`; #3 = browser deep-state, `docs/36`).

Dylan's existing flow is tmux + a sessionizer script: tmux session ≈ a project /
workspace, switched fast from the CLI. The workflow is great **except
observability** — you have to *remember* which pane / window / session an agent is
in. The one thing missing is *seeing*, at a glance: what are my agents doing, and
where are my projects/workspaces/zones?

Continuum's canvas already shows live tiles spatially — that *is* observability for
what's on screen. The gap is the **overview / index**: a persistent place to see
all workspaces, the projects and zones inside them, the tiles inside those, and
each agent's status — and to jump to any of them. tmux can't show you this;
Continuum should.

## Current state (grounded, 2026-06-17)

- **Data model exists, UI does not.** `Sources/ContinuumRevivedCore/SidebarTree.swift`
  defines `SidebarTree` (`:33`) and `SidebarWorkspaceRow` (`:21`) — the shape of a
  workspace → zone tree — but it is **never instantiated or rendered** anywhere in
  the app. The sidebar Dylan remembered designing was modeled but never built.
- **Workspace switching is palette-only.** `Ctrl+Space` then `w` opens
  `LaunchProfilePalette` pre-filtered to "switch workspace"
  (`ContinuumApp.swift:2417`). There is no persistent, always-visible list.
- **Agent status already exists.** Zone chrome renders an agent-status rollup
  (working / needs-attention / done / stale) — see `AgentStatusRollup` and the
  zone chrome draw path. The sidebar can reuse this signal rather than invent one.

## Direction (to refine later)

A persistent, collapsible sidebar that renders the live hierarchy:

```
Workspace
  └─ Zone / Project
       └─ Tile (terminal · browser · note · …)  [agent status glyph]
```

- **Jump/focus:** click a row → pan/focus that workspace/zone/tile (reuse the
  existing leader-jump / palette-jump focus plumbing).
- **Agent status at a glance:** surface the `AgentStatusRollup` per zone/tile so
  you can see "this agent needs attention" without hunting.
- **Workspace switching home:** the sidebar likely becomes the primary
  workspace-switch surface, augmenting (not necessarily replacing) the palette.
- Built on the existing `SidebarTree` model — render it, don't redesign it, unless
  the model proves wrong.

## Open questions (for the elaboration session)

- Placement & form: left dock (persistent, resizable) vs slide-over overlay vs
  toggled with a keybind? Default visible or opt-in?
- Hierarchy depth: workspace → zone → tile, or also project grouping? Collapsible
  per level?
- Live updates: how does agent status stream into rows (polling vs the existing
  status pipeline)? Cost at many tiles.
- Relationship to nav-mode / leader-jump / palette — one coherent "go to" story,
  not three overlapping ones.
- Keybind to toggle (and does it fold into nav-mode?).
- Does the sidebar show *only* the current workspace, or all workspaces with the
  current one expanded?

## Non-goals / later

- Not blocking on #1 (tmux persistence); independent, can land after.
- Reuses agent-status + focus-jump infra; avoid reinventing either.
