# 20 — Deterministic spatial letters in Nav Mode

Status: **product direction captured — implementation not started**

## Outcome

Keep the existing Nav Mode. Do not introduce additional modes or competing
navigation systems.

Make its displayed tile letters spatially predictable:

- the key associated with left stays left as selection moves;
- the key associated with right stays right;
- up and down behave the same way;
- users can choose a familiar letter pattern such as **WASD** or **HJKL**;
- users can still customize the letters;
- the overlay always shows the actual key assigned to each tile.

The user should not need to learn Array's current reading-order assignment rule.

## Reported failure

A user moves left across two tiles with `A`, but the next tile to the left is
labeled `D`.

That is deterministic to the implementation but not intuitive to the user. The
next label is currently influenced by global tile ordering rather than by where
the target sits relative to the selected tile.

## Current cause

`TileArrangement.jumpLabels` sorts visible tiles top-to-bottom and then
left-to-right, then zips them with `asdfghjkl`.

When selection changes, the current tile may be excluded and the visible target
list changes. Labels are reassigned from the start of the alphabet. Consequently,
a letter has no stable directional meaning and can move to a different side of
the selection after every jump.

## Product contract

### One Nav Mode

This changes only how Nav Mode chooses and presents letters. It does not add a
new mode, a separate directional navigator, or another activation gesture.

### Direction-aware assignment

Treat the selected tile as the origin. Classify visible target tiles by their
position relative to it, then assign letters using the selected pattern.

For the **WASD** pattern:

- `A` selects the best tile to the left;
- `D` selects the best tile to the right;
- `W` selects the best tile above;
- `S` selects the best tile below.

For the **HJKL** pattern:

- `H` selects left;
- `L` selects right;
- `K` selects above;
- `J` selects below.

After selecting a tile, Nav Mode recomputes from that new origin. Pressing `A`
again therefore continues left; it does not suddenly mean a target on another
side.

Use the existing spatial-neighbor geometry for choosing the best target in each
direction. Tile creation order, array order, title, and reading-order position
must not determine directional meaning.

### More than four visible targets

The four directional letters go to the nearest/best target in each available
direction first.

Any remaining configured letters may label additional targets, but they must be
assigned deterministically within directional groups—nearest outward first—and
must never take over the four primary directional meanings.

A simple first version may leave overflow targets unlabeled rather than assign a
misleading letter.

### Presets, not modes

Settings offers a **Nav Letters** choice:

- WASD;
- HJKL;
- Custom.

This is only a preset for letter assignment. It does not change what Nav Mode is
or create different behaviors to learn.

Choosing WASD or HJKL fills the existing configuration atomically. Editing the
letters makes the choice Custom. Existing custom configuration remains valid and
is not overwritten.

The UI should show the directional relationship directly rather than exposing a
raw alphabet string such as `asdfghjkl` without explanation.

## Deterministic assignment policy

1. Capture the selected tile and all visible tile frames in world coordinates.
2. For each target, calculate center delta from the selected tile.
3. Classify it by dominant direction: left, right, up, or down.
4. Rank each directional group using the existing spatial-neighbor score:
   primary distance, then orthogonal distance, then stable ID.
5. Assign the pattern's primary key to the first target in each group.
6. Assign any extra custom letters to remaining targets by stable directional
   group and distance order.
7. Draw and dispatch from the same assignment snapshot.

Pan and zoom must not change the geometric answer for the same visible tiles.

## RED witnesses first

1. Reproduce the report: moving left once causes the next left target to stop
   using the left-associated letter under the current reading-order algorithm.
2. WASD: repeated `A` walks through successive leftward tiles.
3. WASD: `W`, `S`, and `D` consistently select up, down, and right.
4. HJKL: repeated `H` walks left and `L` walks right.
5. Missing direction: if there is no tile to the left, the left key is not drawn
   on an unrelated tile.
6. Geometry beats model order: shuffling tile storage does not change labels.
7. Pan/zoom invariance for the same visible target set.
8. Unequal and diagonal tiles use a stable dominant-direction rule.
9. Drawing and key dispatch use the exact same assignment.
10. Existing custom settings resolve without data loss.
11. Choosing a preset writes all relevant letters together.
12. Editing a preset switches its displayed setting to Custom.

## Likely files

- `Sources/ContinuumRevivedCore/TileArrangement.swift`
- `Sources/ContinuumRevivedCore/NavKeymap.swift`
- `Sources/ContinuumRevivedCore/SettingsSchema.swift`
- `Sources/ContinuumRevived/App/SettingsPanel.swift`
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- existing Nav Mode and Core checks

## Acceptance criteria

- There remains one Nav Mode.
- Under WASD, `A` always means the best available tile to the left, and repeated
  `A` continues left.
- Under HJKL, `H/J/K/L` retain their familiar spatial meanings.
- No primary directional letter appears on a tile in another direction.
- Assignment is based on tile geometry, not reading order.
- WASD and HJKL are one-click presets; Custom remains editable.
- Existing custom configuration is preserved.
- Overlay labels and actual key behavior cannot disagree.

## Out of scope

- adding or removing navigation modes;
- changing the Nav Mode activation gesture;
- redesigning tile placement or canvas layout;
- changing docking or tile-moving shortcuts;
- general multi-tile selection.
