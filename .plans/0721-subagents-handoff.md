# Subagent grouping in the sidebar — 0721

Branch `array/0721-subagents`, bench `.worktrees/0721-subagents`, based on
`array/integration` at `2cec73ff`.

> "the expanding of subagents for a main agent looks weird, makes the next
> subsequent agent under the other look like a sub agent in itself — we need to
> greatly enhance how subagents look in the sidebar"

## What was actually wrong

Nesting was drawn by exactly ONE thing: `AgentInbox96CellView.layout()` shifted
the card right by `depth * 16`. Nothing else said anything about the tree.

- A resting row paints no perimeter at all (ticket P1.1, deliberate), there are
  no separators and no indent guides, so an expanded group was an unbroken
  column of identical unfilled cards.
- The gap between two rows is the same 2pt whether they are parent and child or
  two unrelated roots, so a group had no visible END. The first depth-0 row
  after a nested child read as one more member of the group above it — the
  reported defect, verbatim.
- The disclosure triangle was laid out at `textLeft` INSIDE the already-indented
  card, so a parent's control ended **2.0 pt** from where its own child's title
  begins. (That number is measured — it is the RED from mutation M5 below.)
- `AgentInboxRemainderView` ("3 more") pinned its label to `Inset.row.left` with
  no indent at all, so the hidden children of a NESTED parent advertised
  themselves at the list's leading edge.

## The design

A tree connector in the indent gutters, a triangle that is the head of its own
lane, and a group that ends in space as well as in ink. No new visual
vocabulary: one exempt hairline, one existing spacing token, one existing
indent step.

```
x:  4    12   20   28   36        (4 = outer gutter, lanes centred at 4+16k+8)
    |    |    |    |    |
   ┌─────────────────────────────────────────┐
   │ ▾  orchestrator                         │   depth 0, expanded
   └─│───────────────────────────────────────┘     ▾ centred on its own lane
     │                                              descender starts below it
     ├──┌──────────────────────────────────────┐
     │  │ ▾  worker a                          │   depth 1  (elbow, 8pt)
     │  └──│───────────────────────────────────┘
     │     └──┌───────────────────────────────┐
     │        │    worker a1                  │   depth 2
     │        └───────────────────────────────┘
     │                                             (lane at level 0 continues:
     └──┌──────────────────────────────────────┐    another child follows)
        │    worker b                          │   depth 1, LAST of the group
        └──────────────────────────────────────┘   → half lane + elbow, then
                                                     Space.s of room
   ┌─────────────────────────────────────────┐
   │    unrelated root                       │   depth 0 — no ink, no gap:
   └─────────────────────────────────────────┘   unmistakably outside
```

Four changes:

1. **The connector.** `InboxSpineView` (one view per row, `NSBezierPath` in
   `draw`) paints, for each row: the lanes of the ancestor groups that are still
   open below it, a short **elbow** turning out of its own parent's lane into its
   own card, and — if it is an expanded parent — a **descender** from just under
   its triangle to the bottom of the row. A lane stops at the last member of its
   group: that is what makes the extent readable.
2. **The triangle moved into the lane.** It is now centred on `spineX(depth)`,
   i.e. on its own descender, instead of sitting in the card's text column.
   Clearance to a deeper row's title went from 2.0 pt to at least `Space.m`
   (asserted).
3. **A terminator in space.** The last row of a group is `Space.s` taller than
   its card; the room goes BELOW the card, so the card keeps the height it has
   everywhere else. Space is the strongest grouping cue a list has and it costs
   no colour.
4. **The remainder row is a child row.** `N more` now carries its parent's
   indent and its parent's connector.

The list stays a **flat `NSTableView`**, as the file header argues it should.
`InboxSort` emits a pre-order walk, so every descendant of a row is contiguous
with it, and therefore ONE lookahead — the depth of the next drawn row —
answers every question the connector asks. That is `InboxNesting(depth:
nextDepth:)`, and it is why no group-start/group-end `InboxListItem` case was
needed.

## Tokens and geometry

