# Spatial agent awareness — location, canvas context, sessions, and coordination

Status: implementation in progress; host-local Home/Where/What and first native managed-tile status slice mechanically GREEN; supervised UI, proximity, persistent RPC, and messaging remain open
Written: 2026-08-06
Expanded: 2026-08-06
Scope: agent identity, Home/Where/What, spatial awareness, location inference and switching,
external references, session targeting, inter-agent messaging, and canvas-native harness tools

## Product thesis

Continuum should not merely host terminal-like agent tiles. It should give agents an observable,
addressable environment: projects, agents, sessions, notes, terminals, file trees, and zones arranged
in a meaningful two-dimensional canvas.

The canvas already carries intent. A new agent created beside related work probably belongs to the
same project. A prompt composed inside one tile has a natural meaning for “this agent.” A request to
“ask the agent to the left” should resolve to a stable agent identity instead of forcing the user to
find and paste a session UUID. A request to “make a reviewer next to this tile” should be expressible
through explicit, inspectable canvas tools.

The common path remains simple:

- proximity supplies a visible default;
- **Home / Where / What** explains the agent at a glance;
- one native fuzzy switcher handles exceptions;
- explicit canvas tools resolve and act on spatial references;
- Continuum brokers agent-to-agent communication visibly.

The system must remain consistent with the product principle:

> observable agents · explicit tools · no black boxes

Spatial inference is a convenience, not hidden authority. Provider sessions, transcripts, worktrees,
and raw world coordinates are implementation details behind stable Continuum identities and visible
actions.

## The user-facing model: Home / Where / What

The primary vocabulary should stay this small.

### Home

Where the agent fundamentally belongs: its logical project and concrete checkout/worktree.

Home controls the instructions, Git identity, default index, isolation policy, and scope gravity that
nearby new agents may inherit. It is stable unless the user explicitly reassigns or recreates the
agent.

### Where

The agent's current working directory. It may be the same as Home, a subdirectory within Home, or a
directory outside Home.

Where does not silently redefine Home. An agent temporarily working in another repository remains an
agent whose Home is its original project until an explicit project transition occurs.

### What

Observed current or recent activity: reading, editing, searching, running a command, waiting,
thinking, messaging another agent, or inspecting a session.

What is derived from real lifecycle and tool events, not from model self-report. Its target may be
inside or outside Home and may differ from Where.

### Compact examples

Ordinary project-root work:

```text
continuum-overnight · agent/agent-ux · ctx 72%
reading CanvasNSView.swift
```

Working in a project subdirectory:

```text
Home  continuum-overnight
Where Sources/ContinuumRevived
What  editing CanvasNSView.swift
```

Reading another project without leaving Home:

```text
Home  continuum-overnight
Where Sources/ContinuumRevived
What  ↗ reading new-project/src/router.ts
```

Explicitly working outside Home:

```text
Home  continuum-overnight
Where ↗ new-project
What  running its test suite
```

If Home and Where are effectively identical, the UI collapses them rather than displaying duplicate
rows. Access permissions, worktree paths, provider session IDs, and provenance remain available in
details without becoming additional primary states.

## Architecture layers

The complete direction has several layers. They should share identities and indexes, but each layer
has a separate responsibility.

```text
┌──────────────────────────────────────────────────────────────┐
│ 7 · Native UX                                                │
│     status, switcher, @ mentions, message/thread visuals     │
├──────────────────────────────────────────────────────────────┤
│ 6 · Coordination                                             │
│     message, inspect, reply, fork, spawn, place              │
├──────────────────────────────────────────────────────────────┤
│ 5 · Canvas harness                                           │
│     tiny prompt + explicit tools + on-demand skill           │
├──────────────────────────────────────────────────────────────┤
│ 4 · Semantic references                                      │
│     @agent, @session, @tile, @zone, @project                 │
├──────────────────────────────────────────────────────────────┤
│ 3 · Spatial scene index                                      │
│     contains, nearby, left/right/above/below, same zone      │
├──────────────────────────────────────────────────────────────┤
│ 2 · Home / Where / What telemetry                            │
│     stable scope, current cwd, observed activity             │
├──────────────────────────────────────────────────────────────┤
│ 1 · Identity and provider adapters                           │
│     project, checkout, agent, tile, provider session         │
└──────────────────────────────────────────────────────────────┘
```

No layer should infer facts that belong to another layer. In particular:

- current external activity does not redefine Home;
- a nearby note may supply context but not filesystem scope;
- a tile is a view of an agent, not the agent's identity;
- inspecting a session is not the same as messaging or resuming it;
- resolving a spatial phrase is not permission to perform a side effect.

## Layer 1 — identity

Continuum needs distinct stable identities for concepts that often correspond but are not the same.

### Workspace

An organizational and discovery boundary such as Work or Personal. It owns registered projects,
shallow discovery roots, recency, and canvas state. A workspace root is not silently used as an
agent cwd.

### Project

The logical execution boundary: repository/directory identity, instructions, Git context, roles,
and primary file index.

### Checkout

The concrete filesystem root used for execution: main checkout or an isolated worktree. Two agents
must not silently become concurrent writers to another agent's isolated worktree.

### Agent

A durable Continuum-managed worker. It owns its identity, Home, provider configuration, lifecycle,
and conversation continuity. It may exist without a visible tile.

### Tile

One visual representation of an entity on one canvas. A tile may attach to or detach from an agent;
closing a tile does not end the agent.

### Session

One provider conversation/transcript. A durable agent may resume, fork, or accumulate provider
session history. Provider session IDs are routing details behind the stable Continuum `AgentID`.

### Zone

A visual and organizational canvas region. A project zone is an authoritative Home signal. Other
zone types may carry context without carrying filesystem scope.

### Conceptual references

```text
CanvasEntity
  entityId
  kind                    agent | note | terminal | fileTree | browser | zone | …
  frame                    world-coordinate bounds
  zoneId?
  scopeSignal?
  contextSummary?
  agentRef?
  sessionRef?
  capabilities[]

AgentScope
  projectId
  checkoutRoot
  relativeWorkingDirectory
  provenance              zone | proximity(entityId) | manual | workspaceDefault
  state                    provisional | pinned

SessionRef
  continuumAgentId?
  provider
  providerSessionId        host-local/private routing detail
  transcriptLocator        host-local/private routing detail
  freshnessCursor?
```

Raw provider IDs, transcript paths, and absolute worktrees must remain host-local and must not leak
through companion/spatial activity payloads. Agents and UI surfaces normally use Continuum handles
such as `agent:sidebar-review` or an opaque stable ID.

## Layer 2 — location and activity telemetry

Internally, Home/Where/What may require richer facts, but those facts should not expand the primary
user vocabulary.

```text
AgentLocationTelemetry
  home
    projectId
    projectRoot
    checkoutRoot
    worktreeIdentity?

  where
    absoluteDirectory
    relationToHome         root | inside | outside

  accessRoots[]            implementation/detail disclosure
    path
    capability             read | write | execute
    provenance             prompt | manual | inherited | provider
    persistence            turn | session | durable

  what
    operation
    target?
    startedAt
    updatedAt
    relationToHome         inside | outside | none
    evidenceSource         tool event | lifecycle event | host action
```

### Stable scope versus activity

The status line must not jump to whichever file an agent touched most recently. These remain
distinct:

```text
Home/Where: continuum-overnight/Sources
What:       reading docs/38-tickets/...
```

### Paths inside and outside Home

A prompt may legitimately ask:

```text
Look at patterns from ../work/new-project.
```

Possible outcomes:

1. The agent reads an absolute/relative external file without changing Where.
2. The external root becomes a visible, session-scoped reference/access root.
3. The user explicitly changes Where to that external directory.
4. The user explicitly registers the directory as another project or creates a new agent there.

None of the first three silently changes Home.

### External-root capabilities

The user-facing model remains Home/Where/What, but the host may distinguish:

- add for reference — read-only;
- add as a working root — read/write;
- register as project — durable identity and discovery.

An external-reference chip can make a newly resolved path visible without opening a modal for every
read. A write or execution outside existing authority should require explicit policy/approval.
Exact policy remains an owner decision.

## Provider evidence

### Claude Code

Claude Code's status-line JSON already separates the relevant concepts:

| Claude field | Meaning |
|---|---|
| `workspace.project_dir` | directory where Claude Code was launched |
| `cwd` / `workspace.current_dir` | current working directory, which may change |
| `workspace.added_dirs` | extra roots added with `/add-dir` or `--add-dir` |
| `workspace.git_worktree` | linked worktree identity when applicable |
| `workspace.repo.*` | repository host/owner/name |

Official reference:

<https://code.claude.com/docs/en/statusline#available-data>

Claude also emits observable hooks including `CwdChanged`, `DirectoryAdded`, tool lifecycle,
`SessionStart`, and `SessionEnd`, with `session_id` and `transcript_path` in common hook input.

<https://code.claude.com/docs/en/hooks>

Dylan's current `~/.claude/statusline-command.sh` displays
`.workspace.current_dir // .cwd` and computes Git branch from that path. It does not display
`workspace.project_dir` or `workspace.added_dirs`, which is why the current line collapses Home,
Where, and Reach into one cwd label.

