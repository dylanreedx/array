# 06 — Cmd+K command center redesign

Status: **implementation in progress — first slice built, visual review pending**

Resume from [06-command-center-redesign-handoff.md](06-command-center-redesign-handoff.md).

## Outcome

`Cmd+K` becomes Array's one canonical floating command center: fast enough to
feel like a launcher, rich enough to navigate agents and spatial destinations,
and visually connected to the live canvas through restrained frosted glass.

The command center replaces the current raw, flat palette presentation. It does
not reproduce the persistent workspace/activity sidebar inside a modal. The
canvas remains the spatial and activity surface; compact top chrome may retain
ambient counts such as `3 active` or `1 needs you`.

This document remains the design source of truth while implementation proceeds.
The handoff records what has landed in the working tree, verification evidence,
known gaps, and the next ordered steps.

## Product model

```text
canvas → compact ambient status → floating command center when invoked
```

The command center has one shell and no visible modes, tabs, right-hand preview,
or split pane. Parameterized actions advance inside the same card:

```text
Cmd+K → New Agent → choose configuration → create
```

`Escape` moves backward through that shallow stack and then closes the command
center.

## Design principles

1. **Destinations read like things, not command sentences.** A row is
   `Cmd+K menu redesign`, not `Jump to GPT 5.6`.
2. **Categories carry repeated intent.** Section names such as `GO TO` and
   `CREATE` remove the need to repeat a verb in every row.
3. **The empty state is curated.** It is a useful home, not the command registry
   dumped into a table.
4. **Search is unified.** One query spans agents, tiles, zones, workspaces,
   projects, safe actions, and creation actions.
5. **Ambient state stays ambient.** The command center is not a hidden fleet
   dashboard.
6. **Glass supports spatial context.** The canvas remains perceptible behind the
   menu without weakening text, focus, or selection contrast.
7. **Human identity wins over implementation identity.** Agent name or task is
   primary; provider/model is metadata and a fallback only.

## Surface and placement

- Centered horizontally and placed around the upper third of the host window.
- Approximately `640–680 pt` wide.
- Height grows with useful content and is capped by available window space.
- Array `overlay` surface vocabulary, `Radius.container`, one `0.5 pt`
  hairline, and a soft real shadow.
- Custom bezel-free search row rather than a stock `NSSearchField` bezel.
- `42–46 pt` result rows with one primary and one secondary line.
- Fast open/close and shallow drill transitions, respecting Reduce Motion.
- The underlying canvas is not globally dimmed by default. Spatial context
  should remain faintly visible through the command-center background.

## Default empty state

Only non-empty, useful sections render. The home view is capped to roughly
`8–12` rows rather than exposing every registered action.

```text
┌──────────────────────────────────────────────────────────────┐
│  Search Array…                                          ⌘K  │
├──────────────────────────────────────────────────────────────┤
│  NEEDS YOU                                                   │
│  ◉  Review command-center direction                 Needs you│
│     Agent · GPT-5.6 · Array                                  │
│                                                              │
│  RECENT                                                      │
│  ◉  Cmd+K menu redesign                             Working  │
│     Agent · GPT-5.6 · Product zone                           │
│  ▣  Array website                                            │
│     Browser tile · Product zone                              │
│                                                              │
│  CREATE                                                      │
│  ＋  Agent        Terminal        Browser        Note         │
│                                                              │
│  WORKSPACES                                                  │
│  ◇  Array                                           Current  │
└──────────────────────────────────────────────────────────────┘
```

### Needs You

Agents requiring approval, input, or review. Omit the section when empty.
Needs-attention state is also allowed to remain ambient on canvas and in compact
top chrome; this section is the actionable destination list.

### Recent

Recent safe destinations and successful safe actions:

- switch workspace;
- jump to agent, tile, or zone;
- create a common surface;
- show the entire canvas;
- open Settings.

Recents are deduplicated by stable action identity, capped, and cleaned when a
target no longer exists. Failed or cancelled actions do not record recency.
Destructive actions never appear in default recents.

### Create

The common creation set is intentionally small:

- Agent
- Terminal
- Browser
- Note
- Zone

Less common creation paths remain searchable. A compact horizontal treatment is
acceptable if it remains fully keyboard navigable; otherwise use normal rows.

### Workspaces

Show the current and recent workspaces. Mark the current workspace quietly with
an accessory rather than making the title verbose.

`GO TO` results may appear on the empty home when context makes them unusually
relevant. Ordinarily, search is the primary path to the broader destination
set.

## Typed search

Typing searches all supported domains without exposing their implementation
shape. Results regroup into semantic categories:

1. **Agents & Tiles**
2. **Workspaces & Projects**
3. **Actions**
4. **Create**
5. **Developer**, only when relevant

```text
┌──────────────────────────────────────────────────────────────┐
│  browser                                                ×   │
├──────────────────────────────────────────────────────────────┤
│  AGENTS & TILES                                              │
│  ▣  Array website                                            │
│     Browser tile · Product zone                              │
│  ▣  localhost:4321                                           │
│     Browser tile · Array · Development                       │
│                                                              │
│  ACTIONS                                                     │
│  ↗  Open URL                                                 │
│     Browser                                                   │
│  ◌  Inspect current browser                                  │
│     Developer                                                 │
│                                                              │
│  CREATE                                                      │
│  ＋  Browser                                            ⌘3   │
└──────────────────────────────────────────────────────────────┘
```

