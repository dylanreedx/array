# WS5 dispatch — temporary browser-style managed-agent page zoom

## Shared workstream target

This packet defines **WS5: temporary per-managed-agent-tile page zoom** in Array. Begin from the I2A performance/awareness checkpoint at `<BASE_SHA>`; WS3 is already promoted, so its measurement/cache ownership and five remediated performance gates are binding regressions. The rendered `<ROLE>` controls authority: a lead implements; a reviewer or tester evaluates the same locked target under only its selected overlay.

The fully rendered common protocol prepended to this dispatch is binding. The checked-in `00-agent-protocol.md` is an unresolved reference template and never overrides rendered values.

Read `<WORKTREE>/AGENTS.md`, the master plan, `00-agent-protocol.md`, and current managed-agent layout/measurement checks. Work only in `<WORKTREE>` and place evidence in `<EVIDENCE_DIR>`.

### Outcome

Implement traditional browser-like page zoom for a focused managed-agent tile:

- `⌘+`/`⌘=` zoom in, `⌘-` zoom out, and `⌘0` reset, plus discoverable title-bar/context menu commands with current percentage and disabled end stops.
- Supported steps: 80%, 90%, 100%, 110%, 125%, 150%.
- State is per tile/runtime and temporary. It does not persist to `TileMetadata`, workspace JSON, project canvas state, or global defaults; a recreated tile begins at 100%.
- Scale **all inner content** crisply—transcript, status row, composer text, attachment/option rails, buttons, labels, icons, padding, and applicable controls.
- Keep the outer title bar, resize chrome, tile world frame, zone membership, and canvas camera completely unchanged.
- Reflow at the new metrics. Do not bitmap-scale the subtree or use scroll-view magnification if it blurs text, breaks hit testing, or creates horizontal scrolling instead of reflow.
- Preserve semantic scroll anchor, selection/copy, tool disclosure state, composer contents/focus, tail-following, accessibility, and minimum usable hit targets.
- Two agent tiles can hold different zoom levels without cross-tile bleed.

### Existing seam

Canvas zoom is camera-level and is the wrong feature. Managed-agent content has no production scale today, although transcript measurement identity already has scale-bucket seams in the content-size policy/render context. Use or generalize those seams so every measurement cache is keyed correctly and a scale change invalidates exactly once.

### Inspect first

- `Sources/ContinuumRevivedCore/CanvasState.swift` to prove no persistence change is needed
- `Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift`
- `Sources/ContinuumRevived/Canvas/AgentTile/`
- `Sources/ContinuumRevived/Canvas/AgentActivity/`
- `Sources/ContinuumRevived/Canvas/AgentComposer/`
- `Sources/ContinuumRevived/Canvas/AgentTranscript/`
- `Sources/ContinuumRevived/Canvas/AgentTranscript/AgentBlockRenderer.swift`
- transcript measurement/cache/anchor/tail-following code
- key routing/menu code for managed-agent tiles and existing canvas zoom
- AgentUI metrics/tokens and relevant UIProbe/Component Lab checks

### Owned scope

Own a new transient zoom policy/controller, managed-agent inner layout seams, and focused tests. You have a narrow grant in `ManagedAgentTileNSView` and managed-agent action routing. Any transcript measurement/cache hunk requires the exact dispatch grant and must preserve WS3's counters/budgets. Do not alter `TileNSView` outer geometry, canvas zoom, generic terminal/browser tiles, persisted metadata/schema, transcript semantics, or background rendering.

### Required witnesses

1. Pure scale policy: step up/down/reset, clamping, invalid input, per-tile isolation, and default-after-recreation.
2. Action routing: shortcuts affect only the focused managed-agent tile, do not fire while an editable control consumes an unrelated chord, and never alter canvas camera zoom.
3. AppKit geometry at all six steps, repeated 10 times on two tiles:
   - outer tile and title-bar frames exact and pixel-identical;
   - inner font/metric/control geometry follows the effective scale within 1 px;
   - hit regions align with visuals and remain usable;
   - no horizontal clipping at 150% in `360×480` and `560×620` tiles.
