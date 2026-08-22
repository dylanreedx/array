# 96 — Agent sidebar product redesign

Status: **PLANNING AUTHORITY — IMPLEMENTATION HAS NOT STARTED**

Date: 2026-08-14

Owner ruling: Dylan's 2026-08-13/14 screenshot review and corrections are the product authority for
this program. In particular:

- the visible Array sidebar is ugly, too sparse, and not practical enough;
- its vertical padding is excessive;
- `New agent` does not provide usable identity;
- the static diamond provider glyph is unacceptable;
- the custom right-click menu is visually poor and too padded;
- completion is not visible enough to identify which agent finished or when;
- project, branch, and exact ZONE must be understandable;
- History is the one current sidebar workflow worth preserving and elevating;
- agent creation remains in Command Menu (`Cmd-K`); **there is no New button in the sidebar**.

Research baselines:

- Array: `array/integration` at `d334f019ac3aa855ffda40402f6dfb9ed8550247`
- T3 Code: `main` at `30c96228067bcd3a49e432ec898e52d4acb04297`
- Queue 94 final supervised acceptance is still pending. It is not evidence that its product result
  was accepted.

This document is both the product contract and the implementation-agent contract. It exists because
the previous sidebar effort produced a sophisticated architecture, large test surface, and detailed
ledger while the visible product still rendered mostly empty 83 pt rows, repeated `New agent`
subjects, and a Unicode diamond. Agents must not use the sophistication of the implementation as a
proxy for the quality of the product again.

---

## 1. Executive decision

The next sidebar is an **agent inbox and navigation surface**, not an agent-creation surface and not
an inventory dump.

It has four permanent responsibilities:

1. show the active work that exists;
2. identify each agent by human task, placement, branch, harness/provider, and model;
3. show what happened most recently and whether Dylan has seen it;
4. keep completed/parked work recoverable through an obvious History surface.

It does not:

- create agents;
- persist empty composer drafts as active agents;
- display a generic glyph merely to keep a layout band alive;
- use focus, selection, completion, and human attention as synonyms;
- expose every internal lifecycle verb as a top-level menu item;
- make network calls or parse SVGs while drawing a row;
- claim visual completion from source inspection or a headless matrix.

The intended 280 pt active row is:

```text
[project icon] Array › Sidebar                 ✓ Done · 4m
Replace sidebar identity and completion UX
agent/sidebar-redesign       [OpenAI] GPT-5.6 Sol
```

The intended sidebar shell is:

```text
Search
All projects / current scope

Active agent rows
…

History (N)          <- pinned and reachable without scrolling the active list
```

There is no New button. `Cmd-K` remains the one creation path.

---

## 2. Why the previous program failed

This is a failure analysis, not blame. Each failure below needs a process or executable guard in
this program.

### 2.1 Architecture was mistaken for product quality

Queue 94 correctly introduced an `NSTableView` inbox, frozen ordering, lifecycle buckets,
selection/hover/route-active separation, status ownership, keyboard traversal, read watermarks,
accessibility checks, and measured width tiers. Those are useful foundations.

But the existence of those foundations caused reviewers—including a later investigation of this
program—to describe the sidebar as if those capabilities made it close to T3. The owner screenshots
proved otherwise. The visible row contained two readable facts and an unexplained character.

**Correction:** every product claim must name a visible pixel, interaction, or spoken accessibility
result. "The data exists" and "the architecture supports it" are not presentation evidence.

### 2.2 A borrowed metric became a false conclusion

The previous T3 study recorded that Array's 79 pt card and T3's 78 px card were nearly equal, then
locked the conclusion that height was not the problem. That ignored how the height was used:

- Array: 79 pt card + 4 pt gap = 83 pt pitch;
- 24 pt of the card—about 30%—is vertical inset;
- the three text bands total 47 pt;
- an otherwise empty third band can exist only because the provider diamond counts as detail;
- the screenshot commonly exposes only project, `New agent`, and the glyph.

T3 uses approximately the same pitch for project, state/time, title, branch, provider, environment,
and optional VCS/terminal metadata. Equal pitch did not mean equal density.

**Correction:** density acceptance measures readable information and whitespace distribution, not
row height alone.

### 2.3 The fixture corpus was more informative than the real app

The queue-94 corpus contains human titles, roles, long branches, all five states, attention variants,
and lifecycle shapes. The owner screenshots contain repeated blank-agent sentinels and no useful
third-line content. A fixture can prove that a component supports good data while production
continues to feed or display bad data.

**Correction:** the program needs two fixture families:

- **capability fixtures**, which cover every supported state;
- **production-frequency fixtures**, derived from real creation, first-send, working, completion,
  relaunch, and blank-draft flows.

Both must pass. A capability fixture must not stand in for a production-frequency witness.

### 2.4 Empty drafts were promoted into durable work

`TileSpawner` creates a managed-agent tile, then `wireManagedAgentTile` creates and persists an
`AgentRecord` even when no prompt exists. Every untouched `Cmd-K` tile therefore becomes a durable
sidebar `New agent`. T3 keeps the analogous object client-local until the first send.

**Correction:** draft and agent are different domain objects. An untouched composer is not active
work and does not belong in Active or History.

### 2.5 Prompt truncation was called title creation

The first accepted prompt currently goes through whitespace/control normalization and a 60-character
cap. That is a safe label transform, not semantic naming. The actual concise generator is an explicit
context-menu action, is gated on Pi availability/authentication, and may leave the sentinel in place.

**Correction:** title creation becomes an automatic two-stage lifecycle shared by the tile and the
sidebar: immediate useful fallback, then asynchronous 3–8 word semantic generation.

### 2.6 A picker component was reused as a context menu

The right-click menu is a `ChoiceListView`: 220 pt minimum width, 36 pt rows, 8 pt outer padding,
and a checkmark rail even when no action can be selected. It can display ten ungrouped lifecycle and
administrative verbs.

That is reasonable geometry for choosing a model. It is the wrong native primitive for a context
menu.

**Correction:** sidebar row actions use `NSMenu` and state-specific short menus. Choice-list chrome
remains for actual choices.

### 2.7 Completion semantics were stored but not presented

`runCompletedAt` and a desktop read watermark exist, but:

- `runCompletedAt` means any terminal turn event, including failure, interruption, and cancellation;
- the latest outcome is not persisted;
- a never-visited record is deliberately treated as read;
- `.ready + .unread` has no visible word or dedicated mark;
- the row does not carry the completion timestamp;
- direct tile focus and sidebar reveal do not share a complete acknowledgement model;
- the canvas only has a coarse needs-attention border.

**Correction:** persist an honest terminal event and acknowledgement sequence. Render its outcome and
time before deriving alert treatment.

### 2.8 Supervised gates happened too late

Queue 94 put major owner reviews after long autonomous phases. Its final supervised acceptance is
still pending, yet later readers treated the implementation as effectively complete.

**Correction:** this program has a supervised visual gate after every product-visible slice. A later
autonomous ticket cannot depend on an unaccepted visual premise.

---

## 3. Truth hierarchy and evidence contract

When evidence disagrees, use this order:

1. **Dylan's current explicit observation or ruling.**
2. **The visible behavior of the verified scratch app build** on the intended commit and isolated
   scratch project.
3. **Owner-reviewed screenshots/video and VoiceOver output** from that exact build.
4. **Deterministic production-path behavior witnesses.**
5. **Source inspection.**
6. **Planning documents, prior ledgers, comments, and design intent.**

A lower rung can explain a higher rung. It cannot overrule it.

Examples:

| Claim | Insufficient evidence | Sufficient evidence |
|---|---|---|
| Rows are dense | Card height equals T3 | Screenshot shows target facts at 220/280/360 and measured whitespace/pitch |
| Titles are shared | Both paths read `displayName` somewhere | One mutation/relaunch fixture proves identical sidebar, tile, tooltip, notification, and AX text |
| Done is visible | `runCompletedAt` exists | Unfocused agent completes in the scratch app and its row/tile visibly identify outcome and time |
| Menu is native | It is written in AppKit | A real `NSMenu` appears at the pointer with system keyboard, screen-edge, and VoiceOver behavior |
| Logos ship | SVG files exist in the repo | Signed `.app` contains resources and a clean offline launch renders them in both appearances |
| Visual ticket is done | Matrix is green | Matrix is green **and** the exact supervised screenshot set is explicitly accepted |

### 3.1 No "implemented" without an entry witness

Every packet begins by recording the current failure in one of these forms:

- a deterministic red behavior check;
- a screenshot with commit/build/width/appearance metadata;
- a scripted interaction that yields the wrong row/menu/state;
- a spoken VoiceOver transcript for an accessibility failure.

The same witness must turn green or visibly correct after the change. A newly written test that is
green before implementation is not an entry witness.

### 3.2 No visual acceptance by agent inference

Agents may verify geometry, contrast, truncation, state ownership, accessibility roles, resource
packaging, and absence of continuous timers. They may not decide that the sidebar "looks good" or
that owner feedback is satisfied.

All tickets marked **supervised** stop and present the artifact. Silence is not approval.

### 3.3 The artifact must be traceable

Every screenshot set and owner review records:

- source commit;
- dirty tracked/untracked state relevant to the build;
- exact app bundle path and build channel;
- bundle version/build number;
- scratch project path;
- sidebar width;
- appearance and accessibility settings;
- fixture/state being shown;
- whether the screenshot is offscreen-rendered or from the live window.

An offscreen probe is a geometry gate, not proof of the live product.

---

## 4. Product contract

### 4.0 T3 principles and the native translation layer

T3 is valuable here because its sidebar expresses a coherent workflow, not because its React/CSS
implementation is inherently better than AppKit. The reusable principles are:

- a task enters durable navigation when there is real intent, not merely when a blank composer opens;
- each row answers identity before it offers controls;
- repeated metadata has a stable scan position: placement/time, subject, then work/runtime detail;
- high-frequency facts remain visible while low-frequency actions move behind disclosure;
- provider and project marks carry semantic identity rather than ornament;
- state is legible through a word, icon, and time—not through unexplained animation;
- history/recovery is part of the primary workflow rather than an administrative afterthought.

The translation rule is: **copy the information hierarchy and lifecycle intent; use native macOS
semantics and Array's domain model to implement them.**

| T3 reference behavior | Array-native translation | Deliberate divergence |
|---|---|---|
| client-local unsent thread | canvas-local draft presentation | no `AgentRecord` or sidebar row before accepted Send |
| compact multi-fact row | reusable `NSTableCellView` with measured three-band layout | exact project + Zone and honest terminal outcome/time |
| generated conversation title | shared durable `AgentTitlePresentation` with revision CAS | tile, sidebar, search, tooltip, notification, and AX use one projection |
| provider/project icon components | semantic keys resolved by an offline `BrandMarkCatalog` | bundled assets and native labelled fallbacks; no runtime CDN/SVG parsing |
| web overflow/action surfaces | state-specific native `NSMenu` | system keyboard, screen-edge, dismissal, and VoiceOver behavior |
| CSS truncation/responsive bands | AppKit measured-fit policy at declared widths | deterministic sacrifice order; title and urgent state never disappear |
| recent-task/history navigation | bottom-pinned History affordance plus slim native rows | unread results block automatic History movement |
| compose control in sidebar chrome | none | `Cmd-K` remains Array's only new-agent entry point |

This also defines what not to copy. Do not port component names, DOM structure, arbitrary pixel
values, web hover assumptions, or a sidebar New control. Do not treat a screenshot imitation as a
translation if the underlying Array facts—Zone, branch, harness/provider/model, terminal outcome,
acknowledgement, and draft materialization—remain wrong.

### 4.1 Creation and draft materialization

`Cmd-K` remains the sole new-agent entry point. The sidebar gains no creation button.

Creating a managed-agent tile produces a local **draft presentation** containing only what the
composer needs:

- tile identity;
- selected harness/model/thinking;
- placement/home selection;
- unsent composer contents and attachments under the existing draft policy.

It does not create an `AgentRecord`, Active row, History row, read watermark, worktree, provider
session, or companion inventory entry.

The first accepted Send atomically:

1. validates placement, model, capability, attachments, and prompt ownership;
2. creates the durable agent record;
3. binds the existing tile to that agent;
4. persists an immediate local title fallback;
5. begins the turn;
6. schedules semantic title generation.

If validation or provider admission refuses the Send, the object remains a draft. It does not leave
behind a durable `New agent` row.

