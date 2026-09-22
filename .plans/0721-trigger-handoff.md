# 0721-trigger — the composer footer's CLOSED triggers truncated at every width

Branch `array/0721-trigger`, based on `array/0721-nightly` (`e1a79848`).

User report: a ~1250pt managed **Pi** tile drew `[ Pi ⌄ ] [ GPT-5.6… ⌄ ] [ Hi… ⌄ ]`
with several hundred points of empty row beside the Send button. The earlier
popover/re-layout fixes (`502b9493`, `1469c164`) were real and are untouched; they
fixed the OPEN list panel, not the closed trigger.

## Raw pre-change measurements

Reproduced in the production shape — real `ManagedAgentTileNSView` from
`LabCatalog.makeManagedAgentFixtureView`, rendered at 1250×560 darkAqua, harness
Pi, model `openai-codex/gpt-5.6-sol` with display name `GPT-5.6 Sol` injected
through `AgentModelCatalog.resetForQA(snapshot:)`, effort `high`.

```
zoom=100 tile.width=1250.0 footer.bounds=(0,0,1135,32) fits=true
zoom=100 tiers compact=false condensedModel=false hidesEffort=false
         reqFull=252.0 reqCompact=249.0 reqNoEffort=171.0
zoom=100 harness title='Pi'          frameW=56.0  intrinsic=56.0  titleFrameW=12.0 measuredTitleW=12.0 labelIntrinsic=11.0 cellSize=14.151 glyph=10.151
zoom=100 model   title='GPT-5.6 Sol' frameW=110.0 intrinsic=110.0 titleFrameW=66.0 measuredTitleW=66.0 labelIntrinsic=65.0 cellSize=68.228 glyph=64.228
zoom=100 effort  title='High'        frameW=70.0  intrinsic=70.0  titleFrameW=26.0 measuredTitleW=26.0 labelIntrinsic=25.0 cellSize=28.963 glyph=24.963
```

Identical shape at every page-zoom rung (80/90/100/110/125/150) and at every
tile width. The tier decision was never wrong: `compact=false`, the full titles
were installed, the row had ~880pt of surplus. The buttons sat at exactly their
intrinsic width. **The label inside each button was short by ~3pt.**

## Mechanism (proved, not hypothesised)

`ChoiceLabelMetrics.cellInset(for:)` measured the cell's horizontal inset as

```swift
inset = max(inset, field.intrinsicContentSize.width - glyphs)
```

`NSTextField.intrinsicContentSize` is *itself* the quantity that omits the cell
inset — that is the whole `HonestWidthLabel` finding from `2e43f3ed`, one commit
earlier on this same base. So the probe measured `25.0 - 24.963 = 0.037`, `ceil`
turned it into **1**, while the cell's own `cellSize(forBounds:)` wants glyph
**+ 4.0**.

Consequence: `measuredTitleWidth = ceil(glyph) + 1`, three points under what the
cell needs. `ChoiceButton.layout()` hands the label exactly that, so a
tail-truncating cell elides. It elides *hard*, because the ellipsis is wider than
the character it replaces: 26pt for a 28.96pt "High" cannot fit "Hig…" either, so
the cell falls back to **"Hi…"** — the screenshot, exactly. Same for
"GPT-5.6 Sol" at 66pt of 68.23 → **"GPT-5.6…"**. "Pi" survives because its
ellipsis is wider than the string.

This was width-independent and zoom-independent: every trigger on every tile has
been drawing three points short since the inset was introduced.

**Why no gate saw it.** Both witnesses re-derived their expectation from an
under-reporting quantity:

- `ChoiceButton.qaTitleDrawsWithoutTruncation` compared `titleLabel.frame.width`
  against `measuredTitleWidth` — the *same expression that produced the frame*.
  Vacuous by construction; it read `titleFrameW == measuredTitleW` exactly at
  every rung above and was green throughout.
- `ChoiceGeometryChecks.requiredLabelWidth`, written explicitly to be independent
  ("must not route through `ChoiceLabelMetrics`"), used
  `ceil(field.intrinsicContentSize.width)` — the very quantity that under-reports.

## Second defect, found by the fix

