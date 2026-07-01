# Sync Model Spike — CRDT vs deterministic op-log

Status: **spike / decision doc — 2026-06-30.** Output is a locked recommendation +
follow-up tickets, not a PR. No repo code was modified producing this. Audience: a
future implementing agent with **zero memory** of the originating conversation.

This resolves the one fork `docs/38` flags as blocking Decision E:

> **Open decision (blocks E):** CRDT vs deterministic op-log (with deterministic
> merge). Either makes I4 a theorem you can fuzz. (`docs/38:405–426`)

Read `docs/38-agent-orchestration-architecture.md` first — especially **Decision E**
(`:306–326`, sync the SPATIAL layer ONLY, never runtime/pane state) and the
**Verification & test primitives** section (`:342–437`, invariants I4/I5).

**Convention on confidence.** Lines marked **[fact]** are verified against repo code
(`file:line`) or a live source (URL + access date 2026-06-30). Lines marked
**[judgment]** are my reasoning and may be wrong. Lines marked **[unverified]** are
claims I could not confirm and a follow-up must.

---

## Goal

Pick the **merge model** for syncing Continuum's spatial layer (`CanvasState` +
`WorkspaceDocument`) across one user's ≤ few Apple devices (Mac today, iOS later),
ideally real-time and 1:1, tolerating offline edits + reconnect, such that:

- **I4 (convergence)** is a *fuzzable theorem*: any op order, any replica count,
  any partition/reorder/delay/drop/duplicate + offline→reconnect → **byte-identical**
  state on every replica. (`docs/38:382`, `:411–426`)
- **I5 (boundary purity)** holds: the synced payload contains **no pid / pane target /
  host-local handle**. (`docs/38:383`)
