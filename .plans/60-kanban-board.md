# 60 — KB-01: the editable kanban tile

Branch `array/kb01-board`, worktree `~/array-worktrees/kb01-board`, based on
`98e56e11` (Array 0.7.15 build 66). Investigation report and ticket: KB-01 in
`.plans/59-parallel-product-investigations/`.

This file is the running record for the board tile: what is built, why it is
shaped this way, what is witnessed, and what is still open. It is updated as
each slice lands.

---

## The one-sentence version

A board is a per-project **document** — columns and cards with deterministic
fractional ordering — mutated only through `BoardEngine`, persisted to
`<project root>/.array/boards/`, rendered by a tile that carries nothing but a
`boardId`. Card order is board data. It is never canvas geometry.

---

## Status

| Slice | What | State |
|---|---|---|
| KB-01.1 | Board model (`KanbanBoard.swift`) | **landed** |
| KB-01.2 | `ProjectStore` persistence + schema guard | **landed** |
| KB-01.3 | `BoardEngine` reducer, commands, inverses, rebase | **landed** |
| KB-01.4 | `BoardDragResolver` — the jelly, pure | **landed** |
| KB-01.5 | Witnesses B1–B9 (`--board-model-check`) | **landed, teeth-verified** |
| KB-01.6 | Tile view: render, select, edit, keyboard moves | **landed** |
| KB-01.7 | `TileKind` integration: spawn, hydration, cleanup, palette | **landed** |
| KB-01.8 | `BoardRuntime` + `BoardHistoryController` + undo rung | **landed** |
| KB-01.9 | Drag controller: lift, displacement, autoscroll, settle, cancel | **landed, not yet driven on screen** |
| KB-01.10 | B10 lifecycle witness (`--board-tile-lifecycle-check`) | **landed, teeth-verified** |
| KB-01.11 | `board.large-drag` perf scenario + matrix registration | not started |
| KB-01.12 | CX-01 surface: snapshot DTO, command service, typed links | not started |

A board is now reachable: `⌘K → New Board` spawns one, it persists, and it comes
back on relaunch. The drag is implemented and compiles but **has not been driven
on screen** — no build has been launched, so nothing about the feel is verified.

`.plans/59/coordination.md` reserves `TileKind` switches, palette, spawn and
hydration for a single integration owner. Those are now touched, so this branch
holds that lane.

---

## Decisions, and what each one refuses

### 1. Board data lives beside the canvas, never inside it

`<project root>/.array/boards/index.json` + `<boardId>.json`, written through
the existing `AtomicWriter` with a `schemaVersion` guard, exactly mirroring
notes. The tile carries only `TileMetadata.boardId`.

Three concrete failures this avoids — the reason it is not "just a field on the
tile":

1. `canvas.json` is rewritten under the cover-then-replace merge
   (`CanvasPersistenceMerge`). A card move landing there races geometry saves
   and can be erased by a zone below the live hydration tier.
2. `canvas.json` holds **WORLD frames**, converted at the `ZoneLayer` boundary.
   Board data has no frame and must never enter that conversion.
3. Undo. `CanvasHistoryController` replays `CanvasGeometryTransaction`s and
   **wipes its whole stack** when the live geometry does not match the recorded
   snapshot. One card move must be one *board* undo.

Witnessed by **B9**, which hashes `canvas.json`, moves a card, and re-hashes.

### 2. Order is `(position, id)` over `FracIndex`

`FracIndex` already exists in Core (`SpatialOp.swift`) with a frozen `Codable`
form and documented exhaustion semantics. Reusing it buys O(1) inserts with no
renumber pass, and — the part that matters for the canvas API — lets a move be
expressed as *"between card A and card B"* rather than as an index.

An index cannot be repaired when the board moved underneath a caller; it just
silently means something else. Anchors can: the engine re-derives a position
against whatever the anchors are adjacent to *now* and reports
`rebasedAnchors`. Witnessed by **B4**.

Double precision runs out after ~50 successive inserts into one gap. The engine
redistributes the column evenly (order-preserving, invisible) and retries once,
rather than trapping or silently producing a tie. Witnessed by **B2** at 200
inserts; without the retry it fails at insert 51.

### 3. Membership is a register on the card, not an array on the column

