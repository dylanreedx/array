# Linear Master Overnight Workflow

Status: operational workflow for Continuum overnight Linear runs.

Goal: maximize completed Linear tickets without false positives. Linear is the queue, git commits are checkpoints, `.pi/agent-runs/*` and `qa-runs/*` are evidence, and specialist agents are gates. The master/coordinator owns decisions; specialists provide evidence.

## 0. Non-negotiables

- Work on `main` unless Dylan explicitly says otherwise.
- Remote exists since 2026-06-12: `origin` = github.com/dylanreedx/continuum. Push `main` after every committed ticket (`git push origin main`). A failed push is non-blocking: note "commit local-only, push failed" in the Linear comment and continue.
- One writer at a time in the current worktree.
- Do not start another implementation while uncommitted implementation changes exist.
- Do not claim manual/visual/user behavior without artifact or manual evidence.
- Do not weaken or delete checks to get green.
- Stop on unexpected dirty files, protected files, matrix failure, reviewer blocker, or ambiguous ticket scope.

## 1. Deterministic ticket state machine

Repeat this exact loop. Do not skip states.

### SELECT

1. Query Linear for open `CON` issues.
2. Pick one ticket by priority, dependency order, and risk.
3. Confirm `git status --short --branch` is clean except expected local evidence files.
4. Move the issue to In Progress if implementation will start.

Output required before moving on:
- selected issue id/title;
- scope summary;
- branch and dirty-state summary.

### SCOUT

Dispatch read-only scouts using `delegate_agent` in background with harness wake:

- Always: `code-scout`.
- UI/UX ticket: add `ux-scout` or `qa-scout` if useful.
- Broad or unclear ticket: add `qa-scout`.

Use:

```json
{
  "scheduleCheck": true,
  "expectedMinutes": 3,
  "wakeWhenAllDone": true,
  "wakeOnFailure": true
}
```

After dispatch, stop. Do not manually poll unless debugging a missing/stale run. On harness wake, read only needed `final.md` / `summary.md` artifacts.

### PLAN

Synthesize scout evidence into a bounded plan:

- files likely touched;
- production path;
- deterministic QA oracle;
- reviewer checklist seed;
- known gaps/manual pending.

If no deterministic oracle exists and manual evidence is unavailable, stop or choose a different ticket.

### IMPLEMENT

For small tickets, master may implement directly. For larger tickets, delegate exactly one `implementer`. No parallel writers in the same worktree.

Implementer requirements:

- start from scout evidence and acceptance criteria;
- add/update deterministic checks with the feature;
- run scoped checks;
- return an explicit reviewer checklist (see §3).

### VERIFY

Master runs the fast matrix on every ticket:

```sh
./scripts/run-matrix.sh
```

For UI, project-lifecycle, workflow-switching, persistence, windowing, or input/focus changes, the fast matrix is not enough. Add the relevant ticket-specific command and at least one app-driven or external QA flow before review.

E2E checks must be feature-scoped and isolated:

- invoke by a named flag, QA flow name, or standalone file/script;
- create/use temporary project roots and app-support state unless the ticket explicitly tests migration from existing state;
- exercise only the target feature/interaction/behavior, not an open-ended app tour;
- emit artifacts under `qa-runs/` with a manifest/log/screenshot when relevant;
- be callable independently so reviewers can rerun just that behavior.

If no existing scoped flow covers the behavior, add one or record a manual/visual PENDING and stop before marking Done.

If matrix or required ticket-specific/e2e evidence fails, rework or stop. Never commit with a failing required gate.

### REVIEW

Dispatch reviewers only after matrix is green:

- All code/model tickets: `code-reviewer` + `qa-reviewer`.
- User-facing UI/UX tickets: add `ux-reviewer`.
- Interaction-sensitive tickets: reviewer prompt must include the relevant `qa/flows/*` flow or screenshot/AX/self-check artifact to inspect.

Reviewer prompts must include:

- exact ticket scope;
- changed files;
- validation commands and result;
- implementer checklist;
- artifact paths;
- what is out of scope.

Use background delegation with `scheduleCheck`, `wakeWhenAllDone`, and `wakeOnFailure`, then stop for harness wake. Do not waste time waiting manually if the harness has already scheduled a wake.

### REWORK

If any reviewer says `needs rework` or `blocked`:

1. Treat it as blocking unless it is explicitly out of ticket scope.
2. Rework the smallest fix.
3. Re-run scoped checks and full matrix.
4. Re-dispatch the relevant reviewer(s), not necessarily all reviewers.
5. Stop for harness wake.

### COMMIT

Only commit after:

- matrix green;
- reviewer blockers resolved;
- required artifacts exist;
- working tree contains only intended files.

Commit format:

```sh
git commit -m "type(scope): summary"
```

### LINEAR_UPDATE

Comment and move the issue to Done only after the commit exists.

Linear comment must include:

- branch (`main` unless otherwise specified);
- commit hash/subject;
- files changed;
- validation commands;
- reviewer run IDs and verdicts;
- artifact paths;
- manual pending items or `none`;
- push status (pushed to origin / local-only + reason).

### NEXT

Continue only if:

- `git status --short --branch` is clean;
- no background run is active for the finished ticket;
- no unresolved blocker remains.

Otherwise stop with a handoff.

## 2. Background delegation rules

Correct pattern:

1. Dispatch background agents with `scheduleCheck: true` and `wakeWhenAllDone: true`.
2. End the master turn.
3. On harness wake, read final/summary artifacts.
4. Decide one next action.

