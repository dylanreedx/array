# Queue 96 operator handoff — 2026-08-15

You are the **operator** of the companion catch-up queue. A supervisor script
runs tickets autonomously; your job is to watch it, diagnose what it cannot fix
itself, fix that, and restart it. The monitoring loop is the job — read that
section first.

- Checkout: `/Users/dylan/Documents/personal/Array/.worktrees/companion-catch-up`
- Branch: `array/integration`, **nothing pushed** (66 commits ahead of origin)
- HEAD at handoff: `cbc2df4`, tree clean, **loop stopped**
- Progress: **11 done of 48**

---

## 1. The monitoring loop (the important part)

### Start it

```sh
cd /Users/dylan/Documents/personal/Array/.worktrees/companion-catch-up
./scripts/companion-catch-up-loopctl.sh arm
MAX_REPAIR_PASSES=4 ./scripts/companion-catch-up-loopctl.sh start
./scripts/companion-catch-up-loopctl.sh status
```

`MAX_REPAIR_PASSES=4` means **five worker passes** (pass 1 + four repairs). It is
essential — the default 2 loses tickets that were converging. C1.4 just died at
the rework limit with one trivial finding left. Worker and reviewer are both
`openai-codex/gpt-5.6-sol` at high thinking, locked in preflight.

**Right now the loop will not start.** See section 2 — fix that first.

### Watch it

Two watches, both cheap:

1. **Events** — `tail -f <run-dir>/events.log`. One line per transition
   (worker pass, review round, commit, block). The run dir is printed by
   `loopctl status` and lives under
   `/Users/dylan/.pi/companion-catch-up-runs/companion-catch-up/`.
   **Re-point this at the new run dir every time you restart the loop.**
2. **Heartbeat** — `loopctl status` every ~25 min. Gives loop pid, state,
   ticket, and child CPU. This is your hang detector.

### What to do on each event

- **`review round N`** → nothing. Wait.
- **`worker pass N`** *after* a review → read
  `<run-dir>/tasks/iteration-NNN-<ticket>/review-final-<N-1>.md`. That file is
  where operator defects surface. Triage it against section 4.
- **`committed as <sha>`** → **verify it yourself.** Worker and reviewer are the
  same model, so an approval is not evidence. Run the ticket's own `verify`
  command from its packet. Do not skip this; it is how C1.3 was confirmed real.
- **`NOT COMPLETED (...)`** → the ticket blocked. Read every
  `review-final-*.md` and the last `worker-*.md`. Decide whether the ticket
  failed or the *packet* failed (section 4), fix the packet, re-arm, restart.

### Hang signature

0% CPU **and** zero bytes written to the worker output **and** no artifact
writes for 20+ min **and** a connection still held. Kill the **child** pid only
(`loopctl status` prints it); the retry treats rc=143 as transient and starts a
fresh pass keeping prior progress. Normal Sol-high latency also shows 0% CPU,
but artifacts keep moving — check
`<task-dir>/worker-session-N/*.jsonl` mtime before killing anything.

### Stopping safely

```sh
./scripts/companion-catch-up-loopctl.sh stop     # exits between tickets, no work lost
```

Never edit files in the checkout while a worker is running — it dirties the tree
and trips that worker's own scope check. Prepare fixes as scratchpad scripts and
dry-run them against a **copy** of the program dir while you wait.

---

## 2. Blocker: the program checker is RED (fix before restarting)

`scripts/check-companion-catch-up-program.sh --check` runs inside preflight, so
the loop cannot start until it is green. Three failures:

```
done recording did not update queue and ledger together
blocked recording did not update queue and ledger together
loop did not publish lock and pid before its program checker
```

**These are not regressions from the doc commits.** They were always there and
were hidden: the checker does `exit 1` at **line 224**, after its graph check and
*before* its own mutation suite, so any graph failure skips every later leg. A
stale queue/ledger drift was failing the graph check, so the suite never ran.
Clearing the drift revealed them. (This repo has learned this exact lesson once
before — see `matrix-halts-hide-legs`. Consider making the checker
classify-and-continue like `run-matrix.sh` now does.)

**Diagnosis of failures 1 and 2 (verified):** the witness at lines 242–262 copies
the *live* program dir into a fixture and asserts a `pending → done` transition
on **C0.4's own row**. `update_program_state` aborts unless both the ledger and
queue rows equal the expected state. C0.4 is now `done` in both, so the
transition can never succeed. The witness was green only while C0.4 was pending
and is **self-invalidating** — it broke permanently the moment its own ticket
landed. Fix by having the fixture use a synthetic ticket row, or reset the
fixture row to `pending` before the transition. Do not "fix" it by reverting the
queue to `pending`; that reintroduces the drift the same checker forbids.

**Failure 3 is undiagnosed.** I did not investigate it. The assertion is at
`scripts/check-companion-catch-up-program.sh:378`; it claims the loop must
publish its control lock and pid before running its program checker. Verify
against `claim_control` in `scripts/companion-catch-up-loop.sh` (~line 579) before
changing anything.

