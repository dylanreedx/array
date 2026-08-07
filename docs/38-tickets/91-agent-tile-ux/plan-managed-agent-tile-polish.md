# Managed Agent Tile — Conversation, Media, Activity, and Chrome Plan

**Status:** Product/implementation plan · review before implementation
**Repository:** `/Users/dylan/Documents/personal/Array`
**Primary surface:** Live managed-agent tile
**Queue safety:** This document does not resume Queue 91. `STOP` and the paused handoff remain authoritative until Dylan explicitly starts implementation.

## 1. Objective

Make the managed-agent tile feel like a native conversation surface rather than a thin terminal transcript:

- Paste, send, render, and preview images without an arbitrary attachment-count limit.
- Render streamed Markdown correctly while preserving Markdown when users copy selected response text.
- Show a smooth, recognizable thinking/activity indicator and preserve provider reasoning as a quiet disclosure when available.
- Make tool activity compact by default and useful when expanded.
- Move location/activity/context status beneath the composer and above model/effort controls.
- Remove inert footer copy, prevent effort labels from truncating when space exists, and show truthful context-window usage.
- Replace literal `Home` / `Where` / `What` category labels with icons while retaining accessible names and tooltips.
- Replace the tile’s competing dot/ellipsis affordances with one clear overflow owner.

The result should remain provider-neutral above the adapter boundary, local-first, keyboard accessible, themeable, and stable under streaming updates.

## 2. Definition of done

A release satisfies this plan when all of the following are observable on the real managed-agent route:

1. Pasting or dropping images creates visible composer attachments; sending them reaches Pi as image input and the sent user turn renders those images.
2. There is no product-level image-count cap. Large sets remain responsive through disk-backed originals, bounded thumbnail decoding, and lazy rendering.
3. A live response containing Markdown never exposes completed syntax such as `**bold**` as literal delimiters unless it is inside code.
4. Highlighting rendered prose and copying places Markdown syntax on the public string pasteboard type, so a GitHub text field receives Markdown rather than stripped text.
5. The only active animation is a small compositor-driven activity indicator in the status row beneath the input. Completed reasoning becomes a static, collapsed transcript disclosure when reasoning content exists.
6. Tool rows are one-line summaries by default. Expanding them reflows the collection row and reveals sanitized local arguments, output, timing, and failure detail.
7. The status row appears directly beneath the input and directly above the model/effort/action row.
8. The inert `Next turn`/reported “text turn” label is gone.
9. The selected effort title does not truncate when its measured intrinsic width fits. The real 320, 480, and 560 point tile paths are covered.
10. Context usage displays only from authoritative used/max values; unknown data is visibly unknown rather than represented as a false percentage.
11. Location and current activity use icons instead of visible `Home`, `Where`, and `What` prefixes.
12. One outer tile overflow button owns infrequent agent, location, and tile actions; duplicate inner overflow buttons are removed.
13. Reduced Motion, VoiceOver, keyboard navigation, selection, copy, light/dark appearance, and long-session performance are verified.

## 3. Current production facts

### 3.1 Images

- `ComposerTextView` explicitly sets `isRichText = false` and `importsGraphics = false`.
- `AgentComposerDraft`, `AgentTileInput.send`, `ManagedAgentTileNSView.onSubmitPrompt`, and the current Pi send boundary carry text only.
- Merely enabling TextKit graphics import would place opaque attachments in text storage without giving the provider a usable prompt contract.
- The current Pi print transport accepts image references through `@path`; Pi RPC supports structured image data. The UI should not depend on either representation.
- The semantic transcript currently has no built-in image block/renderer.

### 3.2 Markdown

- Queue 91 added `MarkdownAgentMarkupParser`, `StreamingMarkupBuffer`, semantic inline runs, and rich AppKit renderers.
- The live `AgentTranscriptProjection`/reducer path still appends streamed response deltas as plain text runs.
- Rich renderers consume semantic runs; they do not parse provider strings themselves. Literal Markdown in a live response is therefore an upstream projection defect.

### 3.3 Copy

- `RichInlineTextView.copy(_:)` currently writes rendered plain text to `.string` and reconstructed Markdown only to `net.daringfireball.markdown`.
- Browser text fields and many notes/PR editors request `.string`, so they receive stripped text despite the custom Markdown flavor being present.
- Whole-block copy already has semantic Markdown serialization machinery in `AgentTranscriptCopyController`.

### 3.4 Reasoning and tools

- `PiEventTranslator` maps Pi `thinking_delta` events to `.contentDelta(... streamKind: .reasoning ...)`.
- Reasoning prose currently resolves through the ordinary prose renderer rather than a reasoning-specific activity/disclosure presentation.
- `PiEventTranslator` intentionally drops raw tool arguments and result bodies from `AgentRuntimeEvent` to protect the I5 sync boundary.
- `AgentToolCallPayload` and `AgentCommandOutputPayload` can represent richer local presentation, but the live projection usually receives only a tool name and completion status.
- `ManagedAgentTileNSView.v2RenderContext` does not currently bind the existing `DisclosureStateStore`; an expanded row can fail to receive the measured-height invalidation it needs.

### 3.5 Footer/status composition

The production composition in `ManagedAgentTileNSView.makeV2ContentView()` is currently:

1. Agent header
2. `AgentLocationStatusView`
3. Transcript
4. Composer
5. Footer row containing `AgentComposerFooterView` and the primary action

