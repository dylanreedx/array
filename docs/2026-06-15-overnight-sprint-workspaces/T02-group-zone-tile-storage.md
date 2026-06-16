# T02 — Group-zone tile storage in the workspace store

A group zone (`projectId == nil`) owns its tiles in the **workspace** document, isolated
from every project canvas; project zones keep storing their tiles in their `ProjectStore`.

Status: todo
Tag: overnight [pure]
Depends on: T01 (optional `projectId` on `ZonePlacement`) · Blocks: T08, T12

(Per the charter task index: T08 `Depends on: T06,T02`; T12 `Depends on: T01,T02`. T15
`Depends on: T01` only — it reads `WorkspaceDocument` and therefore *consumes* this new
field once it lands, but the charter does **not** make T15 a hard dependent of T02. Do not
treat T15 as blocked by T02.)

## Goal
A *group zone* is pure organization with no backing project, so it has no `ProjectStore`
canvas to hold its tiles. This task gives the **workspace** document a place to store a
group zone's tiles (keyed by `zoneId`), using the same `Tile` model the project canvas
uses (zone-local frames). This is the storage half of "a group zone holds tiles and
persists across quit/relaunch" (charter §1, §4). Project-zone tiles are untouched: they
stay in their project's `ProjectStore` canvas (one project = one canvas = one runtime),
which is the load-bearing decision T08/T09 depend on.

## Exact scope — files & symbols
- **`Sources/ContinuumRevivedCore/WorkspaceDocument.swift`**
  - Add a new field to `WorkspaceDocument` to hold group-zone tile lists keyed by zone id
    (see Data / API changes for the exact shape — **`groupZoneTiles: [GroupZoneTiles]`**).
  - Add the small record type `GroupZoneTiles { zoneId: UUID, tiles: [Tile] }` in this
    file (Codable/Equatable/Sendable, mirroring `ZonePlacement`/`ZonePoint` style).
  - Extend `WorkspaceDocument`'s memberwise `init` with the new field (default `[]`), and
    its `Codable` so v1/v2 docs **without** the field decode to `[]` (backward compatible).
  - Add a tiny accessor + mutator pair on `WorkspaceDocument` so call sites don't poke the
    array directly: `func tiles(forZone:) -> [Tile]` and
    `mutating func setTiles(_:forZone:)` (see Data / API changes). Keep them minimal —
    they exist only so T08/T12/T15 have one stable seam.
- **`Sources/ContinuumRevivedCoreChecks/main.swift`**
  - Add a NEW `// MARK: - Group-zone tile storage (T02)` block (see the check section).
    Place it right after the existing `// MARK: - WorkspaceStore` block so the store
    fixtures are co-located. Anchors (verified): the `// MARK: - WorkspaceStore` header is at
    ~line 1068 and its `do { … }` body ends at ~line 1140 (just before
    `// MARK: - DefaultWorkspaceMigration` at ~1142) — insert the new block between those two,
    at ~line 1141. (Line numbers drift; the MARK headers are the durable anchors.)
- **Do NOT touch:**
  - `ProjectStore` / `ProjectStoreLayout` / `CanvasState` — project-zone tiles stay in the
    project canvas, unchanged. Do **not** add tiles-keyed-by-zone to `CanvasState`.
  - `Tile` / `TileFrame` / `TileMetadata` / `TileKind` — reuse the existing model verbatim;
    do not add fields. **Do NOT add a global `tile.zoneId`** (charter §1: membership is
    project-canvas for project zones, this stored list for group zones — never a tile field).
  - `appendProjectZone(...)` and every existing project-zone construction site — they
    produce project zones whose tiles live in `ProjectStore`; they get **no** group tiles.
  - `WorkspaceStore` / `AtomicWriter` (the new field rides the existing
    `save`/`load` → `AtomicWriter.write/read` path with no API change).
  - `ZoneRuntimeController`, `WorkspaceRuntime`, registry, any AppKit, the runtime that
    *spins ambient controllers* for group-zone tiles — that is T08, not here.
  - Do **not** migrate or move any project tile (charter "Deferred to v2": tile migration
    between zone kinds is explicitly out of scope).

