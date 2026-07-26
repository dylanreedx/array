# 90-agent-ux — Operating contract

## What this program is
Build a full agent UX on the Continuum **desktop**: an agent-first sidebar inbox, a real chat
command surface, an agent entity decoupled from its tile, per-agent git worktrees, and an
orchestrator that can spawn sub-agents. iOS stays **observe-only** this run.

## Locked decisions (do not re-litigate; if a ticket seems to contradict one, mark it blocked)
- **The agent is the entity; a tile is one view of it.** Closing a tile must not kill an agent.
- **Per-agent git worktrees**, opt-in per spawn.
- **Orchestrator** via a Pi extension tool `spawn_agent`, detected in the event stream we already
  translate.
- **Real light + dark theming.** Tokens carry both; contrast is gated in both.
- **Full settle / snooze / archive lifecycle**, with blockers outranking an explicit settle.
- **Frozen list order** on desktop (status travels in place); iOS glance surfaces sort
  attention-first.
- **The sidebar IS the inbox, by default — not a mode you toggle.**
- **Pi `--mode rpc`** is the provider transport (strict superset of `--mode json`).
- **Deterministic gates block; vision is advisory and may never certify "done".**

## Per-ticket contract
1. Read the packet in full. It is authored zero-guessing — if something is genuinely ambiguous or
   contradicts a locked decision, mark the ticket `blocked` with the reason and stop. Do not
   improvise scope.
2. Implement only what the packet asks.
3. `./scripts/run-matrix.sh` must be green. **Never weaken the matrix** — do not delete, skip,
   comment out, or loosen a check to get green, and never bless PNG baselines to pass.
   `CONTINUUM_SKIP_SURFACE_CHECKS=1` is expected headless (no terminal surface); that is the
   documented honest-green convention, not a weakening.
4. Reviews must clear (Claude + Codex cross-review of the diff).
5. Commit: one ticket per commit, `type(scope): summary`, **no AI-attribution trailer**,
   **local only — never push**. Stay on branch `overnight/agent-ux`.
6. Update `_LEDGER.md` (state, commit sha, timestamp, note) and the heartbeat.

## Never
- Push, force-push, rebase shared history, or touch `main`.
- Modify `scripts/agent-ux-loop.sh`, `_LEDGER.md` semantics, `_QUEUE.md` ordering, or anything in
  `docs/38-tickets/_archive/`.
- Touch `scripts/overnight-*` (the previous program's harness) or remove a `STOP` file.
- Certify a visual outcome by eye. Assert it, or leave it to the human.
- Fake green. If it cannot be honestly verified, mark `blocked` and explain.

## Verification substrate (why Phase 0 comes first)
Before this run, the entire visual gate was `distinctSampledColors <= 1` — "more than one colour."
It passed black-on-dark text, half-width cards, and a completely blank transcript. Phase 0 replaces
that with geometry, per-appearance contrast, pixel, and baseline gates plus an iOS build leg. Later
phases depend on those gates being real.

## Stop conditions
Queue drained · usage exhausted · too many consecutive failures · `touch STOP` in the repo root.
On stop, write `docs/38-tickets/90-agent-ux/_MORNING_REPORT.md`: done / blocked / commits / what
needs the owner's decision.

## Supervisor rules (learned the hard way, 2026-07-25 ~06:30)

The supervising session shares the working tree with a live worker. Two collisions happened:

1. **Never edit `_LEDGER.md` while a worker is running.** The worker owns it. (Near-miss at 05:10.)
2. **`git add <paths>` does NOT scope a commit.** A bare `git commit` commits the *entire index*,
   including files the worker had already staged. This swept an in-progress ticket's implementation
   into a docs commit twice (`6ccad1e` took P0.8's files, `4bda832` took P0.3's 408-line
   implementation mid-flight), corrupting commit attribution and destroying the worker's index.

   **Required procedure for the supervisor:**
   - Run `git diff --cached --name-only` FIRST. If anything you do not own is staged, stop —
     a worker is mid-commit. Wait for the next wake.
   - Commit with an explicit pathspec: `git commit -- <paths>` (or `git commit --only <paths>`),
     never a bare `git commit`.
   - Prefer committing supervisor work when no `claude -p` child is alive.

Consequence when it happens: the worker's index vanishes underneath it, so it can neither commit nor
report. Recovery = terminate that child, verify the swept code against its packet, re-run the matrix,
record the ticket honestly with an ATTRIBUTION ERROR note, and relaunch the driver.

### Do NOT use a separate index to "safely" commit (tried 2026-07-25 07:40)

Tempting idea: `GIT_INDEX_FILE=/tmp/idx git read-tree HEAD && git add <mine> && git commit-tree`,
so the worker's shared index is never touched. It commits fine — and then breaks things.

Advancing `HEAD` invalidates the worker's **stale** index: files that exist in the new HEAD but not in
that index read as `D` (deleted). The worker's next commit would then *delete* them. (Observed: 14
freshly-committed packets flipped to `D` in the shared index.)

Repair, if it happens: `git add <the affected paths>` in the shared index so it matches HEAD again,
then confirm `git status --short | grep '^D'` is empty and the worker's own staged files are intact.

**The rule that actually works:** commit only when `pgrep -f "claude -p"` finds nothing. Untracked
packet files are perfectly safe left on disk between wakes — the loop reads them from the filesystem,
not from git. Patience beats plumbing here.