| thing | value | source |
| --- | --- | --- |
| connector colour | `AgentLineRole.decorativeHairline` (= `LineToken.separator`) | the sanctioned EXEMPT line — `contrastFloor == nil`, `exemptionReason` states why. It is decorative and carries no state. |
| stroke | `LineWidth.hairline` = 0.5 | the sidebar's cap on any boundary |
| lane centre, level k | `4 + 16k + 8` | `outerGutter` + `AgentInboxView.indentPerLevel` |
| card leading, depth d | `4 + 16d` | unchanged — no existing card moved horizontally |
| elbow length | 8 pt (`indentPerLevel / 2`) | lane centre → card leading |
| descender start | card mid + 8 | clear of the 14pt triangle |
| group-end room | `Space.s` = 4 | below the card |
| triangle x in card | `(16 - 14) / 2` = 1 | centres it on the lane |
| connector bleed | `AgentInboxView.rowSpacing / 2` = 2 at each end | see below |

**The bleed is load-bearing.** `tableView.intercellSpacing.height` is `Space.s`,
and that 4 pt belongs to no cell. A lane drawn only inside the cells is a dashed
line with a 4 pt break at every row. The spine view is therefore 2 pt taller than
its cell at each end, and `clipsToBounds` is set to `false` on both the cell and
the spine — the default flipped in the macOS 14 SDK, and mutation **M3b** proves
that setting it back to `true` erases the crossing while every geometric
assertion stays green. That is the one thing only a pixel could say.

## Census (hazard 8)

`InboxSpineView` is **not** `TokenThemed` and paints with `NSBezierPath` in
`draw(_:)`, never a layer colour — the same two decisions `AgentInbox96CellView`
and its private `Decorations` already make, and the reason those are absent from
`tokenAdoptedOwners`. So the conformance scan does not find it, no owner entry is
needed, and `--ui-probe-check` / `--ui-contrast-check` are unaffected (both run
green, contrast still gates 1414 pairs with 0 exempt). No resting state paints
`.clear`: a row with nothing to say produces zero segments and draws nothing at
all.

## Checks run (bench binary, `CONTINUUM_SKIP_UI_BASELINES=1`)

| leg | result |
| --- | --- |
| `swift build` | clean |
| `--agent-inbox-check` (incl. the new A4c) | PASS |
| `--sidebar-ux-check` | PASS |
| `--sidebar-production-corpus-check` | PASS |
| `--sidebar-screenshot-check` | PASS (48 images) |
| `--ui-probe-check` | PASS |
| `--ui-contrast-check` | PASS |
| `--ui-geometry-check` | FAIL — **pre-existing**, see below |
| `--component-lab-check` | FAIL — listed in `MATRIX_KNOWN_RED` |

`--ui-geometry-check` fails with
`the phase label was given 44.5pt for 45.0pt of text on a 1200pt row`. That is an
agent-tile status row, not the sidebar. **Verified, not assumed**: `Sources/` was
checked out at `2cec73ff`, rebuilt, and the leg reproduced the identical message
before being restored. It is not in `MATRIX_KNOWN_RED` and probably should be
triaged separately.

One EXISTING expectation moved. `UIProbeGeometry.swift`'s
`sidebar-ux-check.content-height` asserted the remainder row is exactly
`AgentInboxView.slimRowHeight`; the remainder is the last row of its group and now
keeps `Space.s` under it. The expectation is written as the token
(`slimRowHeight + Space.s`), not as a call into the production function the leg
exists to watch.

The matrix was **not** run (instructed not to). No new `--*-check` flag was added,
so `scripts/run-matrix.sh` is untouched and its two verbatim pins are safe; the
new witness runs inside `--agent-inbox-check`, which the matrix already invokes at
line 631.

## The new witness — section A4c of `--agent-inbox-check`