## Data / API changes
A group zone's tiles are reused verbatim from the project tile model (`Tile` from
`CanvasState.swift`) and stored **zone-local** (frames relative to the zone origin, exactly
as project tiles are stored — converted at render via `CanvasEngine.worldFrame(tile:in:)`).

New record type (in `WorkspaceDocument.swift`):
```swift
public struct GroupZoneTiles: Codable, Equatable, Sendable {
    public let zoneId: UUID
    public var tiles: [Tile]

    public init(zoneId: UUID, tiles: [Tile]) {
        self.zoneId = zoneId
        self.tiles = tiles
    }
}
```

`WorkspaceDocument` gains one stored field + init param (defaulted) + accessors:
```swift
public var groupZoneTiles: [GroupZoneTiles]   // empty for a doc with no group zones

public init(
    schemaVersion: Int = WorkspaceDocument.currentSchemaVersion,
    viewport: CanvasViewport,
    zones: [ZonePlacement],
    zoneZOrder: [UUID],
    lastActiveZoneId: UUID?,
    groupZoneTiles: [GroupZoneTiles] = []          // <-- new, defaulted
) { … }

public func tiles(forZone zoneId: UUID) -> [Tile] {
    groupZoneTiles.first(where: { $0.zoneId == zoneId })?.tiles ?? []
}

public mutating func setTiles(_ tiles: [Tile], forZone zoneId: UUID) {
    if let i = groupZoneTiles.firstIndex(where: { $0.zoneId == zoneId }) {
        if tiles.isEmpty { groupZoneTiles.remove(at: i) }   // empty == absent, keeps docs lean
        else { groupZoneTiles[i].tiles = tiles }
    } else if !tiles.isEmpty {
        groupZoneTiles.append(GroupZoneTiles(zoneId: zoneId, tiles: tiles))
    }
}
```

**`Codable` (backward compat — the load-bearing detail).** `WorkspaceDocument` is currently
`public struct WorkspaceDocument: Codable, Equatable, Sendable` with a **synthesized**
`Codable` (verified: no `init(from:)`/`encode(to:)` in `WorkspaceDocument.swift`). The
synthesized decoder would *require* the new `groupZoneTiles` key, so a v1/v2 doc without it
would fail to decode. Add an explicit `Codable` for `WorkspaceDocument` — a custom
`init(from:)` + `encode(to:)` plus a **complete `CodingKeys`** enum listing **all six** keys
(`schemaVersion`, `viewport`, `zones`, `zoneZOrder`, `lastActiveZoneId`, `groupZoneTiles`) —
that does:
- `groupZoneTiles = try container.decodeIfPresent([GroupZoneTiles].self, forKey: .groupZoneTiles) ?? []`
- every other key decoded with `try container.decode(...)` exactly as the synthesized one did
  (so existing fixtures/round-trips are unchanged); `lastActiveZoneId` is `UUID?` →
  `decodeIfPresent` like today.
- encode always writes `groupZoneTiles` (omit-if-empty is **not** required; either is fine,
  but the check asserts a chosen behavior — pick "always encode" for determinism).

**Keep `Equatable` synthesized — do NOT hand-write `==`.** Synthesized `Equatable`
automatically includes the new stored property, which is exactly what assertion 1
(`loaded == document`) relies on. A hand-written `==` that forgets `groupZoneTiles` would let
assertion 1 falsely pass even if the field were dropped on decode. Only `Codable` becomes
explicit here; `Equatable` and `Sendable` stay synthesized.

**Schema version:** T01 already bumps `WorkspaceDocument.currentSchemaVersion` to 2. This
task does **not** bump it again — adding an optional-on-decode field is a compatible v2
addition (a v2 doc written before this task simply has no `groupZoneTiles` key and decodes
to `[]`). If T01 has not landed when this runs, that is a blocker — `projectId == nil`
group zones must be representable first; see "Out of scope / gotchas".

