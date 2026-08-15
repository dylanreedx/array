# 96 — Handoff

Written 2026-08-15. Everything needed to pick this up cold.

Read first: `_DESIGN.md` (the authority), then this file, then `_LEDGER.md` (every
witness and every wrong turn, in the order they happened). `S0-density-review.md` holds
the open rulings; `P0.1-fixture-inventory.md` records what production actually renders.

`_DESIGN.md` is untracked in Dylan's main checkout and therefore absent from this branch.
Read it from
`/Users/dylan/Documents/personal/Array/docs/38-tickets/96-agent-sidebar-product-redesign/_DESIGN.md`.

---

## Where the work is

| | |
|---|---|
| worktree | `~/array-worktrees/sidebar-96` |
| branch | `array/sidebar-96`, base `d334f01` |
| HEAD | `ab161a2`, **clean tree**, 27 commits |
| preview app | `~/Desktop/Array Dev 96.app` on `~/array-scratch-96` |

## HOW TO ITERATE — read this before anything else

```sh
cd ~/array-worktrees/sidebar-96
scripts/sidebar-96-preview.sh        # build + reinstall + relaunch, ~25s
# → View → Component Lab → Sidebar 96 → Live Sidebar
```

Three checkboxes there drive the three previews: **96 row** / **96 header** / **Hover
card**, each A/B-able against what ships.

**Why skipping the gates is legitimate.** Everything this program has built reaches the
screen through a seam that is nil or false everywhere except the Lab:

| seam | what it swaps | default |
|---|---|---|
| `AgentInboxView.cardStyleOverride` | the redesigned row | `nil` |
| `AgentInboxView.headerStyleOverride` | the stacked search header | `nil` |
| `AgentInboxView.hoverCardEnabled` | the hover card | `false` |

A visual change behind one of those cannot alter production, cannot alter what any
queue-94 gate renders, and cannot touch a committed baseline. Running seven checks to look
at a colour is ceremony.

**Run the full pass at these moments, and not otherwise:**

1. **Any change that leaves the preview path** — `DesignTokens.swift` is shared with the
   whole app and iOS; `AgentInboxRow` is shared with Core and every fixture; a new
   `TokenThemed` view is hunted by the census whether or not anything renders it.
2. **Before locking a decision** — a ruling written into `S0-density-review.md`, or a
   ledger entry claiming something is true.
3. **Before any of these becomes the default** rather than an injected override, plus a
   tmux-isolated matrix run.

The full pass is listed at the top of `scripts/sidebar-96-preview.sh` and in
**Verifying**, below.

---

## The design, as it now stands

### A finished row's whole life — three steps, no vocabulary to learn

| state | word | colour | glyph |
|---|---|---|---|
| working | `Working · 1m 24s` | blue | the app's throbber, spinning |
| approval **or** input | `Needs attention` | amber | `hand.raised.fill` |
| failed | `Failed · 12m` | red | `exclamationmark.triangle.fill` |
| finished, unread | `Done · 1m 30s` | **mint** | `checkmark.circle.fill` |
| finished, **read** | `22m` — no word at all | none | none |

Looking at a row IS the acknowledgement, and the reward for it is a row that stops
talking. It keeps its age, because "when did this land" stays a fair question.

Two earlier designs died here and the reasons are worth keeping:

- **`Landed` / `Waiting`** — two words for one fact, so the reader had to learn that they
  were the same fact. The age beside the word already carried the difference.
- **A pulsing mark on the unread row.** It was guarding the wrong row. An unread row is
  already coloured, marked, and sorted where you will see it; the row that actually gets
  lost is the one you read two hours ago, said "yep" to, and never closed. That is the
  settle nudge's job — see the backlog — and it is a different row entirely.

### The palette — one colour per meaning, and colour means "this wants you"

`accentReview` is **mint**: light `#096B57`, dark `#4CD6B4`. Measured, not estimated —
worst case **5.41 light / 7.35 dark**, and **4.77 / 7.75** against the strongest sidebar
fill.

It replaced a rose (`#E5799B`) that Dylan rejected on sight as a second error colour. He
was right and it was measurable: the dark failure red is hue 3° and that rose was 342° —
**21° apart**, with nothing in the gate to notice.

**`.ready` returns no accent at all**, and that is what makes mint legal. Mint sits 25°
from `accentDone` green, so keeping green on the row would have repeated the rose's
failure one hue over. Retiring green costs nothing (a settled row is the one row asking
for nothing) and buys mint a **48° gap** to its nearest neighbour, the widest in the
palette.