Claude sessions are tied to project directories; resume-by-ID lookup is scoped by the directory and
worktrees. Additional directories are not always restored automatically on resume. Continuum should
retain enough host-local launch metadata to invoke provider resume from the correct Home without
making the user manage this coupling.

### Pi

Installed Pi documentation was inspected at:

```text
~/.nvm/versions/node/v22.22.2/lib/node_modules/
  @earendil-works/pi-coding-agent/
```

Relevant supported seams:

- `SYSTEM.md`, `APPEND_SYSTEM.md`, `--system-prompt`, and `--append-system-prompt`;
- `before_agent_start` extensions for per-turn system prompt/context injection;
- custom model-callable tools through `pi.registerTool()`;
- progressive-disclosure skills;
- SDK `AgentSession.prompt`, `steer`, `followUp`, events, and session runtime;
- persistent `--mode rpc` with `prompt`, `steer`, `follow_up`, `get_state`, and `get_messages`;
- extension `pi.sendMessage()` for attributed custom context and `pi.sendUserMessage()` for actual
  user turns;
- tool lifecycle events suitable for deriving What.

Relevant installed docs:

```text
README.md
docs/extensions.md
docs/skills.md
docs/sdk.md
docs/rpc.md
docs/sessions.md
docs/session-format.md
```

Pi's runtime/session `cwd` is normally the launch cwd. A `cd` inside one Bash tool invocation changes
that child shell, not the parent Pi process. Continuum should therefore change Pi's Where through an
explicit location/runtime operation rather than attempting to parse arbitrary shell commands.
External absolute-path reads appear in What while Where remains stable.

### Current Continuum Pi integration

Continuum currently launches one short-lived process per submitted turn:

```text
pi -p --mode json --session-id <stable-agent-session-id> …
```

The stable Pi session ID preserves conversation continuity across processes, but this mode does not
provide a persistent control channel while the turn is active. Current managed-tile capabilities
truthfully expose `canSteer: false` and `canQueue: false`.

`AgentSupervisor.swift` already records the intended architectural handoff: a later phase replaces
`PiAgentRunner` with an RPC client. Live inter-agent messaging, queueing, and steering should build
on that persistent RPC/SDK ownership rather than simulating messaging through files or repeated
one-shot prompts.

## Layer 3 — spatial scene index

The canvas should expose a host-owned, queryable scene graph over stable entities.

### Spatial relations

Useful derived relations include:

- contains / inside zone;
- nearest / within radius;
- left / right / above / below;
- overlap / intersects;
- same zone / same project;
- clustered with;
- selected / composing / focused;
- visible / offscreen.

Distance is measured between tile frames in world coordinates so inference is zoom-independent.
Tools should generally return semantic relations and distances, not require the model to perform raw
coordinate geometry.

### Snapshot semantics

Natural references such as “the agent to my left” resolve at prompt/tool-call time to stable entity
IDs. The resolution result records its origin and geometry snapshot. Moving tiles afterward does not
retarget an in-flight instruction.

### Deictic anchors

Inside an agent tile composer:

```text
this / me / my tile → composing agent tile
```

From a global canvas command:

```text
this → explicitly selected, right-clicked, or command-anchored entity
```

If no anchor is unambiguous, the UI asks rather than guessing.

### Two independent signal channels

#### Scope gravity

Entities that may define Home for a new agent:

- containing project zone;
- nearby agent's primary Home;
- authoritative terminal/file-tree project identity;
- explicit workspace default.

#### Context neighborhood

Entities that may be relevant to a prompt without defining Home:

- agents and sessions;
- notes;
- browser tiles;
- tickets and queues;
- diffs and plans;
- terminals and file trees.

A note can be useful context but has no independent filesystem scope. An agent reading another
repository still emits its stable Home for scope gravity; its external What may be visible context
but must not pull neighboring agents into the external repository.

## Context gravity and provisional Home

When a new agent is created, rank Home signals:

1. containing project zone;
2. nearby context-bearing entities with authoritative scope;
3. agreement among several nearby entities;
4. current workspace's explicit/default project;
5. a one-time native location choice.

Never silently fall back to Continuum's process cwd. A stale globally selected tile must not outrank
an actually nearby cluster.

### Project versus subdirectory inference

Nearby agents are strong evidence for the same project but weaker evidence for an exact
subdirectory. Recommended behavior:

- a containing project zone proposes the project root;
- nearby agreement proposes the project;
- inherit a relative subdirectory only when multiple nearby signals agree, creation came directly
  from a location-bearing entity, or the user selected it explicitly.

This avoids launching deep inside an incidental `Sources/` directory merely because one nearby agent
happened to begin there.

### Provisional binding

A zero-turn, otherwise untouched agent may hold a visible proposal:

```text
Home  continuum-overnight
Where Sources
↳ inherited from “Claude · sidebar work”
```

Moving the empty tile may update the proposal after the drag settles. Proximity is a creation aid,
not a live filesystem link.

Recommended eligibility for automatic re-inference:

```text
no submitted turn
no composer text
no attachment/reference
no manual location choice
```

Any of those facts pins the proposal. Moving an active/restored tile never changes Home or Where.

### Worktree safety

Proximity inherits logical project and, when justified, a relative subdirectory. It never inherits
another agent's raw absolute isolated worktree.

Example:

```text
Neighbor Home checkout: /tmp/worktrees/agent-A
Neighbor Where:         Sources
New isolated agent:     /tmp/worktrees/agent-B/Sources
```

Sharing the exact checkout is an explicit **Join this checkout** action. If an inherited relative
subdirectory does not exist in the new checkout, warn and fall back to checkout root rather than
launching at an invalid path.

## Layer 4 — semantic references

Natural language needs stable, visible targets.

Recommended reference kinds:

```text
@agent:sidebar-review
@session:print-path-investigation
@tile:launch-observations
@zone:continuum
@project:continuum-overnight
@file:Sources/ContinuumRevived/CanvasNSView.swift
```

The UI may display friendly chips while persisting stable opaque IDs. Names are searchable aliases,
not identity, because they can collide or change.

### One reference index, several modes

#### Location mode

Search projects, agents, checkouts, and directories to bind or move an agent.

#### Reference mode

Back composer `@` with real agents, sessions, files, directories, tiles, zones, and canvas artifacts.
A directory reference is semantic; it does not inject an entire tree into context.

#### Global mode

Replace the tmux switch/create surface. Selecting an existing agent focuses its tile. Selecting a
project navigates or creates context there. An explicit modified action creates another agent.

All modes share identity, recency, fuzzy scoring, spatial data, active-agent state, and preview
rendering so the switcher, status, `@`, and canvas tools cannot disagree.

### Reference freshness

A reference to a running session or changing tile must report snapshot freshness. Provider
transcript files may lag in-memory work.

```text
Captured through turn 18 · updated 12s ago
Agent currently working on turn 19
```

Never represent a partial transcript snapshot as current without such evidence.

## Layer 5 — the canvas harness

Pi's philosophy explicitly supports building a custom harness through prompts, skills, extensions,
tools, SDK, or RPC. Continuum should use each mechanism for the smallest responsibility it fits.

### Tiny always-present prompt

A short provider-neutral instruction is sufficient:

```text
## Continuum

You are a managed agent on a spatial canvas.

Your stable identity, Home, and Where are supplied by Continuum. What you are
currently doing is observed from actual lifecycle and tool events; do not invent
or self-report it.

You may query the canvas and message other managed agents through the provided
Continuum tools. Resolve spatial references with canvas_query; never guess agent,
tile, or session identifiers.

Messages to other agents are attributed and visible to the user. Do not read
another session's raw storage or communicate through hidden filesystem side
channels.
```

Dynamic facts should be a small per-session or per-turn envelope, not a large system prompt:

```text
Self: agent:sidebar-review
Tile: tile:7f92
Home: continuum-overnight
Where: Sources/ContinuumRevived
Zone: continuum
```

### Explicit tools

Initial tools:

```text
canvas_query
  resolve nearby/directional/zone/entity references

agent_message
  send an attributed message through the Continuum broker
```

Later tools:

```text
canvas_inspect
session_inspect
agent_spawn
canvas_place
canvas_focus
```

Tools should return resolved stable identities and observable evidence:

```text
Resolved “agent to my left”
Agent:    Pi session scout
ID:       agent:pi-session-scout
Tile:     tile:b832
Distance: 212pt
State:    idle
As of:    14s ago
```

### On-demand skill

A `continuum-canvas` skill provides richer workflows without occupying every turn's context.

```yaml
---
name: continuum-canvas
description: Query the Continuum canvas, resolve spatial references, inspect or
  reference another agent/session, message another agent, or create/place an
  agent relative to a tile. Use when the user refers to this tile, nearby
  objects, directions, zones, another agent, another session, or coordination.
---
```

The skill explains:

- deictic and directional resolution;
- message versus inspect/resume/fork;
- spawning and placement;
- freshness and transcript limits;
- avoiding recursive agent chatter.

A skill alone cannot communicate. The host/extension tools provide capability; the skill only
teaches workflows. Conversely, the tiny prompt is always present because skills do not always load
automatically.

