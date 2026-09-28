# 67 — Array target architecture: the canvas, zones, tiles and their persistence

**This folder is the source of truth for the stability program.** The board
(https://claude.ai/artifact/M7LPdrVA8rgKiypzzVUP5i) tracks status, comments and
screenshots per ticket. This README states the architecture Array converges on,
the decisions behind it, and the order of work. When the two disagree, this file
wins for *what we are building*; the board wins for *where each ticket is*. Any
session that changes a decision edits this file in the same commit as the code.

Written 2026-09-28 against `array/integration` HEAD `1451c030` (0.7.21, build
72). Nothing in this program has been implemented yet.

Contents of this folder:

- `README.md` (this file): target architecture, invariants, decisions, slices.
- `01-consolidated-design.md`: the first-pass consolidation (ARC-1..5) and the
  reconciliation with the second opinion. Historical reasoning; superseded where
  this README differs.
- `02-second-opinion.md`: GPT-6 Astra's independent review. Its §2 (eleven
  mechanisms) and §5 (sequencing) shaped this file. Every mechanism it names was
  verified in source before being accepted.
- `03-tickets.md`: text export of the board tickets at the time of writing.
- `reports/`: the fifteen read-only investigation reports (s1–s11 scouts,
  o1–o4 deep dives). Evidence, with file:line citations at HEAD `1451c030`.
- `second-opinion/`: the brief Astra received and its three children's reports.

## 1. Why this exists

Array's canvas grew feature by feature. Zones, hydration tiers, the jelly auto-
layout, workspaces, managed agents and the workspace API each arrived with its
own model of what a tile is, where its frame lives, and who may write it to
disk. There was never a target design; hazard 9 in `CLAUDE.md` is the record of
that, corrected three times. The result is the set of complaints that started
this program, verbatim from Dylan:

1. "i thought we got rid of the top bar in the MacOS window itself.. i still see it"
2. "zones feel untrustworthy: the zone names often revert as well as the visual of
   the directory location (project home) -- i create a new one fine, but if i
   switch workspaces or close and reopen the app it is no longer present"
3. "when i create an agent tile in a zone, it is blank (---) and when i try to
   select a proper home it doesn't do anything... only after restarting (and
   sometimes having to recreate the zone)"
4. "tiles in zones shift when switching workspaces or after a period of time --
   as well as the zones themselves ... zones overlapping each other ... tiles
   outside the zones but still 'in' the zone -- this is crucial i want my layout
   to be consistent and not to change without my doing"

Complaint 1 is process (a reviewed titlebar branch never landed). The other
three are one problem: **no single owner of the scene, no single writer of the
files, no invariant that says what a committed scene must look like.** The prod
files already show the damage (a read-only audit on 2026-09-27: the `personal`
workspace file holds two zones owned by `work`; an orphan workspace file not in
the registry holds copies of `personal`'s zones with the same ids; the registry
records project ownership in two fields that disagree for four of seven
projects).

The goal of this program is not to fix the four complaints. It is to give the
canvas the architecture it never had, so that this class of bug cannot be
written again, and to make the four complaints impossible as a consequence.

## 2. Diagnosis (settled)

Five sentences, all confirmed by the second opinion:

1. The workspace document has no owner. Eight code paths mutate and save it with
   their own controllers; the arming autosave stays bound to the first workspace
   and is never rebound on switch; several writers read disk back into memory
   while mounted.
2. Zone headers are built by five builders from stored strings, and a stale copy
   of the render models is written back over the display on every agent tick.
3. A zone can be half real: chrome without a `ZoneLayer`. Every downstream path
   has a branch for that state or gets it silently wrong.
4. There are still two tile models, and the retired flat one is reachable: a
   spawn into a half-real zone lands in it and is invisible to the code that
   wires it.
5. "Install a tile" always means "spawn": grow the zone and re-settle. Snapshot,
   restart and restore go through it, so eviction and crashes move tiles; and no
   invariant says a member sits inside its zone or that zones do not overlap.

