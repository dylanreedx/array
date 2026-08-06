# Night 3 handoff — finish Phase 6, hand-driven

Written 2026-08-06 ~01:00Z from three independent audits of the live tree. Sol at max supervises and
reviews; Luna at max implements; **no loop**. Paste-prompt: `plan-night3-prompt.md`.

## State

| | |
|---|---|
| HEAD | `e63321d` feat(sidebar): complete P5.5 width resize persistence |
| Branch | `overnight/agent-ux`, local only, never pushed |
| Ledger | **31 done / 9 pending / 0 blocked** |
| Tree | dirty for the **unfinished P6.1 candidate** (`AgentInboxRowBuilder.swift`, `AgentRecord.swift`) |
| Loop | stopped, `STOP` armed. It stays stopped — every pending row sits behind gate P3.6 in queue order, so hand-drive is the only mode |
| Authorship | verified clean: one identity, **zero trailers** across all 46 queue-94 commits |

Pending: **P3.6** (gate) · **P6.1–P6.6** · **P5.6** (gate) · **P7.1** (gate).

## The one fact that governs everything

`ContinuumApp.swift:6842` is the **single production call site** of `AgentInboxRowBuilder.rows`, and
it passes no `records:`, no `lifecycleFacts:`, no `autoSettleAfter:`. So `record` is nil, line 161
takes `?? .active`, and **every shipped row is `.active` and `.card` regardless of what the builder
can do.** `InboxLifecycle.resolve` still has zero production callers — its own "NOTHING CALLS THIS
YET" comment is still true.

