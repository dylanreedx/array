# 91-agent-tile-ux — extensible transcript and composer

Status: P0 contract and compatibility foundation complete; semantic implementation next
Owner direction: conversation-first, keyboard-first, visually quiet, highly extensible
Runtime prerequisite: `docs/38-tickets/90-agent-ux/` owns provider/RPC/session capabilities; this queue consumes compiled seams without mutating that queue

## 1. Product thesis

An agent tile is not a chat bubble stack and not a terminal emulator. It is a durable view onto an
agent: conversation, structured work, passive provider-current-work state, exceptional provider-enforced needs, and the command surface used to steer that work. Its transcript and composer must be able to grow for years without turning
`ManagedAgentTileNSView` into one giant switch statement.

The target should feel closer to a polished Claude Code pane than a conventional messenger:

- keyboard-first and fast;
- prose is the reading path;
- tool calls, plans, diffs, approvals, and errors are structured semantic blocks;
- operational metadata is available without permanently dominating the page;
- the composer is a real multiline command surface;
- visible controls are Continuum controls, never pasted-in Aqua dropdowns or text fields;
- light and dark appearances are first-class;
- closing a tile detaches a view and never silently kills the agent.

## 2. Locked design direction

These decisions are instructions, not suggestions for ticket workers.

1. **Parse into an owned semantic document.** Provider text may contain Markdown, but AppKit views
   never parse it directly. A platform-neutral document AST sits between events and rendering.
2. **Markdown is one input syntax, not the whole model.** Tool calls, approvals, questions, diffs,
   plans, errors, and notices remain typed structured blocks; they are not encoded as magic fenced
   strings.
3. **Stable identity beats source offsets.** Streaming text updates revisions of existing nodes;
   completed nodes keep their IDs. Appending one token must not recreate the transcript.
4. **Rendering is registry-driven.** A new block kind adds one renderer registration and its tests,
   not switches in the tile, list, scroll controller, copy path, and Component Lab.
5. **Native behavior underneath, custom visuals above.** `NSTextView`, text layout, IME, undo,
   selection, accessibility, and pasteboard behavior are retained. Aqua bezels, `NSPopUpButton`, and
   visibly native text-field chrome are not.
6. **One owner for each concern.** The supervisor owns agents/runners; the content reducer owns the
   transcript document; the renderer registry owns block→view selection; the composer owns draft
   editing; the tile only composes these pieces.
7. **Incremental by construction.** Provider deltas are coalesced, reduced to document patches, and
   applied by stable ID. No full `reloadData` or full Markdown parse per token in the final path.
8. **Visual taste is reviewed by a human.** Deterministic gates certify semantics, geometry,
   accessibility, contrast, and stability—not beauty. The queue has supervised visual gates.
9. **I5 remains absolute.** Transcript bodies, paths, PIDs, tool arguments, prompts, and secrets do
   not cross desktop→phone sync. Only the existing derived metadata projection may cross.
10. **No compatibility cliff.** `ManagedTranscriptCard` remains available as a temporary projection
    until the real tile is completely migrated and the compatibility-removal ticket lands.
11. **The canvas is the session switcher.** One agent tile is one interactive session view. Spatial
    focus and arrangement replace an in-tile session picker; detach never stops the agent.
12. **Provider current work is passive and read-only.** Consume only explicit provider todo/plan
    state, show active item/progress in the tile and FileTree agent index, optionally disclose detail,
    and never infer a plan from prose or create another task manager.
13. **Autonomy is the default.** Continuum adds no approval gate. A provider-enforced request is a
    compact, exceptional, nonmodal state sourced from an explicit request event.
14. **Capabilities are factual.** Queue 90 owns runtime/RPC/session capability. Queue 91 displays
    only capability exposed at the compiled provider-neutral seam and marks a missing prerequisite
    blocked rather than simulating it.
15. **No context tile.** Transcript, current work, and composer belong in the session tile; do not
    create a linked context surface.
16. **Soft hierarchy, not perimeter borders everywhere.** Sidebar/inbox rows and idle tile surfaces
    use spacing, typography, and quiet fills for grouping. A strong outline is reserved for actual
    keyboard focus, selection, or exceptional attention; selected rows must remain unmistakable in
    both appearances without turning every unselected row into a grey box.
17. **Needs-attention must reveal the real request.** A status label is never the whole approval UX.
    An explicit provider-enforced request resolves to one compact transcript request surface with
    the provider prompt/context and clearly labelled choice buttons. The tile and agent index may
    point to that request, but may not invent a second dock, modal, or Continuum approval policy.
