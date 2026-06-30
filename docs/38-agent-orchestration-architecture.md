# Agent Orchestration & the Distributed Canvas

Status: **design / direction — first draft, 2026-06-28.** A thinking document, not
implementation-ready. It will iterate. Where it makes a call it says so; where it
is open it says so. Per the style guide (`docs/37`) this is a **spike**: its output
is locked decisions + follow-up tickets, not a single PR.

This doc is effectively **v2 of the "durable, observable home" arc** and it
**revises a locked decision** in `docs/34`. See *Relationship to existing docs* at
the end for the supersede/extend map.

---

## Why

We have intertwined tmux deeply. That was probably the right substrate, but the
*mapping* between tmux and the canvas grew a few welds that now hurt:

1. **A tile is a tmux session (1:1).** Opening a new tile spins up a brand-new
   session — re-`cd` the directory, no shared env, ceremony every time. Tiles were
   supposed to be cheap, infinite panes; instead each one is a heavyweight session.
2. **Two tiles can't share a session without mirroring.** Because tiles attach as
   normal tmux clients, two clients on one session show the same active window.
   "Split panes" the user wants spatially become literal mirrored views.
3. **Not all shell tiles are agents — but we can't tell which are.** Some tiles run
   a plain shell; some run Claude Code, Codex, or Pi. Today the tile doesn't know
   what it's running, and the agent status that the whole UI consumes is set by
   hand (or mocked). We want to **detect and track agent activity automatically,
   without thinking** — tie into each and any agent from the tile.
4. **No workspace-level knowledge of what's happening.** A workspace should know,
   as a live tree, what each tile is doing — especially agents. The model for this
   already exists (`SidebarTree`) but is never rendered or fed.
5. **Everything is local.** We want agents to be able to run remotely (a VPS), to
   communicate, and — because this is a Swift app — to be **observed from iOS**.
   "Remote or local, everything tied together."

The thesis of this doc: these are not five problems. They are **three layers fused
together**, plus an observation gap, plus a sync gap. Separate the layers and the
rest falls out — including remote and iOS.

---

## The reframe: three layers, two welds

Continuum conflates three layers that want to be distinct:

1. **Spatial / canvas layer** — tiles, zones, positions, membership. Continuum's
   *own* model. Pure Swift. Nothing to do with tmux. *Wants to sync across devices.*
2. **Session / execution layer** — tmux sessions/windows/panes, the ptys, the
   running processes/agents. Persistent. *Wants to live local or remote.*
3. **View / binding layer** — which tile renders which pane (the ghostty surface ↔
   pane binding). *Local to each client.*

Almost every pain above is two of these welded:

- **Weld 1 — session identity is the tile id.** `TmuxSession.sessionName(tileId:)`
  = `"continuum-<tileId>"` (`Sources/ContinuumRevivedCore/TmuxSession.swift:8`).
  One tile, one session, forever. This is the source of "new tile = new session =
  re-cd" (Spatial fused to Session).
- **Weld 2 — ghostty attaches as a plain tmux client.** The wrap runs
  `tmux new-session -A …` (`TmuxSession.swift:12`) and ghostty forks the pty for it
  (`GhosttyTerminalView.createSurface`, `config.command` assignment ~`:502`). tmux's
  renderer decides what an attached client sees → two clients on one session mirror
  (Session fused to View).

The encouraging part: **the data model already has the right seams.** Only those
two lines of philosophy are wrong. Specifically these already exist and are correct:

- `Tile.runtimeRef` → `RuntimeRef` (`CanvasState.swift:39`, `:94`): a tile *points
  at* a runtime; it is not itself the runtime.
- `TerminalSessionDescriptor.id` is distinct from `.tileId`: the session has its own
  identity already.
- `ZoneRuntimeController` owns runtimes **per project**, ref-counted by `projectId`
  (`ZoneRuntimeRegistry.swift:13`, `ZoneRuntimeController.swift:6`): a natural home
  for "one session per project."

This is reshaping, not rebuilding.

---

