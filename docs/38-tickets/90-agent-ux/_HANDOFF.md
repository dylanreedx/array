# Continuum agent-UX — handoff, 2026-07-27 evening

Written for you (or a future session with no memory of this one). Durable state is this file,
`_LEDGER.md`, `_QUEUE.md`, `_RUNBOOK.md`, and `git log`. The conversation is not the source of truth.

---

## 1 · Where we are, in one paragraph

**82 of 92 tickets done.** Phases 0, 1, 2A, 2B, 2C, 2D, 3 and 4 are complete, plus four repair
tickets authored mid-run in response to what you saw in the app. The remaining 10 are all of
**Phase 5 (Pi `--mode rpc` migration)**. The loop is **stopped on purpose** — not finished, not
broken — because the verification matrix started flaking on a leg unrelated to any ticket, and the
whole program's premise is that a red gate blocks. Everything is committed on `overnight/agent-ux`;
the tree is clean; nothing has ever been pushed.

**The app you have installed** (`~/Applications/ContinuumRevived.app`) is from HEAD `25aa91f`, which
is now **7 commits behind** — it does not contain P4.10–P4.13 or P2D.6.

---

## 2 · What this program was for

Continuum runs a real coding agent (Pi + GPT-5.6) in a native canvas tile, streaming a sanitized
activity timeline to an iOS companion over a self-owned relay. It worked, but the surface was
"SUPER basic": no agent-management layer, no command surface, no design system, and — the root
constraint — **the agent *was* the tile**, so closing a tile killed the work.

Locked decisions, still in force:

- **Agent and tile are decoupled** — the agent is the entity, the tile is a view of it.
- Per-agent **git worktrees**; an **orchestrator** that spawns children via a `spawn_agent` tool.
- **Real light + dark** theming, not a dark-only app with a light mode bolted on.
- Full **T3-style settle / snooze / archive** lifecycle.
- **Frozen list order** on desktop, attention-first on iOS.
- The **sidebar IS the inbox by default**, not a mode.
- Migrate to Pi **`--mode rpc`**.
- **Deterministic gates block; vision is advisory.**
- **I5 invariant**: only derived metadata crosses the desktop→phone boundary. Never paths,
  transcript bodies, pids, or secrets.

---

## 3 · How the work actually gets done (the machine)

This matters more than any single ticket, because it is how you continue.

**A "ralph loop"** — `scripts/agent-ux-loop.sh`, running detached under `caffeinate -is`. It is
deliberately dumb: intelligence lives in the ticket packets and in supervision, not the runner.

```
while true:
  [ -f docs/38-tickets/90-agent-ux/STOP ] && exit 0
  ticket = first row in _QUEUE.md that is not done, not blocked, deps all done
  fresh `claude -p` implements it, verifies it, commits it, updates _LEDGER.md
  worker prints `LOOP: CONTINUE|STOP <reason>`
```

- **A fresh agent per ticket** — no context rot, and one bad ticket cannot poison the next.
- **`_QUEUE.md`** is dependency-ordered; **`_LEDGER.md`** is per-ticket state and the heartbeat.
- **A `blocked` row is never retried.** That is why a supervisor-initiated kill must reset the row to
  `pending`, not `blocked` — a kill is not a verification failure.
- **The driver refuses to start on a dirty tree.** Commit doc/ledger edits *before* relaunching, and
  redirect its output to a log — a driver that exits instantly looks identical to one that never
  started.
- Iteration timeout is 9000s (2.5h).

**Verification doctrine** (`./scripts/run-matrix.sh`, ~143 legs, no XCTest):

- Checks are `*Checks` executables driven by `--*-check` flags. Deterministic gates block; the
  vision/`--ui-tour-check` output is **advisory and must never gate**.
- **Never weaken the matrix**: no deleting, skipping, loosening, or blessing baselines to get green.
- Every ticket must observe its **negative tests red at exit 1 against the final code**, with the
  failure text quoted at the assertion. This caught a lot — see §6.
- `CONTINUUM_SKIP_SURFACE_CHECKS=1` is the honest-green convention for headless runs (no terminal
  surface for Ghostty).
- `--managed-agent-live-check` is deliberately **not** in the matrix: it needs Pi auth and a
  supervised GUI, and blocks on a folder-access `NSAlert` unattended.

