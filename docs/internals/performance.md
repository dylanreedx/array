# Performance on the canvas

Array is one window, one main thread, and one display cycle shared by every live
tile. A surface that is merely "a bit expensive" in isolation becomes a frozen
app when it is one of nine tiles on a canvas that re-lays out whenever anything
moves. This file is the standing guidance for building a new tile, renderer, or
document view, plus the tooling that finds the problem when one ships anyway.

It exists because the Markdown file tile shipped in 0.4.15 and took **three
releases** to stop hanging the app. The numbers below are all measured from that
episode; the case study is at the end.

## The one rule

> **Work proportional to content × work repeated per display cycle = a frozen
> app.** Either factor alone is survivable. Together they are not.

Every trap below is a special case of that product being large.

## The four traps

### 1. One AppKit view per content item

A view per semantic block is the obvious way to render a document, and it is
right for a chat message. It is ruinous for a file, because the input size is
whatever the user opens:

| document | blocks | build | layout | resident |
|---|---|---|---|---|
| `docs/VERSIONING.md` (28 KB) | 11 | 0.030 s | 0.021 s | — |
| `docs/09-decisions.md` (84 KB) | 293 | 0.137 s | 0.089 s | — |
| generated 546 KB | 12,000 | 5.147 s | 5.145 s | **1.39 GB** |

`FilePreview` admits files up to 1 MB, so the worst case was roughly double the
last row. Each block view carries its own TextKit stack — a layout manager, a
text container, a text storage.

**Do:** bound the number of live views, or virtualize (build views only for what
is on screen). `AgentTranscriptListView` already virtualizes the transcript; the
file document is only *bounded*, which is the cheap version.

**Never:** silently truncate. The Markdown preview renders 400 blocks and then
renders a visible notice saying how many it held back and where to see the rest.
A user must never be shown a document that quietly stops.

### 2. Measuring inside `layout()`

`layout()` runs on every display cycle that dirties the view — a pan, a zoom, a
tile move, an appearance flip, a neighbour resizing. Anything expensive in there
is multiplied by that frequency.

Measuring text is expensive in ways that do not look expensive:

- `RichInlineTextView.measuredHeight` builds a fresh `NSAttributedString` for the
  row, and `AgentTextStyleResolver` runs **five** `replacingOccurrences` passes
  per text run inside the Markdown escape.
- `CodeTextView.measuredCodeSize` measures the entire source at *unbounded*
  width — and a GFM table becomes one fenced block, so a wide ledger table is one
  enormous single-line measurement.

**Do:** cache measured heights keyed by the width they were measured at, and
invalidate on content or theme change. That is the whole fix; it took ~20 lines
in `FileMarkdownDocumentView` and ~15 in `AssistantProseView`.

### 3. Assigning a frame that did not change

```swift
view.frame = frame          // even when identical
```

For an `NSTextView` this costs a TextKit glyph-bounds pass (`setFrameSize:` →
`_boundingRectForGlyphRange:`) **and** marks the view as needing layout again,
which is how a display cycle keeps finding work to do. In the 0.4.16 CPU report,
20 of 34 samples were in exactly this path.

**Do:** `if view.frame != frame { view.frame = frame }`.

### 4. Sizing a view from inside its own `layout()`

Calling `setFrameSize` on `self` during `layout()` makes AppKit re-enter layout
for that subtree. The 0.4.15 hang report is 53 nested `_layoutSubtreeWithOldSize:`
frames.

**Do:** return the size from `intrinsicContentSize` and call
`invalidateIntrinsicContentSize()` when it genuinely changes. The layout engine
then converges instead of recursing.

## Environment differences a check will not show you

A self-check on this laptop is not the user's machine:

- **Scroller style.** macOS uses *overlay* scrollers on a trackpad and *legacy*
  scrollers when a mouse is connected. A legacy scroller **takes clip width** when
  it appears, which changes a document's width, which changes its height, which
  can hide the scroller again. Pin `scrollView.scrollerStyle = .overlay` for a
  document you size yourself, and test with `.legacy` explicitly.
- **Display scale and appearance** change text metrics; measure in both themes if
  a surface caches heights.
- **Content the user has** is not the content you generated. Every synthetic
  fixture in the 0.4.15 work rendered fine; the file that hung was the repo's own
  `AGENTS.md` sitting in a restored canvas.

## Getting evidence when something is slow

Reasoning about AppKit performance is how the 0.4.15 episode wasted two releases.
Do this instead — in this order:

1. **`/Library/Logs/DiagnosticReports/Array_*.cpu_resource.diag`** — macOS writes
   this automatically when a process exceeds a CPU limit. It contains the heaviest
   stack with per-frame sample counts and the app version. It named the exact
   method both times. Read it FIRST.
2. **`…​.hang`** in the same directory — written when the main thread stops
   servicing events. Same shape, plus a duration.
3. **`sample <pid> 3 -f /tmp/spin.txt`** on a live process — the fastest way to
   confirm a running app is still in the path you think it is. This is what
   proved the wedged 0.4.16 was spending 725 of ~750 samples in
   `AssistantProseView.layout()`.
4. **`/usr/bin/time -l`** on a self-check binary for peak resident size.
5. **`.ips` crash reports** for a real crash — `EXC_BREAKPOINT`/`SIGTRAP` is a
   Swift runtime trap (force-unwrap, array bounds, **arithmetic overflow**), not
   memory pressure.
6. **`JetsamEvent-*.ips`** when the app vanished and left NO report of its own.
   macOS killing a process under memory pressure writes one system-wide report,
   not a per-process crash log. It lists every process with its footprint in
   16 KB pages, so `rpages × 16384` is the app's size at the moment of death, and
   `memoryStatus.memoryPages.free` is what the machine had left. Array being
   killed at **334 MB while the system had 86 MB free and 7.1 GB compressed** is
   a machine problem, not an app problem — and it looked exactly like an app
   crash from the outside.