### Minimal automatic canvas context

Do not inject the complete canvas or nearby transcripts into every prompt. A small envelope is
enough:

```text
You are agent:sidebar-review in tile:7f92, inside zone:continuum.
Nearby: 2 agents, 1 note, 1 file tree.
Use canvas tools when those entities are relevant.
```

Detailed context remains on demand through explicit tools and visible references.

## Layer 6 — agent and session coordination

### Agent-to-agent messaging

Messaging should be a real Continuum mailbox, not direct peer sockets, transcript mutation, or files
left for another agent to discover.

```text
Sender agent
  └─ agent_message(target, body)
       └─ Continuum broker
            ├─ resolve and authorize stable target
            ├─ persist visible attributed envelope
            ├─ enforce delivery/loop policy
            └─ deliver through recipient RPC/SDK session
```

The broker gives Continuum one place for routing, visibility, queueing, provider adaptation, and
safety.

### Message envelope

```text
AgentMessageEnvelope
  messageId
  fromAgentId
  toAgentId
  body
  sentAt
  replyTo?
  conversationId?
```

Message delivery state can remain small and secondary:

```text
queued | delivered | replied | failed
```

Those are message facts, not additional agent lifecycle states.

### Pi recipient delivery

A Continuum Pi extension can inject an attributed custom message with `pi.sendMessage()`:

```typescript
pi.sendMessage({
  customType: "continuum.agent-message",
  content: "…",
  display: true
}, {
  deliverAs: "followUp",
  triggerTurn: true
})
```

Default delivery waits until the recipient finishes its current work. An explicitly urgent action
may steer. If idle, the message may trigger a response according to broker policy. RPC extension
commands or a host-bound extension channel can bridge the broker into the recipient process.

### Visible exchange

Sender tile:

```text
→ Pi session scout
  What did you find about Pi session handling?
```

Recipient tile:

```text
← Sidebar review
  What did you find about Pi session handling?
```

A subtle temporary connector or pulse between the two tiles can make the spatial exchange legible.
The transcript remains the durable evidence; animation is not the only signal.

### Messaging safety

- Every message has an attributable sender and target.
- Agent-originated messages are visually distinct from Dylan-originated prompts.
- Default delivery does not interrupt active work.
- Receiving a message may produce one reply; replies do not require automatic further replies.
- Further chains require explicit tool calls and remain visible.
- The broker enforces hop/turn/rate limits to prevent recursive agent chatter.
- No agent reads another provider transcript path directly to simulate communication.

### Agent versus session operations

#### Message agent

Send work or a question to a durable worker.

#### Inspect session

Read a bounded, freshness-marked transcript snapshot or summary without modifying it.

#### Resume session

Continue the same provider conversation and identity.

#### Fork session

Create a new agent/session with copied conversation context while leaving the original unchanged.

#### Message a historical session

Not a valid primitive. A historical session must first be resumed/forked into an agent, or inspected
read-only. Continuum must not disguise resume as messaging.

Provider CLIs may support “ask this session a question” via resume, but that mutates the session by
adding a turn. Read-only inspection should parse a snapshot or use host-maintained summaries instead.

## Layer 7 — native UX

## Agent status presentation

Glance order remains:

```text
Home[/Where] · branch · model · effort · context
What
```

Example:

```text
continuum-overnight/Sources · agent/agent-ux · GPT-5.6 Sol · medium · ctx 72%
reading CanvasNSView.swift
```

Responsive tiers:

```text
continuum-overnight/Sources · main · ctx 72%
continuum…/Sources · ctx 72%
continuum… · reading CanvasNSView.swift
```

When Where is outside Home, the divergence receives a visible outbound marker. Full paths and
Home/Where details remain available through tooltip/disclosure.

The path is interactive and may offer:

- Change Where;
- Copy Path;
- Reveal in Finder;
- Open Terminal Here;
- Open File Tree;
- Return to Home;
- Register as Project;
- Join This Checkout, when applicable.

## 90 / 9 / 1 location interaction

### 90% — proximity

Create an agent near related work. The inferred Home appears immediately and the user starts typing
without a modal.

### 9% — native switcher

Click Home/Where or invoke the keyboard command. Nearby and Recent results are ranked first with full
keyboard navigation and fuzzy search.

### 1% — system picker

**Choose Folder…** or **Choose File…** opens `NSOpenPanel` for an unregistered/unindexed location.
The system picker is an escape hatch, not normal navigation.

## Native switcher

```text
Where should this agent work?
┌────────────────────────────────────────────────────────────┐
│ Search projects, folders, agents, or sessions…             │
├──────────────────────────────┬─────────────────────────────┤
│ NEARBY                       │ continuum-overnight         │
│ ● continuum-overnight        │ ~/Documents/personal/...   │
│   4 agents · active now      │                             │
│                              │ ▾ Sources                   │
│ RECENT                       │   ▸ ContinuumRevived        │
│   falcon                     │   ▸ ContinuumRevivedCore    │
│   selectus                   │ ▸ docs                      │
│   personal-website           │   Package.swift             │
│                              │                             │
│ WORK / PERSONAL              │ branch  main                │
│   …                          │ agents  4 active            │
├──────────────────────────────┴─────────────────────────────┤
│ ↵ Choose   ⌘↵ New agent   → Preview   ⇧⌘O Choose Folder… │
└────────────────────────────────────────────────────────────┘
```

Rows may show:

- entity/project/session identity and shortened path;
- branch/worktree;
- active-agent state/count;
- dirty Git state;
- recency;
- proximity provenance;
- transcript freshness for sessions.

Preview may show a native outline tree, breadcrumbs, Git status, active agents, and a short
README/project or session summary. It loads asynchronously and never blocks first useful results.

Responsive behavior:

- wide canvas: split list/preview;
- medium: compressed preview;
- narrow tile: list first, explicit preview navigation;
- insufficient anchor space: detach and center over canvas rather than crushing into a popover.

## Existing sessionizer behavior to preserve

Dylan's tmux sessionizer searches:

```text
~/Documents          depth 1
~/Documents/personal depth 1
~/Documents/work     depth 1
```

It combines recent sessions, discovered directories, fuzzy matching, a 50% preview, a two-level tree,
and Enter as switch-or-create. Continuum should preserve this speed and information scent while
improving identity, previews, native interaction, spatial inference, and same-name collision safety.

## Ranking and indexing

With an empty query, rank:

1. explicit anchor/selected entity;
2. inferred nearby context;
3. projects represented by nearby entities;
4. recent agents/sessions/locations;
5. active agent locations;
6. current workspace projects;
7. bounded shallow discovered directories.

Discovery remains bounded; never recursively scan all of `$HOME`. Registered projects and semantic
entities are cached. File indexes update incrementally. Preview and summary work is asynchronous.

Fuzzy matching accepts name and path fragments:

```text
cont src → continuum-overnight/Sources
sidebar review → agent:sidebar-review
print path → session:print-path-investigation
```

## Direct manipulation and spatial actions

Useful optional actions:

- drop a folder on an untouched agent to propose Home/Where;
- drop a folder on the status path to request a switch;
- place a file-tree/terminal nearby to contribute scope/context;
- right-click a project for New Agent, New File Tree, Open Terminal, or Reveal;
- drag an agent/session reference chip into another composer;
- create an agent relative to an explicit tile;
- copy/paste an absolute path into fuzzy search.

Natural requests should become explicit tool calls:

```text
“Compare this with the agent to my left.”
“Summarize the session in the tile above this one.”
“Make a review agent to the right of this tile.”
“Find agents in this zone that touched CanvasNSView.swift.”
“Ask the nearest idle Continuum agent to review this.”
```

A placement/spawn tool resolves the anchor first and returns the created agent/tile IDs and chosen
placement. The user-visible canvas mutation is never hidden inside prose.

## Explicit location changes

Before the first prompt, selecting a result changes the provisional Home/Where.

After work begins, a same-project Where change occurs only between turns. A cross-project change
should initially offer:

- **Open a new agent here**;
- Cancel.

Cross-project **Continue this agent here** is a later/advanced possibility because it changes
instructions, Git identity, indexes, transcript interpretation, and isolation. If eventually shipped,
it records a durable visible event:

```text
Home changed from continuum-overnight to new-project.
Where changed from continuum-overnight/Sources to new-project/src.
```

No switch occurs mid-turn or solely because a tile moved.

## Observable What derivation

For Pi, lifecycle and tool events provide direct evidence:

```text
tool_execution_start(read, path)
  → reading <path>

tool_execution_start(edit, path)
  → editing <path>

tool_execution_start(bash, command)
  → running <safe command summary>

agent_start / turn_start
  → thinking or working

agent_settled
  → waiting / completed according to existing lifecycle rules

agent_message broker event
  → messaging <agent>
```

Tool arguments must be sanitized, path-shortened, and bounded before display/sync. What should not
expose secrets, full prompts, raw command bodies, private transcript paths, or unbounded output.
Existing lifecycle state remains authoritative; What is a descriptive activity line, not another
lifecycle classifier.

## Security and trust boundaries

- Spatial and activity payloads never include raw provider session IDs, transcript paths, resume
  cursors, worktree secrets, or full prompts.