`AgentComposerFooterView` contains an inert `contextLabel` whose value is `Next turn`, followed by model and effort controls. It has measured-fit logic intended to avoid truncation, but the selected effort title has regressed on the real tile despite available width. This means the existing deterministic checks do not fully witness production stack allocation/invalidation.

### 3.6 Context usage

- `TokenUsageSnapshot` currently carries input tokens, output tokens, and optional total cost; it does not carry context used, maximum context, percentage, cache usage, or freshness.
- Real Pi `message_end`/`turn_end` payloads include usage and cost, but the current translator does not emit token-usage events from those lines.
- Queue 90’s `P5.8-session-stats-cost.md` already records the intent to parse message usage and obtain exact context data from `get_session_stats`; this plan reuses that arithmetic intent but places the meter in the bottom status row rather than the header.

### 3.7 Overflow ownership

The tile currently exposes several visually similar affordances:

- Outer title-bar drag dots that look like a menu.
- An agent-header ellipsis menu.
- A location-row action menu.
- A working-state action whose ellipsis-like glyph adds more ambiguity.

The outer `TileNSView` already has the `makeAdditionalTitleBarMenuItems()` extension seam used by other tile kinds.

## 4. Target managed-agent layout

The tile should use this vertical structure:

1. **Tile title bar:** agent identity, one overflow button, close/detach affordance.
2. **Transcript:** user prompts, images, assistant Markdown, reasoning disclosures, tool rows, artifacts.
3. **Composer attachment rail:** visible only when draft attachments exist.
4. **Composer input:** growing text editor and direct send/stop action.
5. **Status row:** location, live activity/throbber, and context-window meter.
6. **Provider row:** model dropdown, effort dropdown, flexible spacer, primary action when it is not already integrated with the input.

The existing top `AgentLocationStatusView` should move into the compose chrome rather than being duplicated. There should be only one animated activity affordance.

### 4.1 Status row

The status row sits **under the input and above the model/effort dropdowns**.

Suggested full-width state:

```text
[folder] Array/.worktrees/fix-markdown     [animated] Thinking · 7s     [ring] 62%
```

Suggested idle state:

```text
[house] Array                              [check] Ready                 [ring] 18%
```

Rules:

- Left: location icon plus a concise project-relative path. Hover reveals the absolute local path.
- Center: current operation (`Reading…`, `Searching…`, `Running…`, `Thinking…`, `Responding…`) with elapsed time when useful.
- Right: context ring and numeric percentage when authoritative.
- At narrow widths, the location text truncates first. Activity and context icons remain visible.
- Visible prefixes `Home`, `Where`, and `What` disappear. Accessibility labels and tooltips retain those words.
- The row uses quiet chrome styling and no permanent card outline.

Suggested icon mapping:

| Meaning | SF Symbol / source |
|---|---|
| Agent home | `house` |
| Working directory | `folder` |
| Outside home | `arrow.up.right` |
| Reading | `doc.text.magnifyingglass` |
| Searching | `magnifyingglass` |
| Editing | `square.and.pencil` |
| Running | `terminal` |
| Waiting | `hourglass` |
| Ready/completed | `checkmark` |
| Failed | `exclamationmark.triangle` |
| Thinking/responding | Selected custom Array activity indicator |

### 4.2 Remove inert footer text

Delete the visible `Next turn`/“text turn” `contextLabel`. Model and effort controls already carry explicit accessibility labels (`Model, next turn` and `Reasoning effort, next turn`), so removing visual decoration loses no semantic information.

### 4.3 Effort control sizing

The effort control is short and semantically important. It must retain its selected title before the model control consumes space.

Layout policy:

1. Primary action: required intrinsic width.
2. Effort control: required compression resistance at its current measured fitting width.
3. Context meter/status icons: required compact width.
4. Model control: consumes remaining width and may use its existing provider-prefix abbreviation.
5. Location/activity text: truncate according to the status-row policy, not by compressing the effort control.
6. Flexible spacers are always the first compression sink.

Implementation must first reproduce the regression using real production stack frames. The existing comments claiming measured fit are not proof that AppKit is honoring those measurements after a selection change.

Required assertions:

- `titleLabel.frame.width >= measuredTitleWidth` whenever the control reports that the title fits.
- Re-run after changing effort, changing model, toggling working/ready action width, resizing the tile, and changing appearance.
- Exercise all configured effort values, especially `minimal`, `medium`, `high`, and `xhigh`/`X-high`.

## 5. Context-window meter

### 5.1 Presentation

Use a compact 18–20 point radial meter with a numeric percentage beside it. The ring is scannable; the percentage remains exact enough to read without hovering.

Hover/focus tooltip example:

```text
Context window
124,820 / 200,000 tokens · 62%
Input 8,431 · Output 1,204 · Cache read 92,110
Updated after the last assistant message
Automatic compaction available
```

States:

- **Known:** ring plus percentage.
- **Warning:** at a documented threshold, add a warning glyph/shape in addition to color.
- **Critical:** stronger warning treatment; do not rely on color alone.
- **Unknown:** hollow/dashed ring, no fabricated `0%`, tooltip explains which value is unavailable.
- **Stale:** retain the last value with a stale indication and timestamp.
- **After compaction:** animate no celebratory transition; simply update to the lower authoritative value.

### 5.2 Data contract