- Logical clocks only — **no wall clock** for ordering (`docs/38:413–414`; same
  discipline as the project's `Date.now()` ban in workflow code).

The transport (CloudKit / relay / P2P) is **secondary** and deliberately decided
later; see *Transport note*. This doc fixes the **model**.

Out of scope (Decision E, `docs/38:312–317`): runtime bindings (`runtimeRef`), live
pane state, `TerminalSessionDescriptor`, agent status. Those are derived/rebound
locally and **never** sync. The activity tree syncs only as a *derived projection of
already-synced spatial data* (`docs/38:421–423`), so it is not part of this fork.

---

## Synced data & concurrency profile

### Exactly what would sync (verified against repo)

**`CanvasState`** (`Sources/ContinuumRevivedCore/CanvasState.swift:3`) — per project,
persisted as `canvas.json` (`ProjectStore.saveCanvas` `ProjectStore.swift:108`):

| Field | Type | line | Shape |
|---|---|---|---|
| `schemaVersion` | `Int` | `:6` | constant |
| `viewport` | `CanvasViewport {x,y,zoom: Double}` | `:7`, `:27` | per-field LWW register |
| `tiles` | `[Tile]` | `:8` | **keyed set** (each `Tile.id: UUID`) |
| `groups` | `[TileGroup]` | `:9` | keyed set; each has `tileIds: [UUID]` (`:193`) |
| `lastActiveTileId` | `UUID?` | `:10` | LWW register |

**`Tile`** (`CanvasState.swift:39`): `id: UUID` (`:40`, immutable key), `kind`
(`:41`), `title` (`:42`), `frame: TileFrame {x,y,width,height: Double}` (`:43`,`:80`),
`zIndex: Int` (`:44`), **`runtimeRef: RuntimeRef?`** (`:45`, `:94` — **I5 taint, see
below**), `metadata: TileMetadata` (`:46`, `:111`).

**`TileGroup`** (`CanvasState.swift:190`): `id: UUID`, `title`, `tileIds: [UUID]`
(`:193` — an **ordered list of references**), `color`, `collapsed`.

**`WorkspaceDocument`** (`Sources/ContinuumRevivedCore/WorkspaceDocument.swift:13`) —
per workspace, persisted as `canvas.json` under the workspace dir
(`WorkspaceStore.save` `WorkspaceStore.swift:55`):

| Field | Type | line | Shape |
|---|---|---|---|
| `schemaVersion` | `Int` | `:16` | constant |
| `viewport` | `CanvasViewport` | `:17` | per-field LWW register |
| `zones` | `[ZonePlacement]` | `:18` | **keyed set** (`ZonePlacement.zoneId: UUID`) |
| `zoneZOrder` | `[UUID]` | `:19` | **ordered list of references** |
| `lastActiveZoneId` | `UUID?` | `:20` | LWW register |
| `groupZoneTiles` | `[GroupZoneTiles]` | `:21` | keyed set; each = `{zoneId, tiles:[Tile]}` (`:3`) |

**`ZonePlacement`** (`WorkspaceDocument.swift:147`): `zoneId: UUID` (`:148`, key),
`projectId: UUID?` (`:149`, nil for ambient/group zones), `origin: ZonePoint`
(`:150`), `size: ZoneSize` (`:151`), `color` (`:152`), `collapsed` (`:153`),
`hydrationPolicy` (`:154`), `name` (`:155`), `navKey: String?` (`:156`).

**Nesting depth is shallow (≤ 3):** document → keyed set of tiles/zones → struct of
scalars. The only nested *collection* is `groupZoneTiles[*].tiles: [Tile]`
(`WorkspaceDocument.swift:5`) — a keyed set one level down — and the two
ordered-reference lists `tileIds` / `zoneZOrder`. **[fact]**

**I5 taint surface inside the synced payload (must be excluded/scrubbed):**
- `Tile.runtimeRef: RuntimeRef?` (`CanvasState.swift:45`) — a pointer at a local
  runtime; the canonical thing Decision E says must not cross (`docs/38:312–315`).
  **[fact]**
- `TileMetadata` free-text fields: `projectRelativeCwd`, `filePath`, `url`
  (`CanvasState.swift:113`, `:128`, `:130`, `:131`) — host-relative path/URL strings.
  Project-relative is *probably* portable, but absolute leaks are possible.
  **[judgment]**
- For contrast, the genuinely host-local data already lives **outside** the synced
  documents, in `TerminalSessionDescriptor` (`sessions/<id>.json`): `command`, `args`,
  `cwd`, `env`, `scrollback`, `lastExit`, `createdAt`/`lastStartedAt`
  (`TerminalSessionDescriptor.swift:10–21`). That file is **not** in scope E and must
  never be added to the sync set. The architecture already physically separates the
  layers — the I5 risk is narrow and concentrated on `runtimeRef` + a few metadata
  strings, not diffuse. **[fact + judgment]**

### Concurrency profile

- **One human user**, ≤ a few devices (`docs/38:34`, "observed from iOS"). **[fact]**
- **Low contention.** Real simultaneous edits to *the same field of the same tile* on
  two devices are rare; the dominant real case is **offline edits on device A while B
  is idle, then reconnect** (e.g. rearrange on the Mac, open iOS later). **[judgment]**
- **No adversarial / Byzantine peers** — all replicas are the same user's trusted
  devices. **[judgment]**
- Documents are **small**: tens of tiles/zones, not 260k-char text. **[judgment]**

### Operation inventory + required conflict semantics

The actions exist in the canvas/zone executors today (move/resize/close/zone-assign
are named in `docs/38:393`, `:475`). Per op, what merge actually needs:

| Op | Touches | Needed semantics | Hard? |
|---|---|---|---|
| **create tile/zone** | add to keyed set | **add-wins**; key is a fresh UUID → no key collision | no |
| **delete tile/zone** | remove from keyed set | **delete-wins vs concurrent field edits** (do not resurrect via a stray move) | **yes** (move-vs-delete) |
| **move** (frame.x/y) | `Tile.frame` / `ZonePlacement.origin` | **LWW per field**, logical-clock ordered | no |
| **resize** (w/h) | `frame.width/height` / `ZoneSize` | **LWW per field** | no¹ |
| **rename / recolor / collapse** | scalar fields | **LWW per field** | no |
| **z-order (tile)** | `Tile.zIndex: Int` | LWW per field — but two tiles can collide on an int | **mild** (see ²) |
| **z-order (zone)** | `zoneZOrder: [UUID]` | **list reorder** — concurrent moves must not dup/drop | **yes** |
| **group/zone membership** | `TileGroup.tileIds`, `groupZoneTiles[*].tiles` | **set add/remove + a tile in ≤1 zone** | **yes** (churn) |
| **viewport pan/zoom** | `viewport` | **per-device, arguably should NOT sync at all** (see ³) | n/a |

¹ Concurrent resize of the *same* tile on two devices: with per-field LWW you can get
`width` from A and `height` from B — a box neither user drew, but **valid and
non-destructive**. Acceptable at this contention level. **[judgment]**

² `zIndex` is a free `Int` (`CanvasState.swift:44`); two concurrent "bring to front"
can pick the same value. LWW converges (both replicas agree on the winner) but the
*visual* tie is arbitrary. Acceptable; a fractional-index scheme is a later nicety, not
a sync-correctness issue. **[judgment]**

³ **Viewport is camera state, not document state.** Syncing it fights two devices with
different screens. **[judgment]** Recommend it stays device-local (Decision E already
syncs "positions/membership", and a camera is neither). Flagged as an open question —
the *types* currently bundle it into the same struct, so excluding it is a layout
choice, not a model constraint.

**Takeaway:** the overwhelming majority of ops are **LWW-per-field on a keyed set** —
the easy case for *both* options. Genuine conflict resolution is needed in exactly
three places: **move-vs-delete**, **ordered-list reorder** (`zoneZOrder`), and
**membership churn**. The decision hinges on how cleanly each option handles those
three, and at what cost. **[judgment]**

---

## Option A — CRDT (off-the-shelf)

A CRDT gives convergence *by construction*: merge is associative, commutative,
idempotent, so any order/dedup of deliveries lands on the same state. I4 becomes "trust
the library + fuzz the integration" rather than "prove my merge." **[fact, standard
CRDT property]**

### Current (2026-06-30) Swift/iOS-usable options

| Library | Latest | Released | Kind | iOS / macOS min | License | Maturity |
|---|---|---|---|---|---|---|
| **Loro** (`loro-dev/loro-swift`) | **1.13.2** | **2026-06-15** | Rust+UniFFI xcframework | iOS 13 / macOS 10.15 / visionOS 1 | MIT | post-1.0, **actively shipping** |
| **Automerge** (`automerge/automerge-swift`) | **0.7.2** | **2025-12-20** | Rust+UniFFI xcframework | iOS 13 / macOS 10.15 / visionOS 1 | MIT | 0.x, maintained, slower cadence |
| **YSwift** (`y-crdt/yswift`) | **0.2.1** | **2024-04-04** | Rust+UniFFI xcframework | (WIP) | MIT | **stale ~2 yr**, WIP, not prod-ready |
| **Ditto** (`getditto`, `DittoSwift`) | v4.9.x | 2026 | commercial SDK (CRDT + mesh transport) | iOS/macOS | **commercial, per-peer pricing** | mature but model+transport bundled |
| **heckj/CRDT** | 0.5.0 | ~2023 | **pure Swift**, δ-state | n/a (source) | MIT | small; registers/sets/seq, **no movable list** |

