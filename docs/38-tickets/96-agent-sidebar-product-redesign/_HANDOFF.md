# 96 — Handoff

Written 2026-08-14, before a context compaction. Everything needed to pick this up cold.

Read first: `_DESIGN.md` (the authority), then `_LEDGER.md` (every witness, red and
green, in the order observed), then `P0.1-fixture-inventory.md` (what the product
actually renders) and `S0-density-review.md` (the open ruling).

---

## Where the work is

| | |
|---|---|
| worktree | `~/array-worktrees/sidebar-96` |
| branch | `array/sidebar-96`, base `d334f01` |
| HEAD | `fa0cc83`, **clean tree**, 14 commits |
| latest artifact | `qa-runs/2026-08-14T193650Z/sidebar-96/` (gitignored) |
| scratch bundle | `~/Desktop/Array Dev 96.app` on `~/array-scratch-96` |

`_DESIGN.md` is **untracked in Dylan's main checkout** and therefore absent from this
branch. It has not been committed because it is his file, not this program's. Read it
from `/Users/dylan/Documents/personal/Array/docs/38-tickets/96-agent-sidebar-product-redesign/_DESIGN.md`.

## Status: Phase 0 complete. Gate S0 presented, NOT ruled.

P0.1 and P0.2 are done, green, matrix-registered and adversarially reviewed. **No
product behaviour has changed** — Phase 0 is evidence machinery only. Nothing may
proceed past S0's geometry question until Dylan rules (§3.2: silence is not approval).

---

## What exists now

### `--sidebar-production-corpus-check` (P0.1)

`Sources/ContinuumRevived/App/SidebarProductionCorpus.swift`. 30 flows that drive the
REAL writers (`spawn`, `sendPrepared`, `rename`, the naming CAS, lifecycle verbs, runtime
events through `deliver`) against real on-disk stores, let the app's own
`refreshAgentSurfaces → buildAgentInboxRows → AgentContextIndex.build →
AgentInboxRowBuilder.rows` produce the values, and read every fact off a **rendered
cell**. Nothing constructs an `AgentInboxRow`.

The world is built by `AppDelegate.makeSidebarCorpusWorld(now:reusing:)` in
ContinuumApp.swift — it lives there because it touches `private` AppDelegate members and
`configureWorkspaceSidebar`'s declaration is pinned verbatim by a program source-scan.
`reusing:` builds a second app over the same stores: that is the relaunch world.

**It has teeth.** `expectation(for:)` pins today's rendered values per flow, plus
cross-flow assertions. Teeth-tested: claiming `succeeded` shows `Done` goes red.
A later packet that fixes a defect MUST come here and flip the expectation — that is the
ratchet, and the failure messages name the design section that earns the change.

### `--sidebar-screenshot-check` (P0.2, offscreen)

`Sources/ContinuumRevived/App/SidebarScreenshotChecks.swift`. 36 images: corpus sweeps at
220/280/320/360 × Aqua/Dark Aqua, the 662 pt density fixtures, one interaction reference,
and the three density proposals. Machine-readable `manifest.json` with every §3.3 field.
Gate asserts **mechanics only** — files written, manifest↔directory parity both ways, no
empty provenance field, no blank image, no duplicate images, Aqua ≠ Dark Aqua. Nothing
can fail on taste.

Renders through its own sized host (not `UIProbe.render`, which re-parents and centres,
and whose `make` runs before the view is in a window so a table never materializes
cells). Reuses `UIProbe.bitmap`, which became internal for this.

### `--sidebar-live-capture-check` + `scripts/capture-sidebar-96.sh` (P0.2, live)

Not a matrix leg — needs a WindowServer and Screen Recording permission. Drives the live
app's own supervisor, captures the window twice (`live-window` via
`CGWindowListCreateImage`, `live-view-cache` via `cacheDisplay`), and **exits nonzero**
if the rows never appear, the image is blank, or the requested width was not applied.

Fenced: requires `CONTINUUM_APP_SUPPORT`, refuses the prod bundle id, refuses a
`~/Documents/personal` root. It mints five durable `AgentRecord`s and never deletes them,
which is why those fences exist.

---

## The measured facts this program now rests on

All from rendered cells, not prose:

1. **The row carries two facts and a glyph.** `meta` and `branch` are empty in **all 30
   flows**; the placement band never holds more than a project name.
2. **`Project › Zone` never renders** — not even for a tile genuinely on the canvas inside
   a zone. Two agents in *different zones of the same project* render byte-identically.
3. **Placement is the first casualty of width** — long titles displace it entirely at the
   default 280 pt.