Do not derive a context percentage from `inputTokens + outputTokens` unless the provider explicitly defines that as current context occupancy. Introduce a provider-neutral snapshot that distinguishes per-message usage from context occupancy:

```swift
struct AgentContextWindowSnapshot: Codable, Equatable, Sendable {
    var usedTokens: Int?
    var maximumTokens: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var totalProcessedTokens: Int?
    var totalCostUSD: Double?
    var compactsAutomatically: Bool?
    var observedAt: Date
    var source: Source
}
```

The provider adapter owns source-specific parsing:

- Current Pi JSON mode: parse `message_end`/`turn_end.message.usage` for message/session totals.
- Pi RPC: prefer `get_session_stats.contextUsage` for authoritative used/max/percent.
- Model metadata may supply a maximum only when it is provider-authoritative and matches the active model.
- If used or maximum is missing, do not show a percentage.

Session aggregation must include nested tool-result usage where Pi reports it, or the displayed total will be knowingly low.

## 6. Image attachments

### 6.1 Product behavior

There is no arbitrary count limit. Resource protection should be based on actual work—disk availability, decode failures, provider rejection, and bounded in-memory thumbnails—not a small product constant.

Supported input:

- Paste image data from the macOS pasteboard.
- Drag image files into the composer.
- Optional attachment picker using the same ingestion path.
- Multiple paste/drop operations append to the draft.
- Image-only turns are valid.

Composer presentation:

- A horizontally scrollable, lazy attachment rail above the text editor.
- Aspect-preserving thumbnails with remove controls.
- Processing, ready, unsupported, and failed states per attachment.
- Keyboard navigation and accessible labels containing filename/type/dimensions when available.
- Full-resolution originals never remain resident merely because a thumbnail is visible.

Transcript presentation:

- User turns render an image gallery alongside text.
- Thumbnails preserve aspect ratio and load lazily.
- Images expose Copy Image, Save As, Reveal/Open, and Preview actions.
- Future assistant/tool-generated images reuse the same semantic image renderer.

### 6.2 Attachment contract

Keep media outside `NSTextStorage`:

```swift
struct AgentPrompt {
    var text: String
    var attachments: [AgentAttachment]
}

enum AgentAttachment {
    case image(AgentImageAttachment)
}

struct AgentImageAttachment {
    var id: UUID
    var localURL: URL
    var mediaType: String
    var pixelWidth: Int?
    var pixelHeight: Int?
    var byteCount: Int?
    var altText: String?
    var originalFilename: String?
}
```

Add a semantic image block/payload to `ContinuumRevivedAgentContent` instead of encoding image paths into prose.

### 6.3 Storage and lifecycle

- Copy pasted data into an Array-managed Application Support attachment store.
- Store metadata in the per-agent draft; do not serialize `NSImage`.
- Generate bounded thumbnails off the main actor and cache them separately from originals.
- Preserve draft files across tile detach/reopen and app relaunch.
- Delete abandoned attachment files when a draft removes them, subject to a short undo/grace period.
- Keep sent attachments for as long as their local transcript entry can reference them.
- Generate provider transport copies separately if downsampling or format conversion is required; preserve the original for preview/save.

### 6.4 Provider adapters

- Pi print adapter: materialize safe local files and pass `@path` image references without leaking those paths into visible prompt text.
- Pi RPC adapter: encode the same attachments as structured image input.
- Unsupported model/provider: reject visibly before destructive draft clearing when capability is known; if Pi rejects after send, restore/preserve the draft and display the provider error.

### 6.5 Large preview and image tile

Recommended two-level behavior:

1. **Quick Preview:** click/double-click a transcript thumbnail to open a native large preview using a focused AppKit/Quick Look surface. This is transient and does not mutate the canvas.
2. **Open as Tile:** an explicit action can create a persistent image tile on the canvas, useful for spatial reference during an agent conversation.

A persistent image tile is a larger scope than preview because it needs a new tile kind, workspace persistence, hydration/snapshot behavior, file-lifetime ownership, and missing-file recovery. It should not block image paste/render/Quick Preview. Whether `Open as Tile` belongs in the first implementation slice remains an open product decision.

Remote Markdown images must not silently issue network requests. Attachment-backed/local images render automatically; remote URLs require an explicit load action.

## 7. Markdown rendering and source-preserving copy

### 7.1 Live Markdown producer

Parse Markdown once at the provider-neutral projection boundary:

```text
provider text deltas
        ↓
StreamingMarkupBuffer (per entry/stream)
        ↓
MarkdownAgentMarkupParser
        ↓
AgentNodeIdentityReconciler
        ↓
AgentDocument blocks and inline runs
        ↓
existing AppKit renderers
```

Requirements:

- Buffer across delta boundaries; delimiters and code fences may split across events.
- Reconcile node identity so streaming does not replace every collection item.
- Avoid showing completed Markdown delimiters as literal text.
- Flush incomplete input safely on completion, interruption, failure, or translator reset.
- Ensure streamed prefixes converge to the same semantic document as parsing the final complete source once.
- Apply the same parser to reasoning streams.
- Preserve unsupported syntax as readable text with diagnostics rather than dropping it.

### 7.2 Copy contract

For rich response prose, **Markdown is the public copied string**:

