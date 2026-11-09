# Stream: practicality after tidy (camera rule, Tidy canvas at scale)

Branch `array/aln-tidy-camera`, worktree `.worktrees/aln-tidy-camera`, off
`array/auto-layout-night` at `309cf255` (`b17a1156` plus the README). Debug
build, 2026-11-09, local commits only.

## In short

When you tidy one zone and it grows or moves partly off screen, the camera now
flies to show the whole zone, starting in the same turn as the tidy's own
animation. A zone that stays in view never moves the camera, and Tidy canvas
never moves it.

Tidy canvas over 6 zones × 15 tiles:
- **One commit and one Undo.** A single Undo restores every tile.
- **Motion starts at 63–70 ms.**
- **Zones below the live tier are left exactly alone.** Only 5 of the 6 zones
  were live.

## What changed

- `af9d025d` feat(auto-layout): frame a tidied zone that tidy carries out of view
- `8f1712c8` test(auto-layout): witness the tidy camera rule and Tidy canvas at scale

How it works:
- **Which tidies.** `CanvasNSView.tidyAutoLayout(…, framesZone:)` takes the
  new flag. Only the three user paths pass `true`: the zone menu's Tidy Zone
  Now, ⌥⌘T, and the ⌘K "Tidy This Zone" row. Internal tidies leave it off
  (zone creation, auto-layout mode changes, onboarding), and so does Tidy
  canvas (zone `nil`).
- **The rule.** Before the solve, it notes whether the zone's world rect lies
  wholly inside the usable view (`usableVisibleScreenRect`, which excludes
  overlays, at `navigationViewport`). After the solve and the neighbour
  pushes, if it was and no longer is, it calls
  `navigateViewport(to: framedZoneViewport(for: newRect))`.
- **The framing.** `framedZoneViewport` is the zone overview camera the
  sidebar and leader zone jumps use (`CameraFraming.zoneOverviewViewport`),
  fitted to the usable rect the way `framedWorkViewport` does for tiles.
  `navigateViewport` is the shared flight path: it flies, and cuts under
  Reduce Motion.
- **Timing.** The flight is armed before `commitGeometryEdit`, whose
  present-before-write commit carries the tidy's animations, so the camera's
  first step is the next frame. Nothing runs one after the other.
- **Undo** restores the layout, not the camera, as the sidebar jumps do.

## Witness: `--tidy-camera-check`

Every scenario runs through the production entries:

| scenario | trigger | outcome |
|---|---|---|
| A: zone wholly in view (bottom edge 10 pt above the view's) grows downward | zone menu | flight armed in the same turn as the committed movement; lands exactly on the framed viewport (zoom 1.40 → 0.80); zone then wholly in view |
| A, same | real ⌥⌘T key-down through `NSApp.sendEvent` | same |
| B: roomy zone shrinks and stays in view | zone menu | viewport unchanged, no flight |
| C: the A zone grows out of view | Tidy canvas (`qaPerformPaletteAction(.tidyCanvas)`) | viewport unchanged, no flight |
| D: 6 zones × 15 tiles | Tidy canvas | 75 tiles in the 5 live zones tidied, 1 commit, Undo offered, one Undo restores all 75, the non-live zone's rect unchanged, camera unchanged |

- **Flights in an offscreen window.** They are forced on with
  `navigationFlightOverrideForQA`.
- **Landing.** The check waits on the real driver. When the offscreen display
  link does not tick, the driver's stalled-link backstop lands the flight
  exactly, and the viewport is compared for equality.
- **Teeth.** With the framing call disabled it fails 6 times. For each
  trigger: no flight, wrong landing, and the grown zone left partly off
  screen.

## Numbers: Tidy canvas, 6 zones × 15 tiles (5 live, 1 dormant)

| run | motion start | call | solve | apply | present layout | flush | persist (after start) |
|---|---|---|---|---|---|---|---|
| 1 | 62.8 ms | 78.8 | 5.2 | 5.5 | 30.1 | 23.9 | 7.1 |
| 2 | 69.5 ms | 86.9 | 5.6 | 6.2 | 34.0 | 25.8 | 7.7 |

All 75 live tiles were in view at zoom 0.28, so none were far-parked. Most of
the time before motion is laying out and redrawing 75 resized tiles once.

## Findings for the lead

- **Only 4–5 zones are live** (`ZoneHydrationBudgetConfig.maxLiveZones`,
  default 4). Tidy canvas tidies only the live ones; a zone below the tier has
  no tile views in the scene. The check asserts tidy leaves such a zone's rect
  untouched, and it does. A user may still expect "Tidy canvas" to cover every
  zone; it only covers live ones.
- **The zone overview zoom can be a big change for a small growth.** In A the
  zone grew 46 pt and the camera went from 1.40 to 0.80 zoom, because that's
  what the sidebar's zone overview framing chooses. A gentler option is the
  smallest pan or zoom that contains the new rect. I followed the brief and
  used the existing path.
- **My rule breach, found by this audit.** These legs open windows on screen
  with `orderFrontRegardless`: `--leader-jump-check`,
  `--tile-reveal-work-check`, `--palette-zone-check`, `--canvas-undo-check`
  and `--spawn-placement-check`. I ran the first four in earlier rounds
  without checking. I ran none of them this round.

## Checks (exit codes, final code)

Each leg's source was checked for on-screen windows first. All exit 0:
- new and tidy legs: `--tidy-camera-check` (3 runs), `--tidy-zone-shortcut-check`,
  `--tidy-offscreen-defer-check`, `--auto-layout-tidy-latency-check`;
- camera: `--spawn-framing-check`, `--canvas-zoom-momentum-check`;
- zone and auto-layout: `--zone-arming-check`, `--layout-commit-truth-check`,
  `--auto-layout-fanout-app-check`, `--spawn-sizing-check`,
  `--tile-insert-slide-check`, `--canvas-pointer-path-check`,
  `--jelly-auto-layout-check`.

Not run (they put windows on screen): `--leader-jump-check`,
`--tile-reveal-work-check`, `--palette-zone-check`, `--canvas-undo-check`,
`--spawn-placement-check`.