**Why an array of records, not `[UUID: [Tile]]`:** Swift's default `Codable` encodes a
`[UUID: [Tile]]` dictionary as a flat *unkeyed* array (`[key, value, key, value, …]`)
because `UUID` is not `CodingKeyRepresentable` — ugly, order-unstable, and hostile to the
hand-written backward-compat fixture in the check. The `[GroupZoneTiles]` record array
encodes as a clean array of JSON objects and round-trips deterministically. (If a later
task truly needs O(1) keyed access, derive a dictionary in memory — keep the *stored* shape
a record array.)

**Configurable-first:** this task introduces **no new binding / threshold / default** — it
is pure storage of an existing model. The group zone's *default size* and *ambient cwd* are
not decided here; they belong to T08 (the task that actually creates a group zone and spins
its ambient controller), which must ship those as persisted defaults + `SettingsSchema`
entries + conflict-guard at that time. This spec deliberately does not add a setting (per
"Surgical changes"); it is noted here so the reviewer does not flag a missing setting and so
T08 owns it. There is therefore nothing to add to `SettingsSchema.swift` in T02.

## The check, written FIRST (spec-as-test)
A NEW Core round-trip table in **`Sources/ContinuumRevivedCoreChecks/main.swift`**
(`// MARK: - Group-zone tile storage (T02)`), driven through the **real persistence path**:
construct a `WorkspaceDocument`, `WorkspaceStore.save(_:)` it to a temp App Support dir,
`WorkspaceStore.load()` it back, and assert on the reloaded document and the on-disk JSON.
For a pure-model/persistence task this real store round-trip (save → on-disk file →
load → AtomicWriter decode) IS the real path; nothing constructs a tile dictionary by hand
and asserts on it directly. No `run-matrix.sh` / `ContinuumApp.swift` registration is needed
— `ContinuumRevivedCoreChecks` is already a matrix target; this block runs inside it.

Fixtures (all UUIDs literal so every asserted value is hand-derivable):
- `wsId = AAAAAAAA-0000-4000-8000-000000000001`
- group zone `gz = 0000AAAA-0000-4000-8000-00000000000A` (`projectId: nil`)
- project zone `pz = 0000BBBB-0000-4000-8000-00000000000B` (`projectId: projP`,
  `projP = 0000CCCC-0000-4000-8000-00000000000C`)
- group tile `t1 = 0000D001-0000-4000-8000-000000000001`,
  `t2 = 0000D002-0000-4000-8000-000000000002` (both with zone-local `TileFrame`s, e.g.
  `t1.frame = (x: 40, y: 40, w: 600, h: 400)`, `t2.frame = (x: 700, y: 40, w: 500, h: 300)`).

Build a `WorkspaceDocument` with `zones: [gz, pz]`, `zoneZOrder: [gz, pz]`,
`lastActiveZoneId: gz`, and `groupZoneTiles` set via `setTiles([t1, t2], forZone: gz)`
(no entry for `pz`). Save with `WorkspaceStore(workspaceId: wsId, applicationSupportDirectory: scratch)`,
then `load()`.

Assertions (every one hand-derivable):
1. **Store round-trip equality:** `loaded == document` (full `Equatable` — proves
   `groupZoneTiles` is included in the encode/decode and in `Equatable`).
2. **Group tiles survive the disk round-trip:** `loaded.tiles(forZone: gz) == [t1, t2]`
   (same ids, kinds, **zone-local frames**, order preserved). Assert `t1.frame.x == 40`
   on the reloaded tile (proves the frame is the unchanged zone-local value, not rewritten).