## Current state (grounded, 2026-06-28)

What exists today, with the surprising amount that is **already built but unfed or
unrendered**:

### Session / execution (the welds live here)
- `TmuxSession` (`TmuxSession.swift`): `sessionName(tileId:)` `:8`,
  `wrap(profile:tileId:tmuxPath:)` `:12` (`new-session -A -s continuum-<tileId> -c <cwd>`),
  `killSessionCommand` `:27`. `TmuxPersistenceConfig` `:78`, `TmuxLocator.resolve` `:36`.
- `TileSpawner.spawnTerminal` `:108`, `tmuxWrappedProfileIfAvailable` `:221`,
  `restartTerminalTile` `:273` (rebinds via `listSessions().first(where: tileId==)` `:303`),
  `flushTerminalSessionSnapshot` `:371`. **The only existing tmux IPC** is a
  `send-keys "cd <path>"` to sync cwd (`:3473`).
- `GhosttyTerminalView.createSurface` (`~:480`) sets `config.command` to the wrapped
  tmux command; ghostty forks the pty. **No libghostty change needed to re-wrap.**

### Agent state model (already built — this is the good news)
- **`AgentStatus`** enum already exists with the full vocabulary:
  `configuring / working / idle / needsAttention / done / stale`
  (`TerminalSessionDescriptor.swift:85`).
- **`AgentDescriptor`** (`:94`): `agentKind: String`, `worktreePath`, `status`,
  `statusUpdatedAt`, `runId`; `restoredForBoot()` marks `stale` on reboot.
- **`SidebarTree` / `SidebarTreeBuilder`** (`SidebarTree.swift:126`, `:134`): builds
  the full `workspace → zone → tile` tree and **already takes
  `agentStatusesByTileId: [UUID: AgentStatus]`** (`:139`) and rolls it up via
  `SidebarAgentStatusRollup` (`:21`). The activity tree is *modeled and has a
  builder*. It is **never rendered** (per `docs/35`).
- **Zone chrome already renders a rollup** (`CanvasNSView.swift` `AgentStatusRollup`
  struct `:45`) — but it is fed **hardcoded mock data**:
  `AgentStatusRollup(working: 1, needsAttention: 1, …)` at `:3176`.

### Spatial / persistence (all local, no sync, no network)
- `CanvasState` / `Tile` (`CanvasState.swift`), persisted as `canvas.json` per
  project via `ProjectStore` (`saveCanvas` `:108`, `loadCanvas` `:112`, sessions
  under `sessions/<id>.json` `:136`/`:157`).
- `WorkspaceDocument` (`WorkspaceDocument.swift:13`), `ZonePlacement` (`:147`,
  `projectId: UUID?` `:149` — **nil for ambient/group zones**), `groupZoneTiles`
  `:21`. Persisted by `WorkspaceStore` (`:29`, `save` `:55`).
- **Zero networking / sync code anywhere.** Stores are concrete local-JSON readers.

### The gap, stated precisely
The **state model and its consumers already exist**. What is missing is: (a) a
**source** that populates `agentStatusesByTileId` automatically; (b) **decoupling
session from tile**; (c) **de-mirroring**; (d) a **sync seam** for the spatial layer;
(e) a **remote host** option for the session layer.

---

## Design

Six decision areas, ordered by dependency. **A** and **C** are the heart.

### A. Session topology — project = session, tile = window (revises `docs/34`)

