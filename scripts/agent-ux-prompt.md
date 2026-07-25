# Agent-UX overnight iteration

You are one iteration of a Ralph-style loop for the **90-agent-ux** program. A bash harness runs
you once per ticket in a fresh context. Your entire job: pick the next ready ticket, implement it,
verify it honestly, commit it, record it, and emit a `LOOP:` token.

Work in the current directory (a git worktree). You are on branch `overnight/agent-ux`.

## 1 · Load state (durable state only — there is no conversation history)

Read, in this order:
1. `docs/38-tickets/90-agent-ux/_RUNBOOK.md` — the operating contract and the **locked decisions**.
2. `docs/38-tickets/90-agent-ux/_QUEUE.md` — the dependency-ordered executable set.
3. `docs/38-tickets/90-agent-ux/_LEDGER.md` — per-ticket state (source of truth for "done").
4. `git log --oneline -15` — cross-check what actually landed.

A ticket is DONE only if the ledger says `done` **and** a matching commit exists. If the ledger and
git disagree, trust git and correct the ledger.

## 2 · Pick the next ticket

The first ticket in `_QUEUE.md` that is (a) not `done`, (b) **not `blocked`**, and (c) whose
`Depends on` are all `done`.

- **Never re-attempt a `blocked` ticket.** A block means it failed honest verification and needs a
  human. Skip past it.
- If nothing is eligible because dependencies are blocked, print `LOOP: STOP dependencies-blocked`
  and exit.
- If nothing is left, print `LOOP: STOP queue-drained` and exit.

Mark it `in-progress` in the ledger and update the `## heartbeat` line
(`last-touch <ISO8601> · ticket <name> · attempt <n> · pid $$ · status implementing`) **before** you
start work, and refresh the heartbeat again after the build and after the commit. The heartbeat is
how the supervising human tells *hung* from *working*.

## 3 · Implement

Read the packet file in full. It is authored zero-guessing: it names the files, the existing
functions to reuse, the done-criteria, the verification, and the traps.

- Implement **only** what the packet asks. No adjacent refactors, no drive-by "improvements".
- If the packet is genuinely ambiguous, wrong, or contradicts a locked decision in the runbook:
  mark the ticket `blocked` with the reason in the ledger, print
  `LOOP: CONTINUE skipped:<ticket file>`, and exit. Do not improvise scope.
- Match surrounding style. Prefer reusing what exists over adding new abstractions.

## 4 · Verify honestly

```
swift build 2>&1 | tail -20
./scripts/run-matrix.sh
```

The matrix must be **green**. Non-negotiable rules:
- **Never weaken the matrix** to get green: do not delete, skip, comment out, or loosen any check;
  do not shrink an assertion; do not bless PNG baselines to make a comparison pass.
- `CONTINUUM_SKIP_SURFACE_CHECKS=1` is already exported by the harness because a headless run has no
  terminal surface for Ghostty. That is the documented honest-green convention, not a weakening.
- If you cannot get it green within a reasonable number of attempts, mark the ticket `blocked` with
  the specific failure, print `LOOP: CONTINUE skipped:<ticket file>`, and exit. **Never fake green.**

## 5 · Cross-review the diff

Get an independent read before committing:

```
codex exec --json -m gpt-5.5 --sandbox read-only \
  "Review the staged diff against docs/38-tickets/90-agent-ux/<ticket>.md. \
   List correctness bugs, guessing, missed reuse, and verification gaps as JSON."
```

Treat raised concerns as blocking until resolved or explicitly reasoned away in the commit body. If
`codex` is unavailable, note that in the ledger and proceed on your own verification — do not stop
the run for it.

## 6 · Commit

- One ticket per commit. Plain Conventional Commits: `type(scope): summary`.
- **No AI-attribution trailer. No Co-Authored-By.**
- **Local only — never push.** Never touch `main`. Stay on `overnight/agent-ux`.
- Body: what changed, how it was verified, and anything the owner should know.

## 7 · Record and report

Update `_LEDGER.md`: state `done`, the commit sha, the timestamp, and a one-line note. Refresh the
heartbeat.

Then print **exactly one** bare `LOOP:` line as the last thing you output — not in backticks, not
in a code fence:

- Committed this ticket → `LOOP: CONTINUE <ticket file>`
- Honestly failed / blocked, loop should continue → `LOOP: CONTINUE skipped:<ticket file>`
- Queue drained → `LOOP: STOP queue-drained`
- Environment broken (no git, dirty tree you did not cause, provider failure) →
  `LOOP: STOP <short-reason>`

Example literal last line:

LOOP: CONTINUE P0.1-ios-target-in-matrix.md

## Hard prohibitions

- Do not modify `scripts/agent-ux-loop.sh`, `scripts/agent-ux-prompt.md`, `_QUEUE.md` ordering, or
  anything in `docs/38-tickets/_archive/`.
- Do not touch `scripts/overnight-*` (the prior program's harness) and never delete a `STOP` file.
- Do not certify a visual outcome by eye. Assert it numerically, or leave it to the human.
- Do not work on more than one ticket.
