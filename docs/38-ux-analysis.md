# Agent UX Design & UX-Testing Guide (docs/38, UX layer)

Status: **design — settled decisions, 2026-06-30.** This is the UX companion to
`docs/38-agent-orchestration-architecture.md`. Where that doc decides *architecture*
(topology, sync, readers, adapters), this one decides *what the human sees and does*,
and — just as importantly — *how each UX-touching ticket proves it works*.

**Audience: the agents who will implement the UX-touching tickets.** Read this before
you write any of: the activity surface (docs/35), the per-tile agent chrome, the
approvals affordance, the managed-agent tile, or the iOS observer. Every one of those
tickets inherits its design and its verification contract from here.

**This document makes calls.** The tickets need a settled design, not a menu. Each
section below picks exactly one design, says why, names the existing seam it builds on,
and ends with the concrete check the ticket must ship. Open sub-questions are flagged
explicitly and scoped down so they don't block the settled part.

> **The one principle that ties it all together.** Continuum already has the *entire*
> agent-state vocabulary and most of its consumers built — they are just fed mock data.
> `AgentStatus` (`configuring/working/idle/needsAttention/done/stale`,
> `TerminalSessionDescriptor.swift:85`), `SidebarTree` + `SidebarTreeBuilder`
> (`SidebarTree.swift`), the `WorkspaceSidebarView` (fully built NSOutlineView with
> glyph+label status rows), the zone-chrome `AgentStatusRollup` (`CanvasNSView.swift:45`,
> drawn at `:5260`), and the marching-ants `FocusBorderOverlay` (config-driven via
> `FocusBorderConfig`) all exist today. **The UX work is overwhelmingly wiring real
> signal into surfaces that already render, plus two genuinely new surfaces (the managed
> tile transcript and the iOS observer).** Design *with* these seams; do not reinvent
> them. This is the visual analog of the architecture doc's "reshaping, not rebuilding."

---

## 0. The state vocabulary every surface shares

There is exactly **one** status vocabulary, and every surface — canvas tile, zone
rollup, sidebar, iOS list, push notification — must render the *same* six states the
*same* way. Consistency here is what lets a glance mean the same thing everywhere.

| `AgentStatus` | Meaning | Glyph | Color | Motion |
|---|---|---|---|---|
| `working` | agent is actively running a turn | `●` filled | **blue** (`.systemBlue`) | slow pulse (opacity 0.6↔1.0, ~1.6s) |
| `needsAttention` | agent is blocked on the human (approval / question / hook) | `◆` diamond | **orange** (`.systemOrange`) | marching-ants border + attention pulse |
| `done` | last turn completed cleanly | `✓` check | **green** (`.systemGreen`) | none (settled) |
| `stale` | status is old / survived a reboot / evidence went cold | `◌` hollow | **gray** (`.systemGray`) | none |
| `configuring` | spawning / handshaking, not yet running | `◍` half | **teal** | none |
| `idle` | alive but between turns, nothing pending | `○` ring | **tertiary label** | none |

These glyphs and colors are **already** the ones `WorkspaceSidebarView` uses
(`glyph(for:)`/`color(for:)` at `WorkspaceSidebarView.swift:570-588`) — the table above
adopts them verbatim and extends them to `configuring`/`idle` so the palette is complete.
`SidebarAgentStatusKind` (`SidebarTree.swift:3`) already collapses `configuring`+`idle` →
`unknown`; **keep that collapse for the compact sidebar rollup text**, but give each of
the six a distinct glyph on the *tile itself* where there's room to be precise.

**The priority ladder (steal from t3code, verbatim in spirit).** When more than one
signal is live, `needsAttention` **wins over everything**. t3code's
`resolveThreadAwarenessPhase` (`agentAwareness.ts:85`) checks `hasPendingApprovals`
*first, above running*, and its test asserts "prioritizes approval requests over running
state." Continuum's status derivation (ticket T3C-01, `AgentStatusDerivation.swift`) must
do the same: **a pending approval/attention signal beats a running signal; an unknown
signal never fabricates `working`/`done`.** This single rule is why the whole UX is
trustworthy — orange never hides behind blue.

