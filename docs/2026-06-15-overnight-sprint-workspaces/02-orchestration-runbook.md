# Overnight Orchestration Runbook

Status: 2026-06-15. **You (the resumed/compacted session) are the orchestrator** for the
workspaces/zones sprint. This runbook is authoritative — it survives compaction; the chat
summary may not. Read it fully, then `00-charter.md`, `01-conventions-and-review.md`, and
the task specs before dispatching anything.

---

## 0. Mission
Drive the workspaces/zones sprint autonomously, long-lived, all night: generate the
remaining task specs, then execute tasks in dependency order by **delegating one agent per
task and reviewing each adversarially**, committing `[overnight]` tasks on PASS and
*staging* `[morning]` tasks for Dylan. Stay responsive — react to each agent's completion,
handle PASS/REWORK, catch wrong paths, and course-correct. End the night with a
`MORNING-REPORT.md`. **Quality over speed: deep, thorough, edge-case-hunting, TDD.** A
green bypass check is failure, not progress.

## 1. Context you must load (in order)
1. `00-charter.md` — the settled architecture (workspace→zones→tiles, optional project,
   project-owned tiles, adaptive size, 3 persistence layers, profiles, two-level sidebar),
   the staged overnight/morning split, and the **19-task index + 4-wave order**.
2. `01-conventions-and-review.md` — the non-negotiable working method, the task-file
   template, and the **review protocol** (§5) you enforce on every task.
3. The `TNN-*.md` specs (T01 + T09 exist as exemplars; you generate the rest in §3).
4. `docs/33` (nav/snapping baseline this builds on), `docs/23` (keystone source for
   T03–T10), and the project memory (`verification-doctrine`, `tdd-and-configurable-first`,
   `no-co-authoring`, `continuum-reintegration-state`).

**The 4 architecture decisions in the charter are SETTLED. Do not re-litigate them.** If
one genuinely blocks a task, record it for the morning report and flag the task
needs-human — do not silently change the design.

## 2. Branch & safety (autonomous defaults)
- **Work on a sprint branch** `overnight/workspaces-zones` off `main`. Create it first.
- Commit per **reviewed-PASS** task (plain `type(scope): summary`, **no co-author footer**).
- **Push the branch** after each commit (backup + Dylan can watch remotely).
- **Never touch or merge `main` overnight.** The morning review merges. Never `git push`
  to main. Never force-push.
- **Matrix-gate every commit:** `./scripts/run-matrix.sh --fast` green before commit; never
  commit red. After integrating a task, re-run it to catch integration regressions.
- Never delete/overwrite files outside a task's declared scope. Surgical only.

## 3. The loop (state machine)

### Phase 0 — Bootstrap
Clean tree? (`git status`). Create + checkout `overnight/workspaces-zones`. Initialize
`STATE.md` (already seeded — keep it live: every task's status as it moves
todo→building→review→done/staged/blocked, with commit shas + notes). This is your durable
progress ledger; update it at every transition so progress survives a mid-night compaction.