This is a follow-up on C0.4's shipped work, so it is legitimate operator repair.
Everything else in that checker is strong: 19 mutation witnesses (launch
spellings, fences, model arguments), control witnesses, override witnesses, and
loopctl preflight witnesses all reject correctly.

---

## 3. Ticket state

| Ticket | State | Note |
|---|---|---|
| C0.1–C0.3, C1.1, C1.2, C1.3, C1.6, C1.7, C4.1, C4.2, **C0.4** | done | 11 total |
| **C0.5** | blocked **deliberately** | Do **not** retry — see below |
| **C1.4** | re-armed, pending | Died at rework limit with one trivial finding left |
| **C4.3** | re-armed, pending | Three attempts died on provider `fetch failed`, not a code defect |
| rest | pending | |

**C0.5 — do not retry.** Five attempts across two models died on Swift lexical
edge cases (bare regex starting with `=`, custom slash operators, escaped triple
quotes). A bash regex cannot be a Swift lexer. The fix is to widen its fence so
the scan becomes a Swift check target. It parks C0.6 and C0.7.

**C1.4 is close.** Round 5 left exactly one finding: the privacy fixture derives
forbidden substrings from `NSUserName()`/hostname, so on an account named
`runner` the synthetic text "Synthetic runner failure" trips its own gate. Its
packet has been re-armed with both real production card shapes and a corrected
red witness. It should land in one or two passes.

---

## 4. Failure classes, in order of frequency

1. **The packet fence excludes something the ticket must produce.** Dominant
   class. Fix `_PACKET_CATALOG.json`, re-render with
   `ruby scripts/render-companion-catch-up-packets.rb`, **never hand-edit a
   rendered `.md`**. Two shapes: the fix lives in a file the fence forgot (C1.4
   needed `AgentDocumentBlock.swift`; sharing a file across packets is normal —
   C1.2, C1.7 and C6.2 already co-own it), or correcting canonical policy text in
   the renderer template legitimately regenerates all 48 packets, so the rendered
   packets must themselves be in the fence (C0.4).
2. **An unbounded goal never converges.** C0.4 burned two entire runs because
   "make the queue self-checking" reads as "prove the checker cannot be fooled."
   Every round accepted the prior fixes and found a *new* bypass. Findings were
   all legitimate; the ticket still could not finish. The fix that landed it:
   rewrite Approach to **enumerate** every required witness and state in the
   packet that a bypass outside the enumeration is a follow-up note, not a
   REWORK ground. Watch for this shape on any "prove X is safe" ticket.
3. **Operator staleness — including stale red witnesses.** A packet's Red
   witness goes stale when an earlier ticket already fixed the thing. C1.4's
   demanded a future-block RED that C1.2 had already implemented. **A file that
   does not exist in HEAD has no pre-change behavior**, so it can only be proved
   by a final-code mutation witness. A worker that logs the pre-change GREEN
   instead of faking a red is behaving correctly — retarget the witness.
4. **Out-of-fence gates hardcode paths a ticket moves.** The iOS rename broke
   four; all now resolve by content, not path.
5. **Provider transport.** Outages, `fetch failed`, hangs. Retries handle them.

**Verify production claims yourself before writing them into a packet.** I put
"classify on itemKind first" into C1.4 from a review; production's streaming
cards carry no `itemKind` at all, so the worker made it mandatory, every real
card fell to opaque, and it burned two passes — then overcorrected. Read the
tree, then write the packet.

---

## 5. Rules paid for in blood

- **Never `git commit` in this checkout without checking `git diff --cached
  --stat` first.** One careless commit swept the worker's staged deletions and
  removed `ios/Continuum/Sources` entirely — 2,802 lines — breaking the build for
  five hours.
- **Commit before cleaning.** `git checkout -- .` / `git clean` destroyed
  uncommitted operator fixes three separate times.
- **Never edit while a worker runs.** Use `loopctl stop`.
- **The loop selects tickets by `_LEDGER.md`**, not `_QUEUE.md`'s state column.
  Those two had silently drifted on 11 rows.
- **A restart runs the newly committed machinery, the running loop does not.**
  The loop parses its script once at startup. C0.4 rewrote the loop, loopctl and
  the checker while the old code was still running, so the row it wrote for
  itself still carried the obsolete "Luna-medium" evidence. After any commit that
  touches `scripts/companion-catch-up-*`, stop and restart the loop.
- Never point anything at `/Applications/Array.app` or Dylan's project root, and
  never run tmux-touching checks against the default socket while Array is open.

---

## 6. Next actions, in order

1. Fix the three checker failures (section 2) and get
   `bash scripts/check-companion-catch-up-program.sh --check` green.
   Consider making it classify-and-continue instead of `exit 1` at line 224.
2. Commit that fix (`git diff --cached --stat` first).
3. `arm` + `MAX_REPAIR_PASSES=4 start`, re-point the events watch at the new run
   dir, resume the loop in section 1. C1.4 runs first, then C4.3.
4. Verify each commit yourself with the ticket's own `verify` command.