18. **Custom controls must feel designed, not merely de-Aqua'd.** Composer inputs, model/effort
    choices, completion surfaces, and their focus/selection states use friendly Continuum spacing,
    shape, motion, and contrast while retaining native editing, keyboard, and accessibility engines.

## 3. Current pipeline and its limit

```text
PiAgentRunner
  → PiEventTranslator
  → AgentRuntimeEvent
  → AgentSupervisor multicast/history
  → ManagedAgentTileNSView subscription
  → ManagedAgentTranscriptModel.ingest
  → [ManagedTranscriptCard]
  → makeTranscriptEntryView(kind switch)
  → TranscriptProseView / TranscriptCardView
```

The current pure model does several things correctly: it folds streaming deltas, gives each turn a
separate card, tracks active tools, bounds raw event history, and keeps the tile a subscriber. The
limit is its flat six-kind card schema. It has no nested block structure, inline marks, links, fenced
code, source ranges, renderer registration, update patches, or reusable composer architecture.

## 4. Target architecture

```text
Provider JSON / future Pi RPC
        │
        ▼
AgentRuntimeEvent                       (existing provider-neutral boundary)
        │
        ▼
AgentTranscriptProjection               (Core adapter: event → semantic mutations)
        │
        ▼
AgentDocumentReducer                    (AgentContent, pure + platform-neutral)
        │
        ├── immutable AgentDocument snapshot
        └── small AgentDocumentPatch [insert/update/remove/move]
                  │
                  ▼
AgentTranscriptListView                 (AppKit list + scroll ownership)
                  │
                  ▼
AgentBlockRendererRegistry
        ├── prose / rich inline
        ├── code block
        ├── tool + command output
        ├── plan + diff
        ├── exceptional provider request + question
        ├── error + notice
        └── unknown fallback
```

The composer is parallel rather than embedded in the transcript parser:

```text
ComposerTextView (NSTextView engine)
  → ComposerDraft (text, selection, revision)
  → CompletionQueryDetector (/ @ $)
  → suggestion providers
  → AgentComposerIntent [send, stop, steer, queue, command]
  → AgentTileActionSink / AgentSupervisor

Only intents supported by explicit compiled capabilities are advertised. Send/Stop are not evidence
that Steer/Queue exists; unsupported future intents remain unavailable rather than being simulated.
```

## 5. Module and file boundaries

### `ContinuumRevivedAgentContent` — new Swift target

Foundation plus Apple's `swift-markdown`; no AppKit, SwiftUI, DesignTokens, provider process, sync,
or storage dependency.

Planned home:

```text
Sources/ContinuumRevivedAgentContent/
  AgentDocument.swift
  AgentBlock.swift
  AgentInline.swift
  AgentDocumentMutation.swift
  AgentDocumentReducer.swift
  AgentMarkupParser.swift
  MarkdownAgentMarkupParser.swift
  AgentNodeIdentityReconciler.swift
  AgentContentDiagnostics.swift
```

This target owns the semantic tree and parser. It does not know what a tile or `NSView` is.

### `ContinuumRevivedCore`

Owns `AgentRuntimeEvent` and the adapter from runtime events/local user actions into content
mutations. It remains the provider-neutral application layer and retains the compatibility card
projection during migration.

### `ContinuumRevivedAgentUI`

Keeps visual tokens and renderer-neutral display descriptors. It remains Foundation-only and must
not import AppKit. New semantic tokens describe hierarchy—soft hairline, focus ring, artifact
surface, composer surface—rather than choosing arbitrary colors in each renderer.

### `ContinuumRevived` AppKit target

Planned folders:

```text
Sources/ContinuumRevived/Canvas/AgentTranscript/
  AgentBlockRenderer.swift
  AgentBlockRendererRegistry.swift
  AgentBlockHostView.swift
  AgentTranscriptListView.swift
  renderers/*.swift

Sources/ContinuumRevived/Canvas/AgentComposer/
  AgentComposerView.swift
  ComposerTextView.swift
  ComposerActionButton.swift
  ChoicePopoverController.swift
  CompletionPopoverController.swift

Sources/ContinuumRevived/Canvas/AgentTile/
  AgentTileHeaderView.swift
  AgentTileStatePresenter.swift
```