Sections disappear when empty. Do not add a separate `BEST MATCH` section
unless witnessed search behavior shows that grouping buries exact matches.

### Ranking

For an empty query:

1. needs-attention agents;
2. safe recents;
3. contextually relevant destinations;
4. common creation actions;
5. current/recent workspaces.

For a typed query:

1. exact and prefix title match;
2. explicit aliases and keywords;
3. recent-use boost;
4. current workspace/zone/focused-tile boost;
5. fuzzy match;
6. category relevance.

Search may match stable IDs internally but never displays raw UUIDs. Full
repository file indexing is deferred from the first cut. `Open File…` and file
tree actions remain searchable; an eventual explicit `file:` scope can add file
destinations without overwhelming everyday results.

## Row anatomy and language

Every row has the same conceptual shape:

```text
[glyph] title                         [status / shortcut / accessory]
        subtitle/context
```

### Identity rules

- Managed agent: explicit display name, generated session title, or abbreviated
  first prompt.
- Agent fallback: provider/model plus `agent`, for example `GPT-5.6 agent`.
- Model, effort, status, project, workspace, and zone are metadata rather than
  the normal identity.
- Tile: user title or meaningful content identity, such as `Array website`.
- Workspace, project, and zone titles remain their natural names.

### Language cleanup

| Current/raw | Target row | Context/accessory |
| --- | --- | --- |
| `Jump to GPT 5.6` | `Cmd+K menu redesign` | `Agent · GPT-5.6 · Working · Array` |
| `Switch to Array Workspace` | `Array` | `Workspace · Current` |
| `Add Array to Canvas` | `Array` | `Project · Add to canvas` |
| `New Agent Without a Tile…` | `Background agent` | `Create` |
| `Fit Canvas to All` | `Show entire canvas` | `Canvas` |
| `Back to Previous View` | `Previous view` | `Navigation` |
| `Go to Previous Tile` | `Previous tile` | `Navigation` |
| `Open Inspector for Focused Browser` | `Inspect current browser` | `Developer` |

The section supplies the repeated verb. A trailing accessory may clarify a
row-specific operation such as `Switch`, `Add`, `Current`, an agent status, or a
keyboard shortcut.

### Default visibility policy

The following remain searchable but do not appear on the default home unless
context requires them:

- rename/delete workspace;
- developer inspectors;
- harness roles;
- background/headless agent creation;
- queue fan-out;
- rare contextual commands;
- destructive actions.

## Glass and transparency

The command center uses a blurred/material backdrop beneath a tinted Array
overlay surface. Transparency applies to the **background**, never to the entire
view. Whole-view alpha would wash out text, glyphs, selection, and focus.

Text, icons, section labels, and contrast-critical selection states stay fully
opaque.

### Appearance presets

- **Solid** — Array overlay surface with no translucency.
- **Frosted** — default; approximately `84%` tinted background opacity with
  moderate blur.
- **Glass** — clearer backdrop with a stronger readability scrim.
- **Custom** — bounded background-opacity control.

The user-facing language may use `Glassiness` for presets, while the custom
control is labeled precisely as `Background opacity`. Do not expose an
ambiguous `Transparency` slider whose direction is unclear.

```text
Appearance

Command menu appearance     Frosted
Background opacity          ━━━━━━━●━━  84%
```

The custom range must have a readability floor rather than allowing the surface
to become functionally invisible. Bright and dark canvas regions both need
deterministic contrast coverage.

### Accessibility overrides

- macOS Reduce Transparency forces `Solid`.
- Increase Contrast may strengthen tint and hairline values.
- Reduce Motion removes or shortens drill/open/close transitions.
- Accessibility overrides affect the resolved presentation, not the stored user
  preference, so the chosen preset returns when the system override is removed.

## Interaction behavior

- `Cmd+K` opens the shell and focuses search.
- `Cmd+K` while visible closes it.
- Up/Down traverses selectable rows across category boundaries.
- Return executes a leaf action or advances into the next step.
- Escape moves back through the drill stack, then closes.
- Whether Escape first clears a non-empty query remains a dogfood decision.
- Pointer hover and keyboard focus share one selection state.
- Successful navigation restores semantic focus to the chosen destination.
- Cancellation restores the responder that owned focus before `Cmd+K`.
- The shell opens over canvas, browser, terminal, and text focus without those
  embedded surfaces consuming the reserved shortcut.

## Ambient agent awareness without the sidebar

The canvas remains the primary spatial and activity surface. A compact
top-chrome control may show `3 active` or `1 needs you`; activating it opens the
same command-center shell already scoped to agents.

Needs-attention state remains visible through tile and zone status. A richer
fleet-management view is a separate product decision only if dogfood proves
that the command center and canvas are insufficient.

## Presentation model