- `.string`: Markdown with meaningful delimiters, links, list markers, headings, quotes, and fences.
- `net.daringfireball.markdown`: the same Markdown.
- Optional HTML/RTF flavor: rendered rich content for destinations such as Notion that prefer rich pasteboard types.
- Explicit “Copy as Plain Text” context-menu action may provide stripped rendered text when needed.

Selection behavior:

- Selecting an entire response or semantic block produces complete Markdown structure.
- Selecting a complete strong/emphasis/link run retains its delimiters/destination.
- Partial selections produce valid normalized Markdown rather than malformed fragments.
- Dedicated code-block Copy buttons continue to copy code only; whole-response copy wraps fenced blocks.
- Cross-block selection preserves blank lines and list structure.

`AgentTextStyleResolver` and `AgentTranscriptCopyController` already provide most semantic serialization. The important behavioral change is that `RichInlineTextView.copy(_:)` must no longer put stripped text in `.string` for response selection.

“Raw Markdown” in this plan means source-meaningful Markdown suitable for GitHub/notes, not a guarantee that every original whitespace choice or alternate delimiter spelling is byte-identical. If exact provider bytes become a requirement, retain per-entry source Markdown and a rendered-to-source selection map rather than reverse-engineering it from attributed text.

## 8. Thinking/activity presentation

### 8.1 Lifecycle

Use one active indicator in the bottom status row:

| Phase | Status-row copy | Transcript behavior |
|---|---|---|
| Send accepted, no provider event | `Starting…` | User prompt/attachments are already visible |
| Reasoning delta received | `Thinking · 7s` | Reasoning is accumulated but not expanded by default |
| Assistant text received | `Responding · 10s` | Assistant Markdown streams normally |
| Tool active | Tool-specific activity | Compact tool row updates in transcript |
| Turn complete with reasoning | `Ready` | Static collapsed `Thought for 12s` row remains |
| Turn complete without reasoning | `Ready` | No empty reasoning row |
| Failed/interrupted | Explicit failure/interruption | Preserve available reasoning/content and error |

Do not animate both the header and transcript. The bottom status row is the single live motion location; completed transcript disclosures are static.

### 8.2 AppKit implementation contract

All candidates should share a small AppKit contract:

```swift
@MainActor
protocol AgentThinkingIndicatorAnimating: AnyObject {
    func startAnimating()
    func stopAnimating()
    func setReducedMotion(_ enabled: Bool)
    func setSnapshotPhase(_ phase: CGFloat)
}
```

Implementation rules:

- Layer-backed `NSView` using Core Animation.
- No `Timer`, `CVDisplayLink`, SwiftUI wrapper, or frame-by-frame Auto Layout.
- Design-token colors only; re-resolve on appearance changes.
- Start only while attached to a visible window and stop when hidden/detached.
- Deterministic snapshot phase for UI baselines.
- Reduced Motion uses a static glyph or slow opacity change without orbital/translation motion.
- 16–20 point footprint, legible at 1× and 2× scale.
- Accessibility label is phase-specific (`Thinking`, `Responding`) and does not announce every animation frame.

## 9. Throbber motion study

Build four candidates in isolated background-agent branches. Candidate agents implement only their unique view/check files; a coordinator owns the shared Component Lab gallery and production selection. This avoids four agents conflicting in `ComponentLab.swift` or `ManagedAgentTileNSView.swift`.

Suggested unique file locations:

```text
Sources/ContinuumRevived/Canvas/AgentActivity/ThrobberCandidates/
  OrbitingTriadThinkingIndicatorView.swift
  ThinkingWaveIndicatorView.swift
  BreathingSparkIndicatorView.swift
  DrawingLoopIndicatorView.swift
```

The gallery belongs in the existing in-app Component Lab/debug surface. It should show every candidate simultaneously on tile chrome in light/dark appearance, normal/reduced motion, 1×/2× scale, and `Starting`/`Thinking`/`Responding` labels. No candidate enters production until Dylan chooses one.

### 9.1 Candidate A — Orbiting Triad (recommended starting point)

Three small nodes orbit an invisible center. One node leads at full emphasis and two form a fading trail. The orbit has a slight breathing scale so it feels active rather than mechanical.

Target feel: recognizable, calm, and specific to “Array”—multiple elements arranging themselves.

### 9.2 Candidate B — Thinking Wave

Three horizontal dots rise a small distance, brighten, and settle in sequence. The motion uses a soft sine-like cadence rather than a bouncing typing indicator.

Target feel: immediately understandable and very quiet, with less brand distinctiveness.

### 9.3 Candidate C — Breathing Spark

A custom four-point spark gently expands/contracts while alternating emphasis between its long and short axes. Rotation, if present, is minimal.

Target feel: iconic and compact without reading as a generic network spinner; avoid exaggerated “AI magic.”

### 9.4 Candidate D — Drawing Loop

A partial circular/rounded path continuously draws and releases using `strokeStart` and `strokeEnd`, with a small leading node or thickness taper.

Target feel: fluid and premium; must avoid resembling an indeterminate progress spinner.

## 10. Background-agent prompts for the throbber candidates

Use one isolated worktree/branch per prompt. Agents must not push. Each agent should read `AGENTS.md`, this plan, `DesignTokens.swift`, the existing UI-probe conventions, and nearby AppKit animation precedents before editing.

### Prompt A — Orbiting Triad