**There is now a witness for the defect itself.** Nothing in the suite compared two
*different* accents to each other — only one accent across themes, and exact-value
collisions. `runDesignTokenChecks` now requires **30°** between any two accents that can
share a list. Tightest real pair is red/amber at 32°; the rose measures 21.40 and fails.
`accentDone`/`accentReview` are exempted **by name**, with the reason recorded, rather
than by lowering the floor for everybody.

### The header — stacked, and boxless

Search takes a full-width row above the scope control: a magnifier at 14pt, no border and
no resting fill, a hover fill to say it is a target, the focus hairline only while a caret
is genuinely in it, and a clear button that appears with text — its space reserved
permanently, so typing the first character does not shove the rest sideways.

Boxless because that is what the reference does: T3's input is `unstyled` inside a row
that only takes `hover:bg-sidebar-row-hover`.

**Costs about a third of an agent row.** That is a live input to the S0 pitch ruling.

### The hover card — the tooltip §4.3 already depended on

`InboxHoverCard.swift`. Hovering a row opens a card to its right after **150ms**, with a
**400ms grace** after close where the next one opens instantly (without it, running the
pointer down the list re-serves the delay on every row and scanning feels like wading).

Lines, all optional, all hidden when absent: full title · project · **zone** · host ·
branch · **branch mismatch** · **harness** · exact model id · exact timestamp.

This is not decoration. §4.3's measured-fit sacrifice order lets a narrowing row drop
placement, model text and branch detail **on the stated condition that they survive in the
tooltip**. No tooltip existed, so every drop was a plain loss — P0.1 measured three
long-title flows rendering no project at all at the default width.

---

## What exists in code

| file | what |
|---|---|
| `App/AgentInbox96CellView.swift` | the redesigned row; owns `InkAlignedSymbol`, `BrandMark96`, `StatusGlyphView`, the palette, `isUnseen`, `isSettleCandidate` |
| `App/InboxHoverCard.swift` | `InboxHoverCardView` + `InboxHoverCardLine` |
| `App/AgentInboxView.swift` | the three seams, the hover-card controller, `InsetTextFieldCell`, the two header constraint sets |
| `App/SidebarScreenshotChecks.swift` | 48 images, `AgentInbox96Fixtures`, the hover-card witness |
| `App/ComponentLab.swift` | `SidebarInbox96PlaygroundView` + the three checkboxes; `place()`'s clamp; `expectEverySurfaceFitsTheHost` |
| `AgentUI/DesignTokens.swift` | `accentReview` mint, and the provenance tables |
| `AgentUIChecks/DesignTokenChecks.swift` | pinned margins + the accent-separation witness |
| `Core/Agents/AgentContextIndex.swift` | `AgentRowContext.harness` |
| `Core/Agents/AgentInboxRowBuilder.swift` | stops dropping zone/harness/mismatch |
| `AgentUI/AgentInboxRow.swift` | `zoneName`, `harness`, `checkedOutBranch`, `isBranchMismatch` |

### Row fields added this round

`zoneName`, `harness`, `checkedOutBranch` — Foundation-only `String?`, because
`ContinuumRevivedAgentUI` has no dependencies and cannot see Core's `AgentHarness`. All
three already existed in `AgentRowContext` and were being discarded; **`zoneName` had zero
consumers in the entire app**.

`checkedOutBranch` is carried **only when it disagrees** with the agent's branch, so
`isBranchMismatch` is a plain presence test and no surface re-derives the comparison.

---

## Verifying

```sh
swift run ContinuumRevivedAgentUIChecks           # twice on a colour change: read table, fix pins, re-run
.build/debug/Array --sidebar-screenshot-check     # 48 images + the hover-card witness; then LOOK at them
.build/debug/Array --sidebar-ux-check             # 90 filter-band assertions
.build/debug/Array --agent-inbox-check
.build/debug/Array --sidebar-production-corpus-check
.build/debug/Array --ui-probe-check               # the token census
.build/debug/Array --ui-contrast-check
scripts/check-color-hygiene.sh
```

All green at `ab161a2`.

**Run every app leg tmux-isolated** — the corpus drives real writers, and CoreChecks has
killed a live Array before:

```sh
env -u TMUX -u TMUX_PANE TMUX_TMPDIR=<disposable> CONTINUUM_APP_SUPPORT=<disposable> \
  .build/debug/Array --<flag>-check
```

**Reading a pinned contrast table.** `expect` exits on the FIRST failure, so it is two
passes: `TokenContrastChecks` prints all 116 pairs *before* asserting, then
`main.swift:~1203` prints the 30 sidebar pairs — but only if you got that far. Read the
numbers out of the harness; never estimate them.