`BoardCard.columnId`, mirroring `Op.setTileZone`'s treatment of tile membership.
This is what lets a pointer move and an agent move commute instead of
conflicting at the list level.

### 4. One write path

Pointer drags, keyboard moves, the palette and the canvas API all build a
`BoardCommand` and hand it to `BoardEngine.apply`. There is deliberately no
second path, so "UI and agent-originated moves use the same validation and
persistence" is a property of the types rather than a convention.

`apply` is pure: no I/O, no AppKit, and `now` is injected so witnesses are
byte-identical on every run.

---

## The jelly, and one thing it got wrong first

The canvas already solved this shape for tiles, and the board reuses the
**principle** — never the geometry solver as board-data authority:

| Layer | Truth of | Canvas precedent |
|---|---|---|
| free | the pointer, raw and un-smoothed | `TileNSView.mouseDragged`'s `moveFreeWorldFrame` |
| preview | intent, recomputed every event with hysteresis | `MagneticPlacement.resolve` |
| model | the board, untouched until mouse-up | `mouseUp` commits exactly the previewed frame |

Recomputing the preview from scratch each event — rather than latching slots at
mouse-down — is what makes displacement genuinely interruptible: a card the
canvas API moves mid-drag is absorbed on the very next pointer event.

### The correction worth recording

The first implementation copied `MagneticPlacement`'s acquire/release **radii**
(44/64 screen points, scaled to 18/28 for card scale). Teeth-verification killed
it: collapsing the two radii to one changed nothing, and every hysteresis
assertion still passed.

The reason is arithmetic. A radius around the held slot's centre only has an
effect while it exceeds **half the slot spacing**. For ordinary 80pt cards the
nearest slot and the held slot cannot disagree until 40pt, which is beyond any
plausible release radius — so the resolver silently degenerated to nearest-slot
and would have flickered at the midpoint. That is precisely the feel the file
exists to prevent, and a centre-based witness is structurally blind to it.

Hysteresis is now a **margin past the boundary** between the held slot and its
challenger, which bites at every spacing:

| Constant | Value | Role |
|---|---|---|
| `boundaryMarginScreenPoints` | 10 | how far past the midpoint before the preview retargets |
| `acquireScreenPoints` | 18 | early commit: a slot this close wins without serving the margin |
| `columnReleaseFraction` | 0.15 | how far past a held column's edge before leaving it |
| `displacementDuration` | 0.16 s | neighbour displacement, origin-only |
| `settleDuration` | 0.11 s | verbatim `CanvasNSView.animateSnapLanding` |

All distances are screen points ÷ canvas zoom, so the feel is constant at any
zoom — the same reasoning as `DragMagnetizeConfig`.

**The two bands interact at low zoom, and that is correct.** At zoom 0.5 a card
is visually compact, so the acquire override fires before the widened margin
does. B6 therefore isolates the margin on a tall fixture, and says why in a
comment, rather than asserting something false about the 80pt one.

---

## Witnesses

`.build/debug/ContinuumRevivedCoreChecks --board-model-check` (also runs inside
the full `ContinuumRevivedCoreChecks` sweep).

| ID | Asserts |
|---|---|
| B1 | append order; a move lands exactly between its anchors; strictly increasing positions; replay determinism; equal positions tie by id; one command bumps the revision once |
| B2 | 200 inserts into one gap preserve exact order and strict ordering |
| B3 | every command's inverse restores the prior board exactly, for nine command shapes |
| B4 | non-adjacent anchors rebase and say so; a deleted anchor is rejected, not guessed |
| B5 | unknown column/card, non-empty column deletion with nowhere to go, self-reassignment, last-column deletion; reassignment preserves relative order |
| B6 | the boundary margin holds through jitter across the raw midpoint; retargets past it; the new slot is sticky in both directions; the acquire override on compact cards; margin scales with zoom |
| B7 | a drag commits **exactly** the previewed anchors; a cancelled drag leaves the board and its revision untouched; one accepted drag is one revision |
| B8 | column leave-hysteresis; exactly one retarget per crossing; an empty column is a reachable drop target |
| B9 | round trip through a fresh store; **a card move does not modify `canvas.json`**; the file lives at `.array/boards/<id>.json`; a future schema is refused with `unknownFutureSchema`; delete is idempotent |