### Reading a report without fooling yourself

Three ways a report misled this project in a single afternoon:

- **Check the `Version:` line.** It is easy to diagnose a build the user is no
  longer running.
- **Check the pid, and when the event happened — not when the file appeared.**
  macOS flushes a `cpu_resource.diag` minutes after the sampling window closes,
  so two reports timestamped *after* a fix was installed both described a process
  that had been killed *before* it.
- **Check the process name.** Three `Array-*.ips` files turned out to be a check
  binary trapping on its own assertion, not the app.

"No crash report" is not a finding on its own. It means: not a signal crash —
now go look for a `.hang`, a `JetsamEvent`, or a clean exit.

## Witnessing performance

A stopwatch assertion is a weak witness: it drifts with machine load and it says
nothing about *why*. Assert the **work**, not the time:

```swift
// The assertion with teeth: nothing about the document changed, so a relayout
// must cost NO measurement.
try expect(panMeasurements == 0, "…they measured \(panMeasurements) block(s)")
```

`--file-markdown-perf-check` counts measurements at both levels and was RED at
**241** / GREEN at **0** for the prose fix. Keep a coarse time budget alongside it
with generous headroom, printed on every run so drift is visible, and say in a
comment which of the two has the teeth.

Register the leg in `scripts/run-matrix.sh` and confirm it prints in a real run —
see [qa.md](./qa.md).

For work whose risk grows with installed tiles, transcript history, visibility,
or restore size, use the axis-isolated fixtures and accepted-baseline ratchet in
[scalability-tdd.md](./scalability-tdd.md). A green single-point stopwatch does
not prove that the scaling slope stayed flat.

## Array is not alone on the machine

A canvas of live tiles competes with everything else the user is running, and the
users of this app run agents that build things. On a machine with Chrome,
Notion, Codex, `ghostty`, `mysqld` and a 1.7 GB WindowServer already resident, a
SwiftPM build of this project — several GB — is what tips the system into
jetsam. Array does not have to be the hog to be the casualty: it was killed at
334 MB.

Two consequences worth designing around:

- **Every megabyte a tile holds is a megabyte closer to being killed**, and the
  app that dies is the one with the big window. Bounded rendering is a
  reliability feature, not only a speed one.
- **Agents running the matrix while the user works** is a memory event, not just
  a CPU one. If an agent is going to build, that is a decision worth making
  deliberately.

## Checklist for a new surface

Before shipping a tile, renderer, or document view:

- [ ] What is the largest input a user can hand this? Measure it, not a fixture
      you sized yourself.
- [ ] How many AppKit views does it create at that size? Is that bounded?
- [ ] Does `layout()` measure anything? Is the result cached per width?
- [ ] Does it assign frames unconditionally?
- [ ] Does it size itself during its own layout?
- [ ] Does it hold up under `.legacy` scrollers?
- [ ] Is there a check that asserts a *count*, not just a duration?
- [ ] If it truncates or samples anything, does the user see that it did?

## Known-slow, deliberately

Recorded so nobody re-discovers them as bugs:

- **The Markdown preview is bounded, not virtualized** (400 blocks). The real fix
  is virtualization.
- **`FilePreview.load` is synchronous** for local volumes, so parsing a 1 MB
  Markdown file happens on the main thread. Bounded by the 1 MB cap.
- **Tables render as a monospace fallback**, which means a wide table is one
  large fenced block measured at unbounded width.
- **Every current canvas layout pass lays out every installed tile subtree.**
  Cheap individual tiles reduce the coefficient, but the canvas must ultimately
  bound its presentation working set and move the retained world once. See
  [infinite-canvas-rendering-research.md](./infinite-canvas-rendering-research.md).

## Case study: the Markdown tile, 0.4.15 → 0.4.17

Kept because the *shape* of the mistake is more instructive than the fix.

- **0.4.15** shipped a Markdown preview that built one view per block. Measured
  only on documents generated for the checks, all of which were small.
- The user reported freezing and crashing. **First wrong diagnosis:** memory
  exhaustion. The 1.39 GB was real, but the `exit 133` cited as proof of the app
  dying was *the check itself* trapping on `Int.max + 1` in an assertion during a
  teeth run — and the `.ips` files from that hour were those check runs, not
  Array. A conclusion was stated that the evidence did not support.
- **0.4.16** added the block budget and per-width height caching. It fixed a real
  problem and did not fix the user's.
- The OS report from 0.4.16 showed **20 of 34 samples in
  `AssistantProseView.layout()`** — the *shared transcript renderer*, reused
  wholesale, which re-measured every row and re-assigned every frame on every
  pass. The reused component, not the new one, was the cost.
- **0.4.17** cached row heights there and stopped re-assigning unchanged frames.
  Confirmed on the running app: 98.6% CPU → 0.0%.

Three lessons, in order of how much they cost:

1. **Get the OS report before forming a theory.** It named the method both times;
   both wrong diagnoses came from reasoning about plausible causes instead.
2. **Reusing a component inherits its performance envelope**, and that envelope
   was set by a different input size. The transcript renderer was written for
   chat messages and was never wrong until a file was poured through it.
3. **A fixture you generated is not evidence about the user's data.** Every
   synthetic document passed.

One thing was never reproduced: the runaway loop itself, in a harness, at the
pre-fix shape. What is witnessed is that the repeated measurement the profiles
were made of is now zero. That distinction is stated in the plan and the backlog
rather than papered over — a fix you cannot stage is worth shipping and worth
labelling.
