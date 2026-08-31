# WS7 dispatch — global and per-workspace canvas backgrounds

## Shared workstream target

This packet defines **WS7: canvas background customization** in Array. Begin only from the I2 checkpoint at `<BASE_SHA>`. The rendered `<ROLE>` controls authority: a lead implements; a reviewer or tester evaluates the same locked target under only its selected overlay.

The fully rendered common protocol prepended to this dispatch is binding. The checked-in `00-agent-protocol.md` is an unresolved reference template and never overrides rendered values.

Read `<WORKTREE>/AGENTS.md`, the master plan, `00-agent-protocol.md`, `docs/internals/performance.md`, current workspace document/settings schema, appearance/token checks, and canvas rendering code. Work only in `<WORKTREE>` and write evidence beneath `<EVIDENCE_DIR>`.

### Outcome

Add a coherent background system:

- Global defaults with optional per-workspace override or explicit inherit.
- Presets: solid, line grid, dot grid.
- Custom base color and pattern foreground color.
- Optional imported local image, opacity 0–100%, and Fill/Fit.
- Base and image are viewport/screen-fixed. The line/dot grid is world-aligned: pan changes phase, canvas zoom changes scale, and returning to a camera state returns to the same pixels.
- Layer order is base → image → pattern → world content.
- No gradient, blur, animation, or per-line/per-dot view/layer.
- Missing, unreadable, or corrupt images fall back to base/pattern with a nonfatal warning and no lost configuration.
- Camera movement never decodes an image, allocates a grid proportional to world size, or lays out the tile tree.

### Required model

Use a versioned, platform-neutral Codable model in Core. Store colors as validated RGBA values rather than `NSColor`. Separate the global value from the workspace override/inherit state. Persist global configuration as one atomic encoded value in the correct channel-local defaults domain. Persist a workspace override in the workspace document with backward-compatible decoding and a stable default of inherit.

Import selected images into a channel-specific managed Application Support location and persist an asset identifier, not an arbitrary transient picker URL. Downsample/decode off-main to a bounded target suitable for the active display/window; cache the decoded result. Follow existing channel/state isolation. Do not place images in project `.array/` or sync host-local paths as portable data.

### Inspect first