`ManagedAgentTileNSView` ends as a composition root. It must not become the parser, renderer
registry, suggestion engine, menu controller, or agent owner.

## 6. Semantic content model

The precise Swift spelling may evolve in the first content tickets, but the invariants may not.

```swift
public struct AgentDocument: Equatable, Sendable {
    public var version: UInt64
    public var entries: [AgentEntry]
}

public struct AgentEntry: Identifiable, Equatable, Sendable {
    public let id: AgentNodeID           // stable for the turn/item
    public var revision: UInt64          // increases when visible content changes
    public var role: AgentEntryRole      // user, assistant, reasoning, system
    public var provenance: Provenance    // provider item, local prompt, local notice
    public var blocks: [AgentBlock]
}

public struct AgentBlock: Identifiable, Equatable, Sendable {
    public let id: AgentNodeID
    public var revision: UInt64
    public var kind: AgentBlockKind      // RawRepresentable semantic key
    public var sourceRange: AgentSourceRange?
    public var payload: AgentBlockPayload
    public var children: [AgentBlock]
}
```

Built-in block kinds:

- paragraph, heading, list, list item, quote, thematic break;
- fenced code with language and raw code;
- structured tool call and command output;
- plan and diff;
- approval and user question;
- error and local notice;
- unknown/opaque.

Inline runs are semantic: text, emphasis, strong, inline code, link, soft break, hard break. UI fonts,
colors, underlines, and click handlers do not live in the AST.

Unknown nodes preserve a safe debug label and opaque payload so a newer provider or extension does
not make the entire transcript disappear. The fallback renderer never dumps raw secrets or tool
arguments by default.

## 7. Mutation and streaming contract

The reducer accepts small mutations rather than reparsing all history:

```swift
enum AgentDocumentMutation {
    case beginEntry(id: AgentNodeID, role: AgentEntryRole, provenance: Provenance)
    case appendMarkup(entryID: AgentNodeID, delta: String)
    case upsertStructured(entryID: AgentNodeID, block: AgentBlock)
    case completeBlock(id: AgentNodeID, status: AgentItemStatus)
    case finishEntry(id: AgentNodeID)
    case removeEntry(id: AgentNodeID)
}
```

It emits a new document plus a patch:

```swift
struct AgentDocumentPatch {
    var inserted: [AgentNodeID]
    var updated: [AgentNodeID]
    var removed: [AgentNodeID]
    var moved: [AgentNodeID]
}
```

Streaming rules:

- coalesce visual updates to at most 30 Hz;
- keep raw source for the open markup entry;
- parse only the open entry, not completed history;
- reconcile the new parse with the previous parse so completed block IDs survive;
- increment revisions only for changed nodes;
- never lay out once per token;
- finish incomplete Markdown safely: an open fence renders as code-in-progress, never vanishes.

## 8. Renderer contract

```swift
@MainActor
protocol AgentBlockRendering {
    static var kind: AgentBlockKind { get }
    func makeView() -> NSView
    func update(view: NSView, block: AgentBlock, context: AgentRenderContext)
    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat
}
```

The production registry rejects duplicate registrations, always includes an unknown fallback, and
is frozen after application bootstrap. Renderers receive actions through `AgentRenderContext`; they
do not reach into `AgentSupervisor` or global app state.

A renderer owns one semantic block family. Shared primitives—rich text, status label, disclosure,
copy button—may be composed, but there is no universal “card view” with thirty conditionals.

## 9. Transcript container contract

The transcript list owns:

- stable-ID incremental updates;
- view reuse and width-sensitive height caching;
- coalescing while streaming;
- stick-to-bottom only when already near the bottom;
- a jump-to-latest affordance after the reader scrolls away;
- preserving the top visible anchor when content above changes;
- selection and copy that produce sensible plain text and Markdown;
- keyboard traversal and VoiceOver order;
- bounded rendered history without discarding the document source of truth.

The implementation target is a view-based `NSCollectionView` (or a demonstrably equivalent custom
list), not one permanent AppKit subview per transcript block for the life of the agent.

## 10. Composer contract

The visible composer is custom-drawn, with `NSTextView` as its editing engine.

Required behavior:

- grows from one to eight visual lines, then scrolls internally;
- Enter sends; Shift+Enter inserts a newline; IME composition never accidentally sends;
- standard undo/redo, selection, copy/paste, spell checking policy, and accessibility;
- draft is saved per agent and restored after detach/relaunch;
- Up/Down traverses prompt history only at the first/last visual boundary;
- custom model and effort controls live in the footer and apply to the next turn;
- no `NSPopUpButton`, rounded-bezel `NSTextField`, or visible stock dropdown chrome;
- Send becomes Stop while stoppable; later runtime capabilities can expose Steer or Queue without
  replacing the editor;