Headless, ticket-derived, parent-derived, and orchestrated spawns already have prompt/source identity.
They materialize immediately through the same record/title contract.

Draft recovery is deliberately outside this sidebar program. If unsent canvas drafts persist across
relaunch, they remain canvas drafts and still do not appear in Active or History.

### 4.2 One title lifecycle for every surface

Introduce one pure local presentation:

```swift
struct AgentTitlePresentation: Equatable, Sendable {
    let value: String
    let source: Source
    let isPlaceholder: Bool
    let revision: UInt64
    let syncDisposition: SyncDisposition

    enum Source {
        case draftPlaceholder
        case promptFallback
        case sourceItem
        case parent
        case generated
        case manual
    }
}
```

Local precedence:

1. manual title;
2. latest accepted generated title;
3. source-item title;
4. safe prompt fallback;
5. parent-relative title;
6. contextual draft placeholder, only on the draft tile.

Workflow:

1. Before Send, the tile may say `Draft` and shows project/model context. No sidebar row exists.
2. On first accepted Send, persist a safe one-line prompt fallback immediately.
3. In parallel, run automatic semantic title generation with a provider-neutral text-generation
   service and a configured utility/title model.
4. Ask for a specific 3–8 word task title, at most 50 displayed characters, no prefix, quote,
   filler, or trailing punctuation, and not a verbatim restatement.
5. Image-only prompts pass their approved visual context to generation; until generation lands the
   fallback is a contextual label such as `Visual task`, never a path or attachment filename.
6. Apply generation with request ID + expected revision compare-and-swap. A manual rename always
   wins.
7. Generation failure consumes the request and leaves the prompt fallback. It never restores the
   sentinel.
8. `Regenerate Title` uses bounded recent conversation context, includes the previous title, and
   must produce a distinct result.
9. A restored pending generation is either safely resumed or explicitly cancelled/consumed before
   first-send fallback logic runs. It may not strand the title gate.

The sidebar, managed tile header, command/search result, notification, tooltip, and VoiceOver row
must all consume this one presentation. No surface performs identifier filtering or fallback logic
independently.

Prompt-derived and generated title privacy must be an explicit `syncDisposition`, not inferred from
`source`. The current behavior that redacts every automatic title to `New agent` on companion sync is
not silently changed by this program.

### 4.3 Active row anatomy and density

Target metrics at the normal 280 pt sidebar width:

| Token | Target |
|---|---:|
| card height | 66 pt |
| inter-row gap | 2 pt |
| effective pitch | 68 pt |
| list outer gutter | 4 pt per side |
| inner horizontal inset | 10 pt |
| inner vertical inset | 8 pt |
| corner radius | 6 pt |
| top/detail type | 11 pt, 14 pt line |
| title type | 13 pt semibold, 17 pt line |
| first-to-title gap | 3 pt |
| title-to-detail gap | 2 pt |
| project/provider marks | 14 pt |

Arithmetic: `8 + 14 + 3 + 17 + 2 + 14 + 8 = 66`.

This is a sidebar-specific metric set. Do not change global `Inset.card` or global title typography to
achieve it.

Line ownership:

1. **Placement/state:** project icon + `Project › Zone` on the left; operational/terminal state and
   time on the right.
2. **Subject:** human task title on its own line.
3. **Work identity:** middle-truncated branch on the left; harness/provider mark(s) and short model
   name on the right.

Rules:

- every drawn band must contain human-readable information;
- no band exists only for an icon;
- a row with the full data contract exposes at least placement, title, branch, runtime/model, and
  state/time;
- title and urgent state yield last;
- branch truncates in the middle;
- project/zone and model labels truncate at the tail;
- exact placement, branch, harness, provider, model ID, outcome, and timestamp remain in tooltip and
  accessibility detail;
- row height never grows at wider widths and never adds a fourth line;
- row height is not based on guessed importance;
- History has a separate slim geometry.

Measured-fit sacrifice order:

1. remove redundant harness/provider prose while keeping the identifying mark;
2. shorten model display text, then remove it while keeping mark(s);
3. collapse `Project › Zone` to project when placement remains available in tooltip/AX;
4. further middle-truncate branch;
5. never hide the title or urgent state.

Acceptance widths are 220, 280, and 360 pt. The existing 320 pt corpus may remain as an additional
regression fixture; it is not a substitute for 360.

### 4.4 Interaction surfaces

Preserve the useful interaction distinctions already implemented:

- resting: no row fill;
- multi-selected: quiet fill;
- hover: slightly stronger transient fill;
- route-active/open: strongest interaction fill;
- keyboard focus: separate native-visible focus treatment;
- attention: content and alert treatment, never a synonym for selection or focus.

Selected/active fills receive the 4 pt outer list gutter and must not read as a full-width slab.

No continuous animation communicates ordinary working, selection, or completion. Any arrival
animation is event-driven, finite, and suppressed under Reduce Motion.

### 4.5 Harness, provider, model, and project identity

Delete `AgentProviderGlyph`. It has no target-state role or compatibility role.

Identity facts remain separate:

| Fact | Meaning | Example |
|---|---|---|
| harness | CLI/runtime Array controls | Codex, Claude Code, Pi |
| provider | service serving the model | OpenAI, Anthropic, Google |
| model | exact selected capability | `openai-codex/gpt-5.6-sol` |
| project | repository/workspace identity | Array |

Presentation examples:

- Codex + OpenAI model: Codex/OpenAI mark + `GPT-5.6 Sol`;
- Claude Code + Anthropic model: Claude mark + `Opus`;
- Pi + Anthropic model: Pi mark + Anthropic mark + `Opus`;
- Pi + OpenAI model: Pi mark + OpenAI mark + `GPT-5.6 Sol`.

Do not repeat equivalent marks when the harness already identifies the provider unambiguously. Do
preserve both when the combination conveys real information, especially Pi with a distinct provider.

Fallbacks:

- known identity with a missing asset: labelled native badge (`CX`, `CC`, `Pi`);
- unknown provider: deterministic two-character initials from the exact provider key;
- known model but unknown harness: provider + model, with `Harness unknown` in tooltip/AX;
- known harness but missing model: harness only;
- no identity fact: draw nothing; never draw a generic diamond.

Use a macOS-app `BrandMarkCatalog` that maps semantic keys to bundled/cached `NSImage`s. The shared
Foundation-only row value carries keys and labels, never AppKit images.