- Project-local Pi extensions/skills remain subject to Pi project trust.
- Continuum-owned global extension/tool code is reviewed and host-controlled.
- External directories carry explicit authority and lifetime.
- Session inspection is bounded, local, freshness-marked, and read-only by default.
- Messaging and spawning are visible side effects with stable attribution.
- Canvas tools never infer authorization from proximity alone.
- Notes/browser tiles can contribute context but never grant filesystem access.
- The host broker validates all sender and recipient identities; models cannot fabricate routable IDs.
- Companion sync receives only approved semantic summaries, never host-local paths/handles prohibited
  by the existing I5 boundary.

## Delivery strategy

Future-proof the identities, telemetry, and extension points now; do not attempt to ship every layer
in one change.

### Phase A — contracts and telemetry

- define provider-neutral Home/Where/What types;
- preserve separate project, checkout, relative directory, agent, tile, and session identities;
- derive Pi What from real events;
- add status/disclosure presentation;
- keep external paths visibly outside Home.

### Phase B — location UX

- project-zone and nearby-agent Home inference;
- provisional/pinned behavior;
- native project/folder switcher;
- explicit external folder registration;
- worktree-safe launch and relative-directory mapping;
- remove hidden process-cwd fallback.

### Phase C — persistent Pi harness

- replace one-shot `PiAgentRunner` control with app-owned RPC/SDK sessions;
- retain event fan-out and stable `AgentSupervisor` ownership;
- expose truthful steer/follow-up capabilities;
- inject the tiny Continuum identity prompt;
- load Continuum tools/skill through reviewed resources.

### Phase D — scene graph and references

- register stable `CanvasEntity` records;
- spatial query service over world-coordinate frames;
- explicit deictic anchor resolution;
- `@agent`, `@session`, `@tile`, `@zone`, and `@project` chips;
- bounded inspect/preview with snapshot freshness.

### Phase E — messaging

- Continuum mailbox/broker;
- `agent_message` tool;
- recipient custom-message delivery through Pi extension/RPC;
- visible send/receive/reply transcript blocks;
- bounded loop/rate policy;
- optional spatial connector animation with nonvisual equivalent.

### Phase F — canvas actions and global navigation

- agent spawn/place relative to entities;
- session inspect/resume/fork flows;
- global sessionizer mode;
- file/directory reference mode and shared file index;
- trustworthy terminal/file-tree scope emitters;
- richer cross-provider adapters.

## Implementation seams to investigate when scheduled

- `WorkspaceRuntime.activeController` and active-zone/project resolution;
- per-project `TileSpawner` construction and ambient/group-zone behavior;
- `AgentSupervisor` ownership and its planned RPC transition;
- `PiAgentRunner`, `PiEventTranslator`, and managed activity projection;
- `AgentRecord.cwd`, project ID, worktree branch, and a future explicit scope representation;
- `ManagedAgentSessionRecord`/I5 local-only boundaries;
- stable tile/agent/session reference registry;
- installed-view geometry and a world-coordinate spatial index;
- completion-provider registry and `FileTreeScanner` reuse;
- terminal cwd reporting and provider-specific telemetry;
- cached shallow discovery and incremental indexing;
- responsive native panel/outline infrastructure and accessibility;
- host-local message broker, recipient delivery, and loop control;
- Pi extension loading, prompt injection, and skill packaging.

## Non-goals

- Do not make workspace roots the implicit cwd for every agent.
- Do not silently redefine Home when Where or What moves outside it.
- Do not inject complete directory trees, canvases, or transcripts into every prompt.
- Do not infer project identity from conversational prose when spatial/explicit scope exists.
- Do not let moving an active tile mutate Home or Where.
- Do not silently share another agent's isolated worktree.
- Do not make Finder traversal the primary location flow.
- Do not let agents communicate through hidden files or direct unaudited peer sockets.
- Do not treat inspecting, messaging, resuming, and forking a session as one ambiguous operation.
- Do not let spatial proximity grant write/execute authority.
- Do not create an autonomous recursive agent society without visible bounded user intent.

## Full implementation checklist

This is the implementation ledger for the complete direction. Items are ordered by dependency, not
by visual prominence. A later phase must not silently implement an unresolved owner-policy item from
an earlier phase.

Checklist evidence rules:

- capture RED behavior before implementation for every independently testable rule;
- keep existing test expectations unless the requirement is explicitly confirmed;
- distinguish unit/mechanical evidence from real-route and supervised evidence;
- do not call a user-visible feature verified without exercising the real app route;
- do not bless screenshots, baselines, permissions, or supervised gates automatically;
- preserve the current canvas regression patch as a separate reviewable change.

### P0 — boundaries, dependencies, and baseline

- [x] **P0.1** Record the product model and architecture layers in this document.
- [x] **P0.2** Inspect Claude Home/Where/access/activity telemetry and session behavior.
- [x] **P0.3** Inspect Pi prompts, extensions, skills, SDK, RPC, and session behavior.
- [x] **P0.4** Confirm current Continuum Pi execution is one-shot JSON print mode with no persistent
  steer/follow-up channel.
- [x] **P0.5** Map this work onto existing Queue 90/91 phases so the Pi RPC transition has one owner.
- [x] **P0.6** Inventory current persisted agent/session fields and migration behavior before changing
  schemas.
- [x] **P0.7** Inventory all current status/activity projections so Home/Where/What has one canonical
  derivation.
- [x] **P0.8** Record the existing managed-agent fixture and compatibility expectations before RED.
- [x] **P0.9** Keep the already-modified `CanvasNSView.swift` and `TileNSView.swift` repair patch out
  of spatial-awareness changes unless a later spatial feature genuinely requires them.
- [x] **P0.10** Decide whether implementation proceeds in the current dirty tree or only after Dylan
  authorizes separating the existing canvas repair into a commit/worktree.
- [ ] **P0.11** Confirm the first release boundary and explicitly defer every out-of-scope phase.

Exit gate:

- implementation dependencies and persistence compatibility are written down;
- current fixtures pass unchanged;
- the first slice has named RED checks and does not touch the live P3.6 candidate/store.

### P1 — core identity and location contracts

- [x] **P1.1** Define a stable project/Home identity independent of display name and absolute cwd.
- [x] **P1.2** Represent the concrete checkout root separately from logical project identity.
- [x] **P1.3** Represent a relative working directory separately from checkout root.
- [x] **P1.4** Represent Where as an absolute resolved directory plus `root | inside | outside`
  relation to Home.
- [x] **P1.5** Represent What as an observed operation, optional target, timestamps, source evidence,
  and relation to Home.
- [ ] **P1.6** Represent access roots separately from Home/Where with capability, provenance, and
  lifetime.
- [ ] **P1.7** Preserve distinct IDs for workspace, project, checkout, agent, tile, provider session,
  Continuum session reference, and zone.
- [ ] **P1.8** Define explicit provenance for Home/Where proposals: zone, proximity, entity, manual,
  restored, and workspace default.
- [ ] **P1.9** Define provisional versus pinned scope state without deriving it from tile position at
  read time.
- [x] **P1.10** Preserve Codable/versioning behavior so existing persisted agents read without data
  loss; keep the new host-path snapshot deliberately non-Codable.
- [x] **P1.11** Keep raw provider session IDs, transcript paths, resume/runtime payloads, and pane
  handles out of the provider-neutral snapshot and in local/private records only.
- [x] **P1.12** Define one canonical `AgentLocationSnapshot` or equivalent projection consumed by UI,
  tools, and provider adapters.

RED checks:

- [x] **P1.R1** Existing persisted records decode with the same effective cwd and project behavior.
- [x] **P1.R2** An outside Where does not mutate Home.
- [x] **P1.R3** An outside What target does not mutate Home or Where.
- [x] **P1.R4** Two agents in one project can have different checkouts and relative directories.
- [x] **P1.R5** The host-path snapshot is non-Codable and existing companion/spatial projections
  remain I5-clean without provider/runtime routing fields.
- [ ] **P1.R6** Provisional provenance survives persistence and restore.

Exit gate:

- core contracts are provider-neutral and migration-safe;
- all RED checks are GREEN without modifying historical fixture expectations.

### P2 — Home / Where / What derivation

- [x] **P2.1** Derive Home from the authoritative agent/project/checkout record.
- [x] **P2.2** Derive Where from the runtime cwd/location operation rather than recent file activity.
- [ ] **P2.3** Classify Where relative to Home using normalized/symlink-aware path policy.
- [x] **P2.4** Convert read events into bounded `reading <target>` activity.
- [x] **P2.5** Convert edit/write events into bounded `editing <target>` activity.
- [x] **P2.6** Convert Bash/process events into `running` activity without retaining raw command
  bodies; defer command summaries until an explicit safe-summary policy exists.
- [x] **P2.7** Convert search/list/index operations into useful bounded What activity while retaining
  only optional filesystem scope, never query/pattern bodies.
- [x] **P2.8** Convert agent lifecycle events into thinking, waiting, completed, interrupted, and
  failed descriptions without replacing the existing lifecycle classifier.