4. **Three of five terminal outcomes render no state at all** (`succeeded`, `interrupted`,
   `cancelled`); `failed` and `runtimeError` both read `Failed`. **No completion time
   anywhere.** Approval and input share one word.
5. **The Pi harness is invisible** — a Pi agent renders its provider's glyph, so it cannot
   be told from Claude Code or Codex.
6. **Provider identity is `◈`/`✦`/`◇`** with no model text; unknown provider is the bare
   diamond.
7. **A blank ⌘K is durable work**; an accepted image-only send keeps the sentinel.
8. **Geometry, measured**: 79 pt card / 83 pt pitch. A 662 pt sidebar gives its inbox
   **610 pt** (52 pt chrome), of which ~18 pt is reserved by `managementMessageLabel` —
   `isHidden = true`, empty string, still claiming its height.

### The S0 arithmetic

| | card | pitch | bare inbox | **real sidebar** |
|---|---:|---:|---:|---:|
| today | 79 | 83 | 7 | **7** |
| A (documented target) | 66 | 68 | 9 | **8** |
| B | 72 | 75 | 8 | **8** |
| C (= today, redrawn) | 79 | 83 | 7 | **7** |

**No proposal meets §8.1's nine-row floor.** A misses by 0.2 pt of pitch; reclaiming the
hidden label's ~18 pt would put it at 9. An earlier draft claimed "only A meets the
floor" — that was wrong and the adversarial review caught it.

**And the bigger point**: proposal C is today's pitch with the bands filled, and it reads
fine. **The sparseness is mostly a content problem, not a height problem.** A buys one
extra row in a real sidebar.

---

## Dylan's feedback, in order received

Everything up to and including the fourth item is **done and committed**. The fifth and
sixth are **open**.

1. ✅ "icons are upside down" — a double flip (tinted copy built flipped, drawn into an
   already-flipped view). Fixed with `respectFlipped:`.
2. ✅ "done is weird" — was showing an SF Symbol *and* a literal `✓` *and* a colour.
   Now one icon + word.
3. ✅ "we should incorporate our response glyph throbber in the working state" — the
   Working row now poses Array's own `DualPlaneGyroTiltedThinkingIndicatorView` via
   `setSnapshotPhase`, not an imitation. **Caveat: at 11 pt it reduces to a couple of
   dots.** It probably needs a ~14 pt slot to read as the gyro.
4. ✅ "stopped and failed could be confusing" — now differ by silhouette, not colour:
   red triangle (failed), plain square (stopped), outlined slash (cancelled).
5. ✅ "im not seeing the provider icons" — the placeholder chips were too faint. Real
   vendor SVGs now render (`NSImage` loads SVG natively, no conversion pipeline).
6. ✅ **"not the biggest fan of the provider text — maybe we just have icon like T3
   Code"** — the model name is gone from every mock image; the mark stands alone at the
   right of the branch line, which now leads with a branch glyph as T3's does. §4.3 still
   requires the exact model id to survive in tooltip and accessibility detail, which a
   static mock cannot show — that obligation moves to Phase 3.
7. ✅ **"maybe we can experiment with slightly more visual aid for the status"** — three
   variants built (`status/status-{rail,leadingIcon,pill}`), all at proposal A's pitch,
   with `proposals/proposalA-280x662-*` as the control. **Awaiting a second ruling**, now
   in `S0-density-review.md`. Recommendation: rail.
8. ✅ **"let's make the provider icons flat colour based on the theme"** — done, and it is
   the one change that contradicts the design: §4.5 forbids tinting vendor marks without
   per-vendor permission. Recorded as OPEN in `brand-marks/PROVENANCE.md`, added to
   P3.1's trademark review. Nothing ships.

The throbber caveat from item 3 is resolved as far as a still image can resolve it: it
is now at 18 pt, its real size, and it *still* reads as dots because it is a motion glyph.
Judge it in the live app.

## Open rulings (S0) — still needed

0. **Status emphasis**: rail / leadingIcon / pill / none. Plus: keep the branch glyph?
   And should quiet rows (Done, Stopped, Cancelled) carry no emphasis at all, which is a
   §4.6 semantics call rather than a visual one?
1. **Pitch**: A (66/68), B (72/75), or keep 79/83 and fix only content?
2. **Collapse the hidden management label?** ~18 pt; the difference between A meeting
   §8.1 and missing it.
3. **Is the nine-row floor still right**, now that 52 pt of chrome is measured rather than
   assumed?