SVGL may be used for discovery at build/design time, not as a runtime CDN. Prefer vendor originals,
review each vendor's trademark/brand terms, and store a provenance manifest containing source URL,
brand-guideline URL, retrieval date, SHA-256, appearance variants, transformations, and review
status. Do not tint vendor marks unless the brand rules explicitly permit template treatment.

Initial coverage:

- harness: Codex, Claude Code, Pi;
- provider: OpenAI/OpenAI Codex, Anthropic, Google/Gemini, xAI/Grok, OpenRouter, Mistral, Groq,
  Cerebras;
- project: explicit local project icon, then bounded common favicon paths, then SF Symbol folder.

Project-icon lookup is a separate local pipeline. It must enforce containment inside the project
root, decode off-main, cache by project ID plus content revision, keep a prior successful image until
replacement succeeds, and update only affected visible rows.

### 4.6 Honest terminal outcomes and attention

Persist an honest latest terminal event rather than treating `runCompletedAt` as success:

```swift
struct AgentTerminalEvent: Codable, Equatable, Sendable {
    let sequence: UInt64
    let turnID: String
    let outcome: Outcome
    let endedAt: Date

    enum Outcome: String, Codable {
        case succeeded
        case failed
        case interrupted
        case cancelled
        case runtimeError
    }
}
```

Persist a local acknowledgement watermark:

```swift
acknowledgedTerminalSequence: UInt64
```

Derivation:

```text
unread result = latest terminal sequence > acknowledged sequence
```

Migration initializes legacy records to their existing latest terminal sequence so old history does
not light up on upgrade. New durable agents initialize acknowledgement to zero.

Operational, attention, navigation, and lifecycle facts remain orthogonal:

```text
Run phase:        queued | working | waitingApproval | waitingInput | idle
Terminal result:  success | failure | interrupted | cancelled | runtimeError
Attention:        unreadResult | liveHumanRequest | woke | none
Navigation:       tileOpen | routeActive | selected | keyboardFocused | effectiveFocus
Lifecycle:        active | snoozed | history | archived
```

Trailing state vocabulary:

| Fact | Visible text |
|---|---|
| working | `Working · 1m 24s` |
| approval | `Approval` |
| input | `Input` |
| success unread | `✓ Done · 4m` |
| success read | muted `Done · 4m` |
| failed/runtime error | `Failed · 4m` |
| interrupted | `Stopped · 4m` |
| cancelled | `Cancelled · 4m` |
| no terminal event | quiet created/last meaningful activity time or no text |

Relative time remains visible in the row. The tooltip and accessibility value contain the exact
localized date/time.

Attention precedence:

1. unresolved approval/input;
2. unread terminal result;
3. woke-from-snooze modifier and its underlying cause;
4. operational phase;
5. read terminal metadata.

Acknowledgement rules:

- hover, selection, route-active styling, and a merely open tile do not acknowledge;
- successful sidebar reveal or direct tile activation acknowledges only after the target is visibly
  and effectively focused;
- effective focus requires active app, key window, agent-tile focus scope, and matching agent;
- a result arriving during true effective focus announces once and may acknowledge immediately;
- app resignation, canvas scope, non-agent tile focus, tile close, and detachment disarm focus;
- viewing never dismisses an unresolved approval/input request;
- Mark Unread, if retained outside the ordinary context menu, rewinds the sequence intentionally.

Automatic movement to History is blocked by an unread terminal result. An explicit Move to History
may imply acknowledgement after confirmation of the action.

### 4.7 Sidebar and canvas arrival treatment

Sidebar unread result:

- icon + outcome word + relative completion time;
- full subject emphasis;
- optional small static leading attention mark;
- no repeating border animation.

Canvas tile unread result:

- one finite arrival pulse, approximately 500–800 ms or two bounded pulses;
- then a static outcome-appropriate rail/ring/check until acknowledged;
- approval/input remains persistent and higher priority;
- failure remains persistent and uses failure vocabulary;
- Reduce Motion removes the pulse but preserves the static cue;
- Increase Contrast strengthens the cue without relying on color alone;
- recycled/offscreen views never replay the pulse merely because they materialized.

The pulse owner records the terminal sequence it has presented. Cell/view reuse is not an event.

### 4.8 Native context menu

Use `NSMenu` for sidebar row actions. Do not reuse `ChoiceListView`, and do not build a custom
look-alike menu unless a documented AppKit limitation is demonstrated and Dylan approves the
exception.

Menus are short and state-specific:

| Context | Items |
|---|---|
| active idle | Rename…; Regenerate Title; Move to History; Copy ›; Delete Permanently… |
| working | Rename…; Stop Agent; Copy ›; Delete Permanently… |
| needs approval/input | Rename…; Open; Copy ›; Delete Permanently… only if safe |
| History | Reopen; Rename…; Copy ›; Delete Permanently… |
| snoozed, if retained | Wake; Rename…; Copy ›; Delete Permanently… |

Rules:

- ordinary click already opens/reveals; do not duplicate Open on ordinary idle rows;
- `Move to History` replaces user-facing `Settle`;
- `Reopen` replaces user-facing `Un-settle`;
- `Regenerate Title` replaces `Generate Name`;
- Delete uses an ellipsis and a confirmation;
- destructive items are separated at the bottom;
- Copy Branch and Copy Worktree Path live in a Copy submenu;
- irrelevant or impossible actions are absent;
- multi-selection menus state their count and include only actions valid for the whole target set;
- context-clicking inside an existing selection preserves it; outside retargets to one row;
- standard NSMenu keyboard, dismissal, screen-edge placement, and accessibility behavior are not
  reimplemented.

Snooze, Mark Unread, bulk lifecycle machinery, and other power actions may remain reachable through
the command menu or an explicitly approved advanced submenu. They do not dominate the normal row
menu merely because their backend exists.

### 4.9 History

History is preserved and made obvious:

- a bottom-pinned `History (N)` affordance remains reachable with 50+ active rows;
- it is not a New button and is not paired with one;
- opening History shows 34–36 pt slim rows;
- a History row shows provider/project identity, title, and terminal/closed age;
- clicking reopens it;
- search includes History and reveals the containing surface;
- the currently open historical agent remains reachable even beyond paging;
- active ordering stays frozen by creation; History ordering stays based on its terminal/filing
  contract;