- [ ] **P2.9** Convert broker events into messaging/receiving activity.
- [x] **P2.10** Attach evidence timestamps and expire/stale old What values predictably.
- [x] **P2.11** Deduplicate noisy repeated tool updates while preserving meaningful target changes.
- [x] **P2.12** Redact secrets, full prompt text, raw command bodies, private paths, and unbounded tool
  output from shared/summary surfaces; keep bounded canonical targets host-local only.
- [x] **P2.13** Preserve the last useful activity separately from currently active operation when the
  UX requires both.
- [x] **P2.14** Project one canonical location/activity snapshot through `AgentSupervisor` events.

RED checks:

- [x] **P2.R1** Read, edit, Bash, search, wait, interrupt, and failure events produce expected What.
- [x] **P2.R2** Activity against an external path is visibly external while Home remains stable.
- [x] **P2.R3** Bash containing textual `cd` does not change Pi Where by parser inference.
- [x] **P2.R4** Redaction and truncation prevent known secret/long-input fixtures from leaking.
- [x] **P2.R5** Stale activity expires without changing lifecycle state.
- [x] **P2.R6** Event fan-out does not duplicate or reorder terminal lifecycle transitions.

Exit gate:

- deterministic mechanical checks cover all supported event classes;
- a real Pi JSON run visibly updates What in the app without self-report.

### P3 — native status and disclosure UX

- [x] **P3.1** Replace cwd-only presentation with Home/Where/What projection.
- [x] **P3.2** Collapse Home and Where when equivalent.
- [x] **P3.3** Show a clear outbound marker when Where is outside Home.
- [x] **P3.4** Show a clear outbound marker when What targets an external path.
- [ ] **P3.5** Preserve branch, model, effort, context usage, and lifecycle information at responsive
  widths.
- [ ] **P3.6** Provide full Home/Where/provenance/access details through tooltip or native disclosure.
- [ ] **P3.7** Add keyboard-accessible path actions: change, copy, reveal, terminal, file tree, and
  return Home where supported.
- [ ] **P3.8** Ensure VoiceOver announces Home, Where divergence, What, and lifecycle independently.
- [x] **P3.9** Ensure truncation never hides the fact that Where/What is external.
- [ ] **P3.10** Preserve status readability in narrow tiles, expanded tiles, sidebar rows, and reduced
  motion/high contrast modes.

RED/mechanical checks:

- [x] **P3.R1** Equivalent Home/Where renders once.
- [x] **P3.R2** Inside, outside, missing, and stale What fixtures render distinct truthful states.
- [x] **P3.R3** Accessibility tree exposes stable labels and values without duplicate announcements.
- [x] **P3.R4** Narrow-width fixtures retain project identity and external divergence.

Supervised gate:

- [x] **P3.S1** Inspect live status changes during real read/edit/Bash/wait transitions.
- [ ] **P3.S2** Review path hierarchy, truncation, contrast, keyboard behavior, and VoiceOver (VoiceOver
  is explicitly deferred from the current owner-testing effort; do not infer completion from AX checks).
- [ ] **P3.S3** Obtain explicit owner acceptance; do not infer it from mechanical checks.

### P4 — provisional Home and context gravity

- [ ] **P4.1** Register project zones as authoritative Home signals.
- [ ] **P4.2** Register managed agents as stable Home/check-out/relative-directory signals.
- [ ] **P4.3** Define which terminal/file-tree entities may emit proven scope.
- [ ] **P4.4** Compute zoom-independent distance between world-coordinate frames.
- [ ] **P4.5** Rank containing zone ahead of nearby entities.
- [ ] **P4.6** Rank nearby agreement ahead of a single incidental signal.
- [ ] **P4.7** Use only an explicit workspace default when no spatial signal exists.
- [ ] **P4.8** Open the switcher when neither spatial context nor explicit default exists.
- [ ] **P4.9** Never fall back silently to the Continuum process cwd.
- [ ] **P4.10** Infer project more readily than exact subdirectory.
- [ ] **P4.11** Map inherited relative directories into each new isolated checkout.
- [ ] **P4.12** Warn and fall back to checkout root when a relative directory is absent.
- [ ] **P4.13** Never inherit another agent's isolated absolute worktree by proximity.
- [ ] **P4.14** Display provisional provenance immediately on a zero-turn agent.
- [ ] **P4.15** Recompute provisional scope only after settled movement, not every drag frame.
- [ ] **P4.16** Freeze automatic inference at the owner-approved composer/reference/manual/submission
  boundary.
- [ ] **P4.17** Never change Home/Where by moving an active or restored tile.
- [ ] **P4.18** Provide an explicit Join This Checkout action with collision/concurrency disclosure.

RED checks:

- [ ] **P4.R1** Containing project zone wins over a nearby cross-project tile.
- [ ] **P4.R2** A nearby agent's external What does not influence new-agent Home.
- [ ] **P4.R3** Multiple nearby agents agree on project without forcing an incidental subdirectory.
- [ ] **P4.R4** Zoom changes do not alter nearest-neighbor results.
- [ ] **P4.R5** Dragging an active tile never mutates scope.
- [ ] **P4.R6** Composer/reference/manual freeze events prevent later reinference.
- [ ] **P4.R7** Empty-canvas behavior never selects app process cwd.
- [ ] **P4.R8** Isolated checkout inheritance produces the new agent's own absolute path.

Real-route gate:

- [ ] **P4.S1** Create agents inside/outside zones and inspect visible provisional provenance.
- [ ] **P4.S2** Move untouched and active agents across project clusters and verify freeze behavior.
- [ ] **P4.S3** Obtain owner acceptance of inference feel and failure behavior.

### P5 — location/sessionizer switcher and index

- [ ] **P5.1** Define a shared searchable index over projects, directories, agents, sessions, tiles, and
  zones.
- [ ] **P5.2** Preserve stable IDs while allowing friendly labels and aliases to change.
- [ ] **P5.3** Implement bounded shallow discovery roots; never recursively scan all of `$HOME`.
- [ ] **P5.4** Cache registered project metadata, recency, Git identity, and active-agent counts.
- [ ] **P5.5** Add incremental file indexing where file reference mode requires it.
- [ ] **P5.6** Implement fuzzy name/path matching and collision-safe result labels.
- [ ] **P5.7** Rank anchor, nearby context, nearby projects, recency, active agents, workspace projects,
  then bounded discovery.
- [ ] **P5.8** Build a native keyboard-first result list with asynchronous preview.
- [ ] **P5.9** Build project directory preview using a native outline/tree.
- [ ] **P5.10** Show branch/worktree, dirty state, agent activity, proximity, and session freshness.
- [ ] **P5.11** Support wide split view, compressed preview, narrow drill-in, and centered fallback.
- [ ] **P5.12** Preserve tmux-sessionizer speed: immediate results, fuzzy filtering, preview, and
  switch-or-create semantics.
- [ ] **P5.13** Provide explicit Choose Folder/File through `NSOpenPanel` as an escape hatch.
- [ ] **P5.14** Define location mode, reference mode, and global navigation mode over the shared index.
- [ ] **P5.15** Audit and assign conflict-free keyboard shortcuts.

RED/mechanical checks:

- [ ] **P5.R1** Ranking fixtures cover spatial, recent, active, workspace, and discovered results.
- [ ] **P5.R2** Same-name projects/sessions remain unambiguous.
- [ ] **P5.R3** Empty query and partial path fragments produce deterministic results.
- [ ] **P5.R4** Discovery obeys depth/root bounds and cancellation.
- [ ] **P5.R5** Preview loading cannot block typing/selection.
- [ ] **P5.R6** Keyboard and accessibility actions cover search, select, preview, create, and picker.

Supervised gate:

- [ ] **P5.S1** Compare real switch/create speed against Dylan's tmux-sessionizer workflow.
- [ ] **P5.S2** Review narrow/wide layouts, keyboard feel, VoiceOver, and large-index latency.
- [ ] **P5.S3** Obtain explicit owner acceptance.

### P6 — persistent Pi RPC/SDK runtime

- [ ] **P6.1** Confirm whether RPC subprocesses or embedded SDK sessions are the first production
  transport.
- [ ] **P6.2** Preserve `AgentSupervisor` as owner independently of tile lifecycle.
- [ ] **P6.3** Introduce a long-lived runtime per managed Pi agent with explicit startup/shutdown.
- [ ] **P6.4** Resume existing stable Pi sessions without losing conversation continuity.
- [ ] **P6.5** Map RPC/SDK events into the existing provider event stream.
- [ ] **P6.6** Implement prompt, follow-up, steer, interrupt, and queue semantics truthfully.
- [ ] **P6.7** Advertise capabilities only when the active runtime supports them.
- [ ] **P6.8** Handle process crash, reconnect, timeout, malformed output, and orphan cleanup.
- [ ] **P6.9** Preserve per-agent cwd/Home and provider launch arguments across resume.
- [ ] **P6.10** Inject the tiny Continuum prompt without replacing higher-priority owner/project
  instructions.
- [ ] **P6.11** Load reviewed Continuum extension/tool resources through an explicit trusted path.
- [ ] **P6.12** Supply stable self/agent/tile/Home/Where facts through a bounded per-session envelope.
- [ ] **P6.13** Keep project-local Pi extension/skill loading subject to Pi trust behavior.
- [ ] **P6.14** Prevent duplicate prompt delivery during reconnect/retry.
- [ ] **P6.15** Define transcript/session persistence and migration from the one-shot runner.