3. **Project zone has no workspace-stored tiles:** `loaded.tiles(forZone: pz) == []` and
   `loaded.groupZoneTiles.contains(where: { $0.zoneId == pz }) == false` (proves project
   zones don't get an entry — their tiles live in `ProjectStore`).
4. **Isolation from any project canvas:** the on-disk **workspace** `canvas.json` exists
   and contains the group tile ids, AND **no `ProjectStore` canvas was written** — assert
   that under `scratch` there is **no** `.continuum-revived/canvas.json` (a `ProjectStore`
   layout file, path verified: `ProjectStore.swift` `stateRoot = root/.continuum-revived`,
   `canvasFile = stateRoot/canvas.json`) anywhere, i.e. group-zone tiles never leak into a
   project store. Concretely: read `String(contentsOf: store.layout.canvasFile)` and `expect`
   it contains `t1.id.uuidString` and `gz.uuidString`; and `expect` a recursive enumeration
   (`FileManager.default.enumerator(at: scratch, ...)`) finds zero files at a path ending
   `.continuum-revived/canvas.json`.
   - **Load-bearing half = the positive content check.** The `t1.id`/`gz` substring assertion
     is the real proof: it goes through `WorkspaceStore.save` → on-disk JSON and reads the
     bytes back, so it FAILS if `groupZoneTiles` is dropped on encode or the field is excluded
     from the `Codable`. Re-derive: with two group tiles set on `gz`, the encoded
     `workspaces/<wsId>/canvas.json` MUST literally contain both `t1.id.uuidString` and
     `gz.uuidString`.
   - **Negative scan is a guard, not a feature proof — and is near-vacuous in *this* Core
     table** (nothing here constructs a `ProjectStore`, so of course no `.continuum-revived/
     canvas.json` is written). Keep it anyway: its job is to catch a *future* regression where
     someone wires a `ProjectStore` write into the workspace save path. To make it
     non-vacuous, the scan must run over `scratch` **after** `store.save` (so any stray write
     would be present), and the reviewer should confirm it would go RED if a `ProjectStore`
     for `projP` were saved under `scratch` — i.e. it is asserting *absence of a real path*,
     not merely the absence of a construction the check never performs.
5. **Backward compat — v2 doc WITHOUT the field decodes to empty:** decode a hand-written
   JSON literal that is a valid v2 `WorkspaceDocument` (the existing fixture shape at
   main.swift ~681–699 — `schemaVersion`, `viewport`, `zones` with one project zone,
   `zoneZOrder`, `lastActiveZoneId`) **and has NO `groupZoneTiles` key**. **Decode it with
   `JSONCodec.makeDecoder()`** — the SAME decoder `AtomicWriter.read` uses (do NOT use a bare
   `JSONDecoder()`; `JSONCodec.makeDecoder()` is iso8601-dated and *not* snake-case, so keys
   are 1:1 camelCase — matching the on-disk shape). Assert it decodes without error,
   `decoded.groupZoneTiles == []`, and `decoded.tiles(forZone: <its zone>) == []`. (This is
   the behavioral RED: until `decodeIfPresent ?? []` is wired, this decode throws
   `keyNotFound`.) Use a JSON literal, not a re-encoded document, so it genuinely proves an
   older doc loads. **Stronger preferred form (use if cheap):** `try Data(literal.utf8).write(to:
   store.layout.canvasFile)` then `try store.load()` — this proves the literal survives the
   *full* `AtomicWriter` read path (incl. `validateSchema`, which passes because the literal's
   `schemaVersion` is `2` == `currentSchemaVersion` after T01), not just an isolated decode.
6. **`setTiles` empty removes the entry:** starting from `document`, call
   `setTiles([], forZone: gz)`; assert `groupZoneTiles` no longer contains `gz`
   (`tiles(forZone: gz) == []`) — proves the "empty == absent, keep docs lean" rule, so an
   emptied group zone doesn't persist a dangling empty record.
7. **`setTiles` upsert replaces, doesn't duplicate:** on a doc that already has `gz`,
   `setTiles([t1], forZone: gz)`; assert `groupZoneTiles.filter { $0.zoneId == gz }.count == 1`
   and `tiles(forZone: gz) == [t1]` (proves upsert updates in place, no duplicate zone rows).
8. **Multiple group zones coexist:** add a second group zone `gz2` with one tile `t3`;
   save+load; assert `loaded.tiles(forZone: gz) == [t1, t2]` AND
   `loaded.tiles(forZone: gz2) == [t3]` (proves per-zone keying, no cross-talk).

Run `swift run ContinuumRevivedCoreChecks` → **RED**: it fails to compile until
`groupZoneTiles` / `GroupZoneTiles` / `tiles(forZone:)` / `setTiles(_:forZone:)` exist
(compile RED acceptable for a pure-model field, per T01's precedent), and once they compile
as stubs the *behavioral* RED is assertion 5 (the no-field v2 literal throws `keyNotFound`
until `decodeIfPresent ?? []` is implemented). Implement to GREEN.

## Implementation steps
1. Write the Core table above (all 8 assertions) → `swift run ContinuumRevivedCoreChecks`
   → confirm **RED** (compile-missing-member, then assertion 5 once stubbed).
2. Add `GroupZoneTiles` and the `groupZoneTiles` stored field + defaulted init param to
   `WorkspaceDocument`. **RED→GREEN boundary is here**: at this point the synthesized
   `Codable` would *require* the key.
3. Add the explicit `Codable` (or `init(from:)`/`encode(to:)`) doing
   `decodeIfPresent(...) ?? []` for `groupZoneTiles`, everything else as before — assertion
   5 (no-field v2 literal) flips to GREEN.
4. Add `tiles(forZone:)` and `setTiles(_:forZone:)` with the empty-removes / upsert rules.
5. `swift build` → fix any `WorkspaceDocument(` construction-site fallout. The new param is
   **defaulted**, so existing call sites compile unchanged — confirm, don't edit them. The
   actual memberwise-`init` construction sites (verified by grep `WorkspaceDocument(`) are:
   `Sources/ContinuumRevivedCore/DefaultWorkspaceMigration.swift` (1),
   `Sources/ContinuumRevived/App/ZoneRuntimeController.swift` (1),
   `Sources/ContinuumRevived/App/ContinuumApp.swift` (6). `WorkspaceDocumentSaveController`
   *references the type* but does **not** call the memberwise init, so it has no fallout —
   do not edit it.
6. `swift run ContinuumRevivedCoreChecks` → GREEN → `./scripts/run-matrix.sh --fast`.

## Acceptance criteria
- [ ] `WorkspaceDocument.groupZoneTiles: [GroupZoneTiles]` exists; `GroupZoneTiles` reuses
      the existing `Tile` model (no new tile fields, no `tile.zoneId`).
- [ ] Group-zone tiles round-trip through `WorkspaceStore.save`/`.load` (real disk path),
      equal and order-preserved, with zone-local frames intact.
- [ ] A project zone has **no** `groupZoneTiles` entry; no `ProjectStore` canvas is written
      by the workspace save (isolation assertion green).
- [ ] A v2 workspace doc with **no** `groupZoneTiles` key decodes to `[]` (backward compat).
- [ ] `setTiles` upserts (no duplicate zone rows) and an empty list removes the entry.
- [ ] No `ProjectStore`/`CanvasState`/`Tile`/runtime/AppKit files touched; no
      `SettingsSchema` change (no new binding introduced — T08 owns the group defaults).
- [ ] Fast matrix green; commit `feat(zones): group-zone tile storage in the workspace store`.

## Verification commands
```
swift build
swift run ContinuumRevivedCoreChecks
# (CoreChecks is a self-contained binary; it reads no env. The temp dir is created
#  inside the check via FileManager.default.temporaryDirectory and removed on defer,
#  matching the existing WorkspaceStore block.)
./scripts/run-matrix.sh --fast
```
(No single app-check invocation: T02 is a pure Core table inside `ContinuumRevivedCoreChecks`,
not a `--…-check` app flag, so there is no `CONTINUUM_PROJECT_ROOT`/`CONTINUUM_APP_SUPPORT`
seam to set — the store check makes its own temp scratch dir like the existing one.)

## Review rubric
- **Real path, not a bypass:** assertions 1–4 and 8 must go through
  `WorkspaceStore.save` → on-disk file → `WorkspaceStore.load` (AtomicWriter encode/decode),
  NOT `JSONCodec` directly on an in-memory value. A check that only encodes/decodes the
  struct in memory and never writes the store file proves nothing about the persistence
  path — REWORK. (Assertion 5's hand-written literal decode is the one legitimate
  in-memory decode, because its job is proving an *older on-disk shape* loads.)
- **Isolation is actually asserted, not assumed:** assertion 4 must positively verify no
  `.continuum-revived/canvas.json` exists under scratch — confirm the reviewer can see the
  recursive scan, not just "we didn't construct a ProjectStore." Would it still pass if
  group tiles were accidentally also written into a project canvas? It must FAIL then.
- **Backward compat uses a hand-written literal** (assertion 5), not a re-encoded v2 doc —
  otherwise it can't prove a pre-T02 doc loads. Confirm the literal has NO `groupZoneTiles`
  key and that reverting the `decodeIfPresent ?? []` line turns assertion 5 RED.
- **Equatable includes the new field:** assertion 1 (`loaded == document`) would silently
  pass even if `groupZoneTiles` were dropped on decode *if* the field were excluded from
  `Equatable`. Assertion 2 (`tiles(forZone:) == [t1, t2]`) is the backstop — confirm it
  reads the reloaded doc, not the original. Re-derive `t1.frame.x == 40` by hand.
- **No project-tile migration / no `tile.zoneId`:** grep the diff — `CanvasState`, `Tile`,
  `ProjectStore` untouched; `appendProjectZone` untouched. Any edit there is out of scope.
- **Schema version not bumped again** (T01 already set it to 2); the new field is
  decode-optional, so v2-without-field still loads. Confirm no second bump.
- **`setTiles` empty-removes + upsert** (assertions 6, 7) — confirm a re-derivation that the
  zone row count is exactly 1 after upsert and 0 after empty.

## Out of scope / gotchas
- **NEEDS-HUMAN / dependency:** this task assumes **T01 has landed** — `ZonePlacement` must
  already accept `projectId: nil` so a group zone is representable, and
  `WorkspaceDocument.currentSchemaVersion` must already be `2`. If T01 is not yet Done when
  an agent picks this up, **stop and flag** (T02 cannot construct a `projectId: nil` group
  zone or assert v2 backward-compat against the right baseline). The brief gave the design
  latitude ("WorkspaceDocument gains group-zone tile records keyed by zoneId, **or**
  ZonePlacement carries a tile list"); this spec chose the `WorkspaceDocument.groupZoneTiles`
  record array because it (a) keeps `ZonePlacement` a pure placement (its `Equatable` is
  used in render/hit-test paths and a tile list there is noise), (b) round-trips cleanly,
  and (c) gives T12 (autosave) and T15 (sidebar tree) one document-level seam. If a reviewer
  prefers tiles-on-`ZonePlacement`, that is a design call — flag it; do not silently switch.
- **The group zone's default size + ambient cwd are NOT decided here.** They are T08's
  (`addZone` spins the ambient controller). Do not invent a `groupZoneDefaultSize` setting
  in T02 — that would be speculative config this task doesn't use.
- **Zone-local frames:** group tiles store frames relative to the zone origin, exactly like
  project tiles, converted at render by `CanvasEngine.worldFrame(tile:in:)`. Do not store
  world-absolute frames — the union-bounds (T11) and hit-test (T05, which already uses
  `tilesByZone: [UUID: [Tile]]`) math assume zone-local.
- **`[UUID: [Tile]]` dictionary trap:** if a future agent "simplifies" the record array to a
  `[UUID: [Tile]]` dictionary, the JSON shape changes to an unkeyed flat array and the
  hand-written backward-compat fixture breaks; keep the stored shape a record array (derive
  a dict in memory if O(1) lookup is ever needed).
- **Stale SourceKit diagnostics** ("Cannot find `GroupZoneTiles` in scope") are noise until
  `swift build`; the build is authoritative.