> Implement only the Orbiting Triad thinking-indicator candidate for Array. Work in an isolated branch/worktree and do not push. Read `AGENTS.md`, `docs/38-tickets/91-agent-tile-ux/plan-managed-agent-tile-polish.md`, `Sources/ContinuumRevivedAgentUI/DesignTokens.swift`, and existing AppKit/Core Animation examples first. Add `OrbitingTriadThinkingIndicatorView.swift` under `Sources/ContinuumRevived/Canvas/AgentActivity/ThrobberCandidates/`. Build a 16–20pt layer-backed `NSView` with three radial nodes: one clear leader and two fading trail nodes, smooth ~1.2s motion, and a restrained breathing scale. Prefer `CAReplicatorLayer` or a small fixed set of `CAShapeLayer`s. Conform to the plan’s `AgentThinkingIndicatorAnimating` contract if the shared scaffold exists; otherwise keep the same method signatures without inventing a competing abstraction. Use design tokens only, update on appearance changes, stop when offscreen, support Reduced Motion, and provide deterministic `setSnapshotPhase(_:)`. Add focused checks/QA seams in unique files where possible. Do not wire production or edit shared Component Lab/registry files; the coordinator will integrate the candidate. Run the narrowest relevant build/checks and report exact evidence and remaining visual-review needs.

### Prompt B — Thinking Wave

> Implement only the Thinking Wave indicator candidate for Array in an isolated branch/worktree; do not push. Read the repository policy, the managed-agent polish plan, design tokens, and existing animation/UI-probe patterns. Add `ThinkingWaveIndicatorView.swift` in the candidate directory. Use three horizontally aligned dots with a subtle sequential rise, opacity emphasis, and scale change. It must feel smoother and calmer than a conventional typing indicator: no sharp bounce, no large travel, and no layout movement. Use compositor-driven Core Animation only—no timers, display links, or SwiftUI. Match the shared activity-indicator API, design-token/appearance behavior, visibility lifecycle, Reduced Motion behavior, accessibility label, and deterministic snapshot phase defined in the plan. Keep all edits candidate-specific; do not touch production tile wiring or the shared gallery registry. Run focused verification and record exact results.

### Prompt C — Breathing Spark

> Implement only the Breathing Spark indicator candidate for Array in an isolated branch/worktree; do not push. Read `AGENTS.md`, the managed-agent polish plan, Array design tokens, and Core Animation precedents. Add `BreathingSparkIndicatorView.swift` under the throbber candidate directory. Draw a restrained custom four-point spark with `CAShapeLayer`/`CGPath`; animate a gentle inhale/exhale and alternating axis emphasis. Avoid a stock SF Symbol animation, exaggerated glow, gradients, or “AI magic” styling. Motion must remain legible at 16–20pt and use Core Animation without timers/SwiftUI. Implement the shared lifecycle, appearance, Reduced Motion, deterministic snapshot, and accessibility contract. Do not edit production integration or shared Component Lab files. Add focused candidate-local checks where feasible, run the narrowest relevant validation, and report what still requires human motion review.

### Prompt D — Drawing Loop

> Implement only the Drawing Loop indicator candidate for Array in an isolated branch/worktree; do not push. Read the repository rules, managed-agent polish plan, design tokens, and existing `CAShapeLayer` animation examples. Add `DrawingLoopIndicatorView.swift` in the candidate directory. Create a compact rounded loop whose stroke is continuously drawn and released with coordinated `strokeStart`/`strokeEnd`; a very small leading node or taper is allowed. The result must not look like a generic indeterminate progress spinner, so vary cadence/shape subtly while keeping motion calm. Use Core Animation only, design tokens, correct appearance updates, offscreen stop, Reduced Motion fallback, deterministic snapshot phase, and stable accessibility. Keep changes isolated to unique candidate/check files; no production or shared gallery wiring. Run focused verification and report exact outcomes.

### 10.1 Coordinator gallery prompt

After the four branches are available:

> Integrate the four throbber candidate views into one Array Component Lab motion-study gallery without selecting a production winner. Read every candidate diff and the managed-agent polish plan. First establish or reconcile the shared `AgentThinkingIndicatorAnimating` contract, then merge the candidate files with minimal semantic changes. Add one Component Lab/debug surface showing all four indicators on actual agent tile chrome with labels, normal and Reduced Motion columns, `Starting`/`Thinking`/`Responding` states, and deterministic snapshot phases. Do not wire any candidate into `ManagedAgentTileNSView`. Add geometry/appearance/contrast checks and deterministic baselines where the existing harness supports them; motion quality remains a supervised review. Run the focused matrix, list branch commits integrated, and surface the in-app route/launch command Dylan should use to compare them.

## 11. Reasoning disclosure

Create a role-aware reasoning renderer rather than treating `.reasoning` as ordinary assistant prose.

Collapsed completed row:

```text
›  Thought for 12s
```

Expanded content:

- Provider-supplied reasoning summary/body rendered through the same Markdown pipeline.
- No invented summary when the provider sends none.
- Static disclosure glyph; no completed-state animation.
- Disclosure state persists by agent/block identity and invalidates collection measurement correctly.
- Clear accessibility state (`expanded`/`collapsed`) and keyboard activation.

The UI must label this as provider-supplied thinking/reasoning content; it should not imply Array generated a summary if it only received raw provider reasoning deltas.

## 12. Tool rows and local detail

### 12.1 Collapsed presentation

Examples:

```text
›  [search] Searched for “AgentBlockKind”                    0.4s
›  [terminal] Ran swift test                           ✓     8.2s
›  [edit] Edited AgentTranscriptProjection.swift       ✓
```

Rules:

- One line by default.
- Tool-specific, sanitized summary produced by a pure presenter.
- Completed successful work recedes; active/failing work remains more visible.
- Status and duration align consistently.
- Consecutive tool calls may be visually clustered, but each remains independently inspectable.

### 12.2 Expanded presentation

Show available local detail:

- Provider tool name.
- Sanitized/formatted arguments.
- Command, query, or path summary where policy allows it.
- Start/end time and duration.
- Result status and exit code.
- Bounded output with explicit truncation and “Show more.”
- Copy actions.
- Error detail.
- Reliably known affected files.

### 12.3 Privacy architecture

Do not widen syncable `AgentRuntimeEvent` with raw arguments/results. Add a host-local, non-`Codable` detail channel keyed by provider item ID, analogous to the existing local spawn/runtime observation seams.

The local detail store should:

- Use `SecretRedactor` plus explicit key-based redaction before presentation/persistence.
- Keep raw provider payloads out of collapsed summaries, activity sync, and accessibility labels.
- Bound large values by bytes/lines and mark truncation honestly.
- Load large detail on demand.
- Expire with the local session/transcript retention policy.
- Associate start and end payloads without changing normalized event identity.

Bind `DisclosureStateStore.renderActions(for:)` into the live render context and invalidate/reprepare affected collection items when expansion changes measured height.

## 13. Overflow-menu consolidation

### 13.1 Ownership

The outer tile title bar owns the one visible overflow button. The remaining title-bar region remains draggable, so decorative drag dots can be removed rather than masquerading as a menu.

Remove:

- Inner agent-header ellipsis.
- Location-row ellipsis.
- Ellipsis-like working glyph when a clearer stop/progress glyph is available.

Keep urgent actions direct:

- Stop is available as a direct square/stop action while a turn is active.
- Send remains direct.
- Clicking the location value may open a focused location picker; that is a contextual value interaction, not a second generic overflow menu.

### 13.2 Menu sections

Populate only actions Array already supports at implementation time, using `TileNSView.makeAdditionalTitleBarMenuItems()`:

```text
Agent
  Stop current turn/run
  Retry (when meaningful)
  Start new session (when supported)

Location
  Use agent home
  Choose working folder…
  Reveal in Finder
  Open in Terminal

Tile
  Existing tile actions
  Close / Detach view
```

Availability comes from the same capability/state source as direct controls. A disabled action includes an accessible reason; the menu must not become a second state machine.

## 14. Architecture boundaries

### Provider-neutral core

Owns:

- Prompt/attachment contracts.
- Semantic image blocks.
- Context-window snapshot shape.
- Streaming Markdown projection.
- Stable reasoning/tool identities.
- Pure status/tool/context presenters.

Must not import AppKit or encode Pi-specific `@path` behavior.

### Pi adapter

Owns:

- Print/RPC image transport conversion.
- Pi message usage parsing.
- Pi context-stat parsing.
- Pi reasoning/tool lifecycle translation.
- Host-local extraction of tool details without widening sync events.

### AppKit tile

Owns:

- Pasteboard/drop ingestion.
- Thumbnail/image rendering and Quick Preview.
- Status-row composition and radial meter.
- Core Animation throbber.
- Disclosure interaction and collection remeasurement.
- Pasteboard flavors and copy behavior.
- Overflow-menu placement.

### Local storage

Owns:

- Draft attachment files and metadata.
- Thumbnail cache.
- Sent attachment lifetime.
- Host-local tool detail retention.

None of these local paths or raw payloads should enter cross-device activity sync.

## 15. Proposed implementation sequence

Each stage should capture a failing witness before changing behavior. Tests changed in the same patch are not independent proof of the feature.

### Stage 0 — Real-path RED evidence

- Capture a live response that displays raw `**bold**`.
- Capture the effort truncation using the production tile hierarchy and record exact frames/strings.
- Prove expanded tool disclosure does not remeasure or has no detail.
- Capture a Pi usage payload from the committed fixture and prove the translator emits no usage event.
- Capture current pasteboard flavors for a partial rich-prose selection.

No existing expectation should be rewritten merely to match the proposed behavior.

### Stage 1 — Semantic contracts

Likely files:

- `Sources/ContinuumRevivedAgentContent/AgentBlock.swift`
- `Sources/ContinuumRevivedAgentContent/AgentDocument.swift`
- `Sources/ContinuumRevivedCore/AgentStatusEngine.swift`
- New attachment/context/detail model files in provider-neutral modules

Add attachments, semantic image payloads, context snapshots, and local-detail identities with backward-compatible decoding where persisted types are involved.

### Stage 2 — Live Markdown and copy

Likely files:

- `Sources/ContinuumRevivedCore/AgentTranscriptProjection.swift`
- `Sources/ContinuumRevivedAgentContent/StreamingMarkupBuffer.swift`
- `Sources/ContinuumRevivedAgentContent/MarkdownAgentMarkupParser.swift`
- `Sources/ContinuumRevived/Canvas/AgentTranscript/RichInlineTextView.swift`
- `Sources/ContinuumRevived/Canvas/AgentTranscript/AgentTranscriptCopyController.swift`
- `Sources/ContinuumRevived/Canvas/AgentTranscript/AgentTextStyleResolver.swift`