- reading a historical row does not silently reactivate it;
- a new prompt explicitly returns it to Active;
- drafts never enter History.

The existing lifecycle/storage work is a foundation. User-facing terminology and access are changed;
the program does not delete reversible History semantics.

---

## 5. Architecture contract

### 5.1 One pure presentation join

The intended data flow is:

```text
AgentRecord
+ exact workspace/project/zone placement
+ AgentTileTurnSnapshot
+ latest terminal event / acknowledgement
+ lifecycle facts
+ model-catalogue display snapshot
+ project icon revision
+ now
        |
        v
pure AgentSidebarPresentationBuilder
        |
        v
AgentSidebarRowPresentation[]
        |
        +--> NSTableView row renderer
        +--> tooltip / accessibility aggregate
        +--> search index
        +--> context-menu capability model
```

The AppKit view never:

- parses opaque model IDs to guess a harness;
- searches the filesystem for project icons;
- runs Git;
- decides completion/read state;
- looks up Zone by display name;
- derives a title;
- reads wall clock independently for each cell;
- performs network work.

### 5.2 Shared row value

The Foundation-only row presentation should carry values equivalent to:

```swift
struct AgentSidebarRowPresentation: Equatable, Sendable {
    let id: UUID
    let title: AgentTitlePresentation

    let workspaceID: UUID?
    let workspaceName: String?
    let projectID: UUID?
    let projectName: String?
    let zoneID: UUID?
    let zoneName: String?

    let branch: String?
    let worktreeMode: WorktreeMode

    let identity: AgentPresentationIdentity?
    let runPhase: RunPhase
    let terminal: AgentTerminalEvent?
    let attention: AgentAttentionPresentation
    let lifecycle: InboxLifecycle

    let createdAt: Date
    let workingStartedAt: Date?
    let relativeTimeAnchor: Date?
    let isUnconfirmed: Bool
    let parentID: UUID?
    let depth: Int
}
```

`AgentPresentationIdentity` carries semantic strings/keys:

```swift
harnessKey / harnessLabel
providerKey / providerLabel
exactModelID / modelDisplayName / shortModelName
```

It carries no `NSImage` and imports no AppKit.

### 5.3 Exact placement

If the product promises ZONE, placement must be recorded at materialization. `projectID` plus a later
first-match lookup is insufficient when a project appears in multiple workspaces/zones.

The durable agent location needs stable workspace/zone/project identity or an explicit headless/no-
placement case. Display names remain mutable presentation fields, not identity.

Deduplication rules:

- render `Project › Zone` when both are meaningful and distinct;
- render one name when the current project-backed Zone intentionally shares it;
- show workspace in tooltip/AX when it adds disambiguation;
- never invent a Zone for headless/unplaced work;
- changing display names updates presentation without moving identity.

### 5.4 One time owner

The list owns one clock scheduler:

- visible working rows may update at second cadence;
- terminal/History relative times update at minute/day boundaries;
- offscreen rows do not own timers;
- no cell creates a repeating timer;
- state transitions invalidate changed IDs only;
- semantic accessibility announcements ignore elapsed-only ticks.

### 5.5 Resource packaging

The current app-target/package path does not yet provide a complete provider-mark resource pipeline.
The implementation must account for both SwiftPM processing and hand-built `.app` assembly.

Required bundle witness:

1. build the actual `.app`;
2. enumerate the resource bundle inside `Contents/Resources`;
3. resolve every required semantic key offline;
4. render both appearance variants;
5. prove unknown-provider initials fallback;
6. prove a missing known asset fails visibly in a QA fixture rather than becoming blank.

---

## 6. Delivery program

No implementation packet starts until this contract is approved. Packet files may later be split
from this section, but their semantics and gates must remain.

### Phase 0 — establish visible truth

#### P0.1 — Production-frequency corpus

**Objective:** create fixtures from actual product flows rather than idealized rows.

Required shapes:

- untouched draft tile with no sidebar row;
- first accepted text prompt before semantic title lands;
- generated title landed;
- image-only first prompt;
- manual rename during generation;
- generation failure and restored pending request;
- working, approval, input;
- succeeded, failed, interrupted, cancelled, runtime error;
- first-ever completion without a prior visit;
- exact and ambiguous project/Zone placements;
- Codex/OpenAI, Claude/Anthropic, Pi/Anthropic, Pi/OpenAI, unknown provider;
- long Unicode/RTL title, project, Zone, branch, and model;
- active, snoozed, History, nested child, headless, unconfirmed;
- 50+ active rows with History still reachable.

**Entry witness:** the current corpus can pass while an owner-screenshot-equivalent row still renders
`array-scratch`, `New agent`, and a diamond.

**Gate:** a declared fixture inventory maps each production flow to its resulting row and surface.

#### P0.2 — Live screenshot harness and manifest

**Objective:** make visual artifacts traceable and repeatable.

Required widths: 220, 280, 360 pt. Required appearances: Aqua and Dark Aqua. Required accessibility
variants: Reduce Motion and Increase Contrast.

The harness emits a manifest with commit, bundle path/hash, width, appearance, fixture, scale, and
capture type. It must distinguish live-window screenshots from offscreen renders.

**Supervised gate S0:** Dylan reviews the current red baseline and three proposed static row-density
variants before implementation locks 66/68 geometry. The documented target is the default proposal,
not approval inferred in advance.

### Phase 1 — drafts and one title truth

#### P1.1 — Draft is not AgentRecord

**Objective:** stop empty `Cmd-K` tiles from entering Active and History.

Likely seams:

- `TileSpawner.spawnManagedAgent`
- `AppDelegate.wireManagedAgentTile`
- `AgentSupervisor.spawn`
- managed tile submit wiring
- canvas draft persistence/restoration

**Must not:** break headless/orchestrated prompt-at-spawn flows or create a second agent on reveal.

**Negative witness:** creating and closing ten untouched managed-agent tiles leaves supervisor record
count, sidebar count, History count, and agent-store files unchanged.

**Positive witness:** first accepted Send creates exactly one record, binds the existing tile, produces
one Active row, and survives relaunch.

#### P1.2 — Shared title projection

**Objective:** sidebar and tile consume identical sanitized title state.

**Entry witness:** one identifier-shaped/manual fixture produces different tile and sidebar text.

