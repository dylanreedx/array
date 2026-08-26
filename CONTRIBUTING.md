# Contributing

> **Local-only warning for agent runs:** do not push or pull unless Dylan explicitly asks. Preserve evidence with local SHAs, command output, and artifact paths.

This repo uses Linear as the source of truth for active work. The short version: **no ticket, no code**. [docs/21-agent-workflow.md](docs/21-agent-workflow.md) is the binding workflow for implementing agents; this file is the root quick reference.

## Current workflow

1. Work from exactly one Linear ticket. If there is no ticket, stop and ask/record a proposal instead of coding.
2. Work on `main` unless Dylan explicitly says otherwise. Do not create long-lived branches or worktrees for normal tickets.
3. Keep one writer per file/area at a time. Inspect the current git diff before editing overlapping files.
4. Stay inside the ticket scope. Adjacent ideas become ticket comments or new ticket proposals, not drive-by changes.
5. Pair implementation with deterministic QA. Add or strengthen the oracle needed to prove the behavior.
6. Hand off with evidence and a reviewer gate. Leave work reviewable; do not mark Done yourself unless explicitly assigned that role.

## Evidence and review gate

Before claiming success, report:

- commands run with real results, not invented summaries;
- relevant local commit SHAs if commits were requested/allowed;
- artifact paths such as `qa-runs/<id>/`, screenshots, manifests, logs, or `verdict.md`;
- a PENDING / unproven list for manual, visual, or environmental checks.

Build-only evidence is not enough for UX behavior. If a check failed, was skipped, or was not run, say so plainly.

## Checks are part of the product

- Do not weaken, delete, or skip checks to make a ticket pass.
- If a check's semantics must change, keep that change in scope, explain why, and add replacement coverage.
- Prefer `./scripts/run-matrix.sh` for the fast local matrix; run ticket-specific checks and any required QA flows too.
- For external QA, use `qa/README.md` and review generated artifacts under `qa-runs/`.
  `qa/run-autonomous.sh --scope changed` covers just what the branch touched; it
  supplies the disposable tmux namespace the real-tmux legs require, so never run
  those against the default socket while Array is open.

## Handoffs

- Do not use `git stash` as a handoff mechanism.
- Do not hide uncommitted changes from reviewers; list touched files and remaining risks.
- Do not report success from uninspected artifacts. Read verdicts/manifests/screenshots that your evidence cites.
- Do not update Linear state from this environment unless the task explicitly asks for it.

## Conductor vs Linear

The `.conductor/` database and harness artifacts may be useful context, but they are not the primary queue for current implementation work. Do not run conductor/autonomous tasks and Linear tickets as competing queues. Linear ticket scope wins unless Dylan says otherwise.

## When to stop

Stop and report instead of improvising when:

- the ticket conflicts with `docs/20-product-vision.md`, `docs/21-agent-workflow.md`, or code reality;
- verification cannot be made deterministic and the ticket did not acknowledge that;
- a required check fails and the only apparent fix is to weaken the check;
- the change would require remote git operations, history rewriting, broad refactors, or machine-level setup outside the ticket.

For deeper details, read [docs/21-agent-workflow.md](docs/21-agent-workflow.md) and coordinator notes in [docs/22-linear-master-overnight-workflow.md](docs/22-linear-master-overnight-workflow.md).