4. **Zone in the placement band** — required in Phase 2, or cut? It costs width at 220 pt,
   where titles already truncate.

Write into the "Dylan's ruling" section of `S0-density-review.md`.

## Brand marks — P3.1 has started, and is blocked on review

`brand-marks/` holds `anthropic.svg`, `openai-{light,dark}.svg`, `xai-{light,dark}.svg`
with a `PROVENANCE.md` (source, retrieval date, SHA-256, variants, transformations).
Supplied by Dylan from svgl.app, which §4.5 permits for **design-time discovery**; §10
forbids runtime fetching and nothing fetches.

**These are NOT shipped.** The mock loads them by repo-relative path. Bundling needs a
`BrandMarkCatalog`, `Package.swift` resource declarations, `make-app-bundle.sh` handling,
and §5.5's offline bundle witness — all P3.1.

Blocked / missing:
- **Trademark review per vendor — Dylan's call**, and the first gate in P3.1.
- **Pi, Codex and Claude Code harness marks are missing.** Pi matters most: it is the
  reason a Pi agent is currently indistinguishable from Claude Code.
- §4.5 also names Google/Gemini, OpenRouter, Mistral, Groq, Cerebras.
- Marks must never be tinted (§4.5); Anthropic's carries its own `#D97757`.

---

## How to verify (all offline)

```sh
cd ~/array-worktrees/sidebar-96
swift build --product Array
.build/debug/Array --sidebar-production-corpus-check   # 30 flows, teeth
.build/debug/Array --sidebar-screenshot-check          # 36 images + manifest
.build/debug/Array --sidebar-ux-check                  # queue-94, must stay green
swift run ContinuumRevivedAgentUIChecks                # incl. queue-94 corpus gate
.build/debug/Array --agent-inbox-check
scripts/check-color-hygiene.sh
scripts/capture-sidebar-96.sh                          # live + offscreen, needs a display
```

Full matrix, **only** under isolation (a naive string compare fails because `/tmp` is a
symlink to `/private/tmp` — resolve with `pwd -P`):

```sh
export TMUX_TMPDIR=$(mktemp -d /tmp/array96.XXXXXX); unset TMUX TMUX_PANE
REAL=$(cd "$TMUX_TMPDIR" && pwd -P)
tmux -f /dev/null start-server \; display-message -p '#{socket_path}'   # must be inside $REAL
CONTINUUM_SKIP_UI_BASELINES=1 scripts/run-matrix.sh
```

Last full run: **156 legs, both new legs printed and passed, KNOWN-RED unchanged at 6,
Matrix passed.**

## Rules that bit, or nearly did

- **`ComponentLab.swift` must stay untouched** (0 lines in `git diff d334f01..HEAD`). The
  queue-94 corpus gate text-scans a marker region in it. Its Lab entries also render the
  *capability* corpus at 320 pt, so **the Component Lab shows a nicer sidebar than
  production can produce** — do not use it as a reference for this work.
- Never `CONTINUUM_UPDATE_BASELINES=1`. Inventory regen via
  `CONTINUUM_UPDATE_MATRIX_INVENTORY=1` is sanctioned (323 → 327 records; the three lines
  that appear to move are alphabetical re-sorting, proven by an empty set difference).
- Never touch `MATRIX_KNOWN_RED`.
- Append matrix legs **mid/late** in `run-matrix.sh`; two program checks pin its first
  five lines verbatim with `grep -Fxc`.
- Never rebuild `~/Desktop/Array Dev.app` (the shared preview, canvas-perf's) — this
  program uses `Array Dev 96.app` on its own root.
- The parallel branch `array/canvas-perf` owns `PerfScenarios.swift`, `CanvasNSView.swift`
  and the perf docs. Stay out.
- An offscreen `NSTableView` **defers the incremental reload indefinitely** — this cost
  hours twice. Use `rebuildRowsForQA()`, and never trust a row count from a bare view-tree
  walk (it finds cells AppKit has not removed).

## Traps this program already fell into — do not repeat

1. A check that asserted only that flows *ran*, while every product fact was a `print`.
2. A live check reporting PASS over a screenshot reading "No agents yet".
3. An inventory describing a **refused** `settle` as a rendered surface.
4. Four "accessibility variant" images that were byte-identical to the baseline.
5. A manifest hard-coding `verdict: "PASS"` before the gate ran.
6. A density formula that over-counted rows in the direction flattering the proposal.
7. Recording `meta` as the placement band when placement is a different label entirely.

Each has a guard now. The pattern behind all seven: **an artifact that looks like
evidence but was never checked against what the product paints.**