Plus the eleven mechanisms the second opinion added, all verified at HEAD:

| # | Mechanism | Where |
|---|---|---|
| 1 | Note-to-document conversion writes the layer's ZONE-LOCAL tiles as the whole WORLD file and drops every other zone's tiles from that project | `TileSpawner.swift:2226-2233` |
| 2 | A zone's Home is also the storage partition key for its existing tiles; rebinding a populated zone moves its tiles into the other project's file | `CanvasNSView.swift:1029`, `:6603` |
| 3 | "Saved" can mean the write failed: both canvas flush paths `try?` and clear the dirty flag; a queued write can outlive the project lock | `ZoneRuntimeController.swift:694-699`, `:738-746`, `:206` |
| 4 | Direct `saveCanvas` writers far beyond the three known paths | `TileSpawner.swift:1174, 1264, 2231, 2233, 2421`; `ContinuumApp.swift:14126, 16278`; `WorkspaceRuntime.swift:541, 1882` |
| 5 | A layout transaction skips missing projects/zones/tiles and still returns true | `ContinuumApp.swift:14679, 14705-14719` |
| 6 | Multi-store operations have no recovery: registry then document, N canvases then document, best-effort rollback a crash never runs | `WorkspaceRuntime.swift:128-135`; `ContinuumApp.swift:14663-14750` |
| 7 | A failed switch leaks controller acquisitions | `WorkspaceRuntime.swift:1528, 1591, 1618` |
| 8 | A per-zone hydration plan is applied to a per-project controller | `WorkspaceRuntime.swift:1788-1813` |
| 9 | Unzoned tiles have nowhere to live: close-keep-tiles updates only a cache and the flat model | `CanvasNSView.swift:317-325` |
| 10 | A failed read is treated as an empty canvas, and the persistence merge deletes against it | `WorkspaceRuntime.swift:507-509`; `TileSpawner.swift:2424-2429` |
| 11 | Delayed callbacks are not fenced by session identity (picker reads the current workspace at confirm time) | `ContinuumApp.swift:14874-14876` |

The saver mechanism itself: `WorkspaceRuntime.swift:347, 422-427` (controller
bound once), `:1616` (switch changes `workspaceId`), `:1435-1444` (fresh
controller per sync save, never supersedes the pending snapshot),
`WorkspaceDocumentSaveController.swift:39-70` (200ms value-copy snapshot).

## 3. The target architecture

### 3.1 Owners

One authority per fact. These can start as small types inside `WorkspaceRuntime`;
what matters is that feature code submits commands with stable ids and never
holds a partly edited document or a save callback.

| Owner | Sole authority over | Explicitly not its business |
|---|---|---|
| **WorkspaceSession** (main actor) | Workspace identity, mount epoch, the committed scene revision; executes commands; prepares and commits a switch | Views never mutate persisted facts directly |
| **WorkspaceScene** (value) | Every zone node, every tile placement, root (unzoned) membership, z-order, creation defaults | Hydration adds or removes no logical record |
| **Project content repository** (`.array/`) | A project's tile backing data, notes, documents, session references, storage identity and lock | A zone Home change transfers no existing content |
| **Commit coordinator** | Generation-stamped snapshots, durable receipts, dirty and error state, the one file writer | No view and no timer decides which store owns a tile |
| **View renderer** | Chrome and tile views derived from scene plus status; transient gesture previews | Has no path to `ProjectStore.saveCanvas` |
| **Runtime supervisor** | Runtime identity and generation, attachment lifecycle, the real resource budget | Rehydration and materialization never touch geometry |
| **Registry** | Project identity and root resolution; **one** canonical workspace-ownership relation | Reverse indexes and labels are derived |

### 3.2 What a zone and a tile are

A **zone** is a workspace-owned named spatial group: stable id, one canonical
WORLD rect, z-order, layout policy, and an optional *creation scope* (project +
Home). The Home says where future filesystem-backed tiles start. It is **not**
the storage owner of its members and **not** a process container.