Wire the parser into production, preserve streaming identity, and change public string copy to Markdown.

### Stage 3 — Bottom status/provider rows

Likely files:

- `Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift`
- `Sources/ContinuumRevived/Canvas/AgentTile/AgentLocationStatusView.swift`
- `Sources/ContinuumRevived/Canvas/AgentComposer/AgentComposerFooterView.swift`
- `Sources/ContinuumRevived/Canvas/AgentComposer/ChoiceButton.swift`

Move/recompose location/activity under the input, remove `Next turn`, establish compression priorities, and add production-geometry checks.

### Stage 4 — Context telemetry and radial meter

Likely files:

- `Sources/ContinuumRevivedCore/AgentProviders/PiEventTranslator.swift`
- `Sources/ContinuumRevivedCore/AgentStatusEngine.swift`
- New pure context presenter in `ContinuumRevivedAgentUI`
- New AppKit context meter under `Canvas/AgentComposer` or `Canvas/AgentActivity`
- `ManagedAgentTileNSView.swift`

Parse usage, preserve truthful unknown/stale states, and compare a live displayed value against Pi session stats.

### Stage 5 — Attachment ingestion and transport

Likely files:

- `Sources/ContinuumRevived/Canvas/AgentComposer/ComposerTextView.swift`
- `Sources/ContinuumRevived/Canvas/AgentComposer/AgentComposerView.swift`
- `Sources/ContinuumRevived/Canvas/AgentComposer/AgentComposerDraftStore.swift`
- `Sources/ContinuumRevivedCore/AgentProviders/PiAgentRunner.swift`
- Supervisor/send contracts that currently accept `String`

Add paste/drop, storage, draft semantics, capability/refusal behavior, and Pi transport conversion.

### Stage 6 — Image rendering and preview

Likely files:

- New image renderer under `Canvas/AgentTranscript/Renderers`
- `AgentBlockRendererRegistry.swift`
- `AgentTranscriptProjection.swift`
- New attachment gallery/thumbnail cache views
- Optional future `ImageTileNSView` and `TileKind` changes only if approved

Land transcript rendering and Quick Preview before deciding whether persistent image tiles belong in the first slice.

### Stage 7 — Throbber motion study

- Establish shared candidate API.
- Dispatch the four isolated candidate agents using §10 prompts.
- Integrate the Component Lab gallery.
- Supervised motion review chooses one candidate.
- Only then wire the chosen implementation into the bottom status row.

### Stage 8 — Reasoning and tool disclosures

Likely files:

- `PiEventTranslator.swift`
- `AgentTranscriptProjection.swift`
- New local detail store
- `AgentBlockRendererRegistry.swift`
- `ToolCallRenderer.swift`
- New reasoning renderer
- `DisclosureStateStore.swift`
- `ManagedAgentTileNSView.v2RenderContext`
- `AgentTranscriptListView.swift`

Preserve provider detail locally, sanitize it, and make disclosure state participate in measurement.

### Stage 9 — Overflow consolidation

Likely files:

- `Sources/ContinuumRevived/Canvas/TileNSView.swift`
- `Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift`
- `Sources/ContinuumRevived/Canvas/AgentTile/AgentTileHeaderView.swift`
- `Sources/ContinuumRevived/Canvas/AgentTile/AgentLocationStatusView.swift`
- App-level location menu wiring

Move menu ownership without changing action semantics.

### Stage 10 — End-to-end acceptance

Run the real Pi route, inspect artifacts/screenshots, exercise accessibility/reduced motion, and only then claim user-visible verification.

## 16. Verification plan

### Markdown

- Stream every Markdown delimiter split at every byte boundary.
- Compare final streamed document with one-shot parse.
- Exercise headings, emphasis, strong, nested lists, links, quotes, rules, fenced code, incomplete fences, cancellation, and Unicode.
- Confirm no completed `**bold**` delimiters are visible in real Pi output.

### Copy

- Partial bold/link selection: `.string` contains Markdown delimiters/destination.
- Whole response: headings/lists/fences preserved.
- GitHub PR textarea receives Markdown through `.string`.
- Notion receives either the rich flavor or Markdown without losing content.
- “Copy as Plain Text” remains available if added.

### Images

- Paste PNG/JPEG/TIFF and drag files.
- Paste many images without an artificial count refusal.
- Verify memory does not scale with full-resolution decoded originals.
- Relaunch with an unsent image draft.
- Send an image-only prompt through real Pi and inspect that the model receives it.
- Unsupported model/provider preserves the draft and gives a useful error.
- Sent transcript thumbnails survive detach/reopen.
- Quick Preview, Copy Image, Save As, missing-file recovery, and cleanup are exercised.
- Remote Markdown image never loads without consent.

### Status/footer

- Real tile widths: 320, 480, 560, and a wide case.
- Every effort option and representative long model names.
- Ready, starting, working, needs-action, failed, and detached states.
- `Next turn` absent visually; accessibility labels remain explicit.
- Status row is under input and above dropdowns.
- Icons have tooltips/VoiceOver labels.

### Context

- Parse committed real usage fixture exactly.
- Compare session aggregation with Pi’s stats.
- Include nested tool usage.
- Known, unknown, stale, warning, critical, and post-compaction states.
- Percentage clamped only for rendering; tooltip reports authoritative raw values.
- Missing cost does not display `$0.00`.