**Gate:** first fallback, generated title, manual rename, failed persistence, and relaunch show exact
parity across sidebar, tile, tooltip, notification fixture, and AX.

#### P1.3 — Automatic semantic title generation

**Objective:** provider-neutral, first-send automatic 3–8 word naming.

**Must preserve:** request ID + revision CAS; manual wins; bounded input/output; no prompt in process
arguments; failure fallback; provider capability/auth ownership; privacy boundary.

**Negative witnesses:** generation failure, timeout, stale request, manual race, crash/restore,
image-only prompt, and unavailable utility model never restore/retain the sentinel after accepted Send.

**Supervised gate S1:** review tile and sidebar transitions for real text, visual, and long prompts.
No later row-polish phase begins until the title result is accepted.

### Phase 2 — truthful projection

#### P2.1 — Stable placement identity

**Objective:** persist/derive exact workspace/project/Zone at materialization.

**Negative witness:** the same project placed in two zones no longer resolves both agents to the
first registry placement.

#### P2.2 — Runtime/model identity value

**Objective:** carry harness, provider, exact model, and human model name without view parsing.

**Negative witness:** Pi+Anthropic and Claude Code+Anthropic produce distinct presentation values.

#### P2.3 — Terminal outcome and acknowledgement sequence

**Objective:** persist honest outcome/time and reliable unread state across focus and relaunch.

**Negative witnesses:** first-ever completion, direct tile focus, app resignation, runtime error,
cancel/interruption, relaunch, and mark-unread behavior.

#### P2.4 — One presentation builder

**Objective:** make rows, search, tooltip, AX, context capabilities, and History consume one pure join.

**Must not:** add AppKit to AgentUI/Core value modules or a second state derivation in the view.

### Phase 3 — identity assets

#### P3.1 — Brand provenance and resource pipeline

**Objective:** obtain approved local marks, add provenance, package them in the actual `.app`, and
resolve them offline.

**Gate:** bundle enumeration plus both appearance screenshots and unknown/missing fallbacks.

#### P3.2 — Identity cluster and project icon

**Objective:** replace the glyph label with real `NSImageView`-based identity and meaningful model
text; add bounded local project icons.

**Teeth witness:** source and live-view scans prove `AgentProviderGlyph` and the Unicode glyph values
are absent from the shipped row and provider-picker path owned by this ticket.

**Supervised gate S2:** identity is recognizable at 220/280/360, Pi cross-provider cases are honest,
and no third band exists for an icon alone.

### Phase 4 — dense native row

#### P4.1 — Sidebar-specific geometry tokens

**Objective:** adopt the accepted active/history metrics without changing global card/title tokens.

**Gate:** exact arithmetic, pitch, outer gutter, and no theme-dependent geometry.

#### P4.2 — Three-band layout and measured fit

**Objective:** implement placement/state, title, and branch/identity ownership and sacrifice order.

**Negative witnesses:** long placement/model/branch, RTL, 220 pt width, urgent state, and missing data.

#### P4.3 — Interaction ladder and alert composition

**Objective:** keep hover/selection/route/focus distinct while allowing attention content/rail.

**Supervised gate S3:** compare current baseline and target live-window screenshots at all widths and
both appearances. Dylan explicitly accepts density, hierarchy, selection gutter, and truncation.

### Phase 5 — native actions

#### P5.1 — Replace row ChoiceList with NSMenu

**Objective:** native state-specific context menus and submenus.

**Negative witness:** ordinary idle, working, needs-action, History, snoozed, and multi-select menus
contain exact approved items/order, no empty check rail, and no irrelevant action dump.

#### P5.2 — Vocabulary and lifecycle routing

**Objective:** map Move to History/Reopen/Regenerate Title to existing durable actions without shadow
state.

**Supervised gate S4:** pointer, keyboard, VoiceOver, screen-edge placement, confirmation, focus
return, and multi-selection are reviewed in the live scratch app.

### Phase 6 — completion and canvas attention

#### P6.1 — Sidebar outcome/time

**Objective:** every terminal outcome and exact/relative time remains visible before and after read.

#### P6.2 — Effective focus and acknowledgement

**Objective:** unify sidebar reveal, direct tile focus, app/window focus, and result arrival.

**Teeth witness:** a stale focused ID cannot auto-read a later completion after focus leaves.

#### P6.3 — Canvas arrival pulse and persistent cue

**Objective:** one finite result transition plus a static, accessible unread result cue.

**Must not:** add continuous display invalidation, per-tile clocks, or replay on view materialization.

#### P6.4 — Auto-History blocker

**Objective:** unread results stay Active; explicit History remains possible and honest.

**Supervised gate S5:** Dylan watches multiple background agents complete and can immediately identify
which finished, outcome, time, project, branch, and Zone from sidebar and canvas.

### Phase 7 — History

#### P7.1 — Pinned History access

**Objective:** History remains visible under 50+ active rows with correct count and search routing.

#### P7.2 — Slim history row

**Objective:** 34–36 pt row with title, identity, placement, terminal/closed age, and Reopen.

#### P7.3 — Lifecycle parity/relaunch

**Objective:** Move to History, Reopen, prompt-reactivation, paging, current-route inclusion, and
relaunch preserve one contract.

**Supervised gate S6:** History is explicitly judged useful, reachable, and visually subordinate to
Active without being hidden.

### Phase 8 — final integration

#### P8.1 — Performance and reuse

Prove:

- changed-ID visible-cell updates;
- reusable full/slim cell identifiers;
- one list clock;
- no filesystem/network/Git/model parsing in draw/layout;
- cached images;
- no continuous completion animation;
- stable scroll/selection during title, time, and result updates;
- bounded restore and icon work.

#### P8.2 — Accessibility

Prove:

- state uses icon + word, never color alone;
- one row-owned semantic status;
- VoiceOver order: title, state/outcome/time, project, Zone, branch, harness/provider/model;
- exactly one announcement per semantic transition;
- elapsed ticks do not announce;
- Reduce Motion and Increase Contrast behavior;
- full keyboard access and native menu roles.

#### P8.3 — Packaging/offline

Build the real scratch `.app`, disconnect logo/network dependencies, relaunch, and verify bundled
marks, title/result persistence, and History.

#### P8.4 — Final supervised acceptance