All version/date/license/platform rows above are **[fact]** — verified
2026-06-30 via GitHub API (`gh api repos/<repo>/releases`) and each repo's
`Package.swift` `platforms:` block.

**Per-option notes:**

- **Loro** — `platforms: [.iOS(.v13), .macOS(.v10_15), .visionOS(.v1)]`, binary target
  pinned by URL + checksum to the `1.13.2` `loroFFI.xcframework.zip`
  (`loro-dev/loro-swift` `Package.swift`, fetched 2026-06-30). **[fact]** Distinctive
  feature: a **MovableList** CRDT with first-class `move` and `set`, implementing the
  "Moving Elements in List CRDTs" algorithm on a dual-index RGA, *specifically so that
  concurrent move/set don't degrade into delete+double-insert*
  (https://loro.dev/docs/tutorial/list, accessed 2026-06-30). **[fact]** This is the
  single best fit for `zoneZOrder` + membership churn. Smallest encoding of the three
  JS-benchmarked CRDTs (68 kB vs Yjs 160 kB vs Automerge 250 kB on a 260k-char doc;
  https://www.pkgpulse.com/guides/yjs-vs-automerge-vs-loro-crdt-libraries-2026,
  accessed 2026-06-30). **[fact, but that benchmark is a JS text doc, not our small
  struct doc — treat as directional, not our number]**

- **Automerge** — same platform floor; latest Swift binding `0.7.2` wraps Automerge
  core `0.7.2` (still 0.x — **no "Automerge 3"** for the Swift binding as of
  2026-06-30; `gh api`, accessed 2026-06-30). **[fact]** Lists are **RGA with insert/
  delete only**; `insertAt`/`deleteAt`/`splice` exist but there is **no native
  first-class list `move`** — move-CRDT support is *researched and "planned to be
  integrated"* but not shipped as a stable API (https://automerge.org/docs/reference/
  documents/lists/ and arXiv 2311.14007 "Extending JSON CRDTs with Move Operations",
  both accessed 2026-06-30). **[fact]** Without native move, reorder must be modelled
  as delete+reinsert, which is exactly the concurrent-move anomaly Loro's MovableList
  avoids. **[judgment]** Strong, well-documented Apple story (Automerge-Repo Swift
  edition adds storage/network; same maintainer as `heckj/CRDT`). **[fact]**

- **YSwift** — last release 2024-04-04 (`gh api`, accessed 2026-06-30); WIP, "not all
  Yrs/Yjs features exposed," last PR merged > 1 yr ago. **Do not adopt for production**
  given the project's reliability bar. **[fact + judgment]**

- **Ditto** — CRDT engine **bundled with a Wi-Fi/Bluetooth/ad-hoc mesh transport** and
  **per-active-peer subscription pricing** (https://docs.ditto.live/install-guides/
  swift; Capterra/business-model pages, accessed 2026-06-30). **[fact]** For a
  single-user few-device app this is the wrong shape (transport we don't need, a
  recurring per-device cost, model↔transport coupling Decision E explicitly wants to
  avoid). **Reject.** **[judgment]**

- **heckj/CRDT** — the only **pure-Swift, zero-FFI** option (δ-state CRDTs: LWW
  register, sets, a sequence). Self-contained, no binary. **[fact]** But it has **no
  movable-list / nested-document model**; you'd be assembling the document CRDT
  yourself from primitives — which is most of Option B's work anyway, minus a
  hand-rolled register. **[judgment]** Mention as the "CRDT primitives without a binary"
  middle path; not a turn-key document store.

### How a turn-key CRDT (Loro/Automerge) maps THIS data shape

- **Keyed sets (`tiles`, `zones`):** a CRDT **Map** keyed by UUID string; each entry is
  a nested Map of the tile's/zone's fields. Add-wins on create; per-field LWW register
  on scalar edits. Clean. **[fact, standard]**
- **Scalars (`frame`, `viewport`, `title`, `zIndex`, `collapsed` …):** CRDT registers
  → LWW. Clean. **[fact]**
- **`zoneZOrder: [UUID]`:** Loro **MovableList** → native, anomaly-free reorder.
  Automerge → list of UUIDs with insert/delete only (reorder = delete+reinsert, anomaly
  risk under concurrency). **[fact]**
- **Membership (`tileIds`, `groupZoneTiles[*].tiles`):** model as a CRDT Map/Set;
  "tile in ≤ 1 zone" is **not** a native CRDT invariant — concurrent "move tile T to
  zone X" + "to zone Y" can converge to T in both. The CRDT converges *to a state*;
  whether that state respects your app invariant is **your** post-merge repair (a
  deterministic resolver: pick by (logicalClock, replicaId)). **[judgment — this is the
  load-bearing caveat: a CRDT converges, it does not enforce domain invariants]**