Making the measurement honest turned `--ui-geometry-check` RED at 480pt:

```
FAIL: managedAgent.v2@480pt...effort=minimal: model picker squeezed below its measured width (frame 134.0, needs 140.0)
      [footer 365.0 reqFull=363.0 intr 117.0/140.0/90.0 frames 117.0/134.0/90.0]
```

The footer's stack is `[harness, model, effort, spacer]` — **three** gaps at 8pt,
while `requiredWidth(...)` and `qaFitsCurrentTitles` cost **two**. The fit
decision therefore approved a tier exactly one gap too wide, and the stack took
that 8pt out of the `.defaultLow` model trigger with the spacer collapsed to 0.
Pre-existing and latent; the honest measurement is what exposed it.

## Changes

- `ChoiceLabelMetrics.cellInset` probes `drawingWidth(of:)` — `max` of the
  field's intrinsic and its cell's `cellSize(forBounds:)` at unbounded width —
  instead of `intrinsicContentSize`. Inset 1 → 4 at 100%.
- `ChoiceLabelMetrics.drawingWidth(of:)` is the new shared honest measure.
- `ChoiceButton.qaTitleDrawsWithoutTruncation` now compares the granted frame
  against `qaTitleDrawingWidth` (the installed label's own cell), not the number
  the button sized it with. New seam `qaTitleDrawingWidth`; the failure message
  names all three numbers.
- `ChoiceGeometryChecks.requiredLabelWidth` asks the cell too.
- `AgentComposerFooterView` sets `setCustomSpacing(0, after: effortButton)` in
  the initialiser and in `applyPageZoom`, so the row costs the two gaps its fit
  arithmetic charges for.
- New `qaFitTiersDescription` seam, used in the new gate's failure message.

## The extended gate

`UIProbeGeometry.checkWideTileFooterTriggers()` runs under `--ui-geometry-check`
(already a matrix leg; no new flag, `run-matrix.sh` untouched). It closes both
halves of the coverage gap: widths **900 and 1250**, both appearances, all six
page-zoom rungs, harness Pi, and the pi catalogue reset to carry **real display
names**. It asserts the full-title tier is chosen, that the three rendered titles
are verbatim `Pi` / `GPT-5.6 Sol` / `High`, that no label is elided by its own
cell's measure, and that the row still has >200pt of surplus (so the witness
cannot degrade into a tight-fit test). Ordered before
`checkLiveV2AgentTileLayout` so it reports first.

## Teeth (rebuilt binary each time)

Revert the `cellInset` probe to `intrinsicContentSize`:

```
FAIL: managedAgent.wideFooter@900pt.NSAppearanceNameAqua.zoom=80: provider picker's title frame 10.0pt
is narrower than what the label's own cell needs to draw 'Pi' (12.533543467521667pt; the button sized
it from 10.0pt) — the cell will draw an ellipsis
```

and `--choice-geometry-check`:

```
FAIL: measured label width 75.0 is under what a real label needs (78.0) for "Claude Fable 5.1" at 80%
```

Revert only `setCustomSpacing(0, after: effortButton)`:

```
FAIL: managedAgent.v2@480pt.NSAppearanceNameAqua.effort=minimal: model picker squeezed below its
measured width (frame 134.0, needs 140.0) — its title will ellipsize
```

Both restored → GREEN.

## Verified on the bench

`swift build` clean. All with `CONTINUUM_SKIP_UI_BASELINES=1`, exit 0:
`--ui-probe-check`, `--ui-geometry-check`, `--choice-geometry-check`,
`--provider-model-picker-check`, `--settings-panel-check`, `--agent-inbox-check`,
`--managed-agent-page-zoom-check`.

## Still unverified

- `--component-lab-check` not run (KNOWN-RED on this base).
- The full matrix was not run, by instruction.
- Not observed in the live GUI — the running preview build was left alone. The
  reproduction is the offscreen probe above, whose numbers match the screenshot
  character for character.
- Every other `ChoiceListView` row also widens by 3pt now (it shares
  `ChoiceLabelMetrics`); popover panels are correspondingly a little wider.
  `--choice-geometry-check` and `--provider-model-picker-check` are green on it.
