# Transcript links, surfaced subagents, and contextual lineage

Status: implementation complete and ready for isolated feel testing on
`array/transcript-ux`.

This ledger records the release slice that will be evaluated in the isolated
`~/Desktop/Array Transcript.app`. It intentionally combines the transcript
renovation already in this worktree with three user-visible seams that must be
credible before release: opening transcript links as Array browser tiles,
surfacing delegated Claude and Codex agents as real transcript children, and
making the focused parent/child relationship legible on the canvas.

## Product contract

### Transcript web links

- A normal click on an `http` or `https` link in an agent transcript creates a
  new Array browser tile. It does not reuse an existing browser tile.
- The browser tile belongs to the source agent tile's zone and is placed beside
  that tile. Placement, sibling ordering, z-index, persistence, and zone
  membership must all use that same resolved zone.
- Command-click opens the link in the system browser. The context menu exposes
  both destinations.
- Existing local-file, `continuum:` and rejected-scheme behavior remains intact.

### Delegated-agent affordance

- A delegated agent is represented by a content-sized outlined capsule, not a
  full-width button or filled row.
- The capsule centres a real agent glyph and its label as one group. Live
  working/attention/failure state may tint the glyph, boundary, and a very faint
  resting wash; a ready child remains neutral.
- Only the capsule is clickable. Its label and live status remain readable,
  keyboard focusable, and accessible; hover/press states are subtle and
  token-driven.
- Clicking resolves the current child agent and focuses/reveals its tile. A
  stale or unavailable child produces the existing failure affordance instead
  of silently consuming the click.

### Codex subagents

- Codex app-server is the default backend because its event stream carries
  structured `subAgentActivity` identities. `CONTINUUM_CODEX_TRANSPORT=exec`
  remains the explicit emergency escape hatch.
- App-server startup may fall back to exec only before a turn has been accepted;
  after `turn/start`, replaying the prompt is forbidden because it could repeat
  side effects.
- Provider thread identities are mapped to Array agent identities for the run.
  The primary Codex thread maps to the root tile. A structured child announcement
  adopts a read-only child under the provider parent; later child events route to
  that child. The mapping supports nested descendants, not only first-level
  delegation.
- Parent turn completion is not sufficient to tear down the app-server while
  known child activity is still live. Late child output and terminal events must
  be drained so surfaced child transcripts are not truncated.

### Contextual lineage

- Focusing a parent shows a bounded fan to its visible direct children. Focusing
  a child shows the visible direct-child fan for that child's parent. Unrelated
  focus clears the contextual lineage.
- The fan uses the inbox visibility bound (`InboxSort.maxVisibleChildren`, eight
  today). Durable document relationship connectors keep their existing layer.
- Contextual lineage renders in a dedicated click-through screen-space overlay
  above canvas tiles and below focus, attention, and HUD overlays. This avoids
  disappearing beneath opaque tiles without allowing the connector to obscure
  focus feedback or intercept input.
- All visible edges share one compound path and one dash-phase animation. A
  restrained accent dashed stroke uses the same `[6, 4]` marching rhythm as the
  focus border without an outline/halo. Arrowheads are
  static and align to the final Bezier tangent.
- Geometry updates occur only when focus, relevant tile geometry, or camera
  geometry changes, with implicit Core Animation actions disabled. Animation is
  attached once and is not restarted by camera commits.
- The animation runs only while the canvas is active, visible, unoccluded, and
  Reduce Motion is disabled. Otherwise the connector remains as a static dashed
  relationship. Cleared or wholly offscreen routes detach.

## Measured baseline

- `RichInlineTextView` already classifies web links and emits
  `AgentRenderAction.activateLink`, but `ManagedAgentTileNSView` currently drops
  that action. App-level wiring exists only for local files and child reveal.
- `TileSpawner.spawnBrowser(url:at:)` accepts a world point but derives its zone
  from ambient creation scope. The link path therefore needs an explicit
  source-zone placement contract rather than temporarily arming a zone.
- `AgentReferenceChipView` already has recovered hover, press, accessibility,
  pointer, and live-status work; its button still occupies the full row.
- `CodexAgentRunner` contains an app-server backend, but exec is still the
  default, app-server translation intentionally ignores subagent items, and the
  process is torn down when the parent turn returns. The captured
  `codex-appserver-delegating-turn.jsonl` fixture proves a child can finish after
  its parent.
