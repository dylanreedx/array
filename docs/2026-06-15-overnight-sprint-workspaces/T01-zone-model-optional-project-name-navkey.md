# T01 — Zone model: optional `projectId` + `name` + `navKey`

Status: todo
Tag: overnight [pure]
Depends on: — · Blocks: T02, T05, T08, T11, T15, T17, T18

## Goal
Make a zone an *unopinionated container* whose project is optional, and give zones a name
and a per-zone nav key. This is the data-model foundation the whole sprint stands on:
group zones (no project) become representable, and zones become nameable/keybindable.

## Exact scope — files & symbols
- **`Sources/ContinuumRevivedCore/WorkspaceDocument.swift`** — `ZonePlacement` struct +
  `WorkspaceDocument` schema version + its `Codable`. (Read the current file first to get
  the exact field set; the Explore baseline: `ZonePlacement { zoneId: UUID, projectId:
  UUID, origin: ZonePoint, size: ZoneSize, color: String, collapsed: Bool,
  hydrationPolicy: ZoneHydrationPolicy }`, `WorkspaceDocument.schemaVersion == 1`.)
- **`Sources/ContinuumRevivedCore/WorkspaceDocument.swift`** — `appendProjectZone(...)`
  (it constructs `ZonePlacement`s; update call sites for the new fields with sensible
  defaults).
- **Do NOT touch:** `ZoneRuntimeController`, `CanvasNSView`, runtime/registry, any AppKit.
  Do NOT add a global `tile.zoneId` (membership is project-canvas / group-list — see
  charter §1). Do NOT migrate tile storage (that's T02).

## Data / API changes
On `ZonePlacement`:
- `projectId: UUID` → **`projectId: UUID?`** (nil = group zone).
- add **`name: String`** (zone display name; "" when unset — a higher layer backfills a
  project zone's name from the registry at load, NOT here).
- add **`navKey: String?`** (single-char leader jump key; nil = auto ordinal).
- keep `zoneId`, `origin`, `size`, `color`, `collapsed`, `hydrationPolicy` unchanged.

`Codable`: bump `WorkspaceDocument.schemaVersion` 1 → 2. Decode must be **backward
compatible** with v1 docs:
- `projectId`: `decodeIfPresent(UUID.self)` — present in v1 (stays a project zone),
  absent/null = group zone.
- `name`: `decodeIfPresent(String.self) ?? ""`.
- `navKey`: `decodeIfPresent(String.self)` (→ nil when absent).
Encode always writes all fields at schema 2.

## The check, written FIRST (spec-as-test)
Add a Core table to **`Sources/ContinuumRevivedCoreChecks/main.swift`** (or the existing
`WorkspaceDocument` Core check target if one exists — grep `WorkspaceDocument` in the
checks targets; reuse it). Assertions:
1. **Round-trip v2 — project zone:** encode a `ZonePlacement` with `projectId` set,
   `name: "API"`, `navKey: "a"`, decode → equal to the original.
2. **Round-trip v2 — group zone:** `projectId: nil`, `name: "Scratch"`, `navKey: nil`,
   decode → equal; assert `decoded.projectId == nil`.
3. **v1 → v2 migration:** decode a hand-written **v1-shaped JSON string** (a zone object
   with `projectId` present, NO `name`, NO `navKey`, document `schemaVersion: 1`) →
   `projectId` set, `name == ""`, `navKey == nil`. (Proves old workspace docs still load.)
4. **Mixed document:** a `WorkspaceDocument` with one project zone + one group zone
   round-trips with both zones intact and the group zone's `projectId == nil`.

This check fails to compile until the fields exist (RED is the missing-member error here;
acceptable for a pure model task — the *behavioral* RED is assertion 3, which fails until
the decoder handles missing fields). Implement to GREEN.

## Implementation steps
1. Write the Core table above; `swift run ContinuumRevivedCoreChecks` → RED.
2. Change `ZonePlacement.projectId` to optional; add `name`, `navKey`; update the
   memberwise init + every construction site (esp. `appendProjectZone` → pass the
   project zone's `projectId`, `name: ""`, `navKey: nil`).
3. Implement the custom `Codable` (or `decodeIfPresent` defaults) for backward compat;
   bump `schemaVersion` to 2.
4. `swift build`; fix the construction-site fallout (group zones come in T02/T08 — here
   just keep existing project-zone call sites compiling with the new defaults).
5. Core checks GREEN → `./scripts/run-matrix.sh --fast`.

## Acceptance criteria
- [ ] `ZonePlacement.projectId` is `UUID?`; `name: String` + `navKey: String?` added.
- [ ] v1 workspace docs decode without error (migration assertion green).
- [ ] Round-trips for project zone, group zone, mixed doc all green.
- [ ] No AppKit / runtime files touched; no global `tile.zoneId` introduced.
- [ ] Fast matrix green; commit `feat(zones): zone model — optional project + name + navKey`.

## Verification commands
```
swift build
swift run ContinuumRevivedCoreChecks
./scripts/run-matrix.sh --fast
```

## Review rubric
- The migration assertion uses a **hand-written v1 JSON literal** (not a re-encoded v2
  doc) — otherwise it doesn't actually prove backward compat. REWORK if it round-trips v2.
- `projectId == nil` is asserted for a group zone (not just "decodes") — proves optional
  works, not just compiles.
- Grep for other `ZonePlacement(` construction sites + any exhaustive switch on its
  fields the compiler forced — all updated, none stubbed with wrong defaults.
- No persisted workspace doc on disk is silently invalidated (v1 still loads).

## Out of scope / gotchas
- Group-zone *tile storage* = T02. Backfilling a project zone's `name` from the registry
  at load = the runtime task (T06), not here. Per-zone keybind *behavior* = T18. Sidebar
  consumption = T15. This task is the model + its Codable only.