Do not sit in shell loops waiting for agent files. Manual polling is allowed only if:

- a run is stale/missing;
- the harness reports a failure;
- Dylan asks for immediate diagnosis.

If the harness wakes but a final artifact is missing, inspect run status/events once, then either schedule another short check or stop with the run id and symptom.

## 3. Implementer reviewer checklist

Every implementer final response must include a checklist for reviewers. This is not a full QA plan; it is a dynamic prompt seed so the master can ask reviewers the right questions.

Required checklist sections:

```md
## Reviewer checklist

### Code reviewer focus
- [ ] Production path changed: <files/functions>
- [ ] Persistence/state migration risk: <yes/no + why>
- [ ] Error handling / edge cases: <specific cases>
- [ ] Scope guard: <what should remain out of scope>

### QA reviewer focus
- [ ] Deterministic checks added/updated: <commands>
- [ ] False-positive risks to challenge: <specific risks>
- [ ] Artifacts to inspect: <paths>
- [ ] Matrix command expected: `./scripts/run-matrix.sh`

### UX reviewer focus (if user-facing)
- [ ] User-visible claim: <claim>
- [ ] Screenshot/AX/manual evidence: <paths or pending>
- [ ] Interaction path to test: <click/key path>
- [ ] What is not visually proven: <gaps>

### Suggested extra probes
- [ ] <small command or QA flow reviewer should run if relevant>
```

The master should paste/adapt this checklist into reviewer prompts.

## 4. Verification tiers and safety notes

Use layered verification, not one giant always-on suite:

1. **Fast matrix, every ticket** — `./scripts/run-matrix.sh`; must stay deterministic and reasonably quick.
2. **Autonomous smoke, infra/large UI tickets** — `qa/run-autonomous.sh --scope <ticket>`; captures gate artifacts under `qa-runs/`.
3. **External/user-like flows, interaction-sensitive tickets** — `qa/flows/*.sh`; uses `cliclick`, `osascript`, and `screencapture` to produce screenshot evidence.
4. **New ticket-specific oracle** — add a named flag, Core/App self-check, or QA flow when the feature is not covered.

Do not make the fast matrix absorb every e2e flow. Let the matrix grow with cheap deterministic checks, and let the nightly/ticket workflow choose heavier e2e flows dynamically.

Growth rule:

- Add cheap pure/core/model checks directly to the fast matrix.
- Add app self-checks to the fast matrix only when they are deterministic, isolated, and bounded.
- Keep slow, flaky, permission-dependent, screenshot-heavy, or OS-event-driven tests in `qa/run-autonomous.sh` or `qa/flows/*` and require them by ticket type.
- Design every e2e as a targeted probe: one feature/interaction/behavior per flag or flow, isolated temp state by default, independently rerunnable by reviewers.
- Prefer adding missing e2e coverage tickets before high-risk feature work when the feature depends on project switching, workflow switching, persistence, or multi-tile interaction.

Current `scripts/run-matrix.sh` runs build, Core/Palette checks, multiple app self-check flags, and `git diff --check`.

Safety finding from 2026-06-10/11 investigation:

- App self-checks must not mutate repo-local `.continuum-revived/canvas.json` or Application Support state.
- `scripts/run-matrix.sh` should run app self-check invocations with temporary `CONTINUUM_PROJECT_ROOT` and `CONTINUUM_APP_SUPPORT` values.
- If the app opens with many tiles, master should inspect `.continuum-revived/canvas.json` tile count and must not ignore persistent-state growth.

The matrix is a regression gate, not proof of all behavior. Interaction-heavy UI tickets need additional in-process self-checks, screenshots, AX evidence, or external `qa/flows/*` user-driver flows.

Known coverage gaps to prioritize before trusting broad overnight autonomy:

- project/workflow switching across canvases;
- switching active projects and preserving independent canvas state;
- tile lifecycle across restart: spawn, move, resize, focus, close, relaunch;
- palette/action behavior while browser/editor content owns focus;
- window resize/quit-during-load/crash-resilience flows;
- artifact growth and cleanup policy for `qa-runs/` and `.pi/agent-runs/`.

Ticket selection bias for tonight: if Linear has open QA/e2e tickets for these gaps, choose those before implementing features that depend on the unproven behavior. If no ticket exists, file/follow up rather than pretending the fast matrix proves the gap.

## 5. External/user-like QA flows

The repo has `qa/flows/*` using `osascript`, `screencapture`, and `cliclick`. These are closer to real user interaction than model-level checks, but they are not currently part of `scripts/run-matrix.sh`.

For interaction-sensitive tickets, the master should explicitly ask QA/UX reviewers to run or inspect relevant flows, or file a follow-up if no suitable flow exists. New flows should be narrow and named after the behavior they prove, for example `qa/flows/project-switch-preserves-canvas.sh` or an app flag such as `--project-switch-preserves-canvas-check`.

## 6. Auto-compaction / handoff

Before context gets long, or before starting a large new ticket, stop and write a compact handoff in the response or a handoff doc. Include:

- branch;
- latest commit;
- clean/dirty status;
- current Linear issue and state-machine state;
- background run IDs and artifact paths;
- commands passed/failed;
- decisions made;
- risks/push status;
- exact next action.

After compaction/resume, the master must reload this workflow doc and continue from the recorded state. If state is ambiguous, stop and ask Dylan.
