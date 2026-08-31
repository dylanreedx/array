# Array 0.8.0 prompt index

These are templates for the active overnight release goal. For every dispatch, root renders one self-contained prompt containing the fully substituted common protocol, the fully substituted workstream packet, and exactly one selected role overlay. A checked-in template path by itself is never a valid dispatch.

The master acceptance index is `.plans/54-test-evidence-matrix.md`. A rendered dispatch may narrow ownership but may not silently delete a blocking witness from that matrix.

The ordinary dispatch tokens are `<WS_ID>`, `<ROLE>`, `<PHASE>`, `<WORKTREE>`, `<BRANCH>`, `<BASE_SHA>`, `<RUN_ID>`, `<RUN_ROOT>`, `<EVIDENCE_DIR>`, `<QA_PROJECT_ROOT>`, `<QA_APP_SUPPORT>`, and `<QA_TMUX_TMPDIR>`. Root substitutes all of them immediately before sending the rendered prompt to a `gpt-5.6-sol` low-effort worker. `<ROLE>` is exactly `lead`, `auditor`, `reviewer`, or `tester`; `<PHASE>` is an explicit packet phase such as `implementation`, `independent-review`, `independent-test`, `pre-artifact-audit`, `pre-artifact-review`, `artifact-test`, or `post-artifact-review`. The independent artifact-tester dispatch additionally substitutes `<CANONICAL_RC>` with the one exact DMG path. Angle-bracket strings inside JSON/schema examples are runtime value descriptions, not dispatch tokens.

Root writes the rendered prompt under `<RUN_ROOT>/dispatches/`, checks that no applicable uppercase dispatch token remains, records its SHA-256 in the run ledger, and sends its complete contents. All later packets are gated on the promoted Wave-0 checkpoint that contains `scripts/release-evidence.js` and release-configuration support in `scripts/run-perf-ceilings.sh`; they are not executable against the original repository alone.

At live start, root first commits only the reviewed `.plans/54-*` packet as local control checkpoint P0 (no product files, no push). Worker worktrees therefore contain the same reference templates whose fully rendered text they receive. Wave-0 E0 descends from P0; every later workstream descends from E0 or an integration checkpoint.

Exact future witness flags are producer contracts, not claims that the starting tree already contains them: WS2 produces `--workspace-restart-fault-check`, WS3 `--perf-power-user-compound-check`, WS4 `--completion-awareness-viewed-check`, WS5 `--managed-agent-page-zoom-check`, WS6 `--transcript-provider-parity-check`, and WS7 `--canvas-background-check`. Root never dispatches a reviewer/tester consumer until the named producer candidate contains and registers its flag.

| Packet | Role | Dependency |
|---|---|---|
| `00-agent-protocol.md` | binding common safety/evidence/report contract | always |
| `00-evidence-harness.md` | implementation/review/test for evidence CLI + GUI preflight | first |
| `00-baseline-preflight.md` | read-only baseline tester | promoted E0 harness checkpoint with unchanged 0.7.4 product source |
| `01-zones-auto-layout.md` | implementation/review/test overlays | baseline |
| `02-workspace-persistence.md` | implementation/review/test overlays | baseline |
| `06-transcript-hierarchy-provider-parity.md` | implementation/review/test overlays | baseline |
| `03-performance-and-soak.md` | implementation/review/test overlays | I1 |
| `04-completion-awareness.md` | implementation/review/test overlays | I1 transcript |
| `05-agent-tile-page-zoom.md` | implementation/review/test overlays | I2A performance/awareness |
| `07-canvas-backgrounds.md` | implementation/review/test overlays | I2 persistence/perf |
| `08-release-candidate.md` | clean integrated release verification | I3 |

## Dispatch checklist

Before every worker call, root includes in the rendered prompt:

1. the fully substituted common protocol base and neutral shared workstream body—not a repository path alone; for ordinary `reviewer`/`tester`, append that role's generic common overlay and workstream-specific overlay, and strip every unselected overlay; `lead` receives neither read-only overlay, while WS8 `auditor` receives its shared read-only audit body; baseline preflight is the exception and uses its packet as the complete tester overlay, with no generic “new witness” tester overlay;
2. the exact rendered role—`lead`, `auditor`, `reviewer`, or `tester`—the exact phase, and only the applicable overlay; WS8 pre/post-artifact reviewer subsections are separate dispatches and the irrelevant phase subsection is stripped;
3. absolute worktree and evidence directory;
4. pinned base and candidate SHAs;
5. narrow shared-file hunk grants and active forbidden ownership;
6. isolated project/app-support roots;
7. exact focused commands after verifying current flag/product names;
8. whether one child is allowed and which of implementation/review/testing it may perform;
9. stop/retry limit;
10. report path and expected final decision token.

Do not dispatch a generic “implement this feature thoroughly” prompt. Do not send multiple implementation packets to one worker in one turn. Do not let a worker infer the base SHA, worktree, output directory, release authority, or whether a visual judgment is blocking.

## Review/test rotation with three workers

Wave 1 authors: A→WS1, B→WS2, C→WS6. Review: A→WS2, B→WS6, C→WS1. Test: A→WS6, B→WS1, C→WS2.

Wave 2A authors: A→WS3 and B→WS4; C rotates into eligible review/test work. After I2A, Wave 2B assigns one author, one reviewer, and one tester to WS5; rerun WS3's complete release performance matrix before promotion.

Wave 3: A authors WS7, B reviews, C tests. Wave 4: A audits/prepares the release candidate, B reviews, C independently verifies.

If an agent edits during review, rotate again so final author/reviewer/tester identities remain distinct.
