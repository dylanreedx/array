# Visual Regression Harness — Plan

Status: 2026-06-14. Adopted as Continuum matured past the overnight-loop phase
into dogfooding-driven stabilization. Backs the verification doctrine: the
matrix proves *logic/geometry/state*, never *what the user sees*. Several
"Done" features were hollow because a check asserted a seam, not a rendered
pixel. This harness closes the grossest part of that gap.

## The specific failure it fixes

The codebase already rendered chrome to PNG in three self-checks
(`zone-chrome-enabled.png`, `nav-overlay.png`, `diff-review-tile.png`) — but
only asserted `screenshotBytes > 0`. **A perfectly grey 1600×900 canvas is
also a non-empty PNG.** So a blank/zero-sized/all-one-color render passed the
gate. That is the exact shape of the Cmd+F grey-screen and the dead-corner
bugs: green over something the user can't see or use.

## Principle

A check that screenshots a view MUST assert the *content*, not the byte count.
Assert pixels, never `bytes > 0`.

Constraint: only AppKit-drawn chrome composites through `cacheDisplay`. WKWebView
and Ghostty (GPU/Metal) do NOT — never snapshot live web/terminal pixels, only
the chrome around them.

## Tier 1 — non-degenerate guard (SHIPPED)

`VisualSnapshot.metrics(of: NSBitmapImageRep)` (Sources/ContinuumRevived/App/
VisualSnapshot.swift) samples a capped grid (~64×64), quantizes channels to 5
bits to absorb antialiasing, and counts distinct colors. `Metrics.isBlank` is
true when the render is zero-sized or a single flat color. Every screenshot
site now asserts `!metrics.isBlank` (the grey-screen guard):

- `--multi-zone-render-check` — zone chrome (CanvasNSView.swift)
- `--nav-mode-check` — nav overlay (ContinuumApp.swift)
- `--diff-tile-check` — diff review tile (ContinuumApp.swift)

Zero maintenance: no committed baselines, no blessing, can't flake on
font/colorspace drift (it only asserts "not one color"). Catches the gross
class — blank overlays, zero-sized panes, all-grey fills.

## Tier 2 — baseline diffing (FUTURE, when a render's *layout* needs locking)

For surfaces where exact composition matters (the Settings panel from docs/24,
group hull overlays from the wayfinding track):

| # | Step | Tag | Check |
|---|------|-----|-------|
| V1 | `VisualSnapshot.diff(rep, baseline:)` — quantized per-pixel compare, returns % differing + writes an actual+diff image to qa-runs | [pure-ish] | unit: identical→0%, shifted→>0% |
| V2 | Baseline store under `qa-visual-baselines/<scenario>@2x.png`; `--bless-visual-baselines` flag to (re)write them deliberately | [appkit] | bless round-trip |
| V3 | Per-scenario tolerance (default ~0.5% of pixels) so subpixel/AA noise doesn't flake; log the % every run | [appkit] | tolerance honored |

Baselines are committed PNGs; a real layout change is a deliberate re-bless in
the same commit (like updating a snapshot test). Defer until a high-value
static surface exists to lock — Tier 1 covers the regression-prevention need
until then.

## Convention going forward (the durable rule)

Every new UI/UX feature that draws AppKit chrome ships, in the same change:
(1) a self-check driving the real user path, and (2) a Tier-1 non-degenerate
snapshot of its chrome. `bytes > 0` is banned as a render assertion. Live
web/terminal content is verified by Dylan's dogfood pass, not by snapshot.

## Key files

`Sources/ContinuumRevived/App/VisualSnapshot.swift` (the helper) ·
`CanvasNSView.swift` (zone-chrome site ~:902) · `ContinuumApp.swift`
(nav-overlay ~:5537, diff-tile ~:5853) · `scripts/run-matrix.sh` (the three
checks already run). Doctrine: memory `verification-doctrine`.