- **move-vs-delete:** in a CRDT Map, a delete + a concurrent field-set on the same key
  → library policy decides (typically the delete tombstones the key; a concurrent
  child-set may resurrect it depending on the lib). Must be **tested**, not assumed.
  **[judgment]**

### I5 with a CRDT

The taint risk (`Tile.runtimeRef`, host-y `TileMetadata` strings) is **upstream of the
CRDT**: you choose what to put into the CRDT document. Define a `SpatialSnapshot` →
CRDT projection that **omits `runtimeRef` and host-absolute strings**; the taint scan
asserts the *encoded CRDT bytes* contain none of them (see Test rig). The CRDT doesn't
help or hurt I5 — it's a boundary you build either way. **[judgment]**

### Costs

- **Binary weight (verified 2026-06-30, `gh api` release assets):**
  - Loro `loroFFI.xcframework.zip` = **124,348,376 bytes (~124 MB compressed)**, all
    platform slices (device + simulator, multi-arch) in one zip. **[fact]**
  - Automerge `automergeFFI.xcframework.zip` = **54,278,033 bytes (~54 MB
    compressed)**; per-arch static lib `libuniffi_automerge.a` ≈ **15.6 MB**. **[fact]**
  - **[unverified]** The *linked-into-the-app* slice (one arch, after dead-strip) is
    far smaller than the multi-platform zip — likely low-tens-of-MB for Loro,
    high-single-digits/low-tens for Automerge. A follow-up MUST measure the actual app
    `.app` size delta; I did not build either.
  - Continuum already ships one large binary target (`GhosttyKit.xcframework`,
    `Package.swift:15`), so an FFI xcframework is **not a new category** of dependency —
    but it is a *second* Rust/native blob to vendor, checksum, and update. **[fact +
    judgment]**
- **New dependency on the dependency-free core.** `ContinuumRevivedCore` today has
  **zero external dependencies** (`Package.swift` — `.target(name:
  "ContinuumRevivedCore")` with no `dependencies:`). **[fact]** Adding Loro/Automerge to
  the *core* breaks that property; you'd likely isolate it in a new `…Sync` target.
  **[judgment]**
- **Opacity.** Merge correctness lives in Rust you don't own. When it misbehaves at a
  schema/version edge you debug across an FFI boundary. Mitigated by the libraries'
  maturity (esp. Loro post-1.0). **[judgment]**
- **Versioning / migration.** The encoded CRDT format is the library's, not yours;
  upgrading the lib across a wire-format change is a migration you don't control. Both
  have stable encodings now; still a real long-tail risk. **[judgment]**

---

## Option B — Hand-rolled deterministic op-log

Keep `CanvasState`/`WorkspaceDocument` as the materialized state; sync a **log of
operations** with a **deterministic merge** = sort all ops into one total order and
fold them. Convergence ⇐ every replica sorts the same way + each fold step is a pure
function. No wall clock. **[fact, standard op-log/event-sourcing property]**

### Op model (concrete)

```swift
// Lives in a new dependency-free target, e.g. ContinuumRevivedSync.
struct OpId: Comparable, Codable, Hashable, Sendable {
    var lamport: UInt64       // logical clock (max-seen + 1 on apply)
    var replica: UUID         // stable per-device id; total-order tie-break
}                             // Compare (lamport, replica) lexicographically.

enum Op: Codable, Sendable {
    // keyed-set lifecycle
    case createTile(id: UUID, initial: TileSeed)            // add-wins
    case deleteTile(id: UUID)                               // delete-wins (tombstone)
    case createZone(id: UUID, initial: ZoneSeed)
    case deleteZone(id: UUID)
    // per-field LWW registers (one op per field keeps merges field-granular)
    case setTileFrame(id: UUID, frame: TileFrame)
    case setTileZIndex(id: UUID, z: Int)
    case setTileScalar(id: UUID, field: TileScalarKey, value: Scalar)
    case setZoneOrigin(id: UUID, origin: ZonePoint)
    case setZoneSize(id: UUID, size: ZoneSize)
    case setZoneScalar(id: UUID, field: ZoneScalarKey, value: Scalar)
    // ordered list of refs (zoneZOrder) — store a fractional position, not an index
    case setZonePosition(id: UUID, pos: FracIndex)          // see ordering note
    // membership: tile belongs to ≤1 zone — model as an LWW register *on the tile*
    case setTileZone(tile: UUID, zone: UUID?)               // nil = ambient
}

struct LoggedOp: Codable, Sendable { var opId: OpId; var op: Op }
```

**State is derived, never authored directly:** `materialize(ops:) -> (CanvasState,
WorkspaceDocument)` sorts `ops` by `opId` and folds. The existing stores keep persisting
the *materialized* snapshot for fast load; the **op-log is the source of truth** for
sync. **[judgment]**

### Ordering — logical clock, never wall clock

- **Lamport + replicaId** gives a deterministic **total order** (`(lamport, replica)`,
  lexicographic) — confirmed standard: Lamport alone has ties; tie-break on a unique
  node id yields a deterministic total order
  (https://en.wikipedia.org/wiki/Lamport_timestamp and design-gurus / thecodeforge
  refs, accessed 2026-06-30). **[fact]**