RED/integration checks:

- [ ] **P6.R1** Resume preserves a known multi-turn conversation.
- [ ] **P6.R2** Follow-up waits behind active work and steer reaches active work when explicitly used.
- [ ] **P6.R3** Tile removal does not accidentally terminate an independently owned agent.
- [ ] **P6.R4** Crash/restart does not duplicate the last prompt.
- [ ] **P6.R5** Capability projection changes with runtime support.
- [ ] **P6.R6** Prompt envelope includes stable self facts but no prohibited private fields.
- [ ] **P6.R7** Existing one-shot fixtures either remain supported or migrate through an explicit
  compatibility path.

Real-route gate:

- [ ] **P6.S1** Run a real long-lived Pi session through prompt, active follow-up, steer, interrupt,
  settle, app relaunch, and resume.
- [ ] **P6.S2** Inspect transcript/event ordering and exact provider session continuity.
- [ ] **P6.S3** Obtain explicit owner acceptance before retiring the one-shot path.

### P7 — canvas entity index and spatial query service

- [ ] **P7.1** Register stable entities for agents, tiles, zones, notes, terminals, file trees, browser
  tiles, and future artifact types.
- [ ] **P7.2** Keep agent identity independent from zero, one, or multiple visual tiles.
- [ ] **P7.3** Maintain world-coordinate frames and visibility state for installed entities.
- [ ] **P7.4** Compute contains, overlap, nearest, radius, directional, same-zone, and same-project
  relations.
- [ ] **P7.5** Define deterministic tie-breaking and confidence/evidence output.
- [ ] **P7.6** Resolve composer-local `this/me/my tile` to the composing tile.
- [ ] **P7.7** Resolve global `this` only from an explicit selection/context-command anchor.
- [ ] **P7.8** Snapshot spatial resolution to stable IDs at invocation time.
- [ ] **P7.9** Return chosen target, distance/relation, state, and freshness visibly.
- [ ] **P7.10** Distinguish scope emitters from context-only entities.
- [ ] **P7.11** Exclude hidden/deleted/stale entities according to explicit query options.
- [ ] **P7.12** Keep detailed canvas context tool-driven rather than automatically injected.

RED checks:

- [ ] **P7.R1** Directional and nearest queries are invariant under zoom/pan.
- [ ] **P7.R2** Tie fixtures resolve deterministically or return ambiguity.
- [ ] **P7.R3** Moving an entity after resolution does not retarget the captured request.
- [ ] **P7.R4** Detached agents remain addressable but do not pretend to have visible geometry.
- [ ] **P7.R5** Notes/browser tiles never emit filesystem authority.
- [ ] **P7.R6** Deleted/stale targets fail safely with a visible reason.

### P8 — semantic references and bounded inspection

- [ ] **P8.1** Implement reference records for agent, session, tile, zone, project, file, and directory.
- [ ] **P8.2** Render friendly chips while persisting stable opaque IDs.
- [ ] **P8.3** Back composer `@` completion with the shared index.
- [ ] **P8.4** Resolve pasted absolute/relative paths against explicit Home/Where rules.
- [ ] **P8.5** Treat directory references semantically; never inject entire trees automatically.
- [ ] **P8.6** Define bounded file/context retrieval through explicit tools.
- [ ] **P8.7** Implement read-only session snapshot inspection.
- [ ] **P8.8** Report transcript freshness cursor/time and active-turn lag.
- [ ] **P8.9** Prevent inspection from appending a provider turn.
- [ ] **P8.10** Define explicit resume and fork actions separately from inspect.
- [ ] **P8.11** Show broken/deleted/unavailable references without silently retargeting.
- [ ] **P8.12** Keep provider session IDs and transcript paths hidden behind local resolution.

RED checks:

- [ ] **P8.R1** Renaming a friendly target does not break its persisted reference.
- [ ] **P8.R2** Same-name entities produce distinct chips and previews.
- [ ] **P8.R3** Session inspect is byte-for-byte nonmutating to the provider conversation.
- [ ] **P8.R4** A running session reports an explicitly stale/partial snapshot.
- [ ] **P8.R5** Whole-directory/context injection cannot occur without an explicit bounded retrieval.
- [ ] **P8.R6** Companion/spatial output excludes private reference routing fields.

### P9 — canvas harness tools and skill

- [ ] **P9.1** Finalize the tiny provider-neutral Continuum system addition.
- [ ] **P9.2** Define the bounded dynamic self envelope.
- [ ] **P9.3** Implement `canvas_query` with explicit origin, relation, kind, and ambiguity behavior.
- [ ] **P9.4** Implement `canvas_inspect` for bounded semantic entity details.
- [ ] **P9.5** Implement `session_inspect` as read-only and freshness-aware.
- [ ] **P9.6** Register tools through the trusted Continuum Pi extension/runtime.
- [ ] **P9.7** Create the `continuum-canvas` skill for spatial resolution and coordination workflows.
- [ ] **P9.8** Ensure skill/tool descriptions do not imply unsupported messaging or placement
  capabilities.
- [ ] **P9.9** Inject only self/zone and nearby counts or a one-line roster automatically.
- [ ] **P9.10** Require tools for detailed neighboring context and session contents.
- [ ] **P9.11** Show tool resolutions/actions in the normal transcript/tool UI.
- [ ] **P9.12** Add version/capability negotiation between prompt, skill, extension, and host.

RED/integration checks:

- [ ] **P9.R1** “Agent to my left” resolves through `canvas_query`, not guessed prose.
- [ ] **P9.R2** Ambiguous/global `this` returns a clarification requirement.
- [ ] **P9.R3** Prompt context stays within the defined size/privacy envelope on a dense canvas.
- [ ] **P9.R4** Missing or older extension versions disable unsupported tool guidance truthfully.
- [ ] **P9.R5** Tools cannot fabricate or access an unregistered target ID.

### P10 — agent-to-agent mailbox and messaging

- [ ] **P10.1** Define the host-local `AgentMessageEnvelope` and persistence policy.
- [ ] **P10.2** Implement broker validation of sender, recipient, capability, and message size.
- [ ] **P10.3** Implement stable routing by Continuum `AgentID`, never provider session ID.
- [ ] **P10.4** Implement `agent_message` with explicit target/body/delivery intent.
- [ ] **P10.5** Default active-recipient delivery to follow-up rather than interruption.
- [ ] **P10.6** Offer steer only as an explicit urgent action when supported.
- [ ] **P10.7** Define idle-recipient wake versus queue behavior from the owner decision.
- [ ] **P10.8** Deliver attributed custom messages into Pi through the extension/RPC runtime.
- [ ] **P10.9** Render sender and recipient transcript blocks distinctly from Dylan prompts.
- [ ] **P10.10** Persist queued, delivered, replied, and failed evidence without making them agent
  states.
- [ ] **P10.11** Support explicit replies with `replyTo`/conversation identity.
- [ ] **P10.12** Enforce hop, turn, rate, and size bounds against recursive chatter.
- [ ] **P10.13** Prevent automatic rebroadcast or reply-required loops.
- [ ] **P10.14** Handle stopped, missing, failed, busy, and provider-incompatible recipients visibly.
- [ ] **P10.15** Do not treat a historical unattached session as a messageable agent.
- [ ] **P10.16** Update What while sending/receiving without overwriting lifecycle truth.
- [ ] **P10.17** Add optional transient spatial connector/pulse with reduced-motion and nonvisual
  equivalents.

RED/integration checks:

- [ ] **P10.R1** A message reaches the intended stable agent after its tile moves.
- [ ] **P10.R2** A busy recipient receives default follow-up only after current work.
- [ ] **P10.R3** Explicit urgent steer behaves truthfully when supported and fails visibly otherwise.
- [ ] **P10.R4** Sender/recipient attribution cannot be spoofed by message body text.
- [ ] **P10.R5** Loop bounds stop reciprocal automated messages deterministically.
- [ ] **P10.R6** Missing/stopped recipient produces a durable failure/queue result, not silent loss.
- [ ] **P10.R7** Messaging does not expose or mutate transcript storage directly.
- [ ] **P10.R8** App relaunch preserves or explicitly fails pending messages without duplication.

Real-route gate:

- [ ] **P10.S1** Run two real Pi agents through idle delivery, busy follow-up, reply, failure, relaunch,
  and bounded-loop scenarios.
- [ ] **P10.S2** Inspect both transcripts and canvas attribution/animation/accessibility.
- [ ] **P10.S3** Obtain explicit owner acceptance of interruption policy and interaction feel.

### P11 — session resume/fork and spatial creation actions