**Decision (proposed, supersedes `docs/34` decision #2):** a tmux **session belongs
to a project**, not a tile. Each terminal tile is a **window** in that session.
Windows stay **single-pane, always**.

```
project (ZoneRuntimeController, ref-counted by projectId)
  └─ tmux session   continuum-proj-<projectId>
       ├─ window  ← tile A   (single pane)
       ├─ window  ← tile B   (single pane)
       └─ window  ← tile C   (single pane)
```

- New terminal tile → `tmux new-window -t <projectSession> -c <cwd>` instead of
  `new-session`. Pass cwd explicitly (focused tile's cwd, or project root) so a new
  tile **inherits the directory and shared env for free** — the re-`cd` pain dies.
- Add a durable `tmuxWindowTarget` (pane/window id, e.g. `%5`) to
  `TerminalSessionDescriptor`. That becomes the binding instead of
  `sessionName = f(tileId)`. `restartTerminalTile` rebinds by target.
- `sessionName` keys off project identity. The per-project owner already exists
  (`ZoneRuntimeController`), so lifecycle has a natural home.

**The splitting tension, resolved.** tmux "encourages splitting" only if tmux owns
layout. It won't. **The infinite canvas replaces tmux's pane-splitting entirely.**
The gesture that in plain tmux is "split pane" becomes, in Continuum, "spawn a new
tile" (a new window). We never call `split-window`. tmux becomes a **process host +
persistence + observation surface**, not a window manager — which was never its job
here. (If a *user* or program splits manually inside a tile, that renders nested and
is their deliberate choice; optionally rebind split keys to "new tile" later.)

**Lifecycle changes vs `docs/34`:**

| Event | `docs/34` (tile=session) | This design (project=session, tile=window) |
|---|---|---|
| Close one tile | `kill-session` | **`kill-window`** for that tile's window |
| Last tile in project closed | n/a | session dies when window count hits 0, or on project ref-count → 0 |
| App quit / restart | session survives, reattach | unchanged — session survives, windows intact |
| Project released (`ZoneRuntimeRegistry` → 0) | n/a | **decision: kill or detach the session?** (open question) |

**Open in A:**
- **Ambient/group-zone tiles have no `projectId`** (`ZonePlacement.projectId == nil`).
  What session hosts them? Candidates: a per-workspace ambient session
  (`continuum-ws-<workspaceId>`) vs. each ambient tile keeps a private session
  (today's model as fallback). *Leaning: per-workspace ambient session.*
- Migration: existing `continuum-<tileId>` sessions don't merge into windows
  cleanly. Likely **start fresh project sessions on upgrade** (agents restart once),
  with a one-time note. Acceptable; flag loudly.
- cwd inheritance source: focused tile's `pane_current_path` vs project root —
  default and override.

### B. View binding — de-mirror with session groups (keeps `docs/34` #3)

With a shared session, two ghostty clients attached normally would mirror. Fix
**without control mode** (which `docs/34` #3 already rejected, and which fights
ghostty's pty-owning model — we concur):

**Decision (proposed):** each tile's surface attaches via a **grouped session** —
`tmux new-session -t <projectSession> -s <perTileView>` — which shares the project's
windows but tracks its **own active window**, then `select-window` pins it to that
tile's window. Same attach mechanism ghostty already uses; only the wrap command and
a per-tile view-session name change (`TmuxSession.wrap`, `TmuxSession.swift:12`).

Result: N tiles → N grouped clients → N different windows → **no mirroring**, each
window single-pane so each tile renders exactly one terminal.

**Open in B:** grouped-session naming/cleanup; does `select-window` per view race
with the observer; behavior when two tiles intentionally view the *same* window
(allowed mirror, like two windows on one document).

### C. Agent awareness — observe uniformly, detect not declare (the heart)

**Principle:** **every tile is observed identically; agent-ness is detected, not
declared.** A tile's `kind` stays `.terminal`. Whether it is an agent — and which —
is a *runtime property* the system derives. The user never configures it.

Because every tile is now a window in a session, tmux gives a **uniform observation
surface** over all of them:

- `tmux display -p -t <win> '#{pane_current_command}'` → foreground process
  (`zsh`, `claude`, `codex`, `node`, `python`). **The base classifier.**
- pane pid → walk the process tree to disambiguate wrappers.
- OSC titles (we already capture OSC 7 for cwd; add OSC 0/2 for title/status).
- `capture-pane` / `pipe-pane` → output stream when content is needed.

**A per-project `SessionObserver`** (lives in `ZoneRuntimeController`) polls each
window, classifies it, and **writes `AgentDescriptor.status`** — the field that
already exists and that the whole UI already consumes. Detection vs. rich status is
split by an adapter registry:

```
AgentAdapter (protocol)
  ├─ matches(process, title, cwd) -> Bool      // is this my agent?
  └─ status(pane, pid, cwd)        -> AgentStatus + detail
```

- **Generic fallback** — process name + output heuristics (spinner / prompt / exit
  code). Universal; covers any shell or unknown agent as `idle`/`working`/`unknown`.
- **Claude Code adapter** — read its native signals (transcripts / session JSON, or
  wire its hooks / statusline) so status is authoritative, not scraped.
- **Pi adapter** — read `~/.pi` per-run artifacts (our own doctrine already treats
  these as source of truth). First-class status feed.
- **Codex adapter** — its log/state dir.

Graceful degradation: an unknown agent still shows up (as a shell/unknown); it just
doesn't get deep status until an adapter exists. **Infinite extensibility, zero
required configuration.**

**The workspace activity tree is then almost free** — it is *rendering the existing
`SidebarTree`, fed by the observer* instead of mock data:
- Feed `SidebarTreeBuilder.build(…, agentStatusesByTileId:)` (`SidebarTree.swift:134`)
  from the observer's output.
- **Replace the hardcoded rollup** at `CanvasNSView.swift:3176` with the real signal.
- Render the sidebar (the deferred `docs/35` work) from the same data.

This single tree is the keystone for three goals at once: the at-a-glance fleet view
on the canvas, the **iOS payload** (a phone doesn't need the 2D canvas — it needs
*this tree*), and the substrate for agent-to-agent awareness (F).

**`agentKind` becomes detected**, not a free-typed string — an enum/registry key
(`shell`, `claude`, `codex`, `pi`, `unknown`) so adapters and UI agree.

**Open in C:** polling interval & cost at many tiles (budget/counters required per
style guide); how `working` vs `needsAttention` vs `idle` is decided per adapter
(the semantics, not just the enum — the enum exists); whether status pushes (hooks)
or pulls (poll); debounce so flicker doesn't thrash the tree.

### D. Remote execution — host abstraction

**Decision (proposed):** add a `Host` to the project/workspace
(`localhost` | `ssh://<host>`). The launch wrap becomes
`ssh <host> -t 'tmux …'`. Ghostty still forks a **local** pty (the ssh client); the
session lives on the VPS, survives, and is observed by the *same* mechanism in C
(`ssh <host> tmux display …`). Mostly a change at the wrap layer
(`TmuxSession.swift`) + a host field on the model.

This is additive and unlocks "agents in the cloud" without touching the canvas.

**Open in D:** auth/known-hosts UX; reconnect/backoff when the link drops;
latency on the observer poll over ssh; whether the observer runs locally over ssh vs.
a small Continuum agent daemon on the host (daemon is cleaner long-term, ssh-wrap is
faster to ship).

### E. Sync seam — make the spatial layer device-portable (gates iOS)

**Decision (proposed):** put `ProjectStore` and `WorkspaceStore` behind a **protocol**
now, while the surface area is small, so the backing can later become a synced store
(CloudKit / a sync doc / CRDT) without touching call sites. State is already
value-typed `Codable`.

Critical boundary: **sync layer 1 only** — tiles, zones, positions, membership. Do
**not** sync `runtimeRef` bindings or live pane state; a second device (iOS, or
another Mac) **re-binds** to the session's panes locally. That separation is exactly
what makes "observe from iPhone" clean: the phone syncs the spatial model + receives
the activity tree (C), and binds a simple output view to remote panes on demand.

This ships **no visible feature** but is the one piece that is **retrofit-hostile** —
abstracting the store after `ProjectStore(...)` is sprinkled everywhere is painful,
and it gates the entire iOS / multi-device story. Do it first for that reason.

**Open in E:** sync transport (CloudKit vs. self-hosted vs. CRDT lib); conflict
policy for concurrent canvas edits across devices; what the iOS client actually is
(observer-only first, or control too); identity/account model.

### F. Agent-to-agent communication — later, on the shared session

`docs/README` is explicit: agent-to-agent messaging waits until the core loop is
reliable. Respected. When it comes:
- Bootstrap is already possible via `send-keys` / `capture-pane` across windows in
  the shared session (we already use `send-keys` for cwd).
- The real version is an **app-level message bus** keyed off the session/runtime
  layer (agents post structured messages; tiles/agents subscribe), with the activity
  tree (C) providing "who is doing what." Do not build comms on screen-scraping as
  the destination.

**Out of scope for this doc beyond naming the seam.**

---

## Verification & test primitives

"Right primitives at the start" means **testability is an architectural property, not
a later test suite** — sync especially cannot be retrofit-tested. The doctrine already
in force holds (`docs/37` real-path rule, `docs/26` visual harness): the matrix is
necessary but **not sufficient**; every behavior change needs a real-path check + (for
UI) a visual gate; happy-path-bypass checks are rejected.

Three primitives, designed into the layers from day one.

### 1. A serializable snapshot at every seam
Every test is *drive a real action → capture snapshot → assert*. No log-scraping.
- **Spatial** — `CanvasState` / `WorkspaceDocument` already are Codable snapshots. ✓
- **Session** — new **`SessionTopologySnapshot`**, read back from the daemon
  (`tmux list-windows -F …`: sessions, window/pane targets, cwd,
  `pane_current_command`). This is the **reconciliation oracle** — "what Continuum
  thinks it spawned" vs "what tmux actually holds." Most tmux bugs are drift between
  the two; without this snapshot they are invisible.
- **Agent awareness** — `ActivityTreeSnapshot`: the `SidebarTree`
  (`SidebarTree.swift:126`) plus the *evidence* each status was derived from, not just
  the verdict.

### 2. Injectable substrate (fakes for everything external)
`docs/34` P2 already injects a fake tmux path + isolated `UserDefaults`; generalize:
- **`TmuxControl`** protocol (new-window / kill-window / list-windows / send-keys):
  real impl + **in-memory fake** → logic tests need no daemon; plus a **gated
  real-tmux** integration test (the `docs/34` P5 pattern) for what only a real daemon
  proves.
- **Fake clock** — staleness, `statusUpdatedAt`, debounce are time-based; wall-clock is
  banned in the core exactly as in workflow scripts, or tests flake.
- **Fake `Host`** (localhost vs ssh) and **fake `SyncTransport`** (below).

### 3. Cross-layer invariants asserted continuously — the I-spine
The durable part: these survive refactors and are **reused across all tiers**.

| # | Invariant | Where checked |
|---|---|---|
| I1 | Binding bijection: tile ↔ window 1:1; no orphan window, no tile → dead target | core + real-path |
| I2 | No-mirror: distinct tiles → distinct active-window targets (except a deliberate shared view) | real-path |
| I3 | No session leak: live `continuum-*` sessions ⊆ live projects/zones; last-tile-close kills the session | real-path + topology snapshot |
| I4 | Sync convergence: any op order, any replica count → byte-identical state | core fuzz |
| I5 | Sync-boundary purity: synced payload contains no pid / pane target / host-local handle | core (taint scan) |
| I6 | Status soundness: every `working`/`done` backed by fresh evidence; unknown ⇒ `unknown`, never false `working` | core golden + real-path |
| I7 | Snapshot round-trip: serialize → deserialize → equal, every layer | core |
| I8 | Restart survival: pid + window target + cwd preserved across ghostty-client teardown | gated real-tmux |

### Per-layer specifics
- **tmux persistence / reattach (I8, I1, I3):** a real-path check spawns a tile, runs a
  **sentinel long-lived process** (heartbeat file / known pid), tears down the ghostty
  client (simulated quit), re-runs the spawn path, and asserts *same window target,
  same pid alive, cwd preserved, no exit*. Pure `wrap()`-argv tests are necessary but
  **not sufficient**. Manifest: `pidBefore == pidAfter`, `targetBefore == targetAfter`,
  `exitObserved=false`.
- **Spatial / actions (I1, I7):** property test over random create/move/resize/close/
  zone-assign sequences; real-path drives the **actual action executor**, not the model.
- **Agent detection / status (I6):** **golden fixtures** — recorded real
  `pane_current_command` + process trees + scrollback + `~/.pi` artifacts for
  shell/claude/codex/pi, replayed through the adapters. Decouples adapter logic from
  live agents. The observer carries **counters/budgets** (polls/sec, status-changes/min)
  so it cannot thrash.
- **View binding (I2):** a real-path check proving two tiles render two *different*
  windows of one session, not a mirror.

### The sync-model fork — resolve before E ships
The single decision that determines whether sync is *provable* or *perpetually flaky*:

> **Open decision (blocks E):** CRDT vs deterministic op-log (with deterministic merge).

Either makes **I4 a theorem you can fuzz** — generate random ops, apply in random
orders across N replicas, assert byte-identical convergence. Last-write-wins on
wall-clock timestamps or ad-hoc merge does **not**; pick that and sync bugs are
forever. Determinism is mandatory in the sync core: **logical clocks** (Lamport /
vector), never wall-clock, for ordering — same discipline as the workflow `Date.now()`
ban, for the same reason.

Test rig, either way: a **`SyncTransport` fake** whose tests can partition / reorder /
delay / drop / duplicate messages and go offline → reconnect. An in-process
**N-replica fuzz** asserts I4; a **taint scan** asserts I5; the activity tree syncs as
a **derived projection**, so cross-platform agreement is **snapshot equality** (Mac
render == iOS render from identical synced data), not a re-derivation. A nightly soak
runs M random-op / random-network iterations, asserts convergence every time, and
records max convergence latency as a budget.

This fork gets a **short mini-spike** (CRDT lib vs hand-rolled op-log: dependency,
ergonomics, payload size, Swift/iOS portability) before E is built.

### Tier mapping (to the existing harness)
- **Core checks** (`ContinuumRevivedCoreChecks`): I1, I4–I7, sync fuzz, adapter goldens.
- **Real-path app checks** (`CONTINUUM_SMOKE_TEST=1 … --<feature>-check`) →
  `qa-runs/<ts>/<check>/manifest.json` with **measured** values (pid/target equality,
  convergence latency, `taint=none`) — never `{passed:true}`.
- **Gated real-substrate integration**: real tmux now (I8); real `SyncTransport` later.
  Skip cleanly when the substrate is absent so the matrix stays green.
- **Visual gate** (`docs/26`): the activity-tree / sidebar render.
- **Matrix** (`scripts/run-matrix.sh`): the necessary-but-not-sufficient floor.

---

## Proposed decisions (to lock with Dylan)

1. **Project = session; tile = window; windows single-pane.** Canvas replaces tmux
   splitting. *(Supersedes `docs/34` #2.)*
2. **Close tile = kill-window; session dies at 0 windows or project release.**
   *(Refines `docs/34` #1; the project-release kill-vs-detach choice is open.)*
3. **De-mirror via grouped sessions, not control mode.** *(Keeps `docs/34` #3.)*
4. **Agent-ness is detected, not declared.** Tile kind stays `.terminal`; an observer
   + adapter registry populates the existing `AgentStatus`.
5. **Activity tree = render existing `SidebarTree` fed by the observer**; replace the
   mock at `CanvasNSView.swift:3176`.
6. **Host abstraction (`localhost` | `ssh://…`) for remote execution.**
7. **Store protocol seam first**, syncing layer 1 only; iOS = spatial sync + activity
   tree + on-demand pane view.
8. **Testability is designed in, not bolted on:** a serializable snapshot at every
   seam, injectable substrates, and the I1–I8 invariant spine — stood up in phase 0.
   **The sync model (CRDT vs deterministic op-log) is the one unresolved fork that
   blocks E** and gets a mini-spike first.

None of these are implementation-ready yet (open questions remain in each). This doc
is the spike; tickets come after Dylan locks the decisions.

---

## Rough phasing (dependency order — NOT yet tickets)

0. **Store protocol seam (E) + test scaffolding.** Foundational, retrofit-hostile, no
   user-visible feature. Stand up the snapshot types (`SessionTopologySnapshot`,
   `ActivityTreeSnapshot`), the injectable substrates (`TmuxControl` fake, fake
   clock/host/transport), and the I1–I8 invariant harness here, so every later phase
   asserts against them. Do while small.
1. **Project = session, tile = window (A)** + migration. Kills the re-cd pain.
2. **De-mirror via grouped sessions (B).** Now that tiles are windows.
3. **SessionObserver + AgentAdapter registry (C, base + generic).** Auto-populate
   `AgentStatus`; replace the `:3176` mock.
4. **Render the activity tree / sidebar (C + `docs/35`).**
5. **Rich adapters (C): Claude Code, Pi, Codex.**
6. **Host abstraction (D): remote execution over ssh.**
7. **iOS observer client (E + C).**
8. **Agent-to-agent bus (F).** Last; only once the core loop is reliable.

Each becomes one or more tickets authored to `docs/37` (goal, decision, seams,
numeric policy, falsifiable acceptance, QA contract, stop conditions). Several (A, B,
the observer's polling) carry **performance budgets** and need real-path checks, not
just core math. The **sync-model spike** (CRDT vs op-log) must land before any real
`SyncTransport` — it decides whether I4/I5 are provable.

---

## Risks

- **Migration churn (A):** existing per-tile sessions don't fold into windows; a
  one-time agent restart on upgrade is likely. Communicate; don't silently orphan.
- **Mirroring regression (B):** grouped sessions are subtle; a real-path check must
  prove two tiles show two windows, not one.
- **Observer cost (C):** polling N windows (× ssh latency for remote) must be
  budgeted and debounced, or it taxes every workspace. Counters required.
- **Scrape brittleness (C):** generic heuristics will misclassify; rich adapters and
  honest `unknown` states are the mitigation. Never claim status we can't back.
- **ssh reliability (D):** dropped links must degrade gracefully (stale, not wrong).
- **Sync conflicts (E):** concurrent canvas edits across devices need a defined
  policy before two writers exist.
- **Ambient-zone sessions (A):** the no-`projectId` case is genuinely unresolved and
  could leak sessions if hand-waved.

---

## Relationship to existing docs

- **`docs/34` (tmux shell persistence)** — this **revises** it. Decision #2
  (`session = continuum-<tileId>`) is superseded by project=session/tile=window.
  Decision #1 (close = kill) is refined to kill-*window*. Decision #3 (no control
  mode) and the persistence/fallback machinery are **kept**.
- **`docs/35` (observability sidebar)** — this **subsumes and feeds** it. The
  activity tree here is that sidebar; the missing piece it called out (a source for
  agent status) is the SessionObserver. Render `SidebarTree`, don't redesign it.
- **`docs/36` (browser deep-state)** — sibling (#3 of the original arc); unaffected,
  but benefits from the same store-protocol seam (E).
- **`docs/23` (multi-controller runtime)** — `ZoneRuntimeController` per-project is
  the home for both the project session (A) and the observer (C); align there.

---

## Open questions (master list, for iteration)

- Session ownership for ambient/group zones (no `projectId`).
- Project-release: kill vs detach the session.
- cwd-inheritance default + override for new tiles.
- Observer transport: poll vs hooks/push; interval; debounce; cost at scale.
- Per-adapter semantics for `working` / `needsAttention` / `idle`.
- `agentKind` enum/registry vs. free string.
- Remote: ssh-wrap vs. Continuum host daemon on the VPS.
- **Sync model: CRDT vs deterministic op-log** — gates provable convergence (I4/I5);
  blocks E; gets its own mini-spike.
- Sync transport + conflict policy + iOS client scope (observe-only vs. control).
- Identity/account model once multi-device exists.
- Whether to rebind in-tile split keys to "new tile."

This is a first draft. We can't think of everything now — that's the point.
```