Until that call site is wired, P6.2–P6.5 are provable only against fixtures and Phase 6 ships
nothing. The wiring is **outside every P6 fence** → it is an R2 forced call site, and the precedent
sits five lines above it (`:6837`, P3.4's own allowance note).

Second governing fact: `buildAgentInboxRows` is `private`. Any witness that reads the shipped row
list must live **inside `ContinuumApp.swift`** — `UIProbeGeometry.swift` cannot reach it.

## Slice 0 — finish P6.1 (~30 min). Do this first, alone.

The uncommitted candidate is a **pure API addition with no wiring and no tests.** Audit verdict:
mutating the whole derivation to `InboxLifecycle.active` would stay **green** today. Four of six
"Done when" bullets unmet. Do not send it to review as-is.

To finish it:

1. **Wire `ContinuumApp.swift:6813–6845`** — forward `records:`, `lifecycleFacts:`,
   `autoSettleAfter:`. The records list is already built twenty lines above and simply not passed.
2. **Fix a real bug before wiring, or settling breaks.** `AgentInboxRowBuilder.swift:145` does
   `observedFacts.attentionIsYours |= attention.isYours`, and `isYours` is true for `.unread`
   (`AgentInboxRow.swift:341,360`). So a finished-but-unseen agent — the inbox's central case —
   resolves `.active` through blocker rung 1 even with an explicit `.settled` override, and
   `canSettle` refuses it. With the shipped **Mark Unread** action that makes a row permanently
   undismissable. This is the packet's own "Watch out" verbatim. Unread is not a blocker; a pending
   human request is.
3. **Reconcile three disagreeing settle guards.** New `canSettle` (`AgentRecord.swift:252`) keys off
   attention/runner/prompt; the shipped bulk bar (`AgentInboxView.swift:4324`) keys off `row.state`
   plus a `holdsParentOpen` child-rollup rung `canSettle` has never heard of. The packet requires
   **one function decide both**.
4. **Delete the shadow oracle** at `ContinuumApp.swift:24473–24512` — a local `inboxSections()` that
   re-derives lifecycle by calling `resolve` directly and rebuilding rows, i.e. production agreeing
   with itself while bypassing the shipped row. P6.1 was the ticket meant to delete it.
5. **Migrate the claims that become false** (R2 (b)/(c), name each in the ledger):
   `AgentInboxRowBuilderChecks.swift:285` ("not yet derivable, so every row is an active top-level
   card"), the comment block `ContinuumApp.swift:24444–24463`, and the printed summary clause at
   `:25432`.
6. **Witness**: plant an `AgentRecord` with `settledOverride == .settled` in
   `runAgentObserverIndependenceChecks` (`:20556`, matrix-wired via
   `--agent-observer-independence-check`), assert the shipped row is `.settled` and `.slim`; mutate
   line 161 back to `InboxLifecycle.active` and watch it go red.

## Slices A–C

**Slice A — P6.2 + P6.3 + P6.4 as one pass, one commit, three ledger rows (~115 min).**
Batched because the contention is total, not incidental: five new optional `Date` fields land in the
same four hunks of `AgentRecord.swift`; three are written from the same `switch` in
`AgentSupervisor.updateTurnFacts` (`:2955`); all three edit the same 30-line region of
`buildAgentInboxRows`; and **P6.4's `isUnread` cannot be written before P6.3's `runCompletedAt`
exists.** Precedent: the P4.1+P4.2 batch.

Phase 6 is a **writer** phase, not a derivation phase — queue 90 already shipped `resolve`,
`SnoozePresets`, `AgentAutoSettleConfig`, `LifecycleBlockers`, `InboxSort` sections/shelf/paging, the
shelf header, settled tail, paging footer and crossfade. All of it unreachable. What's missing is
the production writers:

| Field | Writer to create | Where |
|---|---|---|
| `latestPromptAt` | in `send` beside `lastActivityAt` | `AgentSupervisor.swift:1542` |
| `latestTurnAt`, `failedAt`, `runCompletedAt` | in `updateTurnFacts`'s event switch | `:2955` |
| `snoozedUntil` + `snoozedAt` (one mutation — a snooze without `snoozedAt` silently disables both date signals) | new `snooze(agentID:until:now:)`, rejects non-future | `AgentSupervisor` |
| `settledOverride = .active` pin | new `pinActive(agentID:)` beside `clearSettle` (`:2858`) | `AgentSupervisor` |
| `lastVisitedAt` watermark, monotonic `max(...)` | replace `unread.remove(id)` in `focus` (`:2727`) — the one entry point | `AgentSupervisor` |

Also: wire the dead action arms — `.settle`/`.unsettle`/`.snooze`/`.wake`/`.markUnread` into
`wiredInboxRowActions`/`wiredInboxBulkActions` (`ContinuumApp.swift:7075/7078`) and out of
`performInbox*Action`'s dead arms (`:7102/7114`). The comment at `:7069` saying snooze is absent
"because nothing writes `snoozedUntil` yet" becoming false **is the ticket succeeding**.

Slice-A traps:
- **Do not touch `InboxLifecycle.resolve`.** Its `>=` comparison is proved by a 1,728-case sweep;
  the packets' sketches are satisfied by supplying different *inputs*, not new rungs.
- `lastActivityAt` is bumped for **every** event including `.tokenUsageUpdated` — it means "we heard
  something", not activity. That's why P6.2 needs its own stamps.
- Tolerant decode: today's `decodeIfPresent(Double.self, …)` **throws** on a non-numeric value and
  loses the whole record. Use `try? … ?? nil` — that *is* the packet's "malformed timestamp leaves
  the row active".
- Legacy records on disk have none of the new fields, so `realActivityAt == nil ⇒ .active`. The
  settled tail lights up **going forward, not retroactively**. Record it; do not "fix" it by falling
  back to `lastActivityAt`.
- P6.4's two derived properties have **opposite** never-visited defaults — `isUnread` treats it as
  read (`?? .distantFuture`), `isWoke` treats it as woke (`?? .distantPast`). That asymmetry is the
  ticket. And no "Unread" label: `InboxAttention` is a mark, not a word.
- P6.4's best witness is the ordering one: assert `InboxSort` output ids are identical before and
  after a visit, **including the settled block** — that's where a bumped stamp actually moves a row
  via `resolve`'s `settledAt ?? lastActivityAt` fallback. On the active block alone it's vacuous.
- Throttle watermark-only persists (`persist` is an fsync + read-back), but **bypass the throttle
  when the write clears an unread mark**.

**Slice B — P6.5, alone (~85 min).** Best fence of the five; no writers needed. Its risk is
structural: capping children changes the drawn row count, which moves the probe's `cells == rows`
expectation and the derived probe height (`UIProbeGeometry.swift:2912–2934`) — discover that at
minute 5, not minute 40. Requirements 3 and 4 are already satisfied in production (depth clamp at
`InboxSort.swift:141`; unfiltered `knownAgentDirectories()` at `AgentSupervisor.swift:2170`) — assert
them non-vacuously, don't reimplement. **Do not fold descendant attention into `row.attention`** —
that axis is P6.4's watermark and mixing them corrupts both; carry it beside `rollup` like
`emphasis` and `disclosure`.

*The height-cache witness, concretely:* a fresh probe host per width **cannot** observe a stale
cache — nothing was cached. Reuse the existing live-transition harness at
`UIProbeGeometry.swift:1576–1765` (`layoutTransitionHost(width:)`), which already carries a recorded
red at `:1723`. One host, `setContentSize`, fold toggled between transitions. Mutation: in
`AgentInboxView.height(...)` (`:306`) set `let drawsRollup = false`.

**Slice C — P6.6, alone, last (~90 min).** Must follow P6.5, whose remainder row it must audit.
Measures of the gap: `grep accessibilityDisplayShouldReduceMotion` → **one** hit;
`accessibilityDisplayShouldIncreaseContrast` → **zero**. Surfaces with no role/label today: shelf
header, `settledMore` footer, bulk bar card, divider, P6.5's remainder.

*The baseline trap:* `UIProbeBaseline` baselines **every** static card with no exclusion list, and a
card with no committed PNG is a failure. **Adding a Component Lab card makes both baseline legs red
in a way no autonomous ticket may clear.** So don't add one — drive every assertion through
`UIProbeGeometry`/`UIProbeAppearance` over the live inbox subtree, which renders in no pixel
baseline by design. Also make the ticking `elapsedLabel` non-participating with its fact relocated
into the cell label, or a live region announces every second.

## Time and cut order

~30 + 115 + 85 + 90 ≈ **5h20m**. With four hours: slices 0 + A + B, cut C.

Cut safest-first: **P6.6** (nothing depends on it; a deferred and a completed-but-unblessed P6.6 land
in the same place at P7.1) → **P6.5** (decision 15 already settles the policy; needs a 40-child
parent to bite) → **P6.4** (in-memory unread already works within a session; if dropped, leave
`focus`'s `unread.remove` intact — do not half-migrate) → **P6.3** (don't: it's what makes
`.snoozed`, the shelf and `.woke` reachable) → **P6.2 never**. P6.2 is the only ticket that makes
`.settled` reachable, and `.settled` is what lights up the slim variant, settled tail, paging footer
and crossfade — six queue-90 tickets of rendering that has lived only in fixtures for two phases.

## Gates — less ready than the docs claim

**P3.6**: mechanical legs green and `store-before/` (7 stale records, backup count 33) present, but
**the live half was never performed** — no `store-after1`/`after2`, no idempotency output, and
neither baseline leg has ever been run from that folder. `REVIEW.md` is 14 tickets stale.
**P5.6**: **no gate folder at all**; its prep doc still claims none of P5.1–P5.5 landed (all five did).
**P7.1**: requires the **unskipped** matrix plus each focused leg five consecutive times — never done
once in this program; every run so far used `CONTINUUM_SKIP_SURFACE_CHECKS=1`.

Refresh P3.6's and create P5.6's materials as end-of-night work. **Never mark a gate done.**

### Baseline worksheet — 60 PNGs, and 12 need deleting

Nothing has been blessed since `a8c9aed` (P1.5, 22 pairs) — verified: zero commits and zero working-
tree changes under `docs/38-tickets/90-agent-ux/baselines/`.

| Action | Count | What |
|---|---:|---|
| **Delete** | 12 | `chrome.agentInbox*-320x652-*` — dead geometry. `84a4d16` moved the scope band to a 32pt `ChoiceButton`, so `620+40 = 660`. Blessing alone leaves 12 permanent orphans |
| **Bless, no diff available** | 12 | the new `320x660` keys — "no committed baseline" writes no `.actual`/`.diff`, so judge them as renders |
| **Bless after the magenta diff** | 10 | `chrome.sidebar*`, `chrome.activityDock*` — candidates in `qa-runs/2026-08-05T235602Z/ui-baselines/` |
| **Judge as tile changes** | 5 | `managed-agent.*` from `--component-lab-check`, the second baseline leg P1.5 never ran. Hypothesis (unproved): hairline 1.0→0.5 |
| No action | 38 | byte-identical |

"22 mismatched / 38 matched" = 12 no-baseline + 10 real diffs. The "38 mismatched" figures in the
P5.1–P5.3 rows are an **external-display artifact** (16 extra unrelated keys at scale 1.0), not a
regression. **Never bless on an external display.**

## Rails — verbatim, non-negotiable

Never push. Never `git reset`, `clean`, or `stash`. Commits are Dylan's identity with **no trailers of
any kind**. Never run an app instance or the boot probe while Dylan's own instance is running
(`pgrep -f 'Continuum Revived.app/Contents/MacOS'` first). **Never bless a baseline.** Never lower a
floor, a tolerance or a count to pass. Never mark a supervised gate done; never infer approval from
silence. Never edit `_QUEUE.md` order, the program guard, or queue 91/92 work. Leave `STOP` in place.

Per ticket: one R2 ledger note naming file, line, and which of the three purposes it serves. Two
review rounds maximum, then fix mechanical remainders yourself and record them. Every witness in a
**matrix-wired** flag — `--managed-agent-live-check` is not in `run-matrix.sh`, and a witness there
stays green and proves nothing.

## Mechanics

Luna-max implementation, dispatched directly — no new agent definition, and the rails already live
in the repo's own prompt file:

```bash
cd /Users/dylan/Documents/personal/continuum-overnight
T=~/.pi/sidebar-native-ux-runs/continuum-overnight/run-night3/tasks/<slice>; mkdir -p "$T/worker-session-1"
{ echo "[sidebar harness]"; echo "TICKET=<ticket(s)>";
  echo "PACKET=$PWD/docs/38-tickets/94-sidebar-native-ux/<packet>.md";
  echo "TASK_DIR=$T"; echo "PASS=1"; echo "SLICE BRIEF: <the slice's section of this handoff>"; echo;
  cat scripts/sidebar-native-ux-prompt.md; } > "$T/worker-prompt-1.md"
nohup caffeinate -is sh -c "pi --approve --model openai-codex/gpt-5.6-luna --thinking max \
  --session-dir '$T/worker-session-1' --name night3-<slice>-w1 --mode text \
  -p '@$T/worker-prompt-1.md' > '$T/worker-1.md' 2> '$T/worker-1.stderr'" >/dev/null 2>&1 &
```

Review: `pi --no-approve --model openai-codex/gpt-5.6-sol --thinking medium --tools read,grep,find,ls`
on a written request naming the packet, the diff, and R2's three allowed purposes. Last line exactly
`DECISION: APPROVE` or `DECISION: REWORK`.

**Liveness by open file handle, never argv** — `pi` masks its argv:
`for p in $(pgrep -x pi); do lsof -p $p | grep -q "$T/worker-1.md" && echo alive; done`

Run the review **while** the matrix runs; the reviewer is read-only and never builds. Log one
timestamped line per step to `run-night3/supervisor-night3.log`. Commit with
`./scripts/sidebar-native-ux-safe-commit.sh`.

## Stale docs — do not trust these, they will mislead you

`plan-morning-review.md` ("26 of 40"), `plan-P5.6-gate-prep.md` ("none of P5.1–P5.5 landed"),
`plan-P7.1-gate-prep.md` ("26/40 at 83b10a9"), `qa-runs/p3.6-gate/REVIEW.md` ("two tickets stand
between the loop and this gate"). **`_LEDGER.md` and git are the only accurate sources.**

## For P7.1's honest-limits section

Carry these forward — they are recorded in ledger notes and must not be quietly dropped: **P2.4 was
never independently reviewed** (protocol failure preceded review); **all five Phase 5 tickets ended on
a supervisor-only repair pass** with no third review, which is exactly the surface P5.6 must judge as
a whole; **P2.2's `.abbreviated` tier is unreachable in the P0.3 corpus**; **P3.1's N3 witness was not
run**; **P3.5 leaves a live phone/desktop divergence** — no `AgentStatus` case for `failed`, so the
phone says `idle` while tile and sidebar say `Failed`; and **R4's consequence** — several Phase 1–3
tickets were verified against surfaces the shipped app could not reach, which is precisely what
Phase 6 fixes.