- [ ] **P11.1** Implement explicit resume of an existing managed/provider session.
- [ ] **P11.2** Implement fork into a new agent while preserving the original session.
- [ ] **P11.3** Record fork provenance and freshness/context boundary.
- [ ] **P11.4** Implement `agent_spawn` with Home/Where/role/provider inputs.
- [ ] **P11.5** Implement `canvas_place` relative to a resolved stable anchor.
- [ ] **P11.6** Return created agent/tile IDs and actual placement as observable tool output.
- [ ] **P11.7** Avoid overlap using bounded deterministic placement without moving unrelated tiles.
- [ ] **P11.8** Preserve project-zone containment or report when requested placement cannot.
- [ ] **P11.9** Require explicit user/tool action for every spawn, resume, fork, or placement mutation.
- [ ] **P11.10** Keep cross-project continuation separate; recommend New Agent in the first release.
- [ ] **P11.11** Focus existing agents from global navigation without creating duplicates.
- [ ] **P11.12** Support explicit modified action to create another agent for an existing project.

RED checks:

- [ ] **P11.R1** Fork leaves the source transcript/session unchanged.
- [ ] **P11.R2** Spawned agents receive their own checkout and correct relative directory.
- [ ] **P11.R3** Relative placement uses the captured anchor and returns actual geometry.
- [ ] **P11.R4** Failed placement/spawn produces no partial hidden entity.
- [ ] **P11.R5** Selecting an existing agent focuses it rather than duplicating it.

### P12 — provider adapters

- [ ] **P12.1** Define provider-neutral capability/telemetry protocols for Home, Where, What, access,
  message delivery, session inspect, resume, and fork.
- [ ] **P12.2** Implement Pi runtime adapter against the persistent RPC/SDK path.
- [ ] **P12.3** Map Claude `project_dir`, `current_dir/cwd`, `added_dirs`, and worktree fields.
- [ ] **P12.4** Map Claude hooks into observable What and Where changes where available.
- [ ] **P12.5** Preserve provider-specific differences rather than claiming false parity.
- [ ] **P12.6** Keep unsupported capabilities disabled in tools and UI.
- [ ] **P12.7** Define migration/resume behavior when switching provider or adapter version.
- [ ] **P12.8** Add fixtures for missing, malformed, old, and partial provider telemetry.

Exit gate:

- provider differences are explicit and tested;
- the shared UI/harness consumes only the provider-neutral contract.

### P13 — external access and authorization

- [ ] **P13.1** Resolve the owner policy for temporary automatic read-only external references.
- [ ] **P13.2** Implement explicit capability distinctions: read, write, and execute.
- [ ] **P13.3** Implement lifetime distinctions: turn, session, and durable registration.
- [ ] **P13.4** Display newly resolved external roots and their authority/lifetime.
- [ ] **P13.5** Require explicit approval/policy before write or execution outside existing authority.
- [ ] **P13.6** Keep external reference, working root, and registered project as separate actions.
- [ ] **P13.7** Normalize paths and defend against symlink/alias escape from granted roots.
- [ ] **P13.8** Handle unavailable/removable volumes and revoked roots visibly.
- [ ] **P13.9** Ensure proximity, notes, messages, and session context never grant access.
- [ ] **P13.10** Audit provider flags/permissions so host UI authority matches actual capability.

RED/security checks:

- [ ] **P13.R1** Read authority cannot write or execute.
- [ ] **P13.R2** Relative and symlink traversal cannot escape the granted root.
- [ ] **P13.R3** Expired/revoked access fails visibly without changing Home.
- [ ] **P13.R4** A message referencing a path grants no authority to its recipient.
- [ ] **P13.R5** Durable project registration requires an explicit user action.

### P14 — accessibility, performance, privacy, and resilience

- [ ] **P14.1** Provide VoiceOver names/values/actions for status, references, search, messages, and
  spatial results.
- [ ] **P14.2** Provide keyboard equivalents for every essential mouse/spatial action.
- [ ] **P14.3** Preserve visible/nonvisual message evidence when motion is reduced.
- [ ] **P14.4** Meet existing contrast floors without lowering baselines/tolerances.
- [ ] **P14.5** Bound prompt envelope size, tool result size, message size, transcript snapshots, and
  index results.
- [ ] **P14.6** Keep spatial queries responsive on a dense canvas and cancel stale preview/index work.
- [ ] **P14.7** Keep Home/Where/What updates on the correct actor without event races.
- [ ] **P14.8** Verify app relaunch/restoration of locations, references, runtime state, and queued
  broker records.
- [ ] **P14.9** Redact private fields from logs, QA manifests, crash reports, and companion sync.
- [ ] **P14.10** Threat-model fabricated IDs, prompt injection in agent messages, path escape, replay,
  duplicate delivery, and extension version mismatch.
- [ ] **P14.11** Verify no hidden filesystem communication path is introduced.
- [ ] **P14.12** Add diagnostics for routing/resolution failures without exposing message contents or
  private paths unnecessarily.

### P15 — documentation, migration, and release gates

- [ ] **P15.1** Update the Queue 91 design/ledger with the approved release boundary.
- [ ] **P15.2** Document Home/Where/What in user-facing language and provider-neutral developer terms.
- [ ] **P15.3** Document tool schemas, stable identity rules, and broker delivery semantics.
- [ ] **P15.4** Document persistence migration and rollback behavior.
- [ ] **P15.5** Document privacy boundaries and which fields may sync to companion clients.
- [ ] **P15.6** Create focused mechanical QA commands for each shipped layer.
- [ ] **P15.7** Create real-route multi-agent QA with durable manifests and transcript evidence.
- [ ] **P15.8** Run existing complete test/build matrix without lowering assertions or counts.
- [ ] **P15.9** Run repeated focused legs for event ordering, messaging, relaunch, and spatial queries.
- [ ] **P15.10** Run accessibility, keyboard, reduced-motion, and narrow/wide supervised review.
- [ ] **P15.11** Keep screenshot/baseline differences red until Dylan explicitly accepts or blesses
  them.
- [ ] **P15.12** Obtain explicit owner acceptance for every supervised gate.
- [ ] **P15.13** Record exact implementation commits, runtime/provider versions, artifacts, and known
  limitations.
- [ ] **P15.14** Do not advertise messaging, session inspection, or spatial actions before their
  truthful capability gates are GREEN.

## First implementation slice

Status: implemented and mechanically GREEN on 2026-08-06; not committed.

The first slice stayed below UI and Pi RPC:

1. Completed **P0.5–P0.10** as a bounded code/persistence seam audit.
2. Captured RED core checks for **P1.R1–P1.R5** using a literal legacy persisted-agent fixture.
3. Added the smallest provider-neutral Home/Where/What contracts needed to turn those checks GREEN
   while preserving current `AgentRecord.cwd` compatibility.

Implemented files:

```text
Sources/ContinuumRevivedCore/Agents/AgentLocationSnapshot.swift
Sources/ContinuumRevivedCoreChecks/AgentLocationChecks.swift
Sources/ContinuumRevivedCoreChecks/main.swift
```

Contract outcome:

- `AgentHome` separates logical project root from concrete checkout root;
- `AgentWorkingLocation` supplies normalized Where, relative path, and component-safe
  `root | inside | outside` classification;
- `AgentObservedActivity` supplies operation, optional path target, timestamps, and evidence source;
- `AgentLocationSnapshot` owns the target-to-Home relation so provider evidence cannot carry stale
  scope;
- legacy `AgentRecord.cwd` remains both concrete checkout and Where until a later persisted-location
  migration;
- the host-path snapshot is intentionally not Codable; sync requires a separate scrubbed projection.

Evidence:

```text
Baseline CoreChecks: /tmp/continuum-location-baseline.m0pfmT/output.log
RED missing contracts: /tmp/continuum-location-red.kSl2FY/output.log
Focused GREEN: /tmp/continuum-location-green2.bNIEBk/output.log
Full Core + Sync + build GREEN: /tmp/continuum-location-final.zFFf1W/output.log
Read-only seam audit: .pi/agent-runs/code-scout-20260806T152544Z-3441db/final.md
```

This slice proves the most important invariant before adding UI or inference:

> an agent can work or act outside its project without silently changing the project it belongs to.

P4 proximity behavior, P6 RPC, and P10 messaging remain untouched. Messaging depends on persistent
runtime ownership; proximity depends on stable identity/location contracts.

## Second implementation slice — P2 host-local What projection

Status: implemented and mechanically GREEN on 2026-08-06; not committed; live Pi/UI gate still open.

Implemented files:

```text
Sources/ContinuumRevivedCore/Agents/AgentLocationProjector.swift
Sources/ContinuumRevivedCore/AgentProviders/PiEventTranslator.swift
Sources/ContinuumRevivedCore/AgentProviders/PiAgentRunner.swift
Sources/ContinuumRevived/App/AgentSupervisor.swift
Sources/ContinuumRevivedCoreChecks/AgentWhatProjectionChecks.swift
Sources/ContinuumRevivedCoreChecks/main.swift
```

Outcome:

- Pi emits explicit cwd and whitelisted tool operation/target facts through a non-Codable
  `AgentRuntimeObservation` callback separate from `AgentRuntimeEvent`;
- raw Bash commands, search queries, edit bodies, reasoning text, tool output, provider routing, and
  transcript bodies never enter the What projection or companion activity;
- relative tool targets resolve against explicit Pi runtime cwd; textual Bash `cd` never changes
  Where;
- `AgentLocationProjector` rejects out-of-order cwd/activity observations, deduplicates repeated
  meaning, expires current What predictably, and retains `lastUsefulWhat` separately;