### Motion

- Candidate gallery in both appearances and backing scales.
- No animation while detached/hidden.
- Reduced Motion behavior.
- No main-thread timer wakeups.
- Deterministic baseline phase.
- Supervised review at normal size, not only magnified screenshots.

### Reasoning/tools

- Synthetic and real thinking deltas produce an active indicator and completed disclosure.
- No empty completed reasoning row.
- Tool start/end preserves identity, duration, sanitized arguments, bounded output, and errors.
- Expand/collapse changes actual collection item height and persists by identity.
- Raw secrets/paths do not enter sync payloads or accessibility text.

### Menu

- Exactly one visible generic overflow button.
- Direct Stop remains keyboard/mouse accessible while active.
- Menu enablement agrees with the same capability snapshot as direct actions.
- Location actions still reach the existing host callbacks.
- Title-bar drag behavior remains intact after removing decorative drag dots.

### Build and real-route evidence

At minimum:

- `swift build`
- Focused content/core/UI checks for every changed contract
- Existing UI geometry/appearance/contrast/baseline checks as applicable
- Real managed-agent tile launched against Pi
- Inspect resulting screenshots, copied pasteboard values, sent image behavior, and context tooltip

A unit-only result is not sufficient evidence that paste, animation, copy, or Pi transport works end to end.

## 17. Risks and mitigations

### Streaming parser churn

Reparsing full accumulated text on every token can stall long sessions. Use the existing visual update gate, streaming buffer, and identity reconciliation; profile long Markdown responses.

### Attachment lifetime leaks

Disk-backed images can orphan data. Keep explicit draft/sent references and a conservative garbage collector with grace periods; never remove a file still referenced by a transcript or image tile.

### Image decode pressure

Never decode originals at display size by accident. Use ImageIO thumbnail generation, downsample to the target backing-pixel size, and cancel stale requests during collection reuse.

### False context precision

Usage and context occupancy are different. Unknown maximum/occupancy produces an unknown meter, not an inferred percentage.

### Tool-detail privacy

Do not relax I5 to make disclosures convenient. Use a deliberately local, non-serializable side channel and redact before display/persistence.

### Parallel throbber conflicts

Candidate agents must not edit shared integration files. Merge unique candidate files first; one coordinator performs gallery wiring and contract reconciliation.

### Existing uncommitted work

At the time this plan was authored, the working tree already contained unrelated modifications in live transcript/tile/reducer files and multiple untracked ticket artifacts. Implementation agents must use isolated worktrees from an explicitly chosen base and must not overwrite or claim those changes.

## 18. Scope boundaries

This plan does not:

- Resume Queue 91 automation or remove its `STOP` marker.
- Redesign the entire Array canvas or sidebar.
- Turn the semantic transcript into a web view.
- Automatically fetch remote Markdown images.
- Sync raw tool arguments, tool results, local paths, or attachment originals to other devices.
- Promise a persistent image tile in the first slice before its workspace/persistence scope is approved.
- Select a throbber before the in-app motion gallery is reviewed.
- Replace provider-native context facts with guessed model constants.

## 19. Decisions and open questions

### Settled direction

- No arbitrary image-count cap.
- Images render in composer and transcript.
- Status row moves beneath the input and above provider controls.
- Remove visible `Next turn`/“text turn.”
- Effort title receives stronger sizing priority than flexible model/location text.
- Context uses a radial meter plus percentage and detailed hover/focus tooltip.
- Active thinking animation appears only in the bottom status row.
- Completed provider reasoning is a static collapsed disclosure when content exists.
- Highlight-copy uses Markdown on the public string pasteboard flavor.
- Tool detail remains host-local and sanitized.
- One outer overflow menu owns infrequent actions.
- Four throbber candidates are built independently and reviewed together in Component Lab.

### Decisions still needed before implementation reaches those gates

1. **Image tile scope:** Should `Open as Tile` ship with first-pass image paste/render, or should the first pass stop at native Quick Preview?
   **Recommendation:** Quick Preview first; design the attachment identity/lifetime so a persistent image tile can follow without migration.

2. **Throbber winner:** Orbiting Triad, Thinking Wave, Breathing Spark, or Drawing Loop?
   **Recommendation:** Do not decide from prose; review all four at actual size in the in-app gallery. Orbiting Triad is the initial design favorite.

3. **Context thresholds:** What percentages should move from normal to warning and critical?
   **Recommendation:** derive from Pi’s compaction behavior and observed failure pressure rather than adopting arbitrary generic thresholds; begin the gallery with 70%/90% purely as review fixtures.

4. **Exact-source copy:** Is normalized semantic Markdown sufficient, or must copied full responses preserve provider bytes exactly?
   **Recommendation:** normalized Markdown for the first slice, because it satisfies GitHub/notes workflows; retain original per-entry source only if exact-byte fidelity is explicitly required.

5. **Local tool-detail retention:** Session lifetime only, or persisted across relaunch with the transcript?
   **Recommendation:** persist sanitized, bounded detail locally for the same lifetime as the local transcript; never sync it.

## 20. Approval gate

Review this document before implementation. The first executable work should be Stage 0 evidence plus the isolated throbber candidate scaffold—not broad edits across the production tile. Queue automation remains stopped unless Dylan explicitly starts a new supervised implementation sequence.