This is the only program-completion gate. It asks Dylan, against the exact artifact:

1. Can you distinguish every visible agent without opening it?
2. Can you tell what is working, waiting, failed, stopped, cancelled, or newly done?
3. Can you tell when it finished and where it lives—project, branch, and Zone?
4. Do title changes feel useful and consistent on both tile and sidebar?
5. Does right-click feel like a native Mac menu rather than a large custom picker?
6. Is the sidebar dense enough at the width you actually use?
7. Is History immediately reachable and still the useful workflow?
8. Does anything blink, jump, reorder, truncate, or draw attention without earning it?

Any "no" creates a correction ticket. It does not become an honest limitation inside a completion
note.

---

## 7. Agent execution protocol

### 7.1 Before editing

Every implementation agent must:

1. Read `AGENTS.md`, this document, the exact packet, and directly referenced queue-94 source/history.
2. Record `git status --short --branch` and preserve unrelated user changes.
3. Resolve the production call path and the current live presentation path; do not rely on comments
   or old line numbers alone.
4. State the packet's one product outcome in visible language.
5. Establish and run the entry witness red.
6. Identify whether the ticket is autonomous or supervised.
7. Name the file fence and any required fence deviations before editing.

If the entry witness is already green, stop and determine whether the ticket is obsolete, the witness
is vacuous, or a different visible defect remains. Do not implement the prose blindly.

### 7.2 During implementation

- Keep one semantic owner per fact.
- Change the smallest coherent vertical slice that reaches the real surface.
- Do not add compatibility shadows that let old and new presentation paths disagree.
- Do not edit historical queue-94 documents to make this program appear consistent.
- Do not bless baselines, lower counts/floors, loosen tolerances, or add KNOWN-RED entries to make a
  packet pass.
- Do not substitute source scans for behavior witnesses. Source scans are allowed only as companion
  teeth checks for forbidden legacy values/call paths.
- Do not run a visual ticket entirely headless.
- Do not launch against Dylan's production app state or `~/Documents/personal` project root.
- Use the scratch dev app/project workflow from `AGENTS.md` when a launch is authorized.
- Do not use runtime web requests for logo rows.
- Do not infer owner approval from lack of feedback.

### 7.3 Verification ladder

Run in this order, proportional to the packet:

1. rebuild the directly affected product/check;
2. run the entry witness and observe green;
3. run focused Core/AgentUI/AppKit checks;
4. run the relevant UI geometry/contrast/accessibility/resource checks;
5. build the scratch `.app` when packaging or live UI is involved;
6. exercise the real production interaction path in isolated scratch state;
7. capture the declared screenshot/VoiceOver set;
8. run the full matrix without skipping relevant surface legs;
9. repeat ordering/flakiness-sensitive focused legs;
10. stop at the supervised gate when required.

An early green does not waive later rungs.

### 7.4 Required adversarial review

Every phase boundary receives an independent review whose prompt asks the reviewer to falsify the
phase claims, specifically:

- Find a path where the old visible behavior still ships.
- Find a fixture that is richer than the production flow and therefore masks it.
- Find a second state/title/location owner.
- Find a never-visited/relaunch/focus race.
- Find a resource that exists in source but not the `.app`.
- Find a custom control impersonating a native convention.
- Find a width/appearance/accessibility variant not shown.
- Find a test that passes without driving the production call site.

Review cannot approve visual taste; it can prevent false claims before Dylan reviews it.

### 7.5 Handoff format

Every worker hands off:

```text
Packet / objective:
Exact source commit and dirty-state note:
Files changed:
Production path changed:
Entry witness and red output:
Focused checks run and exact results:
Live artifact path/hash/version:
Screenshots/AX artifacts and manifest:
Negative witnesses performed:
Known limitations:
Supervised gate required / result:
Unrelated user changes preserved:
```

Avoid statements such as "should work," "architecture supports," "tests look comprehensive," or
"matches T3" without the concrete artifact and observation that support them.

### 7.6 Definition of done for a packet

A packet is done only when:

- its production-frequency witness passes;
- its capability fixtures pass;
- its exact artifact is traceable;
- it introduces no second owner;
- focused and matrix gates actually ran;
- its visual/interaction artifact is accepted when supervised;
- its handoff reports all skipped or unverified work;
- it leaves unrelated workspace changes untouched.

The program is done only after P8.4 owner acceptance. Number of commits, tickets, assertions,
baselines, or agent approvals cannot substitute for that decision.

---

## 8. Acceptance matrix

### 8.1 Rows

| Fixture | Required proof |
|---|---|
| dense baseline, 280 dark | accepted pitch/gutter; at least nine complete active rows in 662 pt |
| ordinary agent | placement, title, branch, identity/model, state/time all readable when present |
| draft | canvas-only; zero Active/History/store records before Send |
| first-send fallback | useful immediate title on tile/sidebar; no sentinel |
| generated title | 3–8 word semantic title lands on both surfaces without selection/scroll jump |
| manual race | human title survives late generation and relaunch |
| image-only | no path/filename title; useful fallback then generated semantic title |
| working | word + elapsed visible; no perpetual animation required |
| approval/input | distinct words; viewing does not clear request |
| success unread | check + Done + relative time and persistent attention |
| success read | muted outcome/time remains |
| failed/runtime error | honest Failed word/time and persistent attention |
| interrupted/cancelled | honest Stopped/Cancelled word/time, never green Done |
| never visited | first terminal result becomes unread |
| exact placement | project/Zone/branch correct and tooltip gives complete identity |
| ambiguous placement | two same-project agents in different zones remain distinct |
| Pi cross-provider | harness and provider distinction remains visible/accessible |
| unknown provider | deterministic initials; no diamond/blank image |
| 220 pt | title + urgent state survive; no overlap |
| 360 pt | more text appears without fourth line or height growth |
| long/RTL | correct truncation direction, no clipped status or reordered meaning |

### 8.2 Interaction and attention

| Fixture | Required proof |
|---|---|
| selection/hover/route/focus | pairwise distinguishable in both appearances |
| completion offscreen | persistent mark appears when scrolled into view; no replayed pulse |
| completion while focused | one visual/AX transition, correct acknowledgement |
| completion while app inactive | unread persists through activation/relaunch |
| stale focus | cannot auto-read the wrong agent |
| Reduce Motion | no arrival pulse; persistent cue remains |
| Increase Contrast | stronger cue/fills, all text/status contrast maintained |
| VoiceOver | one semantic transition announcement; elapsed ticks silent |

