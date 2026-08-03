# Sidebar study — T3 Code read in full, and what Continuum should take

Written 2026-08-03. Five parallel read-only audits of **T3 Code at its newest sidebar branch**, not
`main`: `origin/subagent-obs/05-thread-visibility` (`573255c6c`, 220 commits ahead of
`origin/main`, tip 2026-08-04). Explored in a detached worktree at
`<scratchpad>/t3code-newest`; Dylan's own checkout stayed on `main`.

Reading `main` would have been wrong in three load-bearing ways, all corrected below: the naming
guard we were about to copy **has been deleted**, `titleSeed` is **dead**, and the row no longer
reads `session.status` at all. Supersedes the pattern-transfer section of
`plan-sidebar-brainstorm-handoff.md`; companion to `plan-sidebar-and-state-findings.md` (our own
defects). Paths prefixed `T3:` are relative to that worktree.

## The headline

**Continuum's inbox row *model* is already a faithful port of T3 Code's sidebar v2 semantics.**
Five states / three colours, unread-as-a-mark, `woke` gets a word, project-as-metadata-not-header,
frozen creation order, card/slim variants derived from lifecycle, in-flight fade. Independently
arrived at, and in two places Continuum is *ahead* (below).

The gap is not design. It is three specific things:

1. **The view paints containment T3 removed** — 1 pt border + opaque fill on every idle row.
2. **Status has three owners reading a frozen disk record**, where T3 has one reading live state.
3. **Nothing ever names an agent**, where T3 names it from the user's own first words.

And one genuine fork in the road, from work T3 shipped *last week*: whether agent-spawned children
belong in the list at all.

---

## 1. Borders and surface — the smallest, highest-value change

### What T3 does

**Rows have no border in any theme.** Confirmed across all four theme scopes and all five row
states (`T3: apps/web/src/components/SidebarV2.tsx:698-711`). Separation is a 1 pt gap plus a
6 pt corner radius; at rest the row is `bg-transparent`. The design rule, verbatim (`:694-697`):

> All Sidebar V2 rows share one surface model. Live threads used to look like elevated cards while
> settled threads were plain rows, leaving neither a useful hierarchy nor a reliable hover cue.
> **Status now lives in the row content; surface is reserved for interaction** (hover, multi-select,
> route).

Three fills, dark theme (`T3: apps/web/src/index.css:1068-1070`), as translucent foreground washes:

| State | Fill | Note |
|---|---|---|
| hover | 8 % foreground | transient feedback |
| route-active | 11 % foreground | the loudest |
| multi-selected | **7 %** foreground | *quieter than hover* — selection is a resting state |

Geometry tokens are declared **once, globally, and never re-declared per theme** (`:82-90`) so a
theme change can never move a pixel: content inset 8, row content inset 10, control gap 8, control
radius 8, icon 16, control height 32. Their comment: *"Keep these values semantic so sidebar,
palette, tooltip, and toolbar controls cannot quietly drift apart."*

Two row heights only — card **78 pt** content (82 pt box, 83 pt pitch) and slim **36 pt** — and the
rule for which (`SidebarV2.tsx:2835-2838`):

> Settled and snoozed are the ONLY things that collapse a row: every other thread is a full card.
> **Density comes from users (or the auto rules) actually parking work, not from the sidebar
> second-guessing what still matters.**

The card's three lines, and this is the part Continuum gets wrong: **the title owns a full line of
its own.** Line 1 = favicon + project (truncating) + status slot; line 2 = the title, alone,
`flex-1 truncate`; line 3 = branch (truncating) + terminal/PR/diff + right-aligned remote and
provider glyphs at 14 pt, `opacity-60`. The **model is never text on the row** — it is a greyscale
provider glyph, with the model *label* only in the hover tooltip (`:301-310`).

Row content is **never adapted to width**: 41 `min-w-0` + 17 `truncate` and zero width-conditional
row rendering. One flexible truncating title, everything else fixed. Width branching exists only
for *chrome* (the wordmark needs 216 pt, the stage label 252 pt, against a 208 pt minimum — so the
brand does vanish at minimum width, deliberately).

### What Continuum does today