Fixture: a root with two children, one of which has a child, followed by an
unrelated depth-0 agent (oldest, so the frozen newest-first root order puts it
last) — plus a second fixture with a nested parent over `maxVisibleChildren + 1`
children, which is what mints a remainder row. Everything is read off laid-out
views (the segments `draw` will paint, `rect(ofRow:)`, the card's real frame) and
compared BETWEEN rows, because "where does this group stop" is a fact about two
rows and no per-row accessor can state it.

Teeth — every assertion mutated, rebuilt, observed RED, reverted, observed GREEN.
Quoted verbatim:

1. **M1** `nestings(for:)` last row given `nextDepth: 1` (a group that never ends)
   → `FAIL: exactly the rows of the group draw the connector — inked [0, 1, 2, 3, 4], group is [0, 1, 2, 3]`
2. **M2** `spine.frame = bounds` (no bleed across the intercell spacing)
   → `FAIL: …and it is painted across the intercell spacing too, not clipped to the cell — at the row boundary Optional(NSCalibratedRGBColorSpace 0 0 0 0), gutter Optional(NSCalibratedRGBColorSpace 0 0 0 0)`
   (and, before the pixel probe existed, the geometric form of the same defect:
   `FAIL: …and unbroken from there down — a 4.0pt seam in the lane`)
3. **M3b** the cell's `clipsToBounds = true`
   → `FAIL: …and it is painted across the intercell spacing too, not clipped to the cell — at the row boundary Optional(NSCalibratedRGBColorSpace 0 0 0 0), gutter Optional(NSCalibratedRGBColorSpace 0 0 0 0)`
4. **M4b** elbow shortened by `indentPerLevel / 4`
   → `FAIL: …and meets that row's card at 20.0pt — the elbow ends at 16.0pt`
5. **M5** triangle put back at `textLeft` inside the card
   → `FAIL: no disclosure control comes within 8.0pt of a deeper row's title — worst clearance 2.0pt`
6. **M6** `trailingGap` forced to 0
   → `FAIL: a group's last row keeps 4.0pt more room than a row that ends nothing — 72.0pt against 72.0pt`
7. **M7** remainder leading constant back to `Inset.row.left`
   → `FAIL: …and its words are DRAWN in the depth-2 lane — 10.0pt, lane starts at 36.0pt`

M5's and M7's RED lines are the reported defect, measured.

## The animation: NOT done, deliberately

`toggleCollapse` still does a bare `reloadData()`. The honest reasons:

- A fold changes the row COUNT, so the animation would have to be an
  insert/remove with `NSTableView.AnimationOptions`, and this list drops
  selection, hover, keyboard focus and every cached cell on a shape change
  precisely because the indexes belong to the list that just went away.
  Animating it means keeping two index spaces alive across the transition.
- The cheap alternative (fade the newly inserted cells from alpha 0) puts rows
  at alpha 0 for the duration, and several checks read row and label alphas
  (`rowViewAlphaForQA`, `textAlphasForQA`, the P4.12 crossfade suite) on a
  runloop that a self-check never spins — the rows would simply be invisible to
  them.

The structural work was the ticket and it is witnessed; the motion is worth its
own pass with the crossfade machinery (`crossfadingCells`) reused rather than a
second, parallel fade.

## For a human, at a supervised visual gate

`--ui-baseline-check` (already `MATRIX_KNOWN_RED`, and deferred by the matrix to
"a supervised Retina-Main visual gate") compares the committed
`docs/38-tickets/90-agent-ux/baselines/chrome.sidebar*.png` and
`chrome.agentInbox*` images. Those legitimately move wherever a fixture contains
a parent row: the triangle changed x, the connector is new ink, and a group's
last row is 4 pt taller. **No baseline was regenerated here** and
`CONTINUUM_UPDATE_BASELINES=1` was never set. A human should look at the new
renders and update them.

Two things nobody has looked at in pixels and an agent cannot certify:

- whether the 0.5 pt `decorativeHairline` lane reads strongly enough in Dark
  Aqua at a 220–320 pt sidebar. The pixel probe proves it is PAINTED and
  distinguishable from the gutter beside it; it does not prove it is legible at
  arm's length. If Dylan wants it louder, the knob is `InboxSpineMetrics.lineWidth`
  in `AgentInbox96CellView.spineMetrics` — but note the sidebar's design caps a
  boundary at `LineWidth.hairline`, and a louder line probably wants to be a
  design decision rather than a constant bump.
- whether `Space.s` of group-end room is the right amount, or whether `Space.m`
  reads better at depth 2. One constant: `InboxSpineMetrics.endGap`.

## Files

- `Sources/ContinuumRevivedAgentUI/InboxNesting.swift` — new, pure: `InboxNesting`,
  `InboxSpineMetrics`, `InboxSpineSegment`, `InboxSpine.segments`.
- `Sources/ContinuumRevived/App/InboxSpineView.swift` — new, the painter.
- `Sources/ContinuumRevived/App/AgentInbox96CellView.swift` — spine subview,
  `setNesting`, the triangle's new lane, the reserved group-end room,
  `spineMetrics` / `trailingGap` (the one place both the list and the cell read).
- `Sources/ContinuumRevived/App/AgentInboxView.swift` — `nestings(for:)` and the
  per-row table, `heightOfRow`, the remainder row's indent and connector, the QA
  accessors the witness reads (including `tableInkForQA`).
- `Sources/ContinuumRevived/App/UIProbeGeometry.swift` — the one moved expectation.
- `Sources/ContinuumRevived/App/ContinuumApp.swift` — section A4c.
