# Agent Workflow — the regression contract

Status: adopted 2026-06-10. Binding for every implementing agent. The
recurring failure mode this document exists to kill: agents doing plausible
work without a clear task, breaking adjacent behavior, and reporting success
anyway. Vision: `docs/20-product-vision.md`. Backlog: Linear, team
`continuum`.

## The loop

**No ticket, no code.** Every change traces to exactly one Linear ticket.

1. **Pick**: take the highest-priority unblocked ticket from the epic you
   were assigned (or the ticket ID you were given). Do not pick tickets with
   unresolved blocking relations. Do not invent work.
2. **Claim**: move it to *In Progress*; add a comment with your session/run
   id and planned approach in 2-3 sentences.
3. **Implement** on `main` (trunk-based; no long-lived branches). Small
   commits, message format `type(scope): summary`, footer
   `Refs: <ticket-id>`. Stay inside the ticket's Scope; anything you notice
   outside it becomes a COMMENT on the ticket or a new ticket proposal —
   never a drive-by change.
4. **Verify** before claiming anything:
   - Full check matrix green: `swift build`, the four `*Checks` executables,
     every `--*-check` app flag (enumerate live:
     `grep -o '"--[a-z-]*-check"' Sources/ContinuumRevived/App/ContinuumApp.swift`),
     `node scripts/check-package-targets.js`, `node scripts/check-qa-flows.js`,
     isolated smoke test.
   - Session gate: `qa/run-autonomous.sh --scope changed` and read the
     verdict.md — do not just check the exit code.
   - The ticket's own acceptance criteria, including the named check it
     requires you to add.
5. **Evidence**: comment on the ticket with: commits (SHAs), commands run
   with REAL pasted output (never summaries of output you didn't capture),
   artifact paths (`qa-runs/<id>/`, screenshots for visual work), and a
   PENDING list for anything you could not verify (e.g. needs a human
   mouse/manual test).
6. **Hand off**: add the `needs-review` label and leave the ticket *In
   Progress* (the team has no In Review state). Only Dylan or a designated
   reviewer agent moves tickets to *Done* and removes the label.

## Honesty rules (non-negotiable)

- Never weaken, skip, or delete a check to make it pass. If a check must
  change semantics, that change belongs in the same commit with written
  justification, and the ticket comment must call it out loudly.
- Never report success from build-only evidence. "It compiles" is not "it
  works."
- Evidence artifacts must contain measured values, never constants.
- Unverifiable claims get a PENDING marker, not optimistic phrasing. The
  precedent: DD-002 was honestly reported as "synthetic path passes, manual
  PENDING" — that is the standard.
- If the ticket contradicts the code, the vision doc, or another ticket:
  STOP, comment on the ticket, move it to *Blocked* (or back to *Todo* with
  the blocker label), and pick the next ticket.

## Stop conditions

Stop and report (ticket comment + session report) instead of improvising:
- Any matrix check fails and the fix would require weakening it.
- The change wants to touch `main` history, `backup/*` branches,
  `archive/*` tags, `.pi/agents/*`, or check infrastructure outside scope.
- The ticket's acceptance criteria cannot be made deterministic and the
  ticket doesn't already acknowledge that.
- You are about to exceed the ticket's Scope to "make it work."

## Ticket anatomy (what you can rely on)

Every ticket has: **Context** (why + links), **Scope / Out of scope**,
**Acceptance criteria** (incl. named deterministic checks), **Pointers**
(files, seams to reuse), **Dependencies** (Linear blocking relations),
**Size** (S/M/L). If a ticket you picked is missing these, that's a defect —
comment and move it to *Blocked* rather than guessing.

## Kickoff prompt template

```
# Task: Work the Linear backlog — team `continuum`

Repo: /Users/dylan/Documents/personal/continuum-revived (branch: main)

Optional local guardrail: run `scripts/install-hooks.sh` once per checkout to
install the opt-in pre-commit hook (`run-matrix.sh --fast`).

Orient (15 min, in order): docs/20-product-vision.md →
docs/21-agent-workflow.md (this file; it is binding) →
docs/15-repo-audit-2026-06-10.md §5 → your epic's tickets in Linear.

Assignment: <epic name or ticket IDs>.

Follow the loop in docs/21 exactly: claim → implement on main →
verify (full matrix + qa/run-autonomous.sh --scope changed) →
evidence comment with real output → add needs-review label. No
ticket, no code.
One ticket at a time. Respect Scope; propose, don't expand.

Stop conditions and honesty rules are in docs/21. PENDING markers
for anything you cannot verify. Remote: `origin` (github.com/dylanreedx/
continuum) — push `main` after each green, committed ticket; if the push
fails, continue working and flag it in your report.
```

## Roles (optional escalation)

The `.pi/agents/` roles remain available for structured runs: scouts explore
and propose tickets (output feeds Linear, via Dylan or a triage agent);
implementer/code-reviewer/qa-reviewer mirror the loop above. The conductor
queue (`.conductor/conductor.db`) is being superseded by Linear as the task
source of truth; until the harness bridge epic lands, do not run
`autonomous.js` against conductor tasks and Linear tickets simultaneously —
one queue at a time.