A **tile** is a durable record: stable id, explicit content/storage owner, kind,
backing reference, one WORLD frame, z-order, optional zone membership. An agent
binding is explicit `bound / unbound / unavailable`; a missing channel-specific
agent record renders an actionable unbound state and never mints a duplicate.
The view and the provider process are replaceable resources attached to the
record. Unzoned tiles belong to the **scene root**.

So on a tile, three facts that today are one: `storageOwner` (which `.array`
holds it), `membership` (which zone, or root), and the zone's `creationScope`.

### 3.3 Frame spaces

WORLD is the canonical scene and durable placement space. Zone-local is a
derived rendering adapter, never an independently editable record. AppKit
coordinates and camera zoom never enter persistence. A zone translation computes
its members' world deltas once; growth that moves a zone's origin leaves
unaffected world frames alone. Undo records accepted geometry, not the request.
The existing exact-rebase safeguards stay through the migration
(`CanvasNSView.swift:2770` explains why installed vs requested geometry matters
to undo).

### 3.4 Commands and commits

Every change is a command: resolve identities and revisions, build a candidate
scene, solve and validate the *entire affected closure*, persist through the
coordinator, publish the committed revision with a receipt. Interactive previews
may precede durability but are explicitly provisional. A failed save keeps the
user's intent and the dirty state; each command chooses rollback or visible
retry and tests it.

Receipts are truthful: `submitted(generation)` vs `durable(generation)`. Flush
waits through the requested revision, succeeds only after persistence, and never
releases a project lease early. The session carries an **epoch**; a callback
captured under an older epoch is refused.

Reads happen at mount and at switch. Never while mounted. A failed read is
`unavailable(error)`, never an empty canvas, and never deletion authority.

### 3.5 Where layout lives (decision pending, see §4)

Today placement is split: zones in the workspace document, tile frames in N
project files. That split is why a zone push writes N+1 files and why a
recoverable multi-file protocol would be needed. The recommended destination is
that **the workspace owns all placement, membership and layout in one durable
aggregate**, and a project's `.array/` owns content and sessions only. Then a
push is one write, the only two-store operation left is zone creation (registry
then document, safe by ordering), and the multi-file recovery protocol is never
built. Old project frames become a one-time import; migration copies originals
aside and can mirror world frames into the project file, non-authoritatively,
for one release.

### 3.6 Geometry

`createTile` creates a record with one explicit target, scope and owner.
`replaceTileView` (materialize) swaps the view of an existing record and moves
**nothing**, including its own tile. Of the seventeen `installProjectTile`
callers, eight are creates and nine are materializations (listed in
`03-tickets.md` under ARC-4).

A layout command carries cause, epoch, baseline revision, affected ids and
accepted before/after geometry, and its effects include the full deterministic
growth/push closure. **Policy (decided): growth pushes neighbouring zones like a
drag does and never overlaps them.** A user spawn or resize authorizes its push
chain. Agent-created tiles need a specified grant. Lifecycle restoration
(snapshot, restart, eviction, remount, pan) authorizes no geometry change.

At commit: every member's world frame inside its zone's content bounds; no two
zones overlap; membership equals containment by the committed rule (defined
once, not "full rect" in one place and "centre" in another). The solver's
bounded loop (`CanvasAutoLayoutEngine.swift:922`) is validated, and
non-convergence refuses the whole candidate. **No silent repair in production**:
a damaged layout is preserved, classified, and offered as a deterministic repair
the user accepts; QA and prod run the same policy.

### 3.7 Presentation

