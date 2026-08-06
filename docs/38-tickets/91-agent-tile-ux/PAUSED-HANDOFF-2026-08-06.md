# Queue 91 paused handoff — 2026-08-06

## Owner direction

Queue 91's expanded implementation is paused. Do not resume ad-hoc fan-out or interactive background delegation.

When Dylan explicitly resumes the program for overnight work, use only the existing observable Ralph-style driver:

```bash
./scripts/agent-tile-ux-loopctl.sh status
./scripts/agent-tile-ux-loopctl.sh arm
./scripts/agent-tile-ux-loopctl.sh start
```

The loop must remain local-only, one ticket/commit at a time, with the existing queue, ledger, file fences, STOP behavior, deterministic gates, and supervised/manual gates preserved. Do not start it until Dylan explicitly requests the overnight run.

Locked model roles for the next run:

- implementation and bounded repair passes: `openai-codex/gpt-5.6-luna`, thinking `high`;
- independent monitoring/reconciliation: `openai-codex/gpt-5.6-sol`, thinking `xhigh`;
- Sol remains read-only and returns a bounded REWORK reconciliation packet to Luna when needed.

Pause was confirmed with:

```text
loop: stopped
STOP: present
child: none active
```

## Saved Git checkpoint

- Branch: `overnight/agent-ux`
- Pause checkpoint before this handoff commit: `96168c1dbbb43184faca958d890190ee78754287`
- Nothing pushed.
- Unrelated logos, `website/`, Queue 92, and relay files remain intentionally untracked and untouched.

Recent merged commits:

```text
96168c1 fix(core): redact canvas snapshot path labels
b0f62bb Add canvas entity index snapshot adapter
4660e03 Add location switcher index foundation
7d01bd0 Add agent context gravity canvas adapter foundation
1db393f fix(agents): refuse implicit process cwd Home
1016b2b docs(queue91): record Home and spatial foundations
ab14feb fix(agents): gate Home actions across platforms
565b423 fix(agents): secure Home selection and core gates
```

The large Queue 91 document contains 291 granular acceptance checks; it is not a list of 291 pre-existing product tickets. At pause, 94/291 are checked. The original Home / Where / What owner workflow is substantially implemented; the larger P4–P15 spatial roadmap is future work.

## What is usable now

The current owner-facing feature includes:

- Home / Where / What on managed-agent tiles;
- `Change Home` for a genuinely untouched zero-turn agent;
- registered projects and arbitrary-folder selection;
- `New Agent Here` after user work or restored history;
- copy, Finder, Terminal, and file-tree path actions;
- durable Home reassignment with rollback;
- invalid/missing/file path rejection;
- restored-agent retargeting protection;
- no ordinary process-cwd fallback at current source HEAD.

Manual owner acceptance remains open: project selection, arbitrary folder, picker cancellation, path actions, first submit transition to `New Agent Here`, and restored-agent refusal.

## Evidence at pause

Foundation checks and builds passed on the merged branch:

- `/tmp/continuum-queue91-wave2-foundation.VVBkWI`
- `/tmp/continuum-queue91-wave2-foundation-ios.log`
- `/tmp/continuum-queue91-no-cwd.t8pLiD`
- `/tmp/continuum-queue91-p7-label-privacy.log`
- final earlier matrix: `/tmp/continuum-queue91-final-matrix2.lJZVy1/output.log`

The final earlier matrix intentionally skipped supervised terminal surfaces and unblessed UI baselines. It is not a complete release acceptance run.

## Review state and open findings

Merged P4/P5/P7 foundations are not all production-wired. The latest code/QA reviews require follow-up before the expanded roadmap resumes:

1. Add a direct production-adapter check for `AgentContextGravityCanvasAdapter.makeInput`.
2. Make P4 checkout-root defaults explicit so a caller cannot accidentally substitute a canonical/shared project root for a newly allocated isolated checkout.
3. Invalidate `LocationSwitcherModel.previewState` and advance its generation immediately when selection changes.
4. Prevent provider IDs, transcript names, and routing handles from entering Codable switcher labels/derived aliases.
5. P7 absolute/path-like label leakage was fixed in `96168c1`; focused P7 checks pass.

Review artifacts:

- `.pi/agent-runs/code-reviewer-20260806T205000Z-8296ed/final.md` — REWORK
- `.pi/agent-runs/qa-reviewer-20260806T205000Z-72e558/final.md` — REWORK

## Completed but intentionally unmerged worktrees

These commits were produced after the pause decision and must not be merged without a new explicit resume decision and fresh review:

- `12eaae212c12882043c92f8e6f5a8ed08eadf874` — native P5 switcher panel; no live hook, build/self-check unverified in its worktree.
- `60a4203d0bceec85510ee84c25768b36c01cac31` — live P4/P7 wiring; build/self-check unverified in its worktree and based before the latest review fixes.

Their worktrees and agent artifacts remain as resumable evidence. Do not count them as merged or verified behavior.

## Resume sequence

1. Confirm Dylan explicitly wants an overnight Queue 91 run.
2. Read this handoff plus the latest code/QA review artifacts.
3. Reconcile the existing Queue 91 `_QUEUE.md` / `_LEDGER.md` with the pause checkpoint; do not use the 291-item prose checklist as an automatic execution queue.
4. Convert the open review findings above into narrowly fenced Ralph-loop packets.
5. Keep `STOP` armed until the queue and first eligible ticket are reviewed.
6. Run the loop via `agent-tile-ux-loopctl.sh`; never use ad-hoc parallel hotspot writers.
7. Preserve manual/VoiceOver/baseline gates as supervised rather than auto-completing them.

## Owner build

A fresh local `Array.app` should be built from the saved branch checkpoint, ad-hoc signed and verified, then launched only after stopping the previous owner process and backing up the canonical store. The handoff/status inside that QA artifact is the authoritative statement of its exact source commit and launch state.
