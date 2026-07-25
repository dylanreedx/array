# Environment blocker 2 — the committed baselines are host-dependent for TEXT

Found 2026-07-25 while verifying `P1.12-ios-consumes-tokens`. Nothing in that ticket
touches a desktop render path (its diff is `ios/`, `scripts/check-color-hygiene.sh`
and the allowlist), yet `./scripts/run-matrix.sh` is red on **24 of 46 committed
baselines**.

## It is pre-existing at HEAD, not caused by the ticket

With the work stashed and the tree clean at `881a458`:

```
swift build                                  → Build complete
.build/debug/continuum-revived --ui-baseline-check
                                             → FAIL: 24 baseline(s) did not match
```

The pixel counts are **byte-identical** to the run with the ticket applied, e.g.

| render | differing pixels | worst channel delta |
|---|---|---|
| `chrome.topbar-720x44-aqua` | 2745 / 31680 (8.6648%) | 183 |
| `chrome.sidebar-280x560-aqua` | 2604 / 156800 (1.6607%) | 124 |
| `managed-agent.approval-dock-560x720-aqua` | 10999 / 403200 (2.7279%) | 127 |
| `terminal.topology-migration-note-520x180-aqua` | 132 / 93600 (0.1410%) | 59 |

Tolerance is 0.0300%. Two consecutive runs produce the same 24 files and the same
counts, so this is **deterministic drift, not a flake**.

## What actually differs: glyph antialiasing, nothing else

`chrome.topbar-720x44-aqua.png.diff.png` is magenta **only on letterforms** — every
glyph edge in "Continuum · 2 projects · 3 zones · Unsaved changes" and in the four
control titles. Layout is unmoved: `actual` and the committed baseline are visually
indistinguishable side by side, same text at the same positions, same fills. The 22
renders that still match are the ones with little or no text.

## Why (and why `5080adc` did not cover it)

`5080adc` fixed the SIZE half of display independence: `UIProbe.renderScale = 2.0`,
its own bitmap at points × scale, `rep.size` in points. That is holding — the host is
now the built-in Retina panel as the only display (3024×1964, Main, 2x) and the
geometry gates are green.

What is still ambient is **glyph rasterisation**. `cacheDisplay` draws through the
window's graphics context, and CoreGraphics font smoothing / subpixel state is not
derived from the declared bitmap scale — it comes from the environment the window is
in. The measured history says the same thing without needing a theory: the identical
tree ran this leg **green earlier today** (P0.7 attempt 2, `e083f97`) under the
display configuration recorded in `_ENV-BLOCKER-1x-display.md` (1920×1080 external as
Main), and is red now that the built-in Retina panel is the only display. Nothing in
between touched a render path.

So the substrate pins its scale and does **not** pin its font rendering. Which
configuration the committed PNGs "belong" to is exactly the property a gate should not
have.

## Why this worker did not resolve it

* **Blessing is the forbidden move.** The runbook bans blessing baselines to make a
  comparison pass, and here it would overwrite 24 known-good renders with one host's
  antialiasing — losing exactly the regression coverage P0.6 bought, and re-arming
  the same failure the next time the display configuration changes.
* **Fixing it is a different ticket.** The fix is in `UIProbe.render` (pin font
  smoothing/antialiasing explicitly for the probe context, e.g. an explicit
  `CGContext` with `setShouldSmoothFonts(false)` rather than inheriting the window's),
  a file `P1.12`'s packet does not name — and it costs one deliberate 46-baseline
  bless commit of its own, which must be reviewed as a substrate change and not
  smuggled into an iOS colour ticket.
* Every remaining ticket in the queue would fail the same leg, so this is a run-level
  stop, not a per-ticket block.

## Owner's options

1. **Pin the probe's font rendering** (substrate ticket), then one bless commit for
   all 46 baselines. Makes the gate genuinely host-independent — the right fix.
2. **Re-bless on this host** and keep the display configuration fixed for the rest of
   the run. Cheap, one commit, but the gate stays display-dependent and this returns.

## P1.12's own state

Implementation is COMPLETE and verified as far as this environment allows — see the
ledger row. Parked in `git stash@{0}` ("P1.12-wip", commit `2c7cc86`), tree left
clean apart from the ledger. What is verified: `swift build` green, the iOS
`xcodebuild` leg green (`** BUILD SUCCEEDED **`), `scripts/check-color-hygiene.sh`
green with 7 negative tests observed red. What is NOT verified: the full matrix, and
specifically the baseline and component-lab legs, both of which are red at HEAD for
the reason above.