- `/`, `@`, and `$` completion is provider-based and registry-driven rather than three hard-coded
  parsing branches in the view.

A custom choice surface is an anchored borderless panel with Continuum tokens, keyboard navigation,
selected checkmarks, optional search, and proper accessibility roles. Native menu behavior may be
used internally; native menu appearance may not leak through.

## 11. Visual system direction

The prior pass over-applied WCAG's 3:1 non-text floor to decorative container edges. This program
splits meaning from decoration:

- **soft hairline** for decorative containment and section separation;
- **strong semantic line** only for selection, keyboard focus, approval, error, or warning;
- tile radius approximately 12 pt, composer 10–12 pt, structured artifact 8–10 pt;
- fewer nested fills; canvas → tile → artifact/composer is the main surface ladder;
- assistant prose sits directly on the tile body with a readable measure;
- user prompts use a quiet fill without becoming right-aligned chat bubbles;
- tool activity is compact and collapsible; completed routine work recedes;
- pending decisions remain near the composer because they are actions, not history;
- motion is short and purposeful, and disabled by Reduce Motion;
- narrow tiles switch layout intentionally rather than squeezing controls until they clip.

Decorative hairlines are not required to clear 3:1. Interactive boundaries, focus, selection, and
meaningful status still are. Text contrast remains AA in both themes with zero exemptions.

## 12. Verification doctrine

Every ticket has a deterministic part. The program adds `ContinuumRevivedAgentContentChecks` for
fast pure checks and continues using the existing app-level geometry, appearance, pixel, Component
Lab, supervisor, and baseline checks.

Required categories:

- event sequence → document and patch shape;
- parser corpus → exact semantic AST;
- stable IDs/revisions under every split point of a streamed message;
- malformed/partial Markdown never crashes or drops source;
- registry completeness and duplicate/fallback behavior;
- view reuse and update-in-place by stable ID;
- scroll anchor invariants and streaming coalescing budget;
- IME-safe key behavior, undo, draft restoration, and prompt history;
- no visible `NSPopUpButton`/bezelled field in the new tile subtree;
- geometry at 320, 480, 640, and 900 pt widths;
- light/dark contrast and appearance switching;
- VoiceOver order, labels, actions, focus, and Reduce Motion;
- I5 taint boundary remains green.

Negative tests are required: mutate the final implementation to reintroduce the named failure and
record the exact red assertion. Baselines may only move in a supervised visual ticket after the
candidate app is installed and reviewed. A headless worker never declares the design attractive.

## 13. Migration strategy

1. Build and gate the new content target without touching the live tile.
2. Project current runtime events into both the old cards and new document; assert parity for the
   existing six kinds.
3. Build renderers and list in isolation against fixtures.
4. Stop for supervised transcript review.
5. Build composer and custom controls in isolation.
6. Stop for supervised composer review.
7. Integrate the new transcript/composer behind the current tile seam.
8. Prove attach/detach, replay, streaming, approvals, light/dark, narrow layout, and I5.
9. Remove the old card/view path only after the final supervised acceptance ticket.

At no point may two independent models both mutate the visible transcript.

## 14. Explicit non-goals

- Replacing `AgentSupervisor` ownership or spawning a second runner.
- Encoding structured provider records as Markdown strings.
- Syncing transcript bodies to iPhone.
- HTML/WebView transcript rendering.
- A general plugin ABI or third-party executable renderer loading.
- Full transcript durability/reconstruction from Pi session files in this program.
- Rebuilding the entire application design system before proving the tile primitives.
- Completing every Pi RPC feature; this program defines capability seams and consumes capabilities
  when available, while the existing Phase 5 owns provider transport.

## 15. Human review gates

The queue intentionally stops three times:

1. **P3.12 transcript review** — mixed Markdown and structured blocks, both themes and widths.
2. **P4.10 composer review** — editing, custom choices, command suggestions, focus, and density.
3. **P5.5 live acceptance** — installed app with a real agent, streaming, stop/attention states, and
   detach/re-attach.

The loop must emit `LOOP: STOP supervised-required:<ticket>` when one becomes the first eligible
row. The supervisor never marks it done on the worker's behalf.