## Supervisor tooling lessons — Saturday daytime run (2026-07-25)

Written to disk immediately because they lived only in wake prompts for hours, and a context
compaction would have lost them. **Every item here is a mistake in MY tooling, not a worker's work.**

### Liveness probes I got wrong (three times)

1. **`find ... -newermt '-40 minutes'` silently returns 0, always.** `find` on this machine is `bfs`,
   which rejects relative timestamps and errors to stderr — and my command suppressed stderr with
   `2>/dev/null`. It reported "0 swift files touched" about a file written **15 seconds** earlier. A
   probe that cannot report life is worse than no probe: paired with a stale ledger it would have
   killed a healthy ticket.
2. **Never sort `stat` time-of-day strings.** `%Sm -t %H:%M:%S` makes yesterday's `23:18` outrank
   today's `12:36`. Use epochs: `stat -f %m` against `date +%s`.
3. **A `Sources/**/*.swift` glob does not expand here.** Iterate `git ls-files 'Sources/*'` and filter
   `*.swift` in a `case`.
4. **`pi` process presence is NOT liveness.** The three resident `pi` processes were 17h / 20h / 1d14h
   old daemons at ~0% CPU. A zombie satisfying a liveness test masks a real wedge.
5. **Driver-log mtime is NOT liveness** — `~/Library/Logs/agent-ux-loop.log` only appends at
   iteration boundaries, so it is meaningless mid-ticket.

### The heartbeat goes stale on healthy long tickets

**Workers do not refresh the `_LEDGER.md` heartbeat during long verify/fix loops.** P2A.8 ran 1h13m+
with a **48-minute-stale ledger** while actively editing (caught mid-edit via a `python3` heredoc
subprocess). Twice tonight the ledger alone would have had me kill working code.

**Wedge requires ALL of:** ledger stale >35min AND newest tracked `Sources/**.swift` stale >35min AND
no build/edit subprocess (`pgrep -fl "swift-build|swift-frontend|python3|continuum-revived --|run-matrix|xcodebuild"`).
`ITER_TIMEOUT_SECONDS=9000` (2.5h), so a 1–2h ticket is normal for a 30-file migration. Child at
0.0–1.3% CPU is normal; so is 10–15min of no writes early on while it reads and plans.

Also: heartbeat *strings* inside `_LEDGER.md` run ~5h ahead of real UTC (writer skew). Use file
mtimes, never those strings.

### When a checks file LOSES lines, count assertions — do not read the minus lines

This has settled **three** near-misses where a diff looked like a weakened gate and was not:

```
git show <sha>~1:<file> | grep -cE "expect\(|throw fail\(|precondition\("
git show <sha>:<file>   | grep -cE "expect\(|throw fail\(|precondition\("
```

- P2A.6 removed 22 lines from `ContinuumRevivedPaletteChecks/main.swift` → assertions **73 → 75**
  (palette-row expectation lists rewritten for a new action).
- P2A.8 churned `ContinuumRevivedSyncChecks` heavily → assertions **212 → 225**.
- P1.11 dropped `minimumSentineledSlots` 26 → 23, which looked like a lowered floor. It was not: the
  descriptor tile's eleven per-`TileKind` fills were retired, so fewer real layer colours exist. The
  same commit RAISED `minimumThemedViews` 10 → 11 and doubled assertions 27 → 54.

**A failed grep means my pattern is wrong far more often than a guard is missing.** Verify the file or
matrix leg exists before concluding anything.

### The I5 architecture, corrected

I repeated a wrong description of this for many wakes. **There is no `SyncPayloadTaint.swift`
key-pattern file.** What actually enforces the sync boundary:

- `Sources/ContinuumRevivedCore/SyncPayloadTaintScanner.swift` — VALUE-shape rules, including
  pid-shaped integers (`2...4_194_304`).
- **`Sources/ContinuumRevivedSyncChecks/`** — the real gate, a whole checks target. Two forbidden
  lists live in `DesktopCompanionSyncPublisherTests.swift` (~171 and ~233); both include `/Users/`,
  which is the **exact leak I once shipped** (`RunError.piFailed(stderr:)` → `String(describing:)`
  put a filesystem path into a synced summary). Keep both witnesses.
- `run_app_check --companion-sync-health-check` — the app-level leg. **No matrix leg has "taint" in
  its name**, so grepping for one and finding nothing proves nothing.

The wall is **doctrinal, not mechanical**: both scanners match key names and value shapes, so ~300
characters of assistant prose would pass them. Read the payload CONSTRUCTION for anything
interpolating an error, path, URL, stderr or transcript body.

### Baselines: never bless in bulk off a sample

I blessed 36 baselines after inspecting 2 diffs, and one had captured a bad render. Then I blessed the
same card twice **in opposite directions** before measuring the underlying cause — a bare `NSView()`
spacer with no constraints left a row's height ambiguous, so the render alternated between two
layouts and the gate coin-flipped. Open SEVERAL diffs, and re-run the check 3+ times to prove
determinism. **A flapping baseline usually means ambiguous layout, not a stale bless.**

### Matrix check-count baseline

115 at the time of writing (`P2A.7` added `--agent-restore-check`). Growth with a matching
`matrix-inventory.txt` entry is fine; a DROP is suspect.