**Commit rules in force:** one ticket per commit, Conventional Commits, **no AI-attribution trailer
ever**, local only, never push, always `overnight/agent-ux`.

---

## 4 · What got built, phase by phase

**Phase 0 — verification substrate (11).** The gate that existed at the start was
`distinctSampledColors <= 1`, which passed black-on-dark text and a blank transcript. Replaced with:
`UIProbe` rendering at a **pinned 2.0 scale in a context we own** (font smoothing and subpixel
positioning off — otherwise baselines follow whichever monitor you're plugged into, which cost two
environment halts); per-appearance contrast read off the real view tree; numeric pixel probes;
committed PNG baselines; geometry gates including `hasAmbiguousLayout`.

**Phase 1 — design tokens, light + dark (12).** New Foundation-only `ContinuumRevivedAgentUI`
module. `TokenColor{light,dark}`, surface/text/line/accent tokens, type and spacing scales, a
colour-hygiene lint whose allowlist can only shrink, one `StatusPresenter` replacing six colour maps
and three glyph maps. iOS consumes the same tokens — the phone got a real light mode for the first
time. **452 contrast pairs gated in both appearances, zero exemptions.** (Read §7 before you
celebrate that number.)

**Phase 2 — the agent entity model (27).** `AgentID`/`AgentRecord` with `tileId` demoted to a
*nullable view binding* (nil = headless); `AgentSupervisor` owning runners and the only place that
constructs a `PiAgentRunner` (enforced by a source scan); tile as a detachable subscriber; restore
on relaunch; one `AgentInventory` feeding all four consumers; per-agent worktrees with cleanup that
**retains unmerged branches**; orchestrator spawn with depth and fan-out caps, parent/child nesting,
and a rollup so a folded group cannot hide a child that needs you.

**Phase 3 — the sidebar becomes the inbox (14 + 2 repairs).** Five states / three colours, with
*attention* tracked separately from *state*; frozen creation-order sort; in-flight fade; card and
slim rows; scope dropdown; reveal-on-click; ⌘1–9 jumps with ⌘-hold hint pills; multi-select with a
bulk bar; context menu; inline rename that lives on `AgentRecord` so it survives the tile.

**Phase 4 — lifecycle: settle · snooze · archive (14).** Tri-state override; **blocker precedence**
(work needing a human outranks "I said done"); auto-settle on inactivity and auto-unsettle on
activity; DST-safe snooze presets (1 hour means *elapsed* time, so it survives the spring-forward
morning); raised-hand early wake; snoozed shelf; settled-tail paging; reading is free; undo;
crossfade; and a **15×6 precedence grid — 450 resolutions** — as the closing ticket.

**Four repair tickets I authored mid-run**, because you looked at the app and told me what was wrong:

| ticket | what you said | what it did |
|---|---|---|
| `P6.0` | "odd response boxes spanning the entire width" | Prose is no longer a card. Assistant turns have no border/fill/title; user turns get a fill only; tool/plan/diff/error stay boxed. |
| `P6.1` | "you can't change the model/effot level wtf happened" | Per-agent model and effort in the tile, persisted on the record, applied to the next turn. |
| `P3.15` | "a lot of stale agents i cant delete" | Delete/Archive/Stop actually wired. **Plus a persisted tombstone**, because deleting a record wasn't enough — tiles re-mint agents at launch. |
| `P4.14` | "sidebar is stuck in working" | The row was showing *process liveness* as *turn activity*. Now derived from turn state. |

---

## 5 · Why the loop is stopped (needs one decision from you)

`./scripts/run-matrix.sh` is red at `ContinuumRevivedFileTreeChecks`:

```
Fatal error: Error raised at top level: timed out waiting for view model snapshot
```

**No ticket caused it.** The worker proved that by stashing its own diff and reproducing the failure
on the clean tree at `adafe6a`. `Sources/ContinuumRevivedFileTreeChecks/main.swift:151` gives an
**uncapped** view-model scan a **2-second** deadline over a scratch tree that an earlier stage of the
same file seeded with **50,250 nodes** — and creating 50k files makes Spotlight index them, so the
check loads the machine it is timing. Measured: 1 pass in ~8 runs once the machine warmed up.