**KNOWN-RED, pre-existing, do not chase:**
- `--component-lab-check` — the composer provider footer leg.
- `--ui-baseline-check` — 12 `chrome.agentInbox*` baselines committed at 320×652 while
  `scopeControlHeight` now computes to 40, so they render at 320×660. Stale since
  `84a4d16` grew the band 8pt without re-blessing, months before this program. **20 PNGs
  will need re-blessing when the header lands for real**, and that size mismatch has to be
  fixed regardless of what we decide.

Never `CONTINUUM_UPDATE_BASELINES=1`. Never touch `MATRIX_KNOWN_RED`.

---

## What is next, in order

### 1. The settle nudge pill — designed by Dylan, not built

The one thing that makes a read row leave. His spec, verbatim in intent: a pill slides in
from the trailing edge of the row, an animated magic wand with stars appearing on its
left, a glimmering 2–4 word phrase (*"Ya done?"*, *"All set?"*), a close/archive button on
the right, opening and closing roughly every 30 seconds.

Already in place: `AgentInbox96CellView.settleNudgeDelay` (10 min) and
`isSettleCandidate(_:now:)` — done, acknowledged, still `.active`, older than the delay.

Five things it must get right, each a rule this program already paid for:

- **One clock, not one timer per row.** Copy the injectable-scheduler seam
  (`AgentInboxView.wakeRerenderScheduler`, and `hoverCardScheduler` right beside it) so a
  check fires the cycle without sleeping.
- **One reused layer-backed view per cell**, `CAAnimation`, no measurement in `layout()`.
  A view per content item is how the Markdown tile froze the app.
- **Only visible rows animate**, and it stops on reuse the way `StatusGlyphView.prepareForReuse()`
  does.
- **Reduce Motion** → static pill or none, read through `prefersReducedMotion`.
- **Hit-testing.** Unlike the jump hint and the hover card, this one has a button, so it
  must take clicks without breaking row activation or double-click-to-rename — and it
  needs the `allRowElementFramesForQA` exemption that today skips only `InboxJumpHintView`.

**Cap it.** Six settled rows all blooming every 30 seconds is a slot machine. Nudge the
oldest one or two, or only when nothing else in the list is asking for anything.

The verb is **Settle** — `canSettle(rollup:)` and the row menu's `Settle` already exist,
and it is the reversible one.

### 2. Pointing-hand cursor over rows

~20 lines. `resetCursorRects()` + `addCursorRect(_:cursor:)`, the pattern at
`WorkspaceSidebarView.swift:~381` and `CanvasNSView.swift:~1943`. There is no shared
helper and no `.cursorUpdate` usage anywhere. Cursor rects are discarded on scroll, so
invalidate from the clip-bounds notification hover already listens to. Expose a
`…CursorForQA` accessor and assert with `===`, the shape `resizeCursorForQA` uses.

### 3. Project icons (P3.2) — the question is answered and verified on disk

T3's `apps/server/src/project/ProjectFaviconResolver.ts` tries a `t3.json` `iconPath`,
then 21 well-known paths (`favicon.svg|ico|png` at root, `public/`, `app/`, `src/`,
`src/app/`, `assets/icon|logo`, `.idea/icon.svg`), then parses `index.html` /
`__root.tsx` / `root.tsx` for `<link rel="icon" href>`. Every candidate goes through a
containment check. **No network.**

