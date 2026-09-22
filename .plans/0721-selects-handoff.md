# 0721-selects — the agent tile selects truncate with room to spare

Bench: `.worktrees/0721-selects`, branch `array/0721-selects`, based on
`array/integration` at `2cec73ff`.

Reported: "the selects in an agent tile are still so weird!!! truncating when
they have plenty of space!!!"

## The RED measurement, before any production change

The first thing built here was the measurement, not a fix:
`--choice-geometry-check` lays out the REAL `ChoiceListView` at exactly the size
`ChoicePopoverController` gives it (`list.intrinsicContentSize`), with realistic
live display names, and compares every row's title-label frame against the width
a real `NSTextField` needs to draw that string. On the unchanged tree:

```
FAIL: [choices @80%] row "openai-codex/gpt-5.3-codex-spark" draws in 174.5pt
      but needs 179.0pt (panel width 218.0pt, short by 4.5pt)
      — the row truncates at the panel's own width
```

That is the whole reported defect in one number: the panel is free to be any
width, sizes itself, and is still ~4.5pt too narrow for its own first row. The
deficit is pure arithmetic and it is the same at every width, so the menu
ellipsizes however much space surrounds it.

Where the missing points came from — the panel sized itself with one pair of
paddings and the rows laid out with a different pair:

| | panel's assumed chrome | row's real chrome | deficit |
|---|---|---|---|
| `.choices` / `.completions` | `horizontalPadding*2 + 26` = 50 | `rowInset*2 (16) + textX (30) + trailing (8)` = 54 | 4pt |
| `.commands` / `.slashCommands`, no icon | `horizontalPadding*2` = 24 | `16 + 10 + 8` = 34 | 10pt |

plus ~1pt for the label cell's own inset, which nothing accounted for at all.

## Which suspects were real

- **(a) the popover list under-measures its own rows — REAL, and it is the
  bug.** Numbers above. Every variant, every zoom rung, every panel width.
  This is also what the grouped provider>model picker pane is sized from
  (`ProviderModelPickerView.paneSize` reads the same `intrinsicContentSize`),
  so the model menu inherited it.
- **(b) an async catalogue refresh does not re-run the fit decision — REAL, and
  broader than reported.** `rebuildChoices()` never asked for layout, so it is
  not only the `AgentModelCatalog` refresh: `apply(_ settings:)` and
  `apply(_ selection:)` have the same hole. The witness caught it on the
  *precondition* of its own refresh case — a footer that had gone compact for
  the default model stayed compact after a launch selection installed a shorter
  one, because nothing marked the view for layout and the frame had not changed:

  ```
  FAIL: before the refresh the trigger shows the bare id, got "m1"
  ```

- **(c) measurement and installation read different harnesses — REAL but
  latent.** `requiredWidth` measured `snapshot(for: recordHarness)` while
  `rebuildChoices` installs from `snapshot(for: selectedHarness)` and shows
  `selectedHarness` on the harness trigger. I could not drive the two apart
  through any production path in this tree (`pick(harness:)` writes both), so
  this is a correctness alignment, not a reproduced defect. Both now read
  `selectedHarness` — the harness whose titles are actually installed.
- **(d) the trigger's magic `+4` cell-padding guess — NOT REAL. Say so plainly.**
  Measured, the label cell's horizontal inset is ~0.008pt (it ceils to 1) at all
  four zoom rungs, for `.label`, `.body` and `.caption`. The `+4` was slack, not
  a deficit; the trigger drew its title fine at its own intrinsic width at 80,
  100, 125 and 150% before any change here. I replaced the constant with the
  measurement anyway (it is one owner now, and the task asked for a measured
  inset), but it fixed nothing and it is not what Dylan is seeing. The teeth
  pass below proves the gate cannot even see that constant.

Stack priorities were not touched. `3f73a2ac`'s `Priority(1)` fill and the
spacer are untouched and still correct.

## What changed

- **`ChoiceLabelMetrics.swift` (new).** One measured answer to "how wide must a
  label be to draw this string": the glyph run plus the cell's own inset,
  measured from a real `NSTextField` once per font and cached, instead of a
  hard-coded `+ 4` at one call site and nothing at the other.
- **`ChoiceListView.swift`.** `intrinsicContentSize` now sizes the panel from
  `rowChromeWidth` — the same `renderedRowInset`, `ChoiceRowView.textInset` and
  `ChoiceRowView.trailingInset` expressions `layout()` uses — over the measured
  label width. The row's two insets became statics so the list and the row
  cannot drift apart again. `reservesLeadingSlot` has one definition.
- **`ChoiceButton.swift`.** `measuredTitleWidth`, `fittingWidth(forTitle:zoom:)`
  and `qaMeasuredTitleWidth` all route through `ChoiceLabelMetrics`; the QA seam
  is now literally the production expression rather than a copy of it.