- Causality is **not required** for this data — no op's *meaning* depends on having
  seen a specific prior op (an LWW field-set is self-contained; create/delete key off a
  stable UUID). So a **Lamport scalar suffices; vector clocks are unnecessary** weight.
  **[judgment]** (Vector clocks would only matter if we needed to *detect* concurrency
  to do something special; LWW doesn't — it just needs a winner.)

### Per-field conflict policy

- **Scalar fields (move/resize/rename/zIndex/collapse):** the op with the **greater
  `opId`** wins (last-writer-wins by *logical* time). Idempotent: re-applying a loser
  changes nothing. **[fact, by construction]**
- **create:** add-wins. A create with a fresh UUID never collides. Re-delivery → no-op
  (id already present, keep the higher-opId field values). **[fact]**
- **delete vs concurrent edit (move-vs-delete — HARD case #1):** delete writes a
  **tombstone** keyed by tile id. `materialize` drops any tile with a tombstone
  **regardless of op order** — a concurrent `setTileFrame` with a higher Lamport does
  **not** resurrect it. Policy = **delete-wins.** This is a deliberate, documented
  choice; the alternative (resurrect-on-edit) is also defensible but delete-wins
  matches "I closed that tile" intent. **[judgment — but it is a *decision*, made
  explicitly, and it converges either way]**
- **`zoneZOrder` reorder (HARD case #2):** **do not store an index.** Give each zone a
  **fractional position** (`FracIndex` — a rational/decimal "between A and B"); reorder
  = `setZonePosition` (LWW on that zone's position). `materialize` sorts zones by
  `(position, zoneId)`. Concurrent reorders converge (each is an independent LWW
  register) and **cannot dup or drop** a zone because position is a *property of the
  zone*, not a slot in a shared array. Ties on identical fractions break by `zoneId`.
  **[judgment — this is the standard fractional-indexing trick; it sidesteps array-CRDT
  entirely for our "few items" case]**
- **membership churn (HARD case #3):** model "which zone owns tile T" as an **LWW
  register on the tile** (`setTileZone`), **not** as add/remove on each zone's array.
  Then "T in ≤ 1 zone" is **automatic** — a tile has exactly one `zone` value, last
  writer wins. Concurrent "move T to X" + "to Y" → the higher-opId wins; T is in
  exactly one. This **turns the hardest CRDT case into a trivial register.** Zone
  membership lists become a *derived view* (`tiles where zone == Z`). **[judgment —
  this re-modeling is the crux of why op-log is attractive here]**
- **viewport:** excluded from sync (see profile ³). If synced later, per-field LWW.

### Convergence argument

Given the same multiset of `LoggedOp`s, every replica: (1) sorts by `opId` — a total
order because `(lamport, replica)` pairs are unique (replicaId unique per device,
Lamport monotonic per replica); (2) folds with pure functions; (3) delete-wins and LWW
are order-insensitive *given the tombstone set + max-opId-per-field*, so even
**partial** logs converge once the same ops have arrived. Duplicates are idempotent
(same `opId` ⇒ same effect). ⇒ **byte-identical materialized state.** This is exactly
the I4 theorem, and it is **mechanically fuzzable** (Test rig). **[fact, given the
policies above are implemented as stated]**

### Serialization

- Each `LoggedOp` is `Codable` → deterministic JSON or a compact binary. **Canonical
  encoding matters for byte-identity:** sort map keys, fixed number formatting. The
  project already runs everything through `Codable` + an `AtomicWriter`
  (`ProjectStore.swift:78`), so this is in-grain. **[fact + judgment]**
- **Log growth:** unbounded if naive. Mitigate with **compaction** — periodically fold
  to a snapshot + keep only ops after a globally-acknowledged Lamport low-water mark.
  Compaction is itself deterministic. This is the main ongoing-maintenance cost.
  **[judgment]**

### I5 with an op-log

`Op` is a **closed, hand-authored enum** — `runtimeRef` and host strings are simply
**not expressible** as ops. I5 becomes a **compile-time property** (the type can't carry
the taint) plus the same runtime taint scan as belt-and-suspenders. This is strictly
*stronger* I5 than a general CRDT Map, where anything could be put in a value. **[fact +
judgment]**

### Costs

- **You own the merge.** Every policy above is code you write, test, and must get
  right; a subtle non-commutative fold = a silent divergence bug — *the exact "sync bugs
  are forever" failure `docs/38:411–412` warns about, now on your side of the line.*
  **[judgment — the central risk of B]**
- **Build cost:** the op enum, `apply`/`materialize`, Lamport clock, fractional index,
  tombstone GC/compaction, canonical encoding, and a command→op mapping at every
  mutation site. The mutation surface is **broad** — `ProjectStore`/`WorkspaceStore`
  are referenced across ~13 files (`grep -l`, 2026-06-30) and `saveCanvas`/`save` are
  call-site-sprinkled — so routing every edit through the op-log is real work and is
  **retrofit-hostile** exactly as Decision E says (`docs/38:318–321`). **[fact +
  judgment]**
- **Zero new dependency / zero binary.** Stays pure Swift, preserves the
  dependency-free-core property, no FFI debugging, no third-party wire-format
  migrations. **[fact]**
- **Total control of payload + format** — smallest possible on-wire ops, full freedom
  to evolve schema with your own versioning. **[judgment]**

---

## Evaluation vs `docs/38` criteria

| Criterion (`docs/38`) | A — CRDT (Loro) | B — op-log |
|---|---|---|
| **I4 provable & fuzzable** (`:382`) | ✅ convergence by construction; fuzz the *integration* + post-merge invariant repair | ✅ convergence by construction *if policies hold*; fuzz the *merge itself* — the riskier surface, but fully in-process |
| **I5 boundary purity** (`:383`) | ⚠️ enforced by a projection you build; value Maps *could* carry taint → rely on the scan | ✅✅ taint **not expressible** in the `Op` enum (compile-time) + scan |
| **Logical clock, no wall clock** (`:413`) | ✅ internal (Lamport-like / OpId) | ✅ explicit Lamport + replicaId |
| **Move-vs-delete** | ⚠️ library-policy-dependent; must test resurrection | ✅ explicit delete-wins tombstone |
| **Ordered reorder (`zoneZOrder`)** | ✅✅ Loro MovableList native / ❌ Automerge (no native move) | ✅ fractional index (no array-CRDT needed for "few items") |
| **Membership "≤1 zone"** | ⚠️ CRDT converges but does **not** enforce the invariant → post-merge repair | ✅✅ LWW register on the tile makes it automatic |
| **Payload size** (`:425`) | ✅ compact (Loro smallest of CRDTs); per-op deltas exist | ✅ smallest possible — you design the op |
| **Swift / iOS portability** | ✅ iOS 13+/macOS 10.15+ (Loro & Automerge), clears the v14 floor | ✅ pure Swift, trivially portable |
| **Dependency weight** | ❌ ~54–124 MB xcframework zip; 2nd Rust blob to vendor; breaks dep-free core | ✅ none |
| **Dev cost (initial)** | ✅ low — adopt + project + invariant repair | ❌ high — author + test the whole merge |
| **Maintenance cost (ongoing)** | ⚠️ lib upgrades, FFI debugging, wire-format migrations you don't own | ⚠️ compaction + you own every merge-policy bug forever |
| **Conflict ergonomics for THIS data** | good (esp. Loro move) but domain invariants still your job | **excellent** — the re-modeling (membership→register, order→frac-index) makes the three hard cases trivial |

**The pivotal observation:** Continuum's data is **not** a collaborative text
document. It is a **small keyed-set of structs** where ~90% of ops are LWW-per-field,
and the only three hard cases all **dissolve under a modest re-modeling** (membership as
a register, order as a fractional index, delete as a tombstone). A CRDT's signature
strength — anomaly-free *concurrent text/array editing at scale* — is **mostly
unneeded** here, while its signature cost — a large opaque native dependency and
domain-invariant repair you *still* have to write — is fully paid. **[judgment]**

---

## Recommendation

**Build Option B — the deterministic op-log — as the sync model.** **[judgment]**

Rationale, in priority order:
1. **The data wants it.** Few small keyed structs, low contention, three hard cases
   that re-model into trivial LWW registers / fractional indices. A document CRDT is
   built for a harder problem than we have. **[judgment]**
2. **I5 is strongest here** — the closed `Op` enum makes the forbidden runtime handles
   *unrepresentable*, turning I5 from a runtime guard into a type-system property; for a
   project that treats boundary purity as a hard line (`docs/38:256`, `:383`) this is a
   real win. **[judgment]**
3. **It preserves the dependency-free core** (`ContinuumRevivedCore` has zero external
   deps today — verified) and adds **no native binary**, no FFI debugging, no
   third-party wire-format migration. **[fact + judgment]**
4. **I4 is just as fuzzable** — convergence-by-construction holds for a correct
   deterministic fold, and the fuzz harness (below) is identical in spirit to what
   you'd run over a CRDT integration anyway. **[judgment]**
5. **Even a CRDT does not let us skip the hard part** — domain-invariant repair
   (≤1-zone, move-vs-delete intent) is *our* code under either option, so the CRDT's
   convenience is smaller than it first appears. **[judgment]**

**Hard gate before this is final:** the op-log only beats a CRDT *if the merge is
actually deterministic and total.* That is a property you must **prove with the I4 fuzz
rig FIRST (RED→GREEN)** per the project's TDD doctrine — write the N-replica
convergence fuzz before the merge, watch it fail, then make it pass. If the fuzz can't
be made green cheaply, that is the signal to fall back to A. **[judgment]**

### Strongest counter-argument to my own choice

**"You are hand-rolling distributed-systems code, and the graveyard is full of op-logs
that looked deterministic and weren't."** `docs/38:411–412` says it plainly: ad-hoc
merge ⇒ "sync bugs are forever." A CRDT moves the *proven-hard* part (convergence) into
a **post-1.0, MIT, actively-shipped (Loro 1.13.2, 2026-06-15)** library that already
solved move/reorder correctly, leaving us only the projection + invariant repair. The
"large binary" objection is **weaker than it sounds**: Continuum *already* vendors a
big native xcframework (`GhosttyKit`), the *linked* slice is far smaller than the
multi-platform zip **[unverified — must measure]**, and the FFI pattern is already in
the build. If the team's appetite for owning subtle merge code is low — or if the iOS
client later wants *real* concurrent editing rather than the assumed low-contention
single-user pattern — **A (specifically Loro, for its MovableList) is the safer
institutional choice**, and a reasonable person could pick it over B on risk grounds
alone. My B recommendation is **contingent** on (a) the contention profile staying
genuinely low and single-user, and (b) the I4 fuzz going green early and cheaply. If
either breaks, switch to Loro.

A defensible **hedge** exists and is worth noting: design the op-log behind the
Decision-E store protocol such that the *seam* is identical whether the backend is an
op-log or a CRDT. Then B-first with a clean fallback to Loro costs little optionality.
**[judgment]**

---

## Test rig (I4 / I5) under the recommendation (Option B)

Lives in `ContinuumRevivedCoreChecks` (core tier, `docs/38:429`). All in-process, no
network, fake clock only (`docs/38:367–372`). Written **before** the merge (RED→GREEN).

### I4 — N-replica convergence fuzz

```
Replica:   { replicaId: UUID, lamport: UInt64, log: [LoggedOp] }
Transport (FAKE, in-proc): a queue per ordered pair of replicas that can
    partition / reorder / delay / drop / duplicate (docs/38:418), and a
    `goOffline(r)` / `reconnect(r)` that buffers then floods the backlog.

fuzz(seed):
  spawn N replicas (N ∈ 2…5)
  for step in 1…K:
     pick a random replica r, a random legal Op against r's *current materialized*
        state (create/delete/move/resize/zorder/membership)  ← real action executor,
        not hand-built ops (docs/38:393 "drives the actual action executor")
     r.lamport += 1; append LoggedOp(OpId(r.lamport, r.replicaId), op); broadcast
     randomly: deliver some queued msgs (reordered/dropped/duped), toggle offline
  // settle
  reconnect all; deliver every queued msg until all queues empty
  bump every replica's clock past max; let all logs equalize
  ASSERT: canonicalEncode(materialize(r.log)) is byte-identical ∀ r      ← I4
  ASSERT: each replica's state satisfies domain invariants               ← repair check
          (every tile in ≤1 zone; no tombstoned id present; zoneZOrder a
           permutation of live zones; no orphan group member)
```

- **Determinism of the *fuzz*:** seed the RNG; a failing seed reproduces exactly →
  shrinkable counterexamples. **[judgment]**
- **Byte-identity** is asserted on the **canonical encoding** of the materialized
  snapshot (sorted keys, fixed formatting) — this is the literal I4 wording "byte-
  identical" (`docs/38:382`). Round-trip (I7, `docs/38:386`) is a free sub-assertion.
- **Nightly soak** (`docs/38:423–424`): M iterations of random ops × random network;
  assert convergence every time; record **max convergence latency / max log length
  before compaction** as budgets.
- **Compaction is in the fuzz:** periodically compact a random replica mid-run and
  assert it still converges with the others — compaction must be merge-equivalent.

### I5 — taint scan

```
taintScan(syncedPayload bytes):
  forbidden tokens (must NEVER appear in the on-wire op/snapshot bytes):
    - any RuntimeRef encoding / the field name "runtimeRef"
    - pid-shaped values, tmux pane/window targets (e.g. "%<n>"), session names
      ("continuum-…"), host strings ("ssh://", absolute "/Users/…")
    - the keys command/args/env/scrollback (TerminalSessionDescriptor surface)
  ASSERT: none present.                                                  ← I5 (docs/38:383)

Plus a STRUCTURAL guarantee (stronger than the scan): a compile-time test that the
`Op` enum's associated values are drawn only from an allow-listed set of spatial
value types (UUID, Double/Int, TileFrame, ZonePoint/Size, enums, short strings) —
so taint is unrepresentable, not merely absent.  ← the type-level half of I5
```

- Run the scan over (a) every individual broadcast op and (b) a full compacted
  snapshot. Manifest records `taint=none` with the actual scanned byte count — never
  `{passed:true}` (`docs/38:431–432`). **[fact, matches the doctrine]**
- Feed the scan **adversarial** inputs too: deliberately try to author an op carrying a
  `runtimeRef` and assert it **doesn't compile / is rejected at the projection
  boundary** (real-path, not happy-path — `docs/38:347`).

### What the rig does NOT need

The activity tree is a **derived projection of synced spatial data** (`docs/38:421`),
so cross-platform agreement reduces to **snapshot equality** (Mac render ==
iOS render from identical synced bytes), not a separate convergence proof. No extra
rig. **[fact, per doc]**

---

## Transport note (secondary — model is the primary decision)

The model above is **transport-agnostic by design**: it emits a stream of
self-contained `LoggedOp`s + occasional compacted snapshots, ordered by logical clock.
Any reliable-eventually channel works. Candidates:

| Transport | Fit | Coupling / caveat |
|---|---|---|
| **CloudKit** (`CKRecord` per op or per doc; private DB) | Strong for single-user Apple-only; free-ish, no server to run; offline queue + push built in | Apple-only (fine — iOS is the only other client); op-as-record needs idempotent upsert keyed by `OpId`; **subscription latency is not real-time-fast** — "near real-time," seconds, acceptable for canvas |
| **Small relay server** (WebSocket fan-out, dumb log broker) | Best **real-time** latency; trivial to make the op-log authoritative + replayable | You run/host it; auth/identity is on you |
| **P2P / MultipeerConnectivity** | LAN, no server, lowest latency same-room | No remote/offline-different-network story; not a sync-of-record |

**Recommendation [judgment]:** keep the model decision (B) independent and ship
transport behind the Decision-E `SyncTransport` fake first (`docs/38:372`, `:416`); the
fuzz never touches a real transport. For the **first real** transport, **CloudKit
private DB** is the lowest-operational-cost fit for a single user's Apple devices, with
a **small relay** as the upgrade if real-time latency proves insufficient. The op-log is
indifferent to which — that indifference is the point. **Model↔transport coupling to
avoid:** Ditto (bundles a mesh transport into the model — Decision E explicitly wants
the seam separable, so a model that *is* its transport is disqualifying). **[judgment]**

---

## Open questions a follow-up must still resolve

1. **Measure the real linked binary size** of Loro and Automerge in an actual
   Continuum `.app` (one arch, post-strip) — the 54/124 MB figures are *multi-platform
   compressed zips*, not the app-size delta. This number materially affects how strong
   the "no binary" argument for B is. **[unverified — blocks a fully-informed A-vs-B
   call if the team is on the fence]**
2. **Lock the conflict *policies* with Dylan**, not just the mechanism: delete-wins vs
   resurrect-on-edit; whether viewport syncs at all; zIndex tie-break (arbitrary vs
   fractional). Each is a product call, not a math call.
3. **Compaction / log-GC protocol**: when is a Lamport low-water mark "globally
   acknowledged" without a central authority? (Trivial with a relay; needs thought with
   CloudKit-only.)
4. **Identity / replicaId provenance** (`docs/38:536`): stable per-device UUID, minted
   where, surviving reinstall? Total-order correctness depends on uniqueness.
5. **iOS client scope** (`docs/38:534`): observe-only first vs control. If iOS becomes
   a real concurrent *editor*, re-examine the "low contention" assumption that underpins
   the B recommendation.
6. **`TileMetadata` portability audit**: which fields are safe to sync (project-relative
   ok) vs must be scrubbed/derived (absolute paths, `runtimeRef`). Feeds the I5 scan
   token list.
7. **Schema evolution for ops**: versioning the `Op` enum across releases so an old
   device's log replays on a new one (and vice-versa) — the op-log's analogue of a CRDT
   wire-format migration.
8. **Does the materialized snapshot stay the on-disk format, or does the log become the
   on-disk format too?** (Affects `ProjectStore`/`WorkspaceStore` and crash recovery.)

---

## Sources

**Repo (verified 2026-06-30):**
- `Sources/ContinuumRevivedCore/CanvasState.swift` — `CanvasState:3`, `CanvasViewport:27`,
  `Tile:39` (`runtimeRef:45`), `TileFrame:80`, `RuntimeRef:94`, `TileMetadata:111`
  (`projectRelativeCwd/filePath/url` `:128`–`:131`), `TileGroup:190` (`tileIds:193`).
- `Sources/ContinuumRevivedCore/WorkspaceDocument.swift` — `GroupZoneTiles:3`,
  `WorkspaceDocument:13` (`zones:18`, `zoneZOrder:19`, `groupZoneTiles:21`),
  `ZonePlacement:147` (`projectId:149`).
- `Sources/ContinuumRevivedCore/ProjectStore.swift` — `ProjectStore:76` (`AtomicWriter`
  `:78`), `saveCanvas:108`, `loadCanvas:112`, `saveSession:136`.
- `Sources/ContinuumRevivedCore/WorkspaceStore.swift` — `WorkspaceStore:29`, `save:55`,
  `load:59`.
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift` — fields `:6`–`:21`
  (`command/args/cwd/env/scrollback`), `AgentStatus:85`, `AgentDescriptor:94`.
- `Package.swift` — `swift-tools-version 6.0`, `platforms: [.macOS(.v14)]`,
  `GhosttyKit` binary target `:15`, `ContinuumRevivedCore` declared with **no**
  `dependencies`.
- `docs/38-agent-orchestration-architecture.md` — Decision E `:306–326`; verification
  primitives `:342–437`; invariant table I4/I5 `:382`–`:383`; sync-fork `:405–426`;
  no-wall-clock `:413`; phasing `:464–485`.

**Libraries (live, accessed 2026-06-30):**
- automerge-swift releases (0.7.2, 2025-12-20; asset sizes) — `gh api
  repos/automerge/automerge-swift/releases` — https://github.com/automerge/automerge-swift
- loro-swift releases (1.13.2, 2026-06-15; `loroFFI.xcframework.zip` 124 MB) — `gh api
  repos/loro-dev/loro-swift/releases` + `Package.swift` (`platforms: iOS13/macOS10.15/
  visionOS1`) — https://github.com/loro-dev/loro-swift
- yswift releases (0.2.1, 2024-04-04) — `gh api repos/y-crdt/yswift/releases` —
  https://github.com/y-crdt/yswift
- Loro List / MovableList ("Moving Elements in List CRDTs", dual-index RGA, native
  move/set) — https://loro.dev/docs/tutorial/list
- Automerge lists (RGA, insert/delete only; no native move; move-CRDT "planned") —
  https://automerge.org/docs/reference/documents/lists/ ; arXiv 2311.14007 "Extending
  JSON CRDTs with Move Operations" — https://arxiv.org/abs/2311.14007
- CRDT comparison 2026 (encoding sizes Loro 68 kB / Yjs 160 kB / Automerge 250 kB on a
  260k-char doc; all MIT) —
  https://www.pkgpulse.com/guides/yjs-vs-automerge-vs-loro-crdt-libraries-2026
- Ditto (CRDT + mesh transport, per-peer commercial pricing) —
  https://docs.ditto.live/install-guides/swift
- heckj/CRDT (pure-Swift δ-state CRDTs, no FFI; registers/sets/seq) —
  https://github.com/heckj/CRDT
- Lamport + replicaId ⇒ deterministic total order —
  https://en.wikipedia.org/wiki/Lamport_timestamp