Verified both directions: `~/Documents/personal/krunkapp/public/favicon.ico` exists
(candidate #5) → T3 draws the pink blob; `~/Documents/personal` has **none** of the 21 →
T3 draws a folder.

`_DESIGN.md` §4.5 already ruled the same ladder and it is a locked §11 decision. Four
things to get right:

- **Sniff content, don't trust the extension.** `krunkapp/public/favicon.ico` is a 32×32
  **PNG**. `NSImage(contentsOf:)` sniffs; a strict ICO parser would fail on the real file.
- **Containment must survive symlinks** — resolve, then verify the prefix.
- Size-cap the read, decode off-main, downscale to 2× the slot, cache by project id, keep
  the prior image until a replacement succeeds, no directory walk.
- The row carries `projectName` but no id. Add `projectId: UUID?` (Foundation-only, legal)
  and resolve the root registry-side — **the root must not go on the row** (I5).

§10 forbids fetching logos at runtime. A local read is not a fetch, but **no network
fallback ever** — no GitHub org avatars.

### 4. The ink-alignment witness does not watch the live cell

`AgentInbox96CellView.swift`'s header claims `SidebarScreenshotChecks` calls into
`InkAlignedSymbol`. It does not — `InkAlignedSymbol` has **zero** references outside its
own file, and `SidebarScreenshotChecks.swift` (~:1625-1690) carries a second, duplicated
implementation whose witness measures the *mock's* symbol set (hand + triangle only). The
live cell now draws `checkmark.circle.fill`, which that witness has never seen. This is
non-negotiable #2: a witness that does not watch behaviour. Point it at the live
implementation and delete the duplicate.

### 5. Right-click menu — blocked on Dylan

He asked how T3's looks. The screenshots he has sent are of the list, not a menu, and it
was not guessed at. Array's row menu today: Open / Rename / Settle / Snooze › / Mark
Unread / Archive / Delete, unavailable actions hidden rather than greyed.

---

## Open rulings

1. **Pitch** — A (66/68), B (72/75), or keep today's 79/83? No proposal reaches §8.1's
   nine-row floor; the arithmetic is in `S0-density-review.md`. **The stacked header
   changes this input** — it costs about a third of a row.
2. **Collapse the hidden management label?** ~18 pt, and it decides whether A works.
3. **Is nine rows still the right floor**, now the chrome is measured?
4. **Zone in the placement band** — *proposed resolution: no, the hover card carries it.*
   Not yet ruled.
5. **Card border** — none / 2 pt rail / bracket. My read: none, the glyph column does it.
6. **Branch glyph** — keep it?
7. **Right-click menu**, per above.

Also observed from T3 and now partly adopted: quiet rows there carry only a relative time,
no state word. Array's read rows now do exactly that.

---

## Traps this round found — all of them by LOOKING

1. **`NSTextFieldCell()` carries AppKit's default title, the literal `Field`.** Swapping
   a cell into an `NSTextField` puts it in the field. It looks like a placeholder (the
   real one is hidden whenever `stringValue` is non-empty) and never filters anything
   (`controlTextDidChange` fires on edits, not on a value the field was born with).
2. **`window?.firstResponder === searchField.currentEditor()` is `nil === nil`** when
   unfocused, which is `true`. The "focus ring" was painted at construction and never
   cleared.
3. **`place()` centred an oversized surface at a negative origin**, shearing equal slices
   off both ends. Two Lab surfaces had been sheared for their whole lives.
4. **A check placed after a red leg never runs.** The surfaces-fit check first sat after
   `--component-lab-check`'s known-red composer leg and stayed *silent* with a surface
   declared at 1600pt. Hoisted, it fires. Verified both ways.
5. **The token census needs a new `TokenThemed` view in BOTH sweeps** — the appearance
   surfaces and `adoptedSurfaces()`. Registering the name alone produces "adopted owners
   that painted nothing".
6. **`withUnconfirmed` rebuilds a row by hand** and silently drops any field it does not
   name — on the live path, against the rows whose state is least certain.
7. **`agentKind` is `.managed` for every row the inbox draws.** The harness comes from
   `AgentRecord.harness`.
8. **The `NSSplitView` adopts an added subview as a PANE** and overwrites its frame; that
   is how the command palette once rendered as a sidebar. Window-level overlays go in the
   content view, which is a plain container for exactly this reason.
9. **A sidebar subview overhanging the trailing edge is occluded, not clipped**, by the
   canvas pane added after it — invisible rather than cut, which is harder to diagnose.

Earlier rounds' traps, still worth reading: a check asserting only that flows *ran*; a
live check reporting PASS over "No agents yet"; four "accessibility variant" images
byte-identical to the baseline; a manifest hard-coding `verdict: "PASS"`; a density
formula over-counting in the direction that flattered the proposal; an ink normalisation
that equalised the dimension which was already equal; a cell whose bands drew upside down;
`Done` rendering as `Do…`; brand marks matching no production row; a throbber that never
span.

The pattern behind every one: **an artifact that looks like evidence but was never checked
against what the product paints.**

---

## Rules that bite

- **Commits under Dylan's identity only.** No `Co-Authored-By`, no AI trailers, ever.
- **Never rebuild or quit `/Applications/Array.app`** (his workspace) or
  `~/Desktop/Array Dev.app` (the shared preview). This program owns `Array Dev 96.app`.
- **Never guess a `--*-check` flag** — an unknown one boots the full app and hangs the
  shell. Enumerate:
  `grep -oE '\-\-[a-z0-9-]+-check' Sources/ContinuumRevived/App/ContinuumApp.swift | sort -u`
- **The list hands cells `now` from its own `clock`**, defaulting to the wall clock. Any
  age-based rendering needs the clock pinned or the fixture measures nothing.
- An offscreen `NSTableView` **defers its incremental reload indefinitely** — use
  `rebuildRowsForQA()`.
- `ComponentLab.swift`'s queue-94 gate scans only between the two `P0.3 SIDEBAR DEFECT
  CORPUS` markers; everything this program adds is well past them.
- Stay out of `.plans/17–21`, `PerfScenarios.swift`, `CanvasNSView.swift` and the perf
  docs — `array/canvas-perf` owns them.