4. Cache/invalidation teeth: one scale change invalidates measurements once; steady layout at the same scale performs zero repeated measurement attributable to zoom; cache entries for distinct scale buckets cannot alias.
5. Mid-session anchor preservation at a named message, selection/copy, folded/expanded tools, composer text and focus, queued/file/image/reply rails, active streaming with tail-follow on/off, and accessibility tree stability.
6. Recreation/relaunch evidence proves the temporary value is not serialized and returns to 100%.
7. Geometry neutrality: no zone auto-layout transaction, tile persistence write, or tile/zone frame mutation occurs.

Use a deterministic transcript containing headings, prose, list, table, long token, code, tool output, diff, image placeholder, failure, composer text, and attachment/choice rails. Capture every scale in Aqua/Dark Aqua at fixed tile sizes; also combine tile content zoom 80/100/150% with canvas zoom 0.50/1.00/1.50 to prove the boundaries do not multiply incorrectly. Semantic artifacts include outer/title/inner frames, font metrics, effective scale, anchor ID/offset, cache counts, hit targets, and persistence diff.

### Required commands

```sh
export CONTINUUM_PROJECT_ROOT="<QA_PROJECT_ROOT>"
export CONTINUUM_APP_SUPPORT="<QA_APP_SUPPORT>"
export TMUX_TMPDIR="<QA_TMUX_TMPDIR>"
unset TMUX TMUX_PANE
swift build
swift run ContinuumRevivedAgentContentChecks
swift run ContinuumRevivedAgentUIChecks
.build/debug/Array --transcript-rhythm-check
.build/debug/Array --perf-budget-transcript-delta-check
.build/debug/Array --canvas-zoom-invalidation-probe-check
.build/debug/Array --managed-agent-page-zoom-check
swift build -c release
swift run -c release ContinuumRevivedPerfChecks
.build/release/Array --perf-budget-zoom-check
.build/release/Array --canvas-zoom-invalidation-probe-check
.build/release/Array --perf-budget-magnify-slope-check
.build/release/Array --perf-budget-gesture-transition-check
.build/release/Array --tile-surface-residency-check
.build/release/Array --perf-power-user-compound-check
CONTINUUM_PERF_CONFIGURATION=release \
CONTINUUM_PERF_APP="<WORKTREE>/.build/release/Array" \
CONTINUUM_PERF_OUT="<EVIDENCE_DIR>/perf-remeasure" \
CONTINUUM_PERF_RUN_ID="<RUN_ID>-ws5" \
scripts/run-perf-ceilings.sh
scripts/check-matrix-inventory.sh
```

The six direct release-binary legs above plus the release-configured runner are the mandatory complete WS3 remeasure; retain each raw output and binary hash. The compound leg uses WS3's promoted deterministic corpus/seed contract. The lead must add the page-zoom production witness under exact flag `--managed-agent-page-zoom-check`, add the Component Lab/UIProbe surface, and register the matrix leg. Reviewer/tester dispatch is gated on the candidate containing it; both run it directly and prove its matrix invocation. Enumerate the current flag inventory before the lead first invokes the new flag.

### Stop rules

Stop if the only viable implementation is a blurry raster transform, if inner scaling requires persisting state, if shortcut ownership conflicts materially with a shipped command, or if a shared AgentUI token change would resize unrelated surfaces. Do not broaden the feature to terminals, browser tiles, global text size, or canvas zoom.

### Success

The focused tile behaves like page zoom, all inner content scales and reflows crisply, outer chrome/geometry is invariant, state remains temporary/per-tile, interaction/accessibility/anchors survive, deterministic screenshots prove every boundary, and the complete WS3 release performance matrix remains green after the cache/layout changes.

## Independent reviewer overlay

Audit the scale boundary and every cache key. Search for global/static zoom state, persisted metadata, layer transforms, `NSScrollView` magnification, double-scaling under canvas zoom, unscaled composer/status subviews, stale hit testing, and repeated measurement. Verify shortcut routing and menu discoverability without hijacking generic canvas/browser behavior.

## Independent tester overlay

Use real shortcuts and menu actions on two agent tiles at 80/90/100/110/125/150%, with canvas zoom combinations. Measure outer/title/inner frames, hit targets, anchor offset, selection/composer state, accessibility, and recreation reset; inspect Aqua/Dark screenshots. FAIL on cross-tile bleed, persistence, outer geometry/title change, clipping, blur, anchor jump over 2 px, wrong shortcut target, or steady repeated measurement.
