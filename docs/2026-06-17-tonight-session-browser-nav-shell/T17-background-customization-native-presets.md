# T17 — Background customization: transparency, blur, images, native patterns

Status: draft
Tag: tonight [visual] [settings]
Depends on: —

## Goal
Add first-class workspace/canvas background customization. Users should be able to choose tasteful defaults, use images, tune transparency/blur, and select cool native patterns without requiring AI generation.

## Scope
- Background style model:
  - solid color
  - gradient
  - image
  - native pattern (SVG/procedural)
  - optional overlay tint
  - blur amount
  - opacity/transparency amount
  - scale/fill mode for images
- Built-in default images/presets.
- Built-in native patterns, likely SVG or procedural vector: grid, dot matrix, contour lines, aurora gradients, blueprint, paper grain, constellation, subtle waves.
- Settings UI for preview/apply/reset.
- Ensure tile readability: backgrounds should not fight translucent UI.

## Design constraints
- Backgrounds must look good behind many tiles.
- Defaults should be calm/productivity-oriented, not loud wallpaper.
- Transparency and blur should be bounded to avoid illegibility/performance problems.
- Native SVG/procedural patterns should be lightweight and theme-aware.

## Acceptance criteria
- [ ] User can choose from built-in background presets.
- [ ] User can choose native pattern presets.
- [ ] User can set a custom image background.
- [ ] User can adjust opacity/transparency and blur.
- [ ] Background config persists after restart.
- [ ] Readability guard or preview warns when background is too busy/high-contrast.

## Verification
- Manual: solid, gradient, image, pattern; restart; inspect tile readability.
- Performance check: pan/zoom with blur enabled versus disabled.

## TDD sketch
Treat background config as a pure schema with render planning.

```swift
let bg = BackgroundStyle.pattern(.dotMatrix, tint: "#0f172a", opacity: 0.42, blurRadius: 12)
let restored = try roundTrip(bg)
expect(restored == bg, "background style persists")

let plan = BackgroundRenderPlan.make(bg, viewport: CGSize(width: 1440, height: 900), scale: 2)
expect(plan.layers.contains(.patternSVG), "native pattern renders as SVG/vector layer")
expect(plan.blurRadius <= BackgroundStyle.maxBlurRadius, "blur is clamped")
expect(plan.estimatedCost != .excessive, "default pattern is safe for pan/zoom")
```

Readability guard:

```swift
let busy = BackgroundAnalyzer.analyze(imageFixture: .highContrastCheckerboard)
expect(busy.requiresReadabilityWarning, "busy backgrounds warn before apply")
```