Three honest fixes, all yours to pick:

1. Give that wait a budget proportional to its fixture — the 50k-node stage beside it already gets
   10s. One line, preserves every assertion. **My recommendation.**
2. Scan a smaller root at line 148 instead of the seeded `scratch`.
3. Have the large-scan stage clean up its 50k nodes so nothing indexes them.

The worker refused to do this itself, correctly: loosening someone else's deadline to get green is
exactly what the runbook forbids a worker from deciding alone.

---

## 6 · What this process is actually good at, and where it isn't

Worth knowing before you decide how much to trust the next 10 tickets.

**It caught real things.** The negative-test discipline repeatedly found that a check was *green
against the bug*: a snooze fixture that passed a naive `+86_400` day-step until a 23:30 case was
added; a "both rows repaint" assertion that was vacuous because the row being checked was always the
last-selected one; a delete test that would have passed while the record survived on disk. Codex
cross-review (gpt-5.5) raised findings on nearly every ticket and most were fixed rather than argued
away — including a HIGH where `send` replaced a live runner and left an orphan Pi process.

**Where it is weak, and this is the important part:** *nothing in the process has taste.* Every gate
asks "is this correct, contrasted, deterministic, asserted?" **No gate asks "is this nice?"** That is
precisely why you are looking at a correct, accessible, well-tested app that you find harsh and ugly.
The machine did what it was told. It was told the wrong thing about aesthetics — by me.

---

## 7 · The design problem — root causes, all traced

You said: *harsh and sharp, too much contrast on the agent/tile borders, the dropdowns are ugly asf,
the agent tile isn't usable, Claude Code's terminal input is better.* All four are real and three
are self-inflicted. Here is exactly why.

### 7.1 The harshness is our contrast gate, applied where it shouldn't be

```swift
case .border:       TokenColor(light: 0x767C86, dark: 0x7A8290)   // mid-grey, everywhere
case .borderStrong: TokenColor(light: 0x4A4F57, dark: 0xA8B0BD)
case .separator:    TokenColor(light: 0xDDE0E6, dark: 0x2E343E)   // soft — and barely used
```

`LineToken.border`'s legal backgrounds are `SurfaceToken.allCases`, meaning **it was chosen to clear
3:1 against every surface in the app**. P1.11 deliberately replaced the shipped `white@0.14`
hairline (measured ~1.1:1) with this. Every tile edge and card edge is now painted a mid-grey that
is legible against anything — which reads as *harsh lines everywhere*.

**The error is doctrinal, not numeric.** WCAG's 3:1 non-text rule targets UI components and
meaningful graphical objects — a *decorative* container edge is not one. We applied one floor
uniformly and got a wireframe look. The fix is to split the token by role: `borderStrong` for things
that carry meaning (focus, selection, status), and a genuinely soft hairline for decorative edges,
with the contrast gate scoped to the semantic ones. `separator` already shows what soft looks like.

### 7.2 The sharpness is a literal number we lowered

`Radius.card = 6.0`, `Radius.container = 10.0`. P1's own migration note records
`TranscriptCardViews cornerRadius 8 → Radius.card (8 → 6)` — **we made it sharper than it shipped.**
6pt at a 1pt hard border reads as a technical drawing. Modern native macOS chrome sits nearer 10–12
for cards and 8–10 for controls.

### 7.3 The dropdowns are ugly because they are native

**9 `NSPopUpButton`s across 7 files** — scope dropdown, model and effort pickers, bulk actions,
settings, diff review, top bar. Every one is a stock Aqua control with system chrome that ignores
the design tokens entirely. They look pasted in because they are. This needs one token-styled
dropdown component that the other nine adopt, with a hand-built `NSMenu` (already the house pattern
for tag ranges, and `menu.autoenablesItems = false` is load-bearing — measured twice).

### 7.4 The input is a form field, and you noticed

```swift
composeField = NSTextField()
composeField.bezelStyle = .roundedBezel
```

A **single-line** `NSTextField` with a system bezel. No multi-line, no history, no `/` commands, no
`@` paths, no `$` skills, no Stop button, no working timer. Claude Code's terminal input beats it
because it is a real composer and this is a form control. **`P6.2` is precisely the `NSTextView`
compose ticket** — it exists in the plan and is simply the furthest thing away in the queue. That
ordering was my mistake and you called it out days ago.

