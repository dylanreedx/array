# Agent-UI component framework — build & own the agent tile, desktop + mobile

**Phase 7 · ticket 87 · started 2026-07-22**

## Why

A user must not interact with an agent through a terminal tile. Nyx (our closest
twin) renders agents as raw PTY/TUI tiles — which is exactly why Nyx is desktop-only
(a terminal can't meaningfully go to a phone). Happy and T3 Code both consume the
agent's *structured* stream and render their own native UI. We do the same, but across
desktop AND mobile from one codebase. This ticket is the UI half; the feed half (the
provider adapter over Pi/GPT-5.6 first, Claude Code second) is ticket 88.

## The framework (proven by the StatusChip reference slice)

**Build once, render twice — share the presentation model, not the view.**

```
AgentStatus / agent events
      │
      ▼
StatusChipPresenter (pure, in ContinuumRevivedCore/AgentUI)   ← the building block
  → StatusChipDisplay { label, glyph, foreground, background } ← platform-neutral
      │                                   │
      ▼                                   ▼
StatusChipNSView (AppKit, Mac)     StatusChipView (SwiftUI, iOS)   ← thin, no logic
```

The presentation model is a **pure `(state) → display model`** function with **no
AppKit/UIKit import**, so it compiles into both apps through the SPM package the iOS
app already consumes (`ContinuumRevivedCore`). Each platform ships a dumb view that
only paints the display model.

**Two-layer testing — only one layer is red-green:**

- **Layer 1 — presentation model: deterministic `*Checks`, matrix-gated (real TDD).**
  Totality (every state maps), content (labels/glyphs present), **WCAG contrast**
  (every fg/bg pair ≥ 4.5:1), distinctness. Written red-first. This is the per-component
  test suite. See `Sources/ContinuumRevivedCoreChecks/StatusChipChecks.swift`.
- **Layer 2 — pixels: vision-QA *review*, NOT red-green.** Render every state in the
  Component Lab ("Agent UI" category), screenshot, a vision agent scores against a
  rubric (contrast, alignment/spacing, truncation-not-clipping, legibility, intent).
  Probabilistic — it complements Layer 1, never replaces it. Do not chase "TDD the
  pixels."

The contrast bug that motivated this (black text on a dark-blue managed-tile fill) is
now caught **deterministically**: `StatusChipChecks` asserts every chip pair ≥ 4.5:1,
anchors the metric (white/black ≈ 21:1), and pins the original bad pairing as a
regression witness that must FAIL the metric.

## Watch-outs (learned building the reference slice)

1. **No AppKit/UIKit in the shared module.** It must compile for iOS. `ChipColor` is a
   neutral sRGB struct; views convert (`NSColor(srgbRed:…)` / `Color(.sRGB, …)`). Use
   **sRGB explicitly** — deviceRGB/generic drifts the rendered colour off the tested
   luminance.
2. **Explicit foreground + background, never system semantic colours or colour-by-name.**
   That is precisely what makes contrast *ownable and testable*. The old bug came from
   ad-hoc per-view `NSColor` pairings with no one checking the pair.
3. **No `default:` in the status switch.** Exhaustive over `AgentStatus` → adding a
   status is a compile error until mapped, and the totality check iterates `allCases`.
   Keep it exhaustive.
4. **Consolidation debt (follow-up, not done here to stay surgical):** status→colour/
   glyph is currently duplicated in `WorkspaceSidebarView` (`color(for:)`),
   `ComponentLab` (`color(for:)` ~line 905), and `ManagedAgentTileNSView`. Migrate all
   three to `StatusChipPresenter` and delete the duplicates, or this rots back into the
   same inconsistency. Tracked as a cleanup task.
5. **Placement is temporary.** Presentation lives in `ContinuumRevivedCore/AgentUI/` for
   now to avoid new-module wiring before the loop was proven. At ~3+ shared components,
   extract to a dedicated `ContinuumRevivedAgentUI` module — cost: new SPM target + a
   `*Checks` target + iOS `project.yml` product dependency + `xcodegen generate`.
6. **iOS Component Lab does not exist yet.** Layer-2 vision QA currently runs on the Mac
   Lab only; the shared model is proven to compile/link on iOS but iOS pixel QA is owed
   (a SwiftUI preview gallery or a sim screen). Until then, iOS chips inherit the
   Mac's Layer-2 result only as far as the shared model guarantees (colours/labels), not
   layout.
7. **Glyphs are unicode (◐●○◆✓◌), matching the sidebar** — they render identically as
   text on AppKit and SwiftUI. If a component needs SF Symbols later, both platforms
   support them, but keep the choice in the presenter, not the view.

## Component roadmap (each = shared presenter + `*Checks` + MacView + iOSView + Lab card)

- [x] **StatusChip** — reference slice (this ticket)
- [ ] TurnRow (user/assistant, markdown, streaming delta)
- [ ] ToolCallRow (collapsed/expanded, I5-sanitized arg summary, result/status)
- [ ] ApprovalCard (inline approve/deny → existing approval round-trip)
- [ ] StreamingIndicator / ThinkingState
- [ ] ComposeBox (text → structured user message)
- [ ] TileHeader (provider badge, elapsed)
- [ ] TranscriptTimeline (ordering, autoscroll/anchoring)

## Verification

- Layer 1: `ContinuumRevivedCoreChecks → runStatusChipChecks` in `run-matrix.sh`.
- Layer 2: Component Lab → "Agent UI" → "Status Chip" card; plus a headless snapshot
  primitive for automated vision QA:
  `CONTINUUM_COMPONENT_SNAPSHOT=status-chips CONTINUUM_SNAPSHOT_OUT=<path> continuum-revived`
  renders the gallery to PNG (dark backing matching the tile) and exits — no boot
  machinery. StatusChip vision-QA'd 2026-07-22: all six pass (contrast, no clipping,
  distinct hues+glyphs, reads as native badges).
- Cross-platform: Mac `swift build` + iOS `xcodebuild` both compile the shared presenter.