A zone's header is a pure function of `(scene node, registry resolution,
provisional/unavailable state, rollup)`. No stored label strings. One builder
replaces the five. A status tick may change status-dependent display only. The
chrome asks on demand and caches by input hash.

### 3.8 Residency

Hydration tiers govern which runtimes (processes, browser engines) exist, never
which records exist. Residency is budgeted per project now (one deterministic
tier per project, reduced from its zones' demands) and per tile later. Cheap
always-present descriptor layers are an acceptable interim bridge while scene
nodes are introduced, not the invariant. The flat live scene
(`canvasState.tiles`, `flatCompatibilitySceneActive`, `retireFlatCompatibility
Scene`, the flat fallback in `installProjectTile`) is deleted at the end.

### 3.9 Invariants the gate asserts

1. **Identity/isolation.** Correct workspace, store and epoch; no mutation in
   another workspace's or project's file; no stale callback after a switch.
2. **Conservation.** Every durable tile survives exactly once unless an
   acknowledged delete or transfer removed it; owner, backing ref and agent
   binding stay with the same identity.
3. **Completeness.** The loaded model holds every known record at every tier,
   root tiles included; a failed load certifies nothing; every transaction
   target resolves exactly once.
4. **Durability.** Receipts describe successful durable generations; flush
   drains submitted work; failure and recovery yield one coherent revision.
5. **Geometry.** WORLD frames are stable under lifecycle operations; only the
   authorized closure moves; membership implies containment at rest; zones never
   overlap after accepted growth or drag.
6. **Projection.** Rendered chrome and Home actions reflect canonical fields;
   status updates alter neither identity nor geometry.
7. **Lifecycle.** One owned runtime per tile; correct leases and refcounts; no
   observer leftovers; residency independent of record existence.
8. **Repair/migration.** Originals preserved, classification deterministic,
   second mount idempotent, explicit repair survives remount.

## 4. Decisions

**Taken.**
- Growth pushes neighbours and never overlaps (Dylan, 2026-09-28).
- No silent production self-repair; preserve, classify, offer.
- Quarantine is a derived classification over preserved raw records, not a
  second durable array.
- No event log, no CRDT expansion, no actor-for-everything, no new database for
  this program. A main-actor command model with a serial persistence worker.
- The flat scene is deleted, not kept "for safety".
- The stale `workspace-foreign-zone-fix` branch is not merged; "only owned zones
  are ever in the mounted document" supersedes its boundary.
- Ownership is recorded once in the registry.
- Never `CONTINUUM_UPDATE_BASELINES=1`. Baseline regeneration is a deliberate
  step Dylan runs; legs assert text and geometry, not pixels.

**Pending, Dylan's call. Default assumption in brackets until he decides.**
- D1 Where layout lives: workspace-owned aggregate (§3.5) vs split stores plus a
  recovery journal. [Recommended and assumed: aggregate. Affects the shape of
  ARC-1 and ARC-2; decide before the scene slice starts.]
- D2 What a zone's Home means when a populated zone is rebound: future tiles
  only, existing members keep their owner. [Assumed: future tiles only.]
- D3 Damaged-layout repair on load: preview and accept, per finding. [Assumed.]
- D4 Agent-created tiles: may they push neighbours? Grant scope to define.
  [Assumed: same closure as a user spawn, gated by the existing workspace-API
  grant model.]

## 5. Slices, benches, releases

One bench per slice at `.worktrees/<slug>`, one session per bench, briefs name
the RED witness before the code. Merge order matters more than parallelism:
`ContinuumApp.swift` and `CanvasNSView.swift` are touched by nearly every slice.

| # | Slice | Bench | Release | Witness (outcome assertions; printed in the matrix summary) |
|---|---|---|---|---|
| 0 | **Fixture + fault seam.** Two seeded workspaces on temp app-support and temp project roots, mounted through `mountWorkspaceSceneAtBoot`, driven through real entry points, with three readable views: model, disk bytes, rendered chrome text. Injectable file writer behind `WorkspaceStore` and `ProjectStore` that can fail write N or abort after write N, then remount a fresh runtime on the same dirs. Register `--workspace-switch-polish-check` in the matrix (unregistered at HEAD). | `stab-fixture` | 0.7.22 | Negative controls fire: injected 1pt shift, foreign zone, ghost layer, stale success receipt each go RED. |
| 1 | **ARC-0 data protection.** Saver identity and supersession; drop the two mounted reloads; fix the note-conversion writer; retired-flat writes throw; truthful save receipts with a lifetime barrier; picker fenced by epoch. | `stab-arc0` (same bench as 0, sequential) | 0.7.22 | Mount A, arm A, switch B, arm B, drain: A's bytes unchanged. Arm then sync rename in the debounce window: durable latest survives abrupt remount. Two zones with nonzero origins: note reuse preserves sibling ids and WORLD frames. Injected save failure never reports saved; lock outlives the pending write. |
| 2 | **ARC-3 derived headers.** One builder; rollups patch rollups; explicit unbound agent state. | `stab-arc3` (parallel with 1) | 0.7.22 | Create, rename, change Home, rollup tick, switch, remount: real chrome text equals canonical inputs. Missing agent record renders unbound and creates no duplicate. |
| 3 | **ARR-1 titlebar, ARR-9 reds, ARR-10 rename hotkey.** | `stab-titlebar`, `stab-reds` | 0.7.22 | Titlebar: real fullscreen and window-drag checks. Reds: matrix summary with zero unowned reds. |
| 4 | **ARC-4a materialize ≠ spawn; lifecycle teardown centralized.** | `stab-arc4a` (after 1 merges) | 0.7.23 | Hand-spaced scene survives browser snapshot, restart, budget eviction, terminal restart and file-tree swaps with identical frames, membership, z-order. Old subscriptions retire once. |
| 5 | **ARC-2 + ARC-1 scene and coordinator** (one slice if D1 = aggregate). Scene nodes with root and storage owner; explicit load states; per-project residency; fenced creation into unavailable zones; session lease released on failed switch; the coordinator with receipts; identity-stamped v10 documents; ownership once; derived quarantine with repair preview; migration of frames into the aggregate with originals preserved. | `stab-scene` | 0.7.23 | Populated zone Home A→B: old members stay in A's store. Close/keep reparents to root without moving; survives remount. Missing store is unavailable, never empty. Fail each acquisition and the registry save: old scene, refcounts, locks unchanged. Migration lossless and idempotent against a copy of Dylan's real prod files. |
| 6 | **ARC-4b causal layout transactions.** Every growth, resize, spawn, tidy, drag and undo through one transaction; push-never-overlap; containment defined once; non-convergence refuses; undo restores the closure. | `stab-arc4b` | 0.7.24 | Long push chain through far zones carries all members by exact deltas; final containment and non-overlap hold; lifecycle materialization changes zero geometry; jelly trajectory probe reviewed by Dylan. |
| 7 | **Delete the flat scene.** The `installInitial*` boot walk migrates (`spawnRunArtifacts` and `spawnDiffReviewFromPalette` moved to the zone path in slice 1); `LegacyCanvasImport` runs once before mount. Hazard 9 rewritten. | `stab-flat-delete` | 0.7.24 | Fresh boot, legacy import, every tile kind, populated/bare/group zones and abrupt remount all use one scene path. |

Dogfood before each release: harness green in a real matrix summary, then the
three hand scripts in the preview app on `~/array-scratch` with before/after
screenshots on the board (rename + switch + relaunch; spawn into an off-screen
zone right after launch; drag that pushes zones then quit within a second and
relaunch). Only then does Dylan take the update in `/Applications/Array.app`.
Before he takes 0.7.22, copy `~/Library/Application Support/Array` and
`~/Documents/personal/.array` aside; the migration in slice 5 is tested against
that copy.

## 6. Rules for every session on this program

- Read this README, then only the slice's ticket in `03-tickets.md` and the
  evidence it cites. Do not re-run the investigation.
- Read-only on `/Applications/Array.app`, `~/Documents/personal/.array`,
  `~/Library/Application Support/Array`, and the default tmux socket. Preview
  app on `~/array-scratch` only, via `scripts/dev-app.sh`.
- Witness discipline per `CLAUDE.md`: a `--*-check` leg or CoreChecks section,
  RED before, GREEN after, asserting outcomes (model, bytes, rendered text,
  world frames), never source strings, and confirmed printed in a real
  `scripts/run-matrix.sh` summary. Never guess a check flag; enumerate them.
- Bench per slice under `.worktrees/`, `git worktree add` never clone, returned
  with `git worktree remove` when done. Never `git stash` (shared across
  worktrees).
- Commits under Dylan's identity only, `type(area): description`, no AI
  attribution, no ticket ids in messages. Never push.
- Subagents: name the model explicitly on every spawn (Sonnet 5 for scouting
  and enumeration, Opus 5.5 for implementation and review). Never Fable. If a
  child reports a model other than the one requested, stop it and respawn.
- A decision that changes §3 or §4 is edited into this file in the same commit.
- Append to §7 at every handoff: date, HEAD, bench, what is RED/GREEN, what is
  merged.

## 7. Status log

- 2026-09-28 — Program defined. HEAD `1451c030`. No code changed. Board
  published. Decisions D1–D4 pending; defaults assumed as stated in §4. Next:
  slice 0 (fixture) on bench `stab-fixture`.
- 2026-09-28 — Slice 0 (fixture + fault seam) on bench `stab-fixture`, branch
  `array/stab-fixture`. `WorkspaceInvariantsFixture` mounts two seeded
  workspaces through `mountWorkspaceSceneAtBoot` (launch's canvas callbacks
  now come from `wireCanvasCallbacks`, which the fixture also calls) and reads
  model, raw disk bytes and the strings each header actually draws.
  `StoreFileWriter` gates every `WorkspaceStore`/`ProjectStore` mutation: fail
  write N, fail from N, abort after N. `--workspace-invariants-check` GREEN:
  seam controls pass in bytes; the clean control (mount, switch B, switch A,
  quit+remount, crash+remount) reports zero violations; all four negative
  controls are caught by their own invariant naming the injected subject (1pt
  shift → geometry, foreign zone in B's file → isolation, ghost layer →
  wholeness, acknowledged-but-dropped write → durability).
  `--workspace-switch-polish-check` registered, GREEN. **Open finding, RED at
  base:** after the real mount every zone header draws its title and no Home
  label — both runtime render-model builders omit `scopeLabel` and the rollup
  tick writes that copy back (complaint 2). Projection is therefore excluded
  from slice 0's clean control, printed as a `MATRIX-NOTE` in the matrix
  report; slice 2 re-enables it in this same leg. Nothing merged.
- 2026-09-28 — Slice 1 (ARC-0) on bench `stab-fixture`, patches landing one
  commit each, every directed witness proven RED by reverse-applying only its
  fix. Saver identity (`--workspace-saver-identity-check`: arming in B wrote B's
  zones into A's file; a rename inside the debounce was lost; a layout commit
  reverted the arming) — one saver per mounted workspace, the two mounted
  reloads now runtime commits. Note reuse (`--note-conversion-writer-check`:
  the project file took zone-local frames and lost its other zone's tiles).
  Retired flat writes (`--retired-flat-write-check`: an inspector reveal wrote
  the boot snapshot over the project file) — the flat state is handed out only
  while the flat scene is live. The two flat-only spawns, `spawnRunArtifacts`
  and `spawnDiffReviewFromPalette`, moved to the zone path
  (`--flat-spawn-migration-check`), so slice 7 no longer carries them; the
  hazard 9 sentence naming them as remaining flat spawns is now stale and is
  left for Dylan to correct in `CLAUDE.md`. Staging `array/stab-0722` cut at
  `1451c030` and fast-forwarded to slice 0: real matrix, 231 legs, exactly the
  nine known unowned reds, NOTES printed.