### Phase 1 — Generate the remaining specs (T02–T08, T10–T19)
These are independent → fan out (a `Workflow`, or parallel `Agent` calls). Each spec-writer
agent: reads the **real source files** named in the charter for exact current signatures
(do not trust the Explore summary's field lists blindly — read `WorkspaceDocument.swift`,
`ZoneRuntimeController.swift`, `CanvasNSView.swift`, `ProjectStore.swift`,
`WorkspaceStore.swift`, `RegistryStore.swift`, `CanvasEngine.swift`, `ContinuumApp.swift`),
and writes `TNN-*.md` **exactly to the template in `01` §3**, with the check's assertions
fully enumerated. Then run a **spec-review pass** (an adversarial reviewer per spec):
precise file/symbol anchors? check drives the real path (no bypass)? assertions
enumerated and hand-derivable? scope bounded with a "Do NOT touch" list? deps correct?
Fix, then commit the specs (`docs(sprint): task specs T02–T19`). If a spec can't be made
precise (source doesn't match expectation), mark it needs-human in STATE.md and continue.

### Phase 2 — Execute tasks (serial on the sprint branch; deps from charter §3)
**Default to serial execution** (build→review→commit, one task at a time). The dependency
chains are mostly serial anyway; serial + adversarial review is the robust path for an
unattended run. (Optional optimization: build two genuinely-independent same-wave tasks in
parallel via `isolation: "worktree"`, then integrate serially with a matrix gate — only if
it's clearly safe.)

For each task whose `Depends on` are all Done, lowest id first:
1. **Dispatch a builder agent** (background) with: the task spec + `01-conventions` + the
   charter §1 model. Instruct: write the named check FIRST → confirm RED on the assertion →
   implement minimum to GREEN → `swift build` → run the single check → `run-matrix.sh
   --fast` → self-review vs acceptance criteria → **report back the diff summary + check
   output; do NOT commit** (you commit after review).
2. **On completion, dispatch a reviewer agent** (separate, adversarial — `01` §5): re-run
   the check from a clean temp env, run the fast matrix, **audit the check for bypass**
   (#1 gate: "would it still pass if the feature were stubbed?"), re-derive one asserted
   value by hand, diff vs scope (no forbidden files, orphans removed, configurable bits
   wired, no footer), run the task's domain adversarial probes. Verdict PASS / REWORK with
   specifics.
3. **PASS** → you (orchestrator) re-run `run-matrix.sh --fast` on the integrated tree,
   commit, push the branch, update STATE.md + the task's `Status: done` + sha, unblock
   dependents.
4. **REWORK** → re-dispatch the builder with the reviewer's exact findings. **Retry budget
   = 2.** Still failing → `Status: blocked`, record why, continue with other ready tasks.
5. **`[morning]` task** → builder implements + runs headless checks; reviewer audits; on
   PASS you integrate + commit but set `Status: staged-for-morning` (NOT done) and append
   the **exact eyeball list** to the morning report. The sprint is not blocked on it.

### Phase 3 — Terminate
When no `[overnight]` task is ready (all done/blocked/staged), write `MORNING-REPORT.md`
(see §6), push the branch, post a final summary, and **stop scheduling wakeups**.

## 4. Staying alive (long-lived)
Background agent completions **auto re-invoke you** — react immediately (review, then
dispatch next). When idle waiting on background work, set a **`ScheduleWakeup` heartbeat
(~1800s)** as a fallback so the loop survives a hung/lost agent; do **not** poll fast
(don't burn the cache every minute). Re-pass this runbook's intent on each wakeup. Stop
scheduling once Phase 3 is reached.

## 5. Course-correction playbook (handle wrong paths)
- **Builder can't get RED** (check passes before implementing) → the spec/check is wrong;
  inspect, fix the check or spec, or mark needs-human. Never "implement" against a check
  that was already green.
- **Scope creep / forbidden files touched** → reviewer flags; instruct builder to revert
  out-of-scope changes; re-dispatch with tighter scope. If it keeps drifting, do the
  surgical version yourself.
- **Bypass check** → REWORK; require a real-path check (synthesizes the real
  event/lifecycle, asserts observable state).
- **Matrix red after integration** → revert that task's commit, mark blocked, continue.
  Never leave the branch red.
- **Ambiguous spec / missing symbol** → don't guess; mark needs-human; continue.
- **Dependency blocked** → its dependents become blocked; record; work independent tasks.
- **Two builders conflict** (if you parallelized) → fall back to serial.
- When genuinely uncertain about a design call → **flag for morning, don't decide**; the
  4 charter decisions are the only ones pre-made.

## 6. Morning report (`MORNING-REPORT.md`)
- **Done:** each task → commit sha + the check that guards it.
- **Staged-for-morning:** each `[morning]` task → the **exact visual/feel items to
  eyeball** (flicker, z-paint, cursor rects, layout, animation) + how to verify on the
  rebuilt bundle (`make-app-bundle.sh` cmd) + the headless checks that already passed.
- **Blocked / needs-human:** task → why + what's needed to unblock.
- **Branch + merge:** branch name, `run-matrix.sh` result, suggested merge order, anything
  risky.
- **Decisions you made** under the playbook, so Dylan can audit them.

## 7. Starting state (as of this handoff)
- `main` @ `4647929`, clean. Nav/snapping shipped (`docs/33`).
- Sprint folder: `00-charter`, `01-conventions-and-review`, `02-orchestration-runbook`
  (this), `STATE.md`, and specs `T01` + `T09` written. **Remaining specs to generate:**
  T02–T08, T10–T19 (Phase 1).
- No code for the sprint written yet. Begin at Phase 0.

## 8. Hard rules recap (violating any = stop and reconsider)
real-path checks only (no bypass) · check RED-first · configurable-first · surgical ·
matrix-gate every commit · no co-author footer · sprint branch only, never main ·
`[morning]` ≠ Done without Dylan · don't re-litigate the 4 settled decisions · when
uncertain, flag — don't guess · separate adversarial reviewer per task · quality over speed.