`dominantKind` on `SidebarAgentStatusRollup` (`SidebarTree.swift:42`) already encodes
this precedence (`needsAttention > working > stale > done > unknown`). Reuse it for every
rollup (zone chrome, sidebar zone row, iOS workspace row) so precedence is defined once.

---

## 1. The MANAGED-AGENT tile — a structured transcript, not a terminal

**Decision: the managed-agent tile is a new `Tile.kind` (`.managedAgent`) that renders a
vertically-scrolling, card-based structured transcript with a persistent status header
and an inline approval dock — visually a sibling of the note/file tiles, deliberately
*not* a terminal surface.** It is gated on the DRIVE fork (T3C-02); when that fork lands
"drive," this is the tile it produces.

### Why a new kind, and why not a terminal

The architecture docs are unambiguous and correct on this: a managed agent is *headless*.
The Claude SDK `query()` loop, `codex app-server` JSON-RPC, ACP over stdio, and OpenCode's
HTTP SSE all emit **structured events**, not a TUI (`03-provider-adapters-protocols.md` §4:
"None of the four managed drive mechanisms produces terminal output a ghostty tile can
meaningfully show. Piping their stdout into ghostty would render JSON-RPC frame noise").
Rendering that in a ghostty surface is not merely ugly — it throws away the one thing the
managed tier buys you: *structure* (a tool call is a distinct object you can label,
collapse, and attach an approve button to). So the managed tile is a real new view with a
real new input path, and `docs/38` decision #10 already names it a "FORK" precisely
because it's more product than plumbing.

Fork C in `03` asked "new kind or a mode?" — **new kind.** The view layer and input layer
differ completely from `.terminal`, and the canvas/zone model keys off `Tile.kind` for
spawn defaults and chrome. A mode-flag on `.terminal` would fork every terminal code path
on a boolean; a new kind keeps `.terminal` pristine (which `docs/38` Decision C
deliberately preserves for *observed* agents).

### How it renders — the anatomy

```
┌─ managed-agent tile ───────────────────────────────────┐
│ ● Claude · feature/login              [working · 2m]  ✕ │  ← status header (persistent)
├────────────────────────────────────────────────────────┤
│  You                                                     │
│    Refactor the auth guard to be idempotent.            │  ← message card (user)
│                                                          │
│  Claude                                                  │
│    I'll read the current guard, then…                   │  ← message card (assistant, streaming)
│    ┌ 🔧 read_file  src/authGuard.ts        ✓ 0.2s ┐     │  ← tool-call card (completed, collapsed)
│    ┌ 🔧 run  npm test                    ● running ┐     │  ← tool-call card (in progress)
│                                                          │
├─ ⚠ Approval needed ────────────────────────────────────┤  ← approval dock (only when pending)
│  Run command:  rm -rf ./dist                            │
│  [ Approve ]  [ Approve for session ]  [ Decline ]      │
└────────────────────────────────────────────────────────┘
```

The card taxonomy maps 1:1 to the canonical event union (`AgentRuntimeEvent`, ported from
t3's `ProviderRuntimeEvent`, `03` §2.5):

- **message card** ← `content.delta` accumulated into an assistant/user turn. Streaming
  text appends live; a subtle typing shimmer while the turn is `working`.
- **tool-call card** ← `item.started`/`item.completed` (`CanonicalItemType`:
  `command_execution`, `file_change`, `mcp_tool_call`, `web_search`, …). Collapsed by
  default showing `{icon} {verb} {target} {status-glyph} {duration}`; click to expand
  args/output. Status glyph reuses §0 (`●` running / `✓` done / `✕` failed).
- **plan card** ← `turn.plan.updated` — a checklist that updates in place.
- **diff card** ← `turn.diff.updated` — a compact file-change summary (full diff opens the
  existing diff-review tile; do not rebuild diff rendering here).
- **approval dock** ← `request.opened` / `user-input.requested` — see §3.

### How it differs *visually* from a shell tile — the at-a-glance tells

A user must be able to tell "managed" from "shell running claude" at a distance, and to
tell in-progress / waiting / done at a glance on *both*. Three deliberate visual tells:

1. **Substance.** A shell tile is a dense monospaced terminal grid to its edges. A
   managed tile is **cards on the tile background** with generous padding — it reads as
   "an app view," not "a terminal." This difference is legible even zoomed out to a
   thumbnail.
2. **The header is always present and structured.** The managed tile *always* shows a
   status header (glyph + agent name + `[phase · elapsed]`), because status is
   first-class here (derived from `events`, not tailed from a file). A shell tile shows
   status only as the small corner badge the terminal chrome already draws.
3. **The reading-state glyph.** Reuse §0 exactly, driven by the pure status function:
   - **in-progress** → header glyph is a **blue pulsing `●`**; the newest card has a
     live shimmer; elapsed timer ticks.
   - **waiting** → header flips to **orange `◆`**, the approval dock slides up from the
     bottom, and the **whole tile wears the marching-ants focus border in orange** (reuse
     `FocusBorderOverlay`, §3). This is the loudest state — it must not be missable.
   - **done** → header settles to a **static green `✓`**, timer stops and shows total
     duration, dock is gone.

**Privacy stays a hard line even here (I5).** The transcript cards carry *bodies*
(`content.delta`, tool args, output) and those live **only in the local view layer / the
private managed-session store**. Only the derived `AgentStatus` + sanitized metadata (≤160
char detail, failure text redacted — t3's `sanitizeRelayAgentActivityState`,
`relay.ts:112`) ever crosses the sync/observation boundary. The iOS observer (§4) renders
the transcript by *subscribing to the projection*, not by receiving raw bodies over sync —
same rule as `docs/38` Decision E.

**Build it in the Component Lab first.** `ComponentLab.swift` already hosts static chrome
cards and a live canvas sandbox. Add a `managed-agent` lab entry seeded with a scripted
fixture transcript (a few message cards, one running tool call, one pending approval) so
the card layout, the three reading states, and the approval dock can be designed and
visually gated *without* a live adapter. This is the natural home for the visual iteration.

**Open (scoped, non-blocking):** exact card typography/spacing (design in the Lab);
whether long transcripts virtualize (defer until a real run is long enough to matter);
whether `user-input.requested` gets its own card style vs. reusing the approval dock (§3
recommends a distinct style — richer phone UX).

---

## 2. The ACTIVITY SURFACE (docs/35) — a persistent left dock, default-visible, toggleable

**Decision: a persistent, resizable left dock rendering the live `workspace → zone → tile`
tree with per-tile status and per-zone rollups. Default-visible on first run, toggleable
with a keybind, width persisted. This is the render of the already-built
`WorkspaceSidebarView`, fed by real observer data instead of the mock.**

### Why a dock, not a slide-over or a HUD

`docs/35` explicitly left this open ("left dock vs slide-over vs HUD; default visible or
opt-in?"). The three options trade differently against the stated purpose — *"seeing, at a
glance, what are my agents doing and where"* — and against what's already built:

- **HUD (transient overlay).** Great for a momentary answer, wrong for an *index* you
  consult constantly and jump from. A HUD that must be summoned defeats "at a glance."
  Rejected as the primary surface. (A HUD *does* have a role — the corner zone rollup on
  the canvas, §3 — but that's an ambient glance, not the index.)
- **Slide-over (overlay that covers canvas).** Good on narrow screens; bad as a default
  because it occludes the very canvas you jump *into*. The click-to-jump loop (row → pan
  camera to tile) is jarring if the panel is covering where the tile will land.
- **Persistent left dock.** Matches Dylan's mental model (the sidebar he "remembered
  designing"), keeps the tree beside the canvas so jump-to-tile reads naturally, is
  resizable/collapsible, and — decisively — **is the exact form `WorkspaceSidebarView`
  already implements** (an `NSOutlineView` source-list with expand/collapse, selection,
  and status accessories). Choosing anything else means throwing that away.

So: **left dock.** On a truly narrow window it may *behave* as a slide-over (overlay when
width is scarce), but its identity and default is a dock.

### Contents, hierarchy, and the status it shows

The tree is exactly `SidebarTreeBuilder.build(...)` output: `workspace → zone → tile`,
zones sorted by z-order, tiles carrying `agentStatus`, zones carrying a
`SidebarAgentStatusRollup`. This is already wired end-to-end in the builder and the view —
the *only* missing input is real `agentStatusesByTileId`, which the `SessionObserver`
(architecture Decision C) provides. Concretely:

- **Per-tile row:** glyph + title + right-aligned status text (`working` / `needs you` /
  `done` / `stale` / `no agent`). Already rendered by `statusPresentation(for:)`
  (`WorkspaceSidebarView.swift:541`). Non-agent tiles (browser/note/file) show "no agent"
  in muted tertiary — present but quiet, so the eye lands on agents.
- **Per-zone row:** the rollup's `displayText` ("1 working · 1 needs you", `dominantKind`
  color). Already rendered. A collapsed zone still shows its rollup so a folded zone with
  a waiting agent still shouts.
- **Per-workspace row:** name + bold if current. (A workspace-level rollup is a nice
  future add — see open items — but zone rollups already surface attention within the
  expanded current workspace, which is the common case.)

**Default expansion:** current workspace expanded with its zones expanded; other
workspaces collapsed. This is *already* the behavior (`applyDefaultExpansion`,
`WorkspaceSidebarView.swift:399`).

### Jump-to-tile — reuse the existing focus plumbing

Clicking a row fires `onSelection` with a `WorkspaceSidebarSelection` (`.workspace` /
`.zone` / `.tile`). Wire that to the **existing leader-jump / palette-jump camera focus**
path (the same one `docs/33` navigation uses) — pan/zoom the canvas to the target and mark
it focused (which also lights the focus border). Do **not** invent a second "go to" story;
`docs/35` explicitly warns against "three overlapping ones." One resolver: sidebar click,
leader-jump, and palette-jump all funnel into the same `focus(tileId:)`.

### Default visible + toggle

Default-visible answers "at a glance" honestly — an index you must summon isn't a glance.
But it must be dismissible for full-canvas work, so: a persisted toggle (default `true`), a
keybind (fold into the existing nav/leader scheme rather than a bare global — see
`docs/29` keybind philosophy), and a persisted width. Per the configurable-first doctrine,
ship the default + a Settings entry + the conflict-guarded binding from day one.

**Open (scoped, non-blocking):** show *only* the current workspace vs. all workspaces with
current expanded (recommend: all, current expanded — cheap, and cross-workspace attention
matters for a fleet); workspace-level rollup glyph (recommend add later, it's one
`SidebarAgentStatusRollup.make` over the workspace's tiles); live-update cadence is an
observer/perf concern owned by Decision C, not this surface (the surface just re-`reload`s
on the observer's change notification, debounced).

---

## 3. APPROVALS UX — the loudest state, on the tile *and* the dock, mapped to `needsAttention`

**Decision: a pending approval is the single authoritative source of `needsAttention` for
managed agents, and it surfaces as (a) an inline approval dock on the managed tile, (b) an
orange marching-ants focus border on that tile, (c) an orange `needs you` row + a
"needs you" rollup in the sidebar dock, and (d) an ambient orange count in the canvas zone
rollup. Approve/deny is a first-class button that dispatches the *same* respond command on
Mac and iOS.** This reuses `FocusBorderOverlay`, `AgentStatusRollup`, and the sidebar's
existing status rendering — it invents no new status channel.

### The mapping: approval → `needsAttention`, checked first

This is the highest-value steal in the whole arc (`06-agent-ux-approvals-mobile-push.md`
§3.1). The AGENT-READERS spike found Claude `needsAttention` is *not file-derivable* in
`bypassPermissions` mode. t3code shows the real fix isn't a better file reader — it's
**owning the approval channel**: a supervised managed agent emits a structured
`request.opened`, and the status function returns `needsAttention` **deterministically,
above `working`.** So:

```
pending AgentApprovalRequest for this tile  ⇒  AgentStatus.needsAttention   (authoritative)
```

checked *before* any running/idle signal in `deriveAgentStatus` (T3C-01/T3C-04). Responding
(accept / acceptForSession / decline / cancel — t3's four decisions,
`orchestration.ts:131`) clears the pending set, and status recomputes to `working`/`idle`.

**Two regimes, never conflated** (`06` §4):
- **Managed agent** (adapter, structured approval): `needsAttention` = a pending approval.
  **Authoritative.** Has the dock + buttons.
- **Observed shell tile** (user typed `claude`/`codex`/`pi`): `needsAttention` = a
  hook/file heuristic (Claude `Notification` hook; Pi `status.json` reason; Codex: none),
  best-effort, under-claim rather than fabricate. **No dock, no buttons** — a shell tile
  has no structured channel to answer through; it surfaces attention only as the badge +
  border + sidebar row, and the human answers *in the terminal*.

The UX must make this legible: a managed `needsAttention` tile shows an **actionable dock**;
a shell `needsAttention` tile shows the same border/badge but **no buttons** (the human
switches to the terminal to respond). Same color, same urgency, different affordance —
because one can be answered structurally and one can't.

### Where it surfaces, reusing existing chrome

1. **On the managed tile — the approval dock (§1).** Slides up from the bottom on
   `request.opened`. Shows the request kind + sanitized detail (e.g. "Run command:
   `npm test`") and the decision buttons. `user-input.requested` (the agent *asks a
   question* rather than requests permission) gets a **distinct card** with a short answer
   field — t3 keeps `waiting_for_approval` and `waiting_for_input` separate and it's the
   better UX (`06` §5, open Q5; recommend the split). Both still map to `needsAttention`.
2. **On any attention tile — the marching-ants border, in orange.** Reuse
   `FocusBorderOverlay` (`applyFocusBorder`, `CanvasNSView.swift:696`). Today it marks the
   *focused* tile in the accent color; add an **attention variant**: when a tile's status
   is `needsAttention`, draw the overlay in orange regardless of focus, so a waiting agent
   is ringed even when you're working elsewhere. The overlay is already config-driven
   (color/gap/speed via `FocusBorderConfig`) and already tracks the tile on pan/zoom —
   this is a new *trigger* and *color*, not new drawing. (Focus + attention can coexist:
   attention-orange takes precedence for the ring color; the priority ladder again.)
3. **In the sidebar dock — the `needs you` row + rollup.** Already rendered: the tile row
   shows orange `◆ needs you`, the zone row rolls up to "… · N needs you" with
   `dominantKind == .needsAttention` → orange. Nothing new; it lights up the moment the
   observer sets the status. Clicking the row jumps to the tile (§2), landing the human on
   the dock.
4. **On the canvas zone chrome — the ambient count.** The zone header already draws
   `agentStatusRollup.displayText` (`CanvasNSView.swift:5260`); "1 needs you" appears there
   in the header the moment the real rollup replaces the mock at `:3128`. This is the
   ambient HUD glance — you see a zone needs you without opening the dock.

### The symmetric respond command

Approve/deny dispatches **one** `respondToApproval(requestId:, decision:)` that is
identical on Mac and iOS (t3's `respondToThreadApproval` is the *same* call from desktop
and mobile, `commands.ts:213`). On Mac it goes straight to the adapter's
`respondToRequest`; on iOS it travels the control channel to the host's adapter. This
symmetry is what makes "approve from your phone" (§4) trivial rather than a parallel
implementation.

**Open (scoped, non-blocking):** the exact attention-pulse motion for the border (a faster
march? a color throb? design in the Lab against the visual gate); whether a
just-resolved approval flashes a brief green confirmation on the dock before it dismisses
(recommend yes, ~400ms, so the tap feels acknowledged).

---

## 4. iOS OBSERVER UX — a fleet list, tap into a transcript, approve from the phone

**Decision: the iOS app is a thin observer over the synced spatial+activity projection —
no 2D canvas. Its home is a grouped list `workspace → zone/project → agent` with the same
status glyphs/colors as the Mac; tapping an agent opens its structured transcript
(read-only tail + approval affordances); a `needsAttention` agent can be approved from the
phone via the symmetric respond command; APNS push on entry into an interruptive state
deep-links straight to that agent.** It never hosts a session.

### Why a list, not a canvas

The architecture is explicit and correct: *"a phone doesn't need the 2D canvas — it needs
this tree"* (`docs/38` Decision C). A spatial infinite canvas is a desktop pointer/trackpad
interaction; on a phone it's a pinch-zoom struggle that hides exactly the thing you opened
the app for. The phone's job is **triage**: which agent needs me, and let me act. That's a
list. t3code's mobile app is precisely this — a thin client reusing the shared runtime,
with SSH/hosting explicitly desktop-only (`platform.ts:143`: "SSH environments are only
available in the desktop app"). We adopt that boundary wholesale.

### The screens

```
  Agents                              ← root: grouped list, sorted attention-first
  ─────────────────────────────
  ◆ Continuum                         ← workspace (rolls up: has a needsAttention)
     ◆ feature/login   Claude  needs you   ← agent row, orange, tap target
     ● api-refactor    Codex   working 2m
  ○ Scratch
     ✓ notes-cleanup   Claude  done
```

1. **Root — the fleet list.** Grouped by workspace, then zone/project, then agent. Each
   agent row: status glyph + title + phase text, using §0's exact glyphs/colors. **Sorted
   attention-first** (needsAttention → working → others) so the thing that needs you is at
   the top. A workspace/zone header carries the same `dominantKind` rollup color as the Mac
   sidebar (reuse `SidebarAgentStatusRollup.dominantKind`). This is literally the
   `SidebarTree` rendered as a mobile list — same model, same precedence, different
   presentation. Live-updates by tailing the activity projection.
2. **Agent detail — the transcript.** Tap an agent → its structured transcript (the same
   card taxonomy as the managed tile §1: message / tool-call / plan / diff cards), rendered
   **read-only** from the projection. A phone can't render a ghostty TUI, but it *can*
   render a structured transcript — which is another reason the managed tier is the one
   that serves iOS (`03` Fork A). Observed shell tiles show their metadata + status but no
   live transcript (there's no structured stream to tail — honest about the limit).
3. **Approve from the phone.** When the agent is `needsAttention` with a pending approval,
   the detail screen shows the **same approval dock** — kind, sanitized detail, and
   Approve / Approve-for-session / Decline. Tapping dispatches the **identical**
   `respondToApproval` command the Mac uses. This is the payoff of the symmetric-command
   design (§3): one code path, two surfaces.

### Push — tap-through to the right agent

Reuse t3's model exactly (`06` §1e, §3.5):
- **Push on entry** into an interruptive/terminal phase — `needsAttention` (approval or
  input) and `done`/`failed` — **deduped by state identity** (fire only on *meaningful*
  change, not every tick; t3's `agentAwarenessPublishIdentity`, `AgentAwarenessRelay.ts:89`).
- **Payload is metadata only** — the sanitized awareness state (`phase`, `headline` like
  "Approval needed", `detail` ≤160 chars with failure text redacted, `deepLink`). I5-clean.
- **Four notify categories**, mapping 1:1 to the phases (t3's
  `notifyOnApproval/Input/Completion/Failure`, `relay.ts:28`), each user-toggleable
  (configurable-first).
- **Deep link is validated on receipt** before navigating (t3 validates the exact
  `/threads/<a>/<b>` shape, `notificationPayload.ts:47`). Continuum needs a
  `continuum://agent/<tileId>` (or universal link) that resolves to the agent detail
  screen. Tapping a push → straight to that agent's transcript + dock.

### The scope guarantee (observer can't mutate — except approvals it's granted)

The iOS session is an **observer** (T3SEC-01: a `Scope` OptionSet where an `.observe`
token *cannot represent* a spatial mutation — enforced as far up the type system as Swift
allows). Approving is not a spatial mutation; it's a scoped control action on the agent
channel, permitted by the pairing grant. So: the phone can watch everything and answer
approvals, but it cannot move tiles or drive the canvas — which is exactly right, and is
enforced by the type, not a runtime `if`.

**Open (scoped, non-blocking):** Live Activities (iOS-18+ lock-screen widget) — strictly
additive over plain push, defer (t3 has it, `relay.ts:789`); whether the fleet list also
lets you *send a turn* from the phone (recommend read+approve first, steer later); direct
APNS-from-Mac vs. a relay (`06` §4 — direct first for local-only, relay when agents run on
a VPS; the interface is the same either way).

---

## 5. The UX-TESTING CONTRACT — every UX ticket ships all three

This is the part that makes the design real instead of aspirational. The verification
doctrine (`docs/26`, `docs/37`, and the memory `verification-doctrine`) is in force and is
*stricter* for UX than for logic: **the matrix proves logic/geometry/state; it never proves
what the user sees.** Several past "Done" features were hollow because a check asserted a
seam, not a rendered pixel (`docs/26`: "a perfectly grey 1600×900 canvas is also a
non-empty PNG"). So every UX-touching ticket in this arc must ship **all three** of the
following, in the same change:

### (A) A real-path check — drive the true event path, never a bypass

The check must exercise the **actual** user path: a real `NSEvent` / gesture / menu
command / observer callback, dispatched through the production executor — **not** a test
that calls the model directly and asserts the model changed. `docs/37`'s real-path rule and
the memory `verification-doctrine` both reject happy-path-bypass checks. Concretely for
this arc:

- Approvals: feed a real `request.opened` **event** through the observer/adapter path and
  assert the *derived* status flips (not: set `status = .needsAttention` and assert it's
  set).
- Sidebar jump: invoke the **click handler** (`clickTileRowForQA` already exists,
  `WorkspaceSidebarView.swift:317`) and assert the camera/focus actually moved.
- Managed tile: push real events into the tile's event sink and assert the cards
  materialize.

The check writes a **manifest with measured values**, not `{passed:true}` — e.g.
`qa-runs/<ts>/<check>/manifest.json` carrying the observed status, the glyph, the rollup
text, the camera target. (Precedent: the existing `agent-status-badge` check writes
`workingTileStatus`/`needsAttentionTileStatus`/`plainTileHasBadge`,
`CanvasNSView.swift:3160`.)

### (B) A visual gate — screenshot, asserted non-degenerate (never `bytes > 0`)

Every surface that draws AppKit chrome ships a Tier-1 non-degenerate snapshot
(`VisualSnapshot.metrics`, `docs/26`): render the chrome, `cacheDisplay` it, assert
`!metrics.isBlank` (not zero-sized, not one flat color), and write the PNG to `qa-runs`.
This catches the grey-screen / dead-corner class that `bytes > 0` sails past. The
**Component Lab is the home for these gates** — `ComponentLab.runSelfCheck()`
(`ComponentLab.swift:706`) already renders every static card over an opaque dark backdrop
and asserts each is non-blank; **add the new surfaces (managed tile, approval dock, updated
sidebar, iOS-list preview if hostable) as Lab entries so they're gated automatically.**

Constraint (`docs/26`): only AppKit-drawn chrome composites through `cacheDisplay`.
WKWebView and ghostty (GPU/Metal) do **not** — never snapshot live web/terminal pixels,
only the chrome around them. The managed tile is AppKit cards, so it *is* snapshottable
(another win of the structured-view choice). Live terminal content stays Dylan's dogfood
pass. Tier-2 baseline diffing (`docs/26`) is available if a specific layout needs locking,
but Tier-1 is the floor for every UX ticket.

### (C) A dogfood snippet — "open the app → do X → see exactly Y"

Per the memory `verification-snippet-per-change`, every UX iteration ends with a concrete,
navigable instruction Dylan can run by hand in ~30 seconds to confirm the real thing —
naming the exact menu/key/gesture, the exact action, and the exact colors/labels/live
values to expect. Not "verify the sidebar works." The pattern:

> **Open the app → `<menu / key / gesture>` → do `<X>` → see exactly `<Y>` (colors,
> labels, live values).**

Three worked examples for this arc:

1. **Approval flips a managed tile to attention.**
   *Open the app → Component Lab (`⌃Space` then the Lab launcher) → select "Managed Agent"
   → click "Fire approval" in the fixture toolbar → see exactly: the header glyph turn from
   blue `●` to **orange `◆`**, the label change to `needs you`, an **orange marching-ants
   border** appear around the whole tile, and the approval dock slide up showing
   "Run command: `npm test`" with `[ Approve ] [ Approve for session ] [ Decline ]`. Click
   Approve → the dock dismisses and the header returns to blue `● working`.*

2. **The sidebar shows real fleet status and jumps.**
   *Open the app with a workspace that has a running agent → the left dock is visible by
   default → see exactly: the current workspace expanded, its zone row reading
   "1 working · 1 needs you" in **orange**, and a tile row `◆ feature/login · needs you`.
   Click that tile row → the canvas pans to that tile and it gains the focus border. Toggle
   the dock with its keybind → it collapses; toggle again → it returns at the same width.*

3. **Push taps through to the waiting agent on iOS.**
   *On the paired iPhone, background the app → on the Mac, let a managed agent hit an
   approval → within a few seconds see exactly: a push titled "Approval needed" naming the
   agent → tap it → the app opens directly on that agent's transcript with the approval
   dock at the bottom → tap Approve → see the dock confirm and dismiss, and on the Mac the
   same tile's border clears. (No transcript body text appears in the push — metadata
   only.)*

### The invariant spine still binds the UX

The architecture doc's I-spine (`docs/38` §"Verification & test primitives") is the durable
backbone; the UX-relevant ones are non-negotiable acceptance for these tickets:

- **I5 (sync-boundary purity):** taint-scan the projected/synced payload — **no transcript
  bodies, no pid/pane targets** cross it. The managed tile makes this *harder* (its events
  carry bodies) and therefore this check is mandatory for the managed/iOS tickets.
- **I6 (status soundness):** every `working`/`done`/`needsAttention` is backed by real
  evidence; unknown ⇒ `unknown`, never a fabricated status. Table-driven Core check on the
  pure `deriveAgentStatus` (T3C-01), including "a pending approval beats a running signal."

A UX ticket that ships (A)+(B)+(C) and honors I5/I6 is done. One that asserts a seam but
not a pixel, or bypasses the event path, or leaves the dogfood step vague, is **not** —
regardless of a green matrix.

---

## Relationship to the other docs

- **`docs/38-agent-orchestration-architecture.md`** — the parent. This doc is its UX layer;
  it decides nothing about topology/sync/readers, only what renders and how it's verified.
  Decision #10 (managed-agent tier, the FORK) is the architectural gate for §1/§3/§4.
- **`docs/35-observability-sidebar.md`** — §2 *is* the resolution of its open questions
  (dock vs slide-over → dock; default-visible → yes; one "go to" story → reuse focus
  plumbing). Render `SidebarTree`, don't redesign it.
- **`docs/2026-06-30-t3code-steal/06` and `/03`** — the mined prior art §1/§3/§4 build on
  (approvals-first status, symmetric respond, thin iOS observer, the managed transcript
  tile). Tickets T3C-01/03/04, T3E-01/03, T3SEC-01, T3A-01 in that dir's `TICKETS.md` are
  the implementation contracts; this doc is the UX design they reference.
- **`docs/26-visual-regression-harness.md` & `docs/37`** — §5 is these doctrines applied to
  this arc; the Component Lab (`ComponentLab.swift`) is where the visual gates live.
- **`docs/29` (keybind philosophy) & configurable-first doctrine** — every binding/threshold
  in this doc (dock toggle, notify categories, attention motion) ships with a persisted
  default + a Settings entry + a conflict-guard from its own phase.