### 8.3 Menus

| Fixture | Required proof |
|---|---|
| idle | short approved menu; Move to History visible; no action dump |
| working | Stop visible; Move to History absent when unsafe |
| needs action | response/open path stays available; unsafe delete absent |
| History | Reopen first; destructive item separated last |
| multi-select | target count and only whole-set-valid actions |
| screen edge | native repositioning, no clipping |
| keyboard/AX | native traversal, dismissal, focus return, roles, labels |

### 8.4 History

| Fixture | Required proof |
|---|---|
| 50 active rows | History (N) remains visible without scrolling |
| unread result | stays Active until acknowledged; auto-History blocked |
| explicit move | row enters History once, correct date/order/count |
| reopen | returns to intended surface without duplicate agent/tile |
| read-only open | remains in History |
| new prompt | explicitly reactivates |
| relaunch/paging | count/order/current route remain correct |

---

## 9. Source map and expected seams

| Concern | Current seam |
|---|---|
| sidebar host/inbox | `Sources/ContinuumRevived/App/WorkspaceSidebarView.swift` |
| table, cells, row menu, History UI | `Sources/ContinuumRevived/App/AgentInboxView.swift` |
| shared row/title/state values | `Sources/ContinuumRevivedAgentUI/AgentInboxRow.swift` |
| row join | `Sources/ContinuumRevivedCore/Agents/AgentInboxRowBuilder.swift` |
| placement context | `Sources/ContinuumRevivedCore/Agents/AgentContextIndex.swift` |
| durable agent/title/completion fields | `Sources/ContinuumRevivedCore/Agents/AgentRecord.swift` |
| spawn/send/title/focus/outcome writers | `Sources/ContinuumRevived/App/AgentSupervisor.swift` |
| empty tile creation | `Sources/ContinuumRevived/App/TileSpawner.swift` |
| app wiring/reveal/focus/sidebar build | `Sources/ContinuumRevived/App/ContinuumApp.swift` |
| managed tile title/status | `Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift` |
| canvas attention/focus overlay | `Sources/ContinuumRevived/Canvas/CanvasNSView.swift` |
| model names/catalogue | `Sources/ContinuumRevivedCore/AgentModelCatalog.swift` |
| current wrong picker/menu geometry | `Sources/ContinuumRevived/Canvas/AgentComposer/ChoiceListView.swift` |
| provider picker identity reuse | `Sources/ContinuumRevived/Canvas/AgentComposer/ProviderModelPicker.swift` |
| shared metrics/tokens/type | `Sources/ContinuumRevivedAgentUI/Metrics.swift`, `DesignTokens.swift`, `Typography.swift` |
| app resource declarations | `Package.swift` |
| hand-built bundle resources | `scripts/make-app-bundle.sh` |

Historical inputs, never current authority over this document:

- `docs/38-tickets/91-agent-tile-ux/plan-sidebar-t3code-study.md`
- `docs/38-tickets/91-agent-tile-ux/plan-sidebar-and-state-findings.md`
- `docs/38-tickets/94-sidebar-native-ux/_DESIGN.md`
- `docs/38-tickets/94-sidebar-native-ux/_QUEUE.md`
- `docs/38-tickets/94-sidebar-native-ux/_LEDGER.md`
- `docs/38-tickets/94-sidebar-native-ux/plan-P7.1-gate-prep.md`

T3 reference seams:

- `t3code/apps/web/src/components/SidebarV2.tsx`
- `t3code/apps/web/src/components/Sidebar.logic.ts`
- `t3code/apps/web/src/components/chat/ProviderInstanceIcon.tsx`
- `t3code/apps/web/src/components/chat/providerIconUtils.ts`
- `t3code/apps/server/src/textGeneration/TextGenerationPrompts.ts`
- `t3code/apps/server/src/textGeneration/TextGenerationUtils.ts`
- `t3code/apps/server/src/orchestration/Layers/ProviderCommandReactor.ts`
- `t3code/apps/server/src/project/ProjectFaviconResolver.ts`

T3 is reference evidence, not a pixel specification. Array deliberately diverges through tighter
native density, exact Zone, honest terminal outcome/time, AppKit focus semantics, local bundled
assets, and the absence of a sidebar creation button.

---

## 10. Explicit non-goals

- Rewriting the sidebar in SwiftUI.
- Replacing `NSTableView` solely because the current result is poor.
- Redesigning the command menu or adding a sidebar New action.
- Rebuilding the agent runtime, transcript, composer, or terminal protocol.
- Reopening every queue-94 lifecycle feature merely because it is hidden from the ordinary menu.
- Fetching provider logos at runtime.
- Syncing prompt-derived titles without an explicit privacy/product decision.
- Solving general notification-center or Dock notification UX.
- Treating terminal-hosted agents as managed inbox members without a separate membership contract.
- Renaming historical files or module names.

---

## 11. Decisions that require Dylan if evidence changes them

The following defaults are locked for planning but return to Dylan if a live artifact proves the
tradeoff wrong:

- 66 pt card / 68 pt pitch after S0 density comparison;
- 34–36 pt History rows;
- one finite tile arrival pulse plus persistent static cue;
- automatic title generation using the configured utility/title model;
- generated-title privacy remaining local under the current companion policy;
- native `NSMenu` rather than a custom action panel;
- History bottom-pinned rather than inline below Active;
- auto-History blocked by unread terminal results;
- project icons from bounded local project assets.

An implementation agent does not silently choose a materially different value or behavior. It
presents the evidence and asks.

---

## 12. Final reminder

The failure this program is designed to prevent is not "bad Swift." It is building an internally
coherent system whose visible product is still poor, then allowing code volume, test count, and
design prose to hide that fact.

The sidebar is accepted only when the exact scratch-app artifact lets Dylan glance at the left edge
of Array and answer, without opening rows:

- what is this agent doing;
- what task is it;
- which project, Zone, and branch owns it;
- which harness/provider/model is running it;
- did it finish, fail, stop, or cancel;
- when did that happen;
- have I seen it;
- and can I recover it from History?

If the artifact cannot answer those questions clearly, the program is not done—however impressive
the architecture underneath it may be.