The current `LaunchPaletteRow` exposes source-specific cases and computes
verbose display sentences. The command-center view should instead receive an
already-presented and grouped model with these semantics:

```swift
struct CommandCenterItem {
    let id: CommandCenterItemID
    let category: CommandCenterCategory
    let kind: CommandCenterItemKind
    let title: String
    let subtitle: String?
    let glyph: CommandCenterGlyph
    let accessory: CommandCenterAccessory?
    let shortcut: String?
    let isSelectable: Bool
    let visibility: CommandCenterVisibility
    let searchAliases: [String]
    let action: LaunchPaletteAction
    let nextStep: CommandCenterStep?
    let recencyID: CommandCenterRecencyID?
}

struct CommandCenterSection {
    let category: CommandCenterCategory
    let items: [CommandCenterItem]
}
```

Names are provisional. The durable decision is the separation of stable action
identity, product presentation, visibility policy, search terms, and optional
drill-forward behavior.

The construction layer gathers static commands and dynamic destinations, then
applies naming, visibility, categorization, ranking, and recency. The AppKit view
must not infer product language from enum cases.

## Existing code to reuse

- `Sources/ContinuumRevivedCore/CanvasCommand.swift`
  - Keep `CommandRegistry` as the stable source for static canvas commands.
  - Enrich or adapt registry entries with category, aliases, default visibility,
    and presentation metadata.
- `Sources/ContinuumRevived/Canvas/AgentComposer/ChoiceListView.swift`
  - Reuse token vocabulary, hover/focus behavior, accessibility selection path,
    density lessons, and the `0.5 pt` boundary.
  - Do not force richer command-center rows into `ChoiceItem` if doing so erases
    section, status, shortcut, or next-step semantics.
- `SurfaceToken.overlay`, `Radius.container`, existing line roles, and current
  appearance/contrast probes.
- Existing focus snapshot/restore and reserved-shortcut routing.

## Expected implementation areas

- `Sources/ContinuumRevivedCore/LaunchPaletteModel.swift`
  - semantic item and section presentation;
  - naming projection;
  - default visibility;
  - grouped construction;
  - ranking and recency identity.
- `Sources/ContinuumRevivedCore/CanvasCommand.swift`
  - command metadata/adapter source.
- `Sources/ContinuumRevived/App/LaunchProfilePalette.swift`
  - replace the fixed `480 × 320` stock field/table shell;
  - sectioned result views;
  - shallow navigation stack;
  - frosted background resolver;
  - one keyboard/pointer/accessibility path.
- `Sources/ContinuumRevivedCore/SettingsSchema.swift`
  - command-menu appearance preference under Appearance.
- `Sources/ContinuumRevived/App/SettingsPanel.swift`
  - reuse the schema renderer; add a bounded slider field only if presets and
    custom opacity cannot be represented by current field types.
- `Sources/ContinuumRevived/App/UIProbeAppearance.swift`
- `Sources/ContinuumRevived/App/UIProbeGeometry.swift`
- existing palette self-checks in `LaunchProfilePalette.swift` and
  `ContinuumApp.swift`.

## Scope boundaries

Included:

- one floating command-center shell;
- removal of the right-sidebar dependency from this workflow;
- category and naming cleanup;
- curated default home;
- unified typed search and ranking;
- safe successful-action recents;
- glass presets and bounded custom background opacity;
- keyboard, focus, accessibility, appearance, and Reduce Motion behavior.

Deferred:

- full repository file indexing;
- a general-purpose agent fleet dashboard;
- global Mission Control;
- arbitrary plugin-defined palette UI;
- destructive action shortcuts;
- a broader Settings redesign.

## Verification contract

Every implementation slice requires a deterministic witness rebuilt before it
is trusted.

### Core checks

- semantic category assignment;
- concise title/subtitle projection;
- agent name/model fallback policy;
- empty-state caps and empty-section omission;
- typed ranking for agent, workspace, project, tile, zone, create, and action;
- recents dedupe, failure exclusion, destructive exclusion, and stale-target
  cleanup;
- stable dispatch identity after presentation changes;
- appearance preference resolution and accessibility overrides.

### App checks

- `Cmd+K` opens exactly one command-center root over canvas, browser, terminal,
  and text focus;
- repeated invocation never duplicates the root;
- category traversal and selection share the production keyboard path;
- drill forward/back, close, and first-responder restoration;
- Solid, Frosted, Glass, and accessibility-forced Solid render paths;
- light/dark appearance, geometry, and contrast;
- successful jump centers and focuses the intended tile rather than merely
  closing the menu.

### Dogfood gate

1. Use only `Cmd+K` for one working session to switch workspaces, reach agents,
   jump to tiles/zones, and create common surfaces.
2. Test over visually bright and dark canvas regions at multiple zoom levels.
3. Adjust the default Frosted opacity only from witnessed readability and feel,
   without weakening the contrast floor.

## Decisions still to review

1. Start Frosted at approximately `84%` background opacity.
2. Keep `NEEDS YOU` first on an empty query; exact typed matches take precedence
   once the user searches.
3. Defer full file destinations from the first cut.
4. Decide through dogfood whether Escape clears a non-empty query before it
   closes the shell.