- `AgentLineageOverlayView` currently draws a low-alpha world-plane path below
  tiles. `revealAgentFromInbox` is its only product trigger. Focus changes flow
  through `installAcceptedTileFocusHook`, which is the authoritative integration
  seam.
- `FocusBorderOverlayView` is the performance reference: one shape layer, one
  reusable dash-phase animation, disabled implicit geometry actions, occlusion
  suspension, and live Reduce Motion handling. Prior measurements found a
  material WindowServer cost when infinite animations remain active offscreen.

## Implementation seams

1. Carry a web-link activation from `ManagedAgentTileNSView` to `ContinuumApp`,
   preserving modifier intent, and add a source-zone browser-spawn API.
2. Wrap the delegated-agent button in a row renderer whose capsule computes its
   intrinsic width and owns the sole hit target.
3. Replace the contextual lineage painter with a screen-space compound-layer
   overlay and drive it from accepted tile focus plus existing canvas lifecycle
   notifications.
4. Promote Codex app-server, translate structured child announcements/events,
   maintain provider-thread routing in `AgentSupervisor`, and drain live child
   work after parent completion.

## Witnesses and release gate

- Transcript link witness: normal click creates one browser tile in the source
  zone beside the agent; repeated clicks create distinct tiles; command-click
  selects the external-open seam; unsafe schemes remain inert.
- Delegated chip witness: intrinsic-width outline, row background does not click,
  hover/press/focus/accessibility states, live status, successful reveal, and
  unavailable-child failure.
- Codex backend witness: default/override selection, captured parent-before-child
  fixture, adoption and nested routing, late child terminal drain, interrupt, and
  no post-acceptance fallback.
- Lineage witness: parent/child/unrelated focus policy, eight-edge bound, route
  geometry under pan/zoom, overlay ordering and nil hit-test, one animation for a
  fan, no restart on geometry updates, Reduce Motion/static behavior, and
  inactive/occluded suspension.
- Run focused checks first, then
  `CONTINUUM_SKIP_UI_BASELINES=1 scripts/run-matrix.sh`.
- Build and launch only the isolated release target:
  `DEV_APP_PATH="$HOME/Desktop/Array Transcript.app"`
  `DEV_PROJECT_ROOT="$HOME/array-scratch-transcript"`
  `scripts/dev-app.sh --release`.
- Never install or overwrite `/Applications/Array.app` from this worktree.

## Completion record

Completed 2026-08-26. The product contracts above landed as one release slice:

- transcript `http`/`https` links now create distinct Array browser tiles beside
  the source agent and in its resolved zone; Command-click and the context menu
  preserve an explicit system-browser path;
- delegated-agent references now render as content-sized outlined capsules whose
  row background is inert;
- Codex app-server is the default transport, structured provider child and
  grandchild identities become observed-only Array agents, descendant output is
  isolated to the correct transcript, and the runner drains children that finish
  after the parent turn;
- focusing either side of an agent relationship displays the parent's bounded
  direct-child fan in a click-through screen-space overlay above tiles. The fan
  uses one compound Core Animation path and one restrained marching-ants animation, with
  static fallback for Reduce Motion and suspension while inactive, occluded, or
  offscreen.

Focused verification passed:

```text
swift build
.build/debug/ContinuumRevivedCoreChecks --codex-agent-backend-check
.build/debug/ContinuumRevivedCoreChecks --codex-appserver-parity-check
.build/debug/ContinuumRevivedCoreChecks --codex-appserver-runner-check
.build/debug/Array --agent-supervisor-check
.build/debug/Array --relationship-geometry-check
.build/debug/Array --agent-first-paint-check
.build/debug/Array --local-file-open-check
scripts/check-matrix-inventory.sh
git diff --check
```

The browser witness includes two successive normal clicks creating two browser
tiles in the source zone, plus the separate system-open target. The delegated
chip witness uses a captured two-child Claude fixture and covers geometry,
hit-testing, hover, reveal, and loud reveal failure. The Codex witnesses use a
captured delegating app-server stream plus deterministic runner and supervisor
fixtures, including root → child → grandchild routing and a child that completes
after its parent. The lineage witness covers pan/zoom endpoints, a 16-child input
bounded to eight visible edges, a maximum of one animation, click-through, and
Reduce Motion behavior.

The release matrix was run as:

```text
CONTINUUM_SKIP_UI_BASELINES=1 scripts/run-matrix.sh
```

All 181 legs ran and the matrix passed. The four expected known-red performance
probes were `--nav-mode-check`, `--perf-budget-zoom-check`,
`--canvas-zoom-invalidation-probe-check`, and
`--perf-budget-magnify-slope-check`. The allowlisted, known-flaky
`--perf-budget-gesture-transition-check` passed on this run; that single
observation does not justify removing its documented allowlist entry. UI image
baseline comparisons were intentionally skipped by the command, while the live
geometry, appearance, interaction, accessibility, screenshot-generation, bundle,
codesign, inventory, strict-harness, root-doc, and whitespace legs all ran.

An earlier full run exposed no product regression but did catch a stale strict
harness contract: the recovered Pi surface now includes `wait_agents`. Updating
that expected tool list and regenerating the 384-record matrix inventory made the
strict witness and inventory check pass before the clean 181-leg run above.

Remaining release risk is deliberately narrow: provider behavior is proven with
captured and deterministic app-server streams, not a live network delegation;
and the interaction/visual feel still needs Dylan's supervised pass in the
isolated app. No production install is authorized. The feel-test bundle is
`~/Desktop/Array Transcript.app`, backed by
`~/array-scratch-transcript`; `/Applications/Array.app` must remain untouched.

### Feel-test correction, 2026-08-26

The first live visual pass found two presentation misses that structural checks
could not judge. Delegated controls looked like cramped anonymous text pills, so
they now use a guaranteed `person.2` fallback glyph, centre the icon/title pair,
use a 26-point rounded-rectangle control with balanced padding, and apply a faint
semantic state wash plus state-tinted icon/border. The lineage overlay's
five-point canvas halo read as a black outline in the dark theme; because the
overlay already owns visibility priority above tiles, the halo was removed and
the remaining accent stroke softened to 1.25 points at 62% opacity.

The second live pass exposed why merely setting `NSButton.alignment = .center`
was insufficient: `NSButtonCell` allocated the leading image and centred title
in separate regions, leaving a large gap inside the capsule. The chip now owns
explicit 14-point glyph and label subviews, holds a four-point gap, and centres
their measured union. Its row derives its leading inset so the label lands on
`ToolCallView.detailIndent`, the transcript's existing action-title reading
column. This renderer is downstream of the provider-neutral `agentReference`
block, so Pi, Codex, and Claude use identical geometry.

The Codex screenshot then exposed a second AppKit-cell mistake: the explicit
label was correct, but `NSButtonCell` could still paint its own title underneath,
creating two overlapping text layers. The button cell is now permanently empty
and its drawing is suppressed; it remains only as the action/keyboard/AX host.
The geometry witness asserts the empty-cell contract, and
`CONTINUUM_AGENT_REFERENCE_CAPTURE=<png>` on `--agent-first-paint-check` emits a
real rendered row for visual inspection.

### Integration and release, 2026-08-26

The transcript branch was committed as `486d156b` and merged into
`array/integration` as `e65c4099`, on top of the agent-awareness sound work.
The shared seams intentionally retain both contracts: tile focus acknowledges
the sound signal and refreshes contextual lineage; Claude launches request both
hook events and forwarded subagent text; Pi translation retains both semantic
signal indexing and streamed-text state; and Codex app-server launches retain
the explicit `approval_policy=never` and `sandbox_mode=workspace-write` policy.

The merged focused suite passed CoreChecks, AgentSupervisor, agent awareness,
agent first paint, relationship geometry, Codex backend/app-server parity and
runner checks, the 387-record inventory, and whitespace validation. The release
matrix then passed all 182 legs with the four documented known-red probes:
`--nav-mode-check`, `--perf-budget-zoom-check`,
`--canvas-zoom-invalidation-probe-check`, and
`--perf-budget-magnify-slope-check`. The allowlisted gesture-transition probe
passed. Display-dependent image baselines were deliberately skipped; live
appearance, geometry, contrast, pixel, accessibility and screenshot-generation
checks ran.

Array 0.5.12 (build 37) was built from the merged integration branch. The app
and DMG were Developer ID signed, accepted by Apple's notarization service,
stapled, and accepted by Gatekeeper. Both `Array.dmg` and
`Array-0.5.12.dmg` were published on GitHub, and the signed 35-item Sparkle
appcast was regenerated for the website.