- `Sources/ContinuumRevivedCore/WorkspaceDocument.swift`
- `Sources/ContinuumRevivedCore/WorkspaceProfileConfig.swift`
- `Sources/ContinuumRevivedCore/BuiltInSettingRegistry.swift`
- `Sources/ContinuumRevivedCore/SettingsSchema.swift`
- `Sources/ContinuumRevived/App/SettingsPanel.swift`
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift`
- `Sources/ContinuumRevived/Canvas/CanvasWorldPlaneView.swift`
- appearance/token-owner census and UIProbe baseline code
- existing managed-asset/import patterns and channel-specific Application Support helpers
- workspace save/reload code promoted in WS2
- camera/zoom performance counters promoted in WS3

### Owned scope

Own new Core configuration/asset types, a new AppKit background renderer, a dedicated Settings section, workspace override field/migration, and focused checks. Narrow changes to `WorkspaceDocument.swift`, `CanvasNSView.swift`, and `SettingsPanel.swift` require the explicit hunk grants in the dispatch. Do not alter tile/zone layout, generic semantic color tokens, page zoom, transcript rendering, or perf ceilings.

### Required UI

Add a dedicated **Canvas Background** settings section with:

- Global / This Workspace scope or a clear workspace “Use Global” switch;
- live preview;
- Solid / Lines / Dots choices;
- base and pattern color wells;
- bounded grid spacing control in world points;
- Choose Image / Remove Image;
- opacity control;
- Fill / Fit;
- Reset and workspace Inherit.

Explicit user colors remain exact. System-derived defaults respond to appearance. Preserve contrast of zone chrome, selection, resize handles, HUD, and tile shadows without silently modifying user colors.

### Required renderer behavior

- Draw the pattern procedurally with one bounded renderer/layer/path operation, not a layer per primitive.
- Use an adaptive stride with hysteresis at deep zoom so primitive count is bounded and the grid does not moiré or flicker between adjacent camera values.
- Disable implicit animation during camera updates.
- Define and test precise world-to-screen phase math for negative coordinates and fractional pan/zoom.
- Image Fill/Fit geometry is deterministic and screen-fixed; cached decode survives pan/zoom and invalidates only for image/display/size changes.

### Required witnesses

1. Pure encode/decode and malformed-value fallback for every configuration field and old workspace documents.
2. Precedence truth table: global default; workspace inherit; workspace override; reset; global change while overridden; global change while inherited.
3. Real restart and A → B → A persistence, including distinct overrides, missing image, and global fallback.
4. Renderer math at fixed camera positions for solid/lines/dots and negative coordinates. Pan/zoom/return must recover grid phase within 1 px and leave image screen pixels fixed within 1 px.
5. Image opacity 0/0.35/1 and Fill/Fit geometry; missing/corrupt asset fallback and warning.
6. Appearance/token census, Accessibility labels/keyboard traversal for controls, and Reset/Inherit semantics.
7. Performance teeth: constant background renderer count; bounded primitive count; zero image decode on camera steps; zero tile layout triggered solely by background camera update.
8. Screenshot matrix in Aqua/Dark Aqua at canvas zoom 0.50/1.00/2.00:
   - default solid;
   - custom solid;
   - custom line and dot colors;
   - image at three opacities in Fill and Fit;
   - settings editor/live preview;
   - workspace override vs inherited global;
   - after pan/zoom/return and after relaunch.

Use a checked-in or generated deterministic non-photographic test image with visible corner/color rulers and no copyright/private-data concerns. Store semantic configuration, camera, image rect, grid phase/stride/primitive count, and pixel samples beside the PNGs. Do not bless unrelated component baselines.

### Required commands

```sh
export CONTINUUM_PROJECT_ROOT="<QA_PROJECT_ROOT>"
export CONTINUUM_APP_SUPPORT="<QA_APP_SUPPORT>"
export TMUX_TMPDIR="<QA_TMUX_TMPDIR>"
unset TMUX TMUX_PANE
swift build
swift run ContinuumRevivedCoreChecks
.build/debug/Array --workspace-switch-check
.build/debug/Array --workspace-boot-persistence-check
.build/debug/Array --ui-probe-check
.build/debug/Array --ui-pixel-check
.build/debug/Array --perf-budget-camera-slope-check
.build/debug/Array --perf-budget-raster-check
.build/debug/Array --canvas-background-check
scripts/check-color-hygiene.sh
scripts/check-matrix-inventory.sh
```

The lead must aggregate the focused configuration, render-transform, persistence, settings, and background-performance witnesses under exact production flag `--canvas-background-check` and register it in the matrix. Reviewer/tester dispatch is gated on the candidate containing it; both run it directly and prove its matrix invocation. Enumerate current flags before the lead first invokes it. Run display-dependent screenshot checks in a supervised WindowServer session and retain candidates/diffs without global baseline updates.

### Stop rules

Stop if persistence would store an unmanaged arbitrary path, if image access requires a security/privacy choice outside the packet, if workspace schema changes conflict with the promoted WS2 model, or if rendering needs per-element views/layers. Do not add gradients/blur/animation or “smart” recoloring beyond the agreed scope.

### Success

Global/inherit/override semantics are exact, settings are usable, images and grids occupy the correct coordinate spaces, all state survives restart/switch, failure is safe, camera cost is bounded, and root can inspect the complete visual matrix.

## Independent reviewer overlay

Audit configuration precedence, migration/defaulting, channel-local managed asset storage, failure cleanup, off-main decode, cache invalidation, world/screen transforms, negative/fractional coordinates, adaptive stride hysteresis, token census, and accessibility. Search for per-grid layers, camera-time decode/allocation, tile-tree layout triggers, arbitrary path persistence, and accidental custom-color rewriting.

## Independent tester overlay

Use every preset/scope/color/image/opacity/Fill/Fit state through the real Settings UI, pan/zoom/return, switch A → B → A, and cold relaunch. Pixel-sample and compare screen-fixed image/world grid phase, inspect Aqua/Dark Retina screenshots, and run performance counters. FAIL on wrong precedence, persistence loss, more than 1 px anchoring drift, decode during camera movement, unbounded primitives, missing fallback, or unusable controls/contrast.