---

## 8 · What I recommend next, in order

The queue currently says Phase 5 next. **I think that is now wrong.** Phase 5 is plumbing you cannot
see; your complaints are all surface. Suggested resequencing:

1. **Fix the FileTree deadline** (§5) — nothing else can be verified until the matrix is green. Ten
   minutes.
2. **Author and run a design-language pass** (new Phase 7, ~5–6 tickets): split the border token by
   role and soften decorative edges; raise the radius scale; one token-styled dropdown adopted by
   all nine sites; spacing rhythm and type hierarchy at page level; real empty states. This is the
   direct answer to "I hate the design", and it must be authored with actual visual intent rather
   than as another correctness ticket — the gates cannot judge it, you will have to.
3. **`P6.2` compose surface** — the `NSTextView` composer. The single biggest usability win, and it
   needs nothing from Phase 5.
4. **Phase 5 (10 tickets, Pi RPC)** — Stop button, `/compact`, steering mid-turn, `set_model` and
   `set_thinking_level` so the pickers work *during* a turn, token/cost/context meter, real
   approvals.
5. **Rest of Phase 6** (`P6.3`–`P6.12`) — `/` commands from Pi's own `get_commands`, `$` skills,
   `@` paths, retry/copy, coalesced output.

A caution I want on the record: **a design pass has no deterministic gate.** Baselines will churn on
every ticket, and "does it look good" will come down to you opening the app. The honest way to run
it is smaller batches with you reviewing each, not an overnight sweep.

---

## 9 · Open decisions waiting on you

- **The FileTree deadline fix** (§5) — blocking everything.
- **Design pass**: approve, and in what order against Phase 5?
- **Sidebar tree wording**: an idle managed agent reads **"unknown"** in the outline (that tree folds
  configuring/idle into one muted kind). The inbox row correctly reads "ready". One-line reword.
- **The delete proof is still owed**: no agent has been deleted through the UI yet, so
  `deleted-agent-tiles.json` does not exist. Delete one and I will quit, relaunch, and confirm from
  disk that it stays gone — P3.15's own test models the relaunch inside a single process.
- **Three `git stash` entries** (`stash@{0}` P4.8 WIP, `stash@{1}` P4.6 WIP, both obsolete;
  `stash@{2}` unrelated and old). Droppable once you say so.
- **A 654 MB worktree** at `.claude/worktrees/agent-ab418a23d122fe7df` with one uncommitted
  `TileSpawner.swift` change, untouched for days.
- **Task E**: the physical phone has never been run against the dev relay.
- **Phase 5 needs a supervised GUI pass** — live RPC cannot be verified headlessly.

---

## 10 · Commands

```bash
cd /Users/dylan/Documents/personal/continuum-overnight

# restart the loop (check the log — it refuses to start on a dirty tree)
rm -f docs/38-tickets/90-agent-ux/STOP
nohup caffeinate -is ./scripts/agent-ux-loop.sh > /tmp/agent-ux-loop.log 2>&1 & disown
sleep 30 && pgrep -f agent-ux-loop && pgrep -f "claude -p"

# stop it gracefully (finishes the current ticket, then exits)
touch docs/38-tickets/90-agent-ux/STOP

# state
grep -c '| done' docs/38-tickets/90-agent-ux/_LEDGER.md
grep '^last-touch' docs/38-tickets/90-agent-ux/_LEDGER.md

# rebuild + install (only from a clean tree with no worker running)
./scripts/make-app-bundle.sh --configuration debug --output /tmp/ContinuumRevived.app
codesign --force --sign "Apple Development: Dylan Reed (DGJTP684C8)" --timestamp=none /tmp/ContinuumRevived.app
osascript -e 'tell application "ContinuumRevived" to quit'
rm -rf ~/Applications/ContinuumRevived.app && cp -R /tmp/ContinuumRevived.app ~/Applications/
open ~/Applications/ContinuumRevived.app
```

Timing note: use `git log` and file mtimes, **never** the ledger's own timestamps — workers have
written times up to half an hour in the future.