### B10 — the lifecycle witness

`.build/debug/Array --board-tile-lifecycle-check`. Drives
`mountWorkspaceSceneAtBoot` (never `install(into:)`), across three launches that
each read from disk.

Two zones for one project, at deliberately different non-zero origins: the armed
zone is A, the creation scope points at B. With a single zone the armed zone and
the scope are necessarily the same placement, and the whole spawn assertion is
vacuous.

It asserts: the spawned tile lands inside zone B's world rect **and** at the
camera centre; the relaunch hydrates through `makeHydratedTileView` exactly once
and through the boot walk zero times; the cards survive; a card move leaves
`canvas.json` byte-identical; an API move of the card under the pointer is
rejected while an unrelated edit still applies; and closing the tile leaves the
board FILE on disk with its index entry's tile pointer cleared.

### Teeth verification

Each mutation was applied to the source, the suite run, the source restored.
A check that cannot fail is not a witness.

| Mutation | Result |
|---|---|
| `boundaryMarginScreenPoints` → 0 | **B6 red** |
| remove the renormalize-and-retry path | **B2 red** at insert 51 |
| `columnReleaseFraction` → 0 | **B8 red** |
| `moveCard` ignores its anchors | **B1 red** |
| `saveBoard` also rewrites `canvas.json` | **B9 red**, **B10 red** |
| spawn frames against the armed zone, not the scope's | **B10 red** |
| closing the tile deletes the board file | **B10 red** |
| `BoardRuntime.board(id:)` loses its disk load | **B10 red** |
| the boot walk hydrates instead of Phase A | **B10 red** |

### Four witness defects this found — in the checks, not the code

Worth recording, because each one passed while guarding nothing:

1. **The hysteresis was decorative.** Collapsing the two radii changed no
   assertion. A radius around the held slot's centre is inert whenever it is
   smaller than half the slot spacing, which at ordinary card sizes it always is.
   Fixed by moving to a boundary margin — this changed the *product*, not just
   the test.
2. **"Inside the zone rect" was too weak.** When the frame is computed against
   the wrong zone, `clampedZoneLocalViewport` parks it at the target zone's
   top-left CORNER — still inside the rect. The assertion now also requires the
   tile to land at the camera centre, which is what centre-aware placement
   promises.
3. **The survival assertion read a cache, then a backup.** Asking
   `BoardRuntime.board(id:)` returns the in-memory copy; asking
   `tryLoadBoard` lets `AtomicWriter` restore from a backup. Both stayed green
   through an outright `deleteBoard`. It now asserts the FILE exists.
4. **The summary named a path it never checked.** It claimed
   `makeHydratedTileView` while the boot walk would have satisfied every
   assertion equally. Two QA counters now make the claim falsifiable.

A fifth, procedural: piping `swift build` through `head` truncates the pipe and
can leave a **stale binary**, so three teeth "passed" against code that was never
rebuilt. Build to a file, check the exit code, then run.

---

## Verification actually run

- `--board-model-check` — B1-B9 green.
- `--board-tile-lifecycle-check` — B10 green, five teeth confirmed.
- Full `ContinuumRevivedCoreChecks` in an isolated `TMUX_TMPDIR` namespace: the
  board section is green. The sweep exits non-zero on a **real-tmux** leg that
  is unrelated to this work and varies run to run in this sandboxed shell
  (`KindClassifier ... got unknown` on one run, `I2: the production grouped-view
  profile did not create array-view-…` on another). This branch touches no tmux,
  Substrates or KindClassifier source. `AgentKind.from` matches only the bare
  basename `zsh` while the assertion above it also accepts a `/zsh`-suffixed
  path, so a tmux that reports a full path fails the second assertion and not
  the first — pre-existing, and not chased here.
- **Not run:** `scripts/run-matrix.sh`, the app bundle check, and any UI or
  perf leg. Nothing has been launched, so **no claim is made about how the drag
  feels**.

## Still open

Product questions carried forward from the KB-01 report, unchanged and still
needing Dylan:

1. One board per project, or many with a picker?
2. Fixed workflow columns, or user-defined from day one?
3. Closing a board tile — delete the board, or retain it as a document?
   (Current code retains: `BoardIndexEntry.tileId` is optional and the index
   entry survives. Consistent with "closing a tile is closing a window".)
