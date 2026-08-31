# Array 0.8.0 workstream agent protocol

Dispatch placeholders are exactly the uppercase names enumerated in `README.md`. Root substitutes every token applicable to the selected role before sending the combined protocol + packet + overlay. Any applicable unresolved uppercase token is a dispatch error. JSON/schema example values are descriptions that the worker replaces with observed runtime values; they are not dispatch placeholders.

## Common role contract

You are working on one bounded slice of a native Swift/AppKit macOS application. Read `<WORKTREE>/AGENTS.md` completely before taking action. The repository uses SwiftPM and scripts; there is no Xcode project and no Makefile.

Worktree: `<WORKTREE>`
Branch: `<BRANCH>`
Workstream ID: `<WS_ID>`
Dispatch role: `<ROLE>`
Dispatch phase: `<PHASE>`
Pinned base/checkpoint SHA: `<BASE_SHA>`
Release run ID: `<RUN_ID>`
Immutable release run root: `<RUN_ROOT>`
Evidence directory: `<EVIDENCE_DIR>`
Isolated project root: `<QA_PROJECT_ROOT>`
Isolated app-support root: `<QA_APP_SUPPORT>`
Isolated tmux namespace: `<QA_TMUX_TMPDIR>`

Before edits, verify `git status --short --branch`, `git rev-parse HEAD`, and base ancestry. Stop with `BLOCKED` if the worktree has unexplained changes, HEAD is wrong, or another active workstream owns a required hunk.

## Role-scoped permission and safety boundary

- **Implementation lead (`lead`):** may inspect the repository, edit only the assigned scope, run non-destructive builds/checks, create deterministic fixtures under the evidence directory, and commit to the assigned workstream branch.
- **Read-only auditor, reviewer, or tester (`auditor`, `reviewer`, `tester`):** must not modify tracked source/configuration, create commits, or leave new non-ignored checkout files. Named builds/checks may create or update ignored build/cache outputs; durable logs/reports/captures go only under `<EVIDENCE_DIR>`. Record pre/post `git status --short --untracked-files=all` and fail on any source/configuration delta. It must not execute the lead implementation sequence below. Lead-directed verbs in the neutral workstream body describe the candidate being evaluated and grant no edit authority to these roles.
- Do not merge, rebase, push, tag, sign, notarize, publish, edit the appcast/version ledger, or alter `Packaging/Info.plist`.
- Never rebuild, quit, automate, or replace `/Applications/Array.app`.
- Never use production Array state or Dylan's real project root. Before any direct app/check launch, export the dispatched `CONTINUUM_PROJECT_ROOT=<QA_PROJECT_ROOT>` and `CONTINUUM_APP_SUPPORT=<QA_APP_SUPPORT>`.
- Never touch the default tmux socket. Export `TMUX_TMPDIR=<QA_TMUX_TMPDIR>` and unset inherited `TMUX` and `TMUX_PANE` before any tmux-capable suite. Follow AGENTS.md isolation exactly.
- Never weaken a budget, delete a check, add a KNOWN-RED entry, globally bless baselines, or substitute a source-string assertion for behavior.
- Preserve unrelated user changes. Use `apply_patch` for edits.

## Child-agent boundary

Only a `lead` may receive a grant for a disjoint implementation child. An `auditor`, `reviewer`, or `tester` may spawn only explicitly granted read-only evidence assistance; no child in that subtree may edit the checkout/candidate. A separately required independent reviewer/tester is a root-dispatched peer, never a child used to approve its parent.

A permitted child is limited to:

1. a disjoint implementation sub-slice;
2. independent review; or
3. independent testing/evidence.

Do not spawn research, planning, management, or orchestration children. A child receives the same absolute worktree/base/evidence/ownership boundary. A child reviewer cannot approve code it edits, and read-only-role children cannot produce an independent approval of their parent.

## Mandatory lead implementation sequence — leads only

Auditors, reviewers, and testers **must not execute this section**. They follow the common safety/evidence/report rules and only their selected role overlay; they modify no tracked source/configuration and leave no new non-ignored checkout file. Ignored outputs from named builds/checks remain allowed under the read-only role rule above.

1. Inspect production paths and current checks named in the packet.
2. Run and retain the baseline focused checks.
3. Add an outcome-based deterministic witness. If it is an app check, register the flag and matrix leg.
4. Record RED before changing behavior. RED is a completed witness whose semantic assertion fails specifically because the locked behavior is absent. A build error, crash, timeout, missing fixture, permission/display failure, or unrelated assertion is infrastructure failure and does not count as RED.
5. Implement the complete, scoped product behavior.
6. Record GREEN for the new witness, focused regressions, and required builds.
7. In a disposable checkout, keep the witness and remove/revert the behavioral fix; record RED. Restore and record GREEN. This is the tooth proof.
8. Run `git diff --check`; inspect the complete diff; commit witness and implementation separately where practical.
9. Write the report below. Do not merge.

## Evidence rules

- Capture commands, stdout/stderr, exit status, commit, dirty status, macOS/build details, and absolute artifact paths.
- UI claims require semantic assertions plus screenshots. A screenshot alone is not a pass.
- Use named readiness states rather than arbitrary sleeps.
- Do not capture screenshots during timed performance intervals.
- Do not keep the only copy of evidence in `/tmp`.
- Do not autonomously bless visual baselines. Produce candidate, actual, and diff images for review.

## Required report

Write `<EVIDENCE_DIR>/report.json` and end your final response with its absolute path. Use:

```json
{
  "workstream": "the dispatched workstream ID",
  "role": "lead|auditor|reviewer|tester",
  "phase": "the dispatched phase",
  "status": "PASS|FAIL|BLOCKED|NEEDS_JUDGMENT|DISPLAY_DEFERRED",
  "base_sha": "observed 40-character Git SHA",
  "candidate_sha": "observed 40-character Git SHA",
  "worktree": "absolute checkout path",
  "branch": "observed branch name",
  "summary": "observable behavior changed or evaluated",
  "owned_files_changed": ["absolute changed path"],
  "unexpected_files_changed": [],
  "commands_run": [{"command": "...", "exit_code": 0, "log": "absolute log path"}],
  "candidate_dirty_status": "clean|dirty-with-explanation",
  "commits": [{"sha": "...", "purpose": "witness|implementation|review-fix"}],
  "red_witness": {"command": "...", "exit_code": "actual nonzero status", "log": "absolute log path", "expected_assertion": "...", "observed_failure": "...", "infra_clean": true},
  "green_evidence": [{"command": "...", "exit_code": 0, "log": "absolute log path"}],
  "tooth_proof": {"method": "...", "red_log": "absolute log path", "restored_green_log": "absolute log path"},
  "review_findings": [{"severity": "P0|P1|P2|P3", "file": "absolute source path", "line": 0, "finding": "...", "resolved": false}],
  "expected_visual_states": [{"visual_state_id": "...", "appearances": ["aqua", "dark"], "required_roles": ["actual"], "semantic_assertion": "..."}],
  "screenshots": [{"case_id": "...", "iteration": 1, "visual_state_id": "...", "role": "baseline|actual|diff|contact_sheet|failure", "path": "absolute PNG path", "sha256": "...", "commit": "...", "point_size": [1440, 900], "pixel_size": [2880, 1800], "backing_scale": 2, "appearance": "aqua|dark", "canvas_zoom": 1.0, "tile_zoom": 1.0, "baseline_path": "absolute path or null", "baseline_sha": "blob/hash or null", "baseline_commit": "commit or null", "actual_path": "absolute path or null", "actual_sha": "hash or null", "diff_metric": 0, "diff_status": "zero|nonzero|failed|candidate_only|not_applicable", "mask_path": "absolute path or null", "mask_sha": "hash or null", "mask_rationale": "... or null", "contact_sheet_members": [], "primary": true, "semantic_artifact": "absolute path", "command_log": "absolute path", "readiness": "...", "inspection": "PASS|FAIL|NEEDS_JUDGMENT"}],
  "semantic_artifacts": ["absolute artifact path"],
  "expected_performance_cases": [{"case_id": "...", "repetitions": 5, "required_roles": ["raw_run"], "configuration": "release", "seed": "..."}],
  "performance_artifacts": [{"case_id": "...", "iteration": 1, "role": "raw_run|trace|signpost|sample|vmmap|soak_samples|soak_summary|diagnostic_before|diagnostic_after|diagnostic_diff|visual_boundary", "path": "absolute artifact path", "sha256": "...", "binary_sha256": "...", "configuration": "release", "seed": "...", "derived_summary": "absolute path or null"}],
  "performance": [{"metric": "...", "before": 0, "after": 0, "unit": "...", "samples": 5}],
  "known_red_observed": [],
  "unexpected_failures": [],
  "risks": [],
  "gaps_or_skips": [],
  "promotion_recommendation": "PROMOTE|DO_NOT_PROMOTE"
}
```

For auditor/reviewer/tester reports, use `commits: []`, `red_witness: null`, and `tooth_proof: null`; do not fabricate lead-only evidence. `owned_files_changed` must be empty unless the role was explicitly converted into an implementation role, in which case it is no longer an independent auditor/reviewer/tester.

Every expected unique visual state has an `actual` entry or membership in a declared contact sheet. Every nonzero/failing diff has an absolute diff path that root must inspect. A checked-in baseline entry pins its path, blob/hash, and owning commit; no approved baseline is `candidate_only/NEEDS_JUDGMENT`, never an inferred zero-diff PASS. A mask is legal only when its file/hash and narrow rationale are retained and the unmasked semantic/geometry assertion remains blocking.

Every failed visual-capable repetition emits a `failure` entry linked to case, iteration, command log, semantic snapshot, and reason. An abort trap attempts capture; if WindowServer capture itself is unavailable, record a typed `capture_unavailable` blocker and diagnostics rather than inventing an image.

Performance work declares its exact expected case/repetition/role inventory. Every raw run, profiler/signpost/sample/vmmap file, soak stream/summary, diagnostic before/after/diff, and visual boundary is an individually hashed typed entry—not merely a directory. The validator rejects missing or extra repetitions, configuration/binary/seed mismatches, and summaries whose declared source artifacts are absent.

## Generic independent-review overlay

The reviewer receives a clean worktree at the candidate SHA and the lead report. The reviewer reads the complete `BASE_SHA..CANDIDATE_SHA` diff without editing it, verifies production entry points and witness provenance, runs the named focused commands, and reports tight absolute `file:line` findings. PASS requires no unresolved P0/P1/P2 and a behavior-observing witness. If the reviewer edits anything, assign a different final reviewer.

## Generic independent-test overlay

The tester is neither author nor reviewer. The tester uses a clean candidate checkout and isolated state, edits no code, independently runs the new witness and regressions, exercises the real user path, captures named visual states, and verifies semantic state. It returns every primary/baseline/diff/metrics path absolutely. It does not fix what it finds.