- matching private observations suppress only one generic `itemStarted`; turn boundaries and
  completion cannot leave a reused ID permanently hidden;
- empty, control-character, and over-4,096-byte path text degrades to targetless local activity;
- `AgentSupervisor` owns the projector, preserves private-observation/event FIFO, removes projector
  state on archive, and fans out the original normalized events unchanged.

Evidence:

```text
RED missing P2 contracts: /tmp/continuum-what-red.UCwX8f/output.log
Focused hardening GREEN: /tmp/continuum-what-hardening2.hPQEcC/output.log
Supervisor ownership/fan-out GREEN: /tmp/continuum-what-supervisor2.OuAUxf/output.log
Full Core + Sync + build GREEN: /tmp/continuum-what-final2.ePIfxD/output.log
Seam audit: .pi/agent-runs/code-scout-20260806T155325Z-f33968/final.md
Initial code review: .pi/agent-runs/code-reviewer-20260806T160722Z-b2b8a7/final.md
Adversarial findings: .pi/agent-runs/platform-breaker-20260806T160736Z-73afd7/final.md
Adversarial re-review APPROVE: .pi/agent-runs/platform-breaker-20260806T161339Z-67078b/final.md
Final code re-review APPROVE: .pi/agent-runs/code-reviewer-20260806T161339Z-15db9b/final.md
```

The P2 exit gate is not complete: deterministic mechanical coverage is GREEN, but no authorized
normal app launch/live Pi run has visibly rendered What. Symlink-aware path authority remains P2.3,
and broker messaging remains P2.9.

## Third implementation slice — P3 native managed-tile status

Status: first tile slice implemented and mechanically GREEN on 2026-08-06; not committed; visual,
VoiceOver, disclosure-action, sidebar, and owner gates remain open.

Implemented files:

```text
Sources/ContinuumRevivedCore/Agents/AgentLocationStatusPresenter.swift
Sources/ContinuumRevived/Canvas/AgentTile/AgentLocationStatusView.swift
Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift
Sources/ContinuumRevived/App/ContinuumApp.swift
Sources/ContinuumRevived/App/UIProbeAppearance.swift
Sources/ContinuumRevived/App/UIProbeGeometry.swift
Sources/ContinuumRevived/App/ComponentLab.swift
Sources/ContinuumRevivedCoreChecks/AgentLocationPresentationChecks.swift
```

This slice also adds `whatExpiresAt` to the non-Codable snapshot/projector and expands the existing
supervisor/Core checks. It does not modify the separate `CanvasNSView.swift` / `TileNSView.swift`
interaction repair.

Outcome:

- one pure, bounded presenter collapses equivalent Home/Where and distinguishes inside, external,
  targetless, current, recent, and empty states;
- project display names come from the matching active project or registry identity rather than an
  isolated worktree's final path component;
- a two-row native band sits below the existing fixed header and above the transcript, preserving
  the header's branch/lifecycle/elapsed lanes and the composer footer's model/effort/context lanes;
- external Where and What each own a fixed, non-AX outbound-marker lane, so text truncation cannot
  erase divergence;
- the two semantic labels are the band's only accessibility children; lifecycle remains owned by
  the existing header;
- full host-local paths, timestamps, and evidence provenance are available in a tooltip/detail value
  without entering Codable records, runtime events, activity drafts, or sync;
- current What schedules one exact projector-owned stale boundary and rolls over to retained recent
  activity; detaching immediately demotes current What before removing its timer/source;
- token adoption, UI geometry, and contrast probes are GREEN, including a 320-point native fixture
  whose complete compact external text fits without truncation;
- Component Lab now renders all seven status states side-by-side at 420 and 320 points in Aqua and
  Dark Aqua, plus the full managed tile at 560 and 320 points with branch, lifecycle, transcript,
  external What, and composer metadata intact;
- integrated geometry asserts the real managed tile at 320/480/640/900 points in both appearances,
  including fixed-marker separation and location content bounds.

Evidence:

```text
Presenter RED: /tmp/continuum-location-presentation-red.yejJKv/output.log
Native wiring RED: /tmp/continuum-location-native-red.okAIyS/output.log
Presenter GREEN: /tmp/continuum-location-presentation-green5.6wBDIn/output.log
Native narrow/AX GREEN: /tmp/continuum-location-native-green5.V4UBLL/output.log
Detach/stale GREEN: /tmp/continuum-location-native-detach-green.nl5K1k/output.log
UI token probe GREEN: /tmp/continuum-location-ui-checks.Zwb4KR/ui-probe-check3.log
UI geometry GREEN: /tmp/continuum-location-ui-checks.Zwb4KR/ui-geometry-check.log
UI contrast GREEN: /tmp/continuum-location-ui-checks.Zwb4KR/ui-contrast-check.log
Initial full Core + AgentUI + Sync + build GREEN: /tmp/continuum-location-p3-final2.33eiRm/output.log
Component fixture RED: /tmp/continuum-location-lab-red2.BtN6Li/output.log
Integrated tile RED: /tmp/continuum-location-tile-fixture-red.KoffUh/output.log
Narrow full-tile RED: /tmp/continuum-location-narrow-tile-red.eupVkB/output.log
Integrated geometry GREEN: /tmp/continuum-location-integrated-geometry2.VH3h8Y/output.log
Final Core + AgentUI + Sync + build GREEN: /tmp/continuum-location-integrated-final.xZxusb/output.log
Real Pi Home/Where/What transitions GREEN: /tmp/continuum-location-live3.N79MUn/output.log
Real Pi capture manifest: /tmp/continuum-location-live3.N79MUn/captures/location-live.json
Two-turn stable-session continuity GREEN: /tmp/continuum-managed-live-fixed.YQuHi7/output.log
Unblessed visual candidates: qa-runs/2026-08-06T172616Z/
Code/UX seam audit: .pi/agent-runs/code-scout-20260806T162244Z-efc577/final.md
UX-state audit: .pi/agent-runs/ux-scout-20260806T162244Z-bab3af/final.md
Initial code review/rework: .pi/agent-runs/code-reviewer-20260806T164907Z-3c9e90/final.md
Detach follow-up APPROVE: .pi/agent-runs/code-reviewer-20260806T165323Z-3ab5cd/final.md
Initial UX review MANUAL_CHECK: .pi/agent-runs/ux-reviewer-20260806T164907Z-0fd38e/final.md
Status-matrix code review APPROVE: .pi/agent-runs/code-reviewer-20260806T171922Z-0e92de/final.md
Status-matrix UX review APPROVE: .pi/agent-runs/ux-reviewer-20260806T171922Z-834bde/final.md
Integrated full-tile code review APPROVE: .pi/agent-runs/code-reviewer-20260806T173010Z-62aa47/final.md
Integrated full-tile UX review APPROVE: .pi/agent-runs/ux-reviewer-20260806T173010Z-34be63/final.md
```

Component Lab comparison remains honestly RED and unblessed at
`/tmp/continuum-location-narrow-tile-candidate.1qgCw4/output.log`: 42 mismatches include four
expected missing baselines for the two new location cards, while 22 other renders match. No baseline
was changed or blessed. Headless Aqua/Dark Aqua candidate screenshots were reviewed and approved,
and the isolated normal-app harness exercised real Pi read/edit/Bash/wait/external/stale transitions.
No real VoiceOver pass, keyboard disclosure/action review, or owner acceptance occurred. VoiceOver is
explicitly deferred from the current owner-testing effort rather than treated as complete. P3.5–P3.8,
P3.10, P3.S2, and P3.S3 therefore remain unchecked where mechanical/live evidence is insufficient.

## Current direction and open owner decisions

Current owner direction:

- visible primary states are **Home / Where / What**;
- Where and What may be inside or outside Home;
- What is observable activity, not self-report;
- spatial awareness should extend beyond directory inference to references, sessions, placement, and
  explicit canvas tools;
- agent-to-agent messaging is a first-class desired capability;
- Pi should receive a small Continuum prompt, explicit host tools, and an on-demand skill rather than
  a giant static prompt.

Still to decide:

1. External path authority: automatically add already-readable paths as temporary read-only
   references, or confirm before any new root is available?
2. Provisional freeze: stop auto-reinference at first typed text/reference/manual choice, or only at
   first submitted prompt?
3. Subdirectory inheritance: project only by default, with relative subdirectory only on stronger
   agreement/direct creation?
4. Empty canvas: use an explicit workspace default when configured; otherwise always show the
   switcher?
5. Initial scope emitters: project zones and managed agents first, or include terminals/file trees
   immediately once their telemetry is proven?
6. Messaging an idle agent: trigger one turn immediately, queue until manually resumed, or expose
   both as explicit delivery choices?
7. Default agent-message delivery: follow-up after active work, with steer only as an explicit urgent
   option?
8. Nearby context injection: include only counts/one-line roster automatically, with details always
   tool-driven?
9. Historical session targeting: inspect/fork only initially, with explicit resume later?
10. Cross-project continuation: omit from the first version and recommend New Agent?
11. Global keyboard shortcut/name and collision audit for the location/sessionizer/canvas command
    surface.