The exact inverse. Every idle row paints `borderWidth = 1` with `LineToken.border` over an **opaque**
`SurfaceToken.tileBody` fill; selection swaps the border to `borderStrong` at the same width
(`AgentInboxView.swift:3703, 3715-3716`). Four view classes each paint their own 1 pt box
(`:2897, :3390, :3580, :3703`). `AgentSurfaceRole.rowHover` / `.rowSelected` — which already exist,
are already contrast-gated, and are already used by `ChoiceRowView` — are referenced by the inbox
**zero times**.

Correcting the handoff doc on two points: the in-flight fade **is** painted (`:3897, :4143`,
`alphaValue = emphasis.textOpacity`) and the slim variant **is** painted
(`AgentInboxSlimCellView`, `:1190`). Those two patterns landed.

### Adopt

- Idle `borderWidth = 0`, clear background; hover/selected/active as `AgentSurfaceRole` fills, with
  selection *quieter* than hover. This is the `ChoiceRowView` idiom already shipping next door.
- Give the agent name its own line. This inverts the current sacrifice order, where the name is the
  only compressible element (compression 250 at `:3756-3762`) and the project chip and elapsed
  label win against the row's own subject.
- Model → provider glyph plus abbreviated text at most, never the row's title.
- Keep the 79 pt card (T3's is 78 — the height was never the problem) and keep the two-variant
  density rule, which we already derive correctly from lifecycle.
- Hoist the geometry literals into one `Metrics`-style set of constants, theme-invariant.

Gate consequence unchanged from the findings doc: `minimumThemedViews = 27` /
`minimumSentineledSlots = 53` were measured **with** one outline slot per row and must be
re-measured in the same change; all seven `chrome.agentInbox*` baselines move.

---

## 2. Status truthfulness — one owner, and a launch-time sweep

### The correction that matters

On this branch the row does **not** read `session.status ∈ running|starting|error`. It reads
`runtime.status`, and `runtime.status` **is literally the latest run's status** —
`status: latestRun?.status ?? "idle"` (`T3: apps/server/.../ProjectionStore.ts:776, 830`), with
`latestRun` = newest run by ordinal. Ten values:
`idle | preparing | queued | starting | running | waiting | completed | interrupted | failed | cancelled | rolled_back`.
The provider-session's own status reaches the row through **exactly one field**: `lastError`.

Six named writers, and no others, can move a run's status; two carry idempotence guards worth
copying verbatim (`ProviderTurnStartService.ts:85-88`, `CheckpointCaptureService.ts:66-70`). The
client **never re-derives** — whole server records are upserted by monotonic sequence
(`shellReducer.ts:96-104`). One upstream, not three.

### What actually prevents our "Working 162h21m"

A **startup reconciliation that terminalizes rather than resumes**
(`T3: apps/server/src/orchestration-v2/ProviderRuntimeRecoveryService.ts`). One command per thread
sweeps every non-terminal run → `cancelled` with `completedAt: now`, every pending request →
`expired`, every session → `stopped`, plus attempts, nodes, subagents, turns, streaming messages.
The reason string is user-visible (`:107`):

> `Cancelled because the server ${trigger === "startup" ? "restarted" : "shut down"} before the provider work completed.`

Two details make it airtight, and both are the actual lesson:

- **It is gated, not merely ordered.** A global router middleware blocks *every* HTTP and WS
  request on `awaitCommandReady` (`server.ts:380-386, 407`), so no snapshot can be served before
  reconciliation commits. Test name: `"expires orphaned runtime requests before command readiness"`.
- **Shutdown runs the identical path** with a different reason, so there is one sweep to maintain.

They also reserve `cancelled` for the system and `interrupted` for the user — which is exactly what
lets you tell "the app killed this" from "I killed this" six days later.

And the premise that makes terminalize-not-resume coherent
(`ProviderSessionManager.ts:57-60`):

> It intentionally does not resurrect persisted sessions. Process-loss recovery terminalizes
> provider-bound work and retires non-replayable effects; a later user command or durable
> replay-safe operation opens a session lazily.

Elapsed is anchored to `run.startedAt ?? requestedAt ?? last transition` — never a creation
instant — written as a *first-valid* scan so a malformed timestamp falls through instead of
poisoning the clock, and clamped (`Number.isFinite ? max(0, …) : 0`), with both pinned by tests.

### Where T3 has our bug too — verified, not assumed

Worth knowing, because it means part of the fix has no upstream to copy:

- **Rows on an unreachable environment show ticking, animated "Working."** Their connection model
  is excellent and explicitly documented (*"It does not infer connection health from cached data or
  the existence of a transport object"* — `docs/internals/connection-runtime.md:86`), and then
  `snapshots.ts:12-19` **strips `status` and `error`** at the boundary, so downstream a cached
  snapshot is structurally indistinguishable from a live one. `environmentShellSummaryAtom` plus
  three siblings are built, tested, and wired to nobody — **their exact analogue of our
  `unobservedAgentIds`**. Mobile does it right (one folded state, one banner); web doesn't.
- **No turn-duration timeout anywhere.** A provider that never emits a terminal keeps a run
  `running` for the process's lifetime. Their only protection is "restart heals it."
- A `waiting` run whose checkpoint effect exhausts 5 retries ticks forever until restart.
- `lease_expires_at` is written in eight places and **never appears in a `WHERE` clause**.
- The "is it active?" predicate is inlined ~20 times in **three incompatible variants**; a canonical
  helper exists and web never calls it. Two presentation functions partition the same enum
  differently; mobile has a third.

**Continuum is ahead here.** `InboxState.state(for:pending:)` already *is* the single total
function, with its two deliberate divergences from `StatusChipPresenter` documented and pinned by
`runAgentInboxRowChecks`. Do not lose that.

### Adopt

1. **Reconcile at launch, before the sidebar can read anything.** Sweep every persisted agent whose
   status is non-terminal to a terminal one with a reason string. This single pass is what makes
   the 162 h row impossible.
2. **Gate the read, don't just order it.** The supervisor exposes no snapshot until the sweep
   commits; the inbox data source starts empty rather than starting from disk. Ordering alone
   loses to a lazily-built row.
3. **One owner.** Status comes from the supervisor's `AgentTileTurnSnapshot`; drafts contribute the
   timeline only. Architecturally clean: `AgentTileTurnSnapshot` is already `public` in
   `ContinuumRevivedCore` and `AgentInboxRowBuilder` already imports `ContinuumRevivedAgentUI`, so
   the builder can take an optional snapshot and map it to `InboxState` with **no new module edge**.
   `AgentTileStatePresenter` lives in the Canvas layer and cannot be the shared owner — the
   snapshot can.
4. **No snapshot ⇒ unconfirmed, never `working`.** This is what finally renders
   `unobservedAgentIds` and is the one place we can beat T3 outright: **freeze the ticking clock
   when observation is not live.** "Working 14m (last seen 3h ago)" is truthful; a ticking number
   is a lie. Nobody in T3 does this.
5. **Anchor elapsed to a stamped work start, first-valid ladder, clamped, capped/coarsened past
   24 h**, with one formatter shared with the tile header (which currently renders the same duration
   as `9502m 12s`).
6. Reserve system-cancel vs user-stop as distinct words, and surface the reason.
7. Make each rule a test *name*, not a comment.

---

## 3. Naming — Dylan's "prolly not" was wrong, with a twist

### Yes, they branch a local CLI to name a conversation

Verbatim argv (`T3: apps/server/src/textGeneration/CodexTextGeneration.ts:183-205`):

```
codex exec --ephemeral --skip-git-repo-check -s read-only \
  --model <m> --config model_reasoning_effort="low" \
  --output-schema <schema.json> --output-last-message <out.txt> -
```

Prompt on **stdin**, never argv. Claude's twin: `claude -p --output-format json --json-schema
'{"title":...}' --model <m>` (`ClaudeTextGeneration.ts:160-175`). Output schema is generated from a
one-field struct (`{title: String}`). Timeout 180 s. Failure is typed, logged, and swallowed — the
title just doesn't change. Cheap model by design: default
`{instanceId: "codex", model: "gpt-5.6-luna"}`, per-driver cheap defaults including
`claude-haiku-4-5`, reasoning effort floored at `"low"`. Prompt rules: *3-8 words*, "summarize the
request, don't restate it", no quotes/filler/prefixes/trailing punctuation; context is a
newest-first whole-message digest capped at 8 000 chars, ≤4 attachments. Output is then sanitized
regardless: first line only, strip wrapping quotes, collapse whitespace, ≤50 chars else
`slice(0,47) + "..."`, empty → the sentinel.

Two macOS constraints to inherit rather than rediscover:

- **Pre-resolve `PATH` from the login shell before spawning** (`packages/shared/src/shell.ts:305-328`
  with a `launchctl getenv PATH` fallback), or a GUI app's stunted PATH makes both binaries ENOENT.
- **Set `CLAUDE_CONFIG_DIR`, never `HOME`** (`provider/Drivers/ClaudeHome.ts:27-33`): overriding
  `HOME` relocates the login-keychain lookup and the CLI reports "Not logged in."

Two things they *don't* do and we should: a **concurrency cap** (they have none — N launches ⇒ N
processes) and a **process-group kill on timeout** (they rely on scope-close and can orphan MCP
grandchildren).

### The twist: that path is nearly dead in the shipping UI

Every client derives the title from the first prompt **client-side** and passes it in — web
`truncate(prompt, 50)`, mobile 72, MCP 80 — so the server's auto-naming trigger
(`input.title === "New thread"`, `ThreadLaunchService.ts:201`) is never true. Server auto-bootstrap
passes the sentinel but with no initial message, so it's false there too. **The only live
LLM-naming path on this branch is the explicit "Regenerate title" menu action.**

So the shipped answer to "what is a conversation called" is: **the user's own first words,
truncated.** The model is an on-demand upgrade, not the fallback. That is the rung that fixes our
screenshot, and it needs no new process machinery at all.

Also note the ladder's shape: five separate first-prompt derivations exist with **five divergent
limits** (50 / 50-plus-appended-ellipsis / 72 / 80 / 47+"…") and the sentinel `"New thread"` is a
**bare literal in five files with no shared constant** — which is precisely how their web and mobile
clients silently disabled server-side naming. One constant, one limit.

### The guard to port is V1's, not V2's

V2 **deleted** the protection we were about to copy. Its completion dispatch is unconditional
(`ThreadTitleRegenerationService.ts:116-121`): pre-flight checks the requestId *before* forking, so
a rename **during** the model call is silently clobbered. V1 had it right
(`orchestration/decider.ts:686-701`):

```ts
const requestIsCurrent = thread.titleRegeneration?.requestId === command.requestId;
  ...(requestIsCurrent && command.title !== undefined ? { title: command.title } : {}),
  ...(requestIsCurrent ? { titleRegeneration: null } : {}),
  updatedAt: requestIsCurrent ? occurredAt : thread.updatedAt,
```

V1 also carried `previousTitle` ("Title at request time, used to avoid overwriting a later manual
rename") and a schema-level rejection of `{title}` + `{regenerate:true}` together. Both dropped.
They have `expectedWorktreePath` and `expectedBranch` compare-and-swap fields but **no
`expectedTitle`** — that absence is the direct cause. Their one clobber test targets the dead V1
decider and asserts a timestamp rather than the title; `ThreadTitleRegenerationService.ts` has **no
test file at all**.

### The metadata inventory (what they thought worth knowing)

Beyond the obvious, from `OrchestrationV2AppThread` / `…ThreadShell`:

| Field | Why it's interesting for us |
|---|---|
| `createdBy` (`user`/`agent`/`system`), `creationSource` (`web`/`mobile`/`mcp`/`provider`/`server`) | Provenance as a first-class fact, separate from identity |
| `lineage {parentThreadId, relationshipToParent: fork\|subagent, rootThreadId}` | Parent link **plus the reason for it** — see §4 |
| `forkedFrom: {run} \| {node} \| {provider_thread}` | Exact fork point |
| `latestVisibleMessage {id, role, text, updatedAt}` | **The row's subtitle is the last message** — a far better use of line 3 than repeating the model id |
| `titleRegeneration {requestId, startedAt} \| null` | One field yields the spinner, the disabled menu item, and the supersession key |
| `itemCount` / `visibleItemCount` | Cheap "how much happened here" |
| `lastVisitedAt` | Read watermark, server-owned, with a documented old-server fallback |

Two absences are as instructive as the fields: there is **no `titleSource` / `titleIsManual`
anywhere in the repo** (the in-flight marker carries all the state), and **`role` exists only on
subagents, never on threads** — where it *is* a fixed enum used only to prefix the prompt, and
**never rendered as a name.** Our `displayName = role ?? model` is the exact inversion.

Their branch slug is our `WorktreeManager.slug` without the hash: lowercase,
`[a-z0-9/_-]`, 64-char cap applied *before* a final trailing-separator strip so truncation can never
leave a dangling `-`, empty → `"update"`. Their worktree path is a pure one-way function of the
branch with **zero collision handling** — two repos sharing a directory basename collide. Our
FNV-1a suffix is strictly stronger; keep it, adopt their "path is a pure function of the branch so
the two cannot drift" shape.

### Adopt — the three-rung ladder

1. **A required name with a sentinel default, not a nullable one.** An agent is born
   `"New agent"` (one constant, one place) and stays displayable. The sentinel is the permission
   slip to overwrite later.
2. **Seed from the first prompt inside `AgentSupervisor.send(_:to:)`** — already the single funnel
   for every prompt, including `makeAgent`'s forwarded first prompt — gated on the sentinel, using a
   human-cased twin of the existing slug sanitizer. Deterministic, synchronous, no process, no
   gate risk. **This alone fixes the screenshot.**
3. **Optional later: a one-shot generated title** on explicit request, forked, failure-swallowed,
   with V1's `requestIsCurrent` guard plus an `expectedTitle` CAS, a concurrency cap, and a
   process-group kill. Its own packet — it is new runtime surface.

Rung 3's manual half already exists (P3.13 inline rename). Their rename UX is worth matching in
detail: double-click the row body (bail on modifiers, bail if already editing, bail if the click came
from a nested control), Enter commits / Escape cancels / **blur commits guarded by a `didCommit`
flag**, and suppress the trailing click of a double-click so renaming doesn't also navigate.

Continuum-only naming sources T3 lacks, better than anything a model would write: `role`
(`.pi/agents/<role>.md`), `sourceItemId` (a ticket / queue item), `worktreeBranch`. For
overnight-loop agents the ticket id *is* the name.

---

## 4. The fork in the road: nested children, or a panel

T3 Code's newest stack (last 30 commits) is subagent observability, and it made a decision we have
not: **agent-spawned child threads are hidden from every user-facing list**, server-side, and
surfaced in a right-side **Agents panel** instead. The argument, verbatim (`d0f89e73e`):

> A subagent's child thread is an implementation detail of the agent that owns it, not a
> conversation the user started. **Listing them alongside real threads makes the sidebar grow with
> every delegation.**
>
> Filtered at the source — the shell snapshot the server serves — so every client sees the same set
> rather than each re-deriving it. […]
>
> Trade-off worth stating plainly: a subagent's transcript becomes unreachable. […] That is the
> intended shape here, and the "Open subagent thread" affordances are removed on both clients
> rather than left as dead ends.

Two things reframe this for us:

- **They never built indentation at all** — no depth field, no depth cap, no indent primitive
  anywhere; even user forks are flat rows. So they did not choose panel-over-nesting; they chose
  panel-over-flat-list-pollution. **We have nesting they never had.** Our `depth ≤ 2` bounds
  *nesting* but not *fan-out*: one agent spawning 30 children is 30 depth-1 rows, and fan-out is the
  problem they actually named.
- **The shape they shipped is two-tier, and it is available to us without giving up nesting:** a
  *bounded* inline summary where the work happened (member rows capped at 8, running and failed
  first, then most-recently-updated, remainder deferred) plus an unbounded panel one click away,
  connected by an explicit "Details" affordance.

Three warnings from their implementation, each cheap to inherit and expensive to rediscover:

1. **Hiding rows breaks resource bookkeeping.** Hidden children still held git worktrees, so they
   had to add a whole unfiltered RPC (`listAllThreadRefs`) and make cleanup **fail closed** rather
   than guess from the filtered list. Keep `allAgents` and `visibleAgents` as separate accessors
   from day one.
2. **A parent does not inherit its child's attention, and they have the bug.** A Codex subagent's
   approval request is stamped with the **child's** id, the parent's row never reads it, and the
   child is filtered out of every list — so **a subagent blocked on approval leaves no signal on any
   visible row.** Their `approvalsCanOriginateFromSubagents` capability flag has zero readers. If we
   ever collapse or hide children we must propagate `needsApproval` upward explicitly.
3. **The one roll-up they did build is the right one:** a live child *holds the parent's run open*,
   so the parent reads "working" for free — one mechanism instead of a status-aggregation function,
   and it survives restart.

Also worth stealing whatever we choose: an explicit **`idle` state distinct from `completed`** for a
reusable child identity ("resting between activations, still resumable"), because it changed what
can be stopped, whether trailing events apply, and whether a later run can re-adopt the row. Without
it, reuse looks like a duplicate row appearing. And their translation safeguard: a child status is
never *copied* onto a parent-visible field, it goes through an exhaustive mapping so adding a status
without giving it a parent meaning is a **compile error** — in Swift, a `switch` with no `default`.

---

## 5. Lifecycle rules worth adopting wholesale

Our five persisted fields and both enums already match theirs; the transition *rules* are what we
lack. The valuable ones, condensed:

- **Lifecycle is a pure derivation, never a stored enum** — no column, no cron, recomputed from
  `(fields, now, autoSettleAfterDays, prState)` at every read.
- **Activity blockers outrank every override, in both directions**, and the classifier and the
  "can I settle this?" predicate share one blocker list: *anything you refuse to CLASSIFY as settled
  must also be refused as a settle TARGET* — pinned by a test asserting the two agree.
- **Auto-settle** on inactivity: strict `<`, day-granular, default **3 days**, range 1–90, `nil` =
  off, measured from *real* activity (max of user message / run requested / started / completed) and
  explicitly **not** `updatedAt`, or bookkeeping writes keep dead rows alive.
- **PR state is a hard override both ways**: merged/closed settles immediately; open **never**
  auto-settles, because *"review can take days, and hiding the thread would bury the work waiting on
  it."*
- **Snooze is a visibility overlay, never a pause** — the agent keeps running, so a *working* row is
  snoozable (unlike settle). **Wake is derived, not scheduled**: no daemon writes the field back;
  stale fields simply stop classifying. Arm at most one timer for the earliest wake purely to
  re-render.
- **Early wake is a "raised hand" that never mutates the stored snooze**, compared against
  `snoozedAt` not `snoozedUntil`: *"a thread snoozed while already failed stays snoozed; that snooze
  was the user saying 'I saw it, not now.'"*
- The two attention defaults are deliberately **opposite**: never-visited counts as **woke** (an
  explicit act deserves the reminder; corrupt local data must not eat the signal) but as **read**
  (flipping a flag must not light up every historical row).
- **Recording a visit must not bump `updatedAt`**, or reading your inbox reorders it; visit writes
  throttled ~10 s but unread-clearing passes through immediately.
- **Activity never reorders a row**; always add a stable id tie-break or equal timestamps swap rows
  on reload. Precedence **snoozed > settled > active**.
- **Settled ≠ archived**: settled stays in the stream and is partitioned out; only archive leaves.
  Sidebar v2 dropped archive from the row menu entirely once settle existed.
- **Hide, never disable, an affordance a peer can't honour** — read the capability with an explicit
  `== true` so *absent* means unsupported, refuse classification into the gated state so no row is
  stranded in a shelf with no working button, and keep a dispatch-time refusal with a human message.
- **Idempotent by re-emission**: a duplicate settle re-emits the *original* `settledAt` and the
  existing `updatedAt`, so bulk-settle and double-click are silent no-ops that reorder nothing.
- **Silent settle, confirmed snooze** — settle is the high-frequency daily verb.

Two AppKit-specific notes: quantizing `now` to the minute for memoization is fine for settle but the
snooze comparison needs a real `Date()`, *"a woken thread must not linger on the shelf for the rest
of the minute"*; and clamp any timer delay so a far-future wake can't produce a degenerate immediate
fire.

---

## 6. Shell and width — mechanics to copy directly

Their sidebar geometry is settled (the 220 commits are all about row *content*), so it is worth
copying rather than re-deriving. Numbers: sidebar min **208**, default **256**, content-pane min
**640**, so `maxSidebar = max(208, floor(viewport) − 640)` — the maximum is *computed*, never
hardcoded. Ours is 280 default / 220 min, comfortably above theirs.

- **Persist width and open-state through different channels**, and restore width **before first
  paint** (*"so a restored sidebar never flashes at the default width first"*) — in AppKit that is
  `viewWillAppear`, not `viewDidAppear`, and write on resize-*ended*, never per-frame.
- **No snapping, no detents** anywhere — pure `max(min, min(w, max))`.
- **Veto asymmetrically**: shrinking always allowed; growing only if the detail pane keeps its floor.
  A rejected drag produces **no state change**, so anything cached at layout time goes stale —
  subscribe to resize rather than snapshotting.
- One **16 pt** grab strip doing double duty (resize when open, toggle when collapsed) with a 2 pt
  hairline that appears only on hover and a 2 pt drag threshold that suppresses the click.
- **Three fixed bands, one scroller**: 52 pt title band → fixed filter/search band → scrolling list →
  fixed footer. The search field is a *sibling of* the scroll view, never a table header.
- Hide the scrollbar; use a 24 pt edge fade masked by `min(fadeSize, actualOverflow)` so nothing
  fades at rest.
- **Narrow a project hierarchy with a fixed-width filter control**, not variable-width chips or
  nested groups: *"Scoping filters the list without making the header width depend on the number or
  length of project names"*, with the popup pinned to the trigger's width. Corollary: **flipping the
  filter must clear the multi-selection** — *"bulk actions must never count or touch invisible
  rows."* (Our scope control is still a raw Aqua `NSPopUpButton`; `ChoiceButton` is in the same
  target and ready to use.)
- Modifier-held jump hints are an **overlay, never an inline slot** (*"holding ⌘ used to blank out
  'Working'"*), `hitTest` → nil, capped at **9**, indexed against only the rows actually rendered,
  and shown only when the held modifier set *exactly* matches a binding so ⌘⇧4 doesn't light up the
  sidebar.
- History pages 10 then 25, and the button is labelled with the **next page size**, not the
  remainder.
- Bake grain into each surface's own background, not a window-wide overlay: *"a full-viewport overlay
  forces the compositor to re-blend every frame any animation produces."*

---

## Owner decisions

1. **Packet shape.** Recommendation unchanged: split. Borders/surface/title-line/scope-control is a
   visual gate (the inbox counterpart of P4.10). Status ownership + launch reconciliation is a
   separate gate — it touches the phone payload and deserves its own witness set.
2. **Naming.** Recommendation: rung 1 + 2 (sentinel constant + first-prompt seed in the send funnel)
   in the first packet — it is ~30 lines and kills the defect. Rung 3 (one-shot LLM title) is its own
   later packet, and per their own experience the explicit "Regenerate name" action is what users
   actually exercise, so build that before any automatic path.
3. **Status rules.** Recommendation: launch-sweep + gated read + one owner + unconfirmed-with-frozen-
   clock. That is a superset of the findings doc's 2+1+3+4 and it is what makes the row structurally
   unable to lie.
4. **Children: keep nesting, or panel?** New decision, and the one worth thinking about longest.
   Recommendation: keep nesting *and* cap fan-out per parent with priority ordering (running/failed
   first), because our depth cap doesn't bound fan-out and theirs is the failure they actually hit.
   Either way, propagate child attention upward explicitly — that is a live bug in their shipped code.
5. **Ticket 93** (border width token) — the inbox is its natural first consumer.

## Preflight (unchanged)

Quit Dylan's instance before any app probe or relaunch. Never `swift build` mid-matrix. Baselines
only at a supervised gate with `check-retina-main.swift` passing. Ledger rows stay `pending` until
the done-commit; one local commit, Dylan's identity, no trailers, never push;
`scripts/check-agent-tile-ux-program.sh --check` green before committing.

## Provenance

Five parallel read-only audits at `573255c6c`, ~64 K + 59 K + 65 K words of findings with
`path:line` citations, retained in this session's tool-results. The exploration worktree is
`<scratchpad>/t3code-newest` (detached; `git worktree remove` when done). Corrections this study
made to earlier reading of `origin/main`: the V2 title-clobber guard is deleted, `titleSeed` is
dead, `session.status` is superseded by `runtime.status`, and `ProviderCommandReactor.ts` no longer
exists.