4. Can a card become an agent? Deliberately out of the MVP — it couples KB-01
   to `AgentSupervisor`, a shared choke point.
5. Card body in the MVP, or title only?
6. WIP limits — enforced, advisory, or absent? Modelled as optional
   (`BoardColumn.wipLimit`), behaviour undecided.
7. Is a card's body a note (reusing `.array/notes/*.md`) or its own text?
8. Board belongs to the project or the workspace? Currently project, matching
   notes — and therefore subject to hazard 10 (two installs on one root).

## Hazards to honour in the remaining slices

- **Grab strip.** `TileNSView.hitTest` claims the whole post-resize grab strip
  before `super.hitTest`, and it is visually enlarged at low zoom. Cards must be
  inset below `grabHeightInLocalCoordinates` or a card drag becomes a tile move.
  Assert this at low zoom, not only at 1.0.
- **`surfaceScrollOffsets`.** A scrolling tile that does not declare its scroll
  owners bakes a surface at a stale offset. `surfaceContentRevision` must track
  `Board.revision`.
- **Spawn.** One `targetZoneId` for all four of `makeProjectTilePlacement`, the
  sibling set, `zPositionAbove` and `installProjectTile` — the `.plans/47`
  contract. Assert the tile's **world frame** against the zone's world rect, not
  the zone stamp; a stamp assertion stays green through exactly this bug.
- **Hydration.** Phase A (`makeHydratedTileView`) — a board is fully
  constructible from the persisted `Tile` plus its board file. Do **not** copy
  the boot-only `installInitial*` walk, which mints ids and writes the canvas as
  a side effect.
- **`TileMetadata` has a hand-written `encode(to:)`.** Adding `boardId` means
  touching the initializer, `CodingKeys` and the encode body — and auditing
  every site that reconstructs `TileMetadata` field-by-field
  (`TileSpawner.installNoteTile` is one), because those silently drop new fields.
- **Undo routing.** `CanvasNSView.undo(_:)`/`redo(_:)`/`validateMenuItem` need a
  third rung between `focusedTextUndoManager` and `activeCanvasUndoManager`.
  Text editing inside a card must still win.
- **`run-matrix.sh`.** Two program checks pin its lines verbatim with
  `grep -Fxc`, and the inventory reads a wrapper rename as deleted checks.

---

## Seeing it

An isolated debug bundle is assembled at `/tmp/kb01-preview/Array Dev.app`
(`dev.arrayapp.macos.dev`, "Array Dev"), with an empty scratch root at
`~/kb01-scratch`. It was built with `scripts/make-app-bundle.sh`, **not**
`scripts/dev-app.sh` — that script quits the shared preview app before it
builds, which is not safe while other lanes are using it.

```sh
open --env CONTINUUM_PROJECT_ROOT="$HOME/kb01-scratch" "/tmp/kb01-preview/Array Dev.app"
```

Then `⌘K → New Board`.

**Not launched from here, on purpose.** `.plans/59/findings.md` records that
bundle-path and Application-Support isolation do NOT isolate the shared DEV
preference domain: two Dev-channel copies running at once are one GUI lane, not
two. Quit `~/Desktop/Array Dev.app` first, or accept that they share defaults.
The scratch root is outside `~/Documents`, `~/Desktop` and `~/Downloads` so the
explicit folder-grant modal does not appear on every launch.

## What to look at first, and what is honestly unknown

The drag compiles and its pure resolver is witnessed, but **no build has been
driven on screen**, so every statement about feel below is a design intention,
not an observation:

1. Nested scrolling. A column's `NSScrollView` inside a zoomed, layer-backed
   world plane is the least-proven part of this. `CanvasNSView.scrollWheel`
   was read, not exercised.
2. A card drag starting just below the title bar at LOW zoom. The inset is
   recomputed from `grabHeightInLocalCoordinates` every layout, but the
   enlarged low-zoom strip has not been measured.
3. Whether the tile keeps first responder well enough for `⌘Z` to reach the
   board stack (`focusedBoardUndoManager` resolves through
   `TileNSView.enclosingTileId`).
4. Whether a residency demote mid-drag pins the tile native. `surfaceScrollOffsets`
   and `surfaceContentRevision` are declared; the interaction with a live drag
   is unverified.
