# Agent-tile UX iteration

You are one fresh iteration of the `91-agent-tile-ux` loop. Durable files are the only context.
Implement exactly one eligible ticket, verify it honestly, commit it locally, update the ledger, and
emit one control token.

## Load state

Read in this exact order:

1. `docs/38-tickets/91-agent-tile-ux/_DESIGN.md`
2. `docs/38-tickets/91-agent-tile-ux/_RUNBOOK.md`
3. `docs/38-tickets/91-agent-tile-ux/_QUEUE.md`
4. `docs/38-tickets/91-agent-tile-ux/_LEDGER.md`
5. `git log --oneline -20`
6. `git status --short`

You must be on `overnight/agent-ux`. The tree/index must have been clean at harness start. Never push.

## Select

Pick the first queue row whose dependencies are all `done` and whose own ledger state is `pending`.
A ticket is done only when the ledger says done and a matching commit exists.

- Never retry `blocked` automatically.
- If the first eligible row is marked `supervised`, do not edit it. End with:
  `LOOP: STOP supervised-required:<ticket-file>`
- If blocked dependencies prevent all remaining work:
  `LOOP: STOP dependencies-blocked`
- If all 50 are done: `LOOP: STOP queue-drained`

Mark the selected autonomous ticket `in-progress` and update the heartbeat before source edits.
Refresh it after implementation, after focused checks, after matrix, and after commit.

## Implement

Read the selected packet completely, then inspect every named production seam.

- Follow the file fence and architecture. No adjacent cleanup.
- Preserve agent/tile separation and AgentSupervisor's sole runner ownership.
- AgentContent stays platform-neutral.
- Parse Markdown into Continuum's semantic model before rendering.
- No visible Aqua dropdown, `NSPopUpButton`, or rounded-bezel text field in v2 tile UI.
- Preserve light/dark, keyboard/VoiceOver/Reduce Motion, stable IDs, incremental updates, and I5.
- Do not modify queue/design/runbook/loop/prompt/check machinery from a normal ticket.
- Do not touch relay, old 90-agent-ux ledger/queue, stashes, worktrees, or unrelated files. FileTree/agent-inbox files are allowed only when the selected packet explicitly fences them.

If compiled reality contradicts the packet or a locked decision, mark it `blocked` with concrete
evidence in the ledger, commit that ledger-only record as `docs(agent-tile): block <ticket>`, and end
`LOOP: CONTINUE skipped:<ticket-file>`. This is still exactly one commit. Do not leave an
`in-progress` row, retry it automatically, or invent a second architecture.

## Verify

Add deterministic positive checks and the packet's negative witness. This project uses executable
check targets, not XCTest.

Run focused checks named by the packet, then:

```bash
swift build
CONTINUUM_SKIP_SURFACE_CHECKS=1 ./scripts/run-matrix.sh
```

Never weaken, skip, lower, exempt, or bulk-bless a gate. Autonomous tickets may not change visual
baselines unless their packet explicitly says they are supervised (and supervised tickets are not
run by this loop).

## Independent review

Stage only the ticket diff temporarily and inspect the staged paths. Save the exact review input:

```bash
git diff --cached --binary > "$TASK_DIR/staged.diff"
cat > "$TASK_DIR/review-request.md" <<EOF
Review the staged implementation for the selected agent-tile packet. Read the packet, design,
runbook, staged.diff, and relevant production files. Be strict about scope, architecture, proof,
gate weakening, and ledger honesty. You are read-only. End with exactly DECISION: APPROVE or
DECISION: REWORK.
EOF
pi --no-approve --model "$REVIEW_MODEL" --thinking "$REVIEW_THINKING" \
  --tools read,grep,find,ls --session-dir "$TASK_DIR/reviewer-session" \
  --name "agent-tile-review" --mode text -p @"$TASK_DIR/review-request.md" \
  > "$TASK_DIR/review-final.md" 2> "$TASK_DIR/review-stderr.log"
```

The review model is the opposite Sol/Luna model selected by the harness. Read
`$TASK_DIR/review-final.md`; resolve every correctness/architecture/verification finding. After any
source, check, inventory, or ledger change, restage everything, overwrite `$TASK_DIR/staged.diff`,
and rerun the reviewer, overwriting `$TASK_DIR/review-final.md`, until its final nonblank line is
exactly `DECISION: APPROVE`. Never edit a reviewer verdict or create a numbered substitute. The
harness compares the reviewed diff byte-for-byte with the sole final commit and verifies the
reviewer's model and thinking metadata. If the reviewer is unavailable, fail closed and leave the work for recovery; do not call the
implementing model its own independent reviewer.

## Commit and record

Only after focused checks, build, matrix, and review are clear:

- one ticket per local commit;
- message must use one real Conventional Commit type accepted by the harness, for example `feat(agent-tile): summary`, `fix(agent-tile): summary`, or `test(agent-tile): summary`; never use the literal placeholder `type`;
- no AI attribution or Co-Authored-By;
- include the ticket's ledger update in the same commit;
- never push.

Record `this commit`, real UTC timestamp, focused/matrix evidence, negative witness, review outcome,
and honest limits in the commit's ledger row. A commit cannot contain its own final SHA; the harness
mechanically ties the one commit after the prior HEAD to the named packet and validates its paths,
subject, and ledger state. The last output line must be exactly one bare token:

- `LOOP: CONTINUE <ticket-file>`
- `LOOP: CONTINUE skipped:<ticket-file>`
- `LOOP: STOP supervised-required:<ticket-file>`
- `LOOP: STOP dependencies-blocked`
- `LOOP: STOP queue-drained`
- `LOOP: STOP <short-environment-reason>`