- **`AgentComposerFooterView.swift`.** `rebuildChoices()` ends by invalidating
  the intrinsic size and marking needs-layout, so installing titles always
  re-runs the fit decision (the catalogue refresh, `apply(settings)` and
  `apply(selection)` alike). `layout()` sets `isInstallingFitDecision` around
  its own rebuild so the pass it is inside cannot re-trigger itself.
  `requiredWidth` measures `selectedHarness`.

The model trigger remains the element allowed to condense; it just no longer
condenses or elides while room exists.

## The new witness: `--choice-geometry-check`

Registered in `scripts/run-matrix.sh` next to `--provider-model-picker-check`.
`scripts/check-matrix-inventory.sh`, `check-agent-tile-ux-program.sh`,
`check-sidebar-native-ux-program.sh` and `check-root-docs.sh` all pass with the
new line. The inventory reports "grew" (allowed) and asks to be regenerated by a
full matrix run — note it was ALREADY behind on this branch point
(`--workspace-api-board-check`, CoreChecks 142→144), so that regeneration is not
mine to fold in from a bench.

Five sections: the measured cell inset; popover rows across 7 presentation /
leading-slot variants × 4 zoom rungs (including `.commands` and
`.slashCommands`); the trigger at its own intrinsic width; the footer with
surplus width at 640pt; and an async catalogue refresh.

**It expects against an independent measurement.** `requiredLabelWidth` builds a
real `NSTextField` and reads its `intrinsicContentSize`; it deliberately does not
call `ChoiceLabelMetrics`. The first draft did, and the teeth pass caught it —
a gate that re-derives its expectation from the expression the control sizes
itself with agrees by construction.

### Teeth (each mutation built and run, then reverted)

| mutation | result |
|---|---|
| panel sized by the old `horizontalPadding*2 + 26` pair | **RED** — `[choices @80%] row "openai-codex/gpt-5.3-codex-spark" draws in 175.5pt but needs 178.0pt (panel width 219.0pt, short by 2.5pt)` |
| `ChoiceLabelMetrics.labelWidth` drops the cell inset | **GREEN — no teeth.** The real inset is ~0.008pt; ceil and the 0.5pt tolerance swallow it. Recorded rather than papered over: this assertion cannot defend the inset, which is the honest state of suspect (d). |
| `rebuildChoices` no longer marks needs-layout | **RED** — `before the refresh the trigger shows the bare id, got "m1"` |
| `requiredWidth` overstates the row's need (×3) | **RED** — `effort must stay visible when the row has surplus width` |

Unmutated, on a rebuilt binary: `ContinuumRevivedChoiceGeometryChecks passed`.

## Legs run from this bench

`--choice-geometry-check`, `--ui-probe-check`, `--settings-panel-check`,
`--agent-inbox-check`, `--provider-model-picker-check`, `--menu-contract-check`,
`--completion-awareness-check`, `--agent-completion-semantic-check`,
`--sidebar-ux-check`, `--workspace-sidebar-actions-check`,
`--agent-first-paint-check` — all exit 0. `swift build` clean. The full matrix
was not run from here.

Two reds seen and both PRE-EXISTING, reproduced byte-for-byte with my four
edited files reverted to `2cec73ff` on this same host:

- `--component-lab-check` — listed in `MATRIX_KNOWN_RED`.
- `--ui-geometry-check` — **NOT** listed in `MATRIX_KNOWN_RED`:
  `FAIL: the phase label was given 44.5pt for 45.0pt of text on a 1200pt row —
  it will render truncated with room to spare` (`UIProbeGeometry.swift:901`).
  Same *family* of defect as this ticket, different surface (the agent tile's
  activity/phase label, not a select), 0.5pt, and out of this bench's scope.
  Someone should own it — it is either a real header truncation or a gate whose
  tolerance is off by a rounding step.

## Overlap with the parallel bench

None in the files that bench owns. I did not touch `ProviderModelPicker.swift`
(not the `ProviderModelButton` class either) and did not touch
`AgentModelCatalog.swift` or any catalogue data. The new check calls
`AgentModelCatalog.shared.resetForQA(options:displayNames:)` — an existing public
QA seam — and restores it with `defer`, exactly as the picker's own self-check
does.

## What I could not verify without a human looking at pixels

- That the ~4.5-10pt the rows gained is what Dylan was seeing, rather than a
  second truncation in the same screenshots. I cannot see the two screenshots.
  The rows demonstrably elided at the panel's own width and no longer do; if a
  select still truncates for him, the next thing to ask for is WHICH select and
  whether it is open or closed — closed triggers measured clean here before any
  change.
- Rendering at the non-100% rungs is asserted by frame arithmetic only. No
  screenshot comparison was taken; the UI-baseline legs were skipped
  (`CONTINUUM_SKIP_UI_BASELINES=1`) because Dylan is on this machine.
- The `--ui-geometry-check` phase-label red above.
