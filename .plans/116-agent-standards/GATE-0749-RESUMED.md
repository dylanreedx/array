# Orchestration candidate: final targeted gate

Verified source head: `15e26bec` (documentation commit follows). No push. Chooser remains OFF. No full matrix rerun after the first run.

## Commits

- `8425cd28`: merge reviewed launch-hang fix `ad85b99b`, including `e4fe301a`. Both confirmed ancestors, together with release `78d658fe` and plan-first `85774265`. Matrix conflicts resolved by retaining both effort-catalog and restore-scaling dispatch and inventory entries. Inventory passes (1094 records).
- `9f49ca5d`: test(cli-fixtures), fresh tool-free installed Claude 2.1.325, Codex 0.167.0, Pi 1.5.0 captures, scrubbed and validated.
- `6b04cff8`: reviewed census, title, presence and scoped capability fixtures.
- `15e26bec`: reviewed supervisor footer scripted metadata. Production effort policy and golden assertions unchanged.

Review: independent reviewer `review_gate_fixes` approved each repair, including scoped snapshot cleanup. Footer metadata includes a legacy model without offering that model, and legacy-auto only for the picked synthetic model. This no longer proves rendering initially unknown effort, but still proves preserving saved effort when switching to a destination that does not advertise it.

## Witnesses

Original full foreground `--skip-awake` run at `c1937534`: **410 legs, 400 PASS, 9 FAIL, 1 KNOWN-RED**, 1398 seconds. `/tmp/orchestration-gaps-full-resumed.log`; `qa-runs/matrix-20261114T005048Z-65750/results.json`. Awake/display legs skipped as requested. This remains the original RED record; targeted repairs do not rewrite its result.

Final sequential runs at the verified source head:

- Supervisor: PASS, `/tmp/orchestration-final-supervisor.log`.
- Restore/outbox/delegation/Codex group: **24/24 PASS**, `/tmp/orchestration-final-restore.log`.
- Managed-mode group: **66/66 PASS**, `/tmp/orchestration-final-managed.log` (includes app and real bundle pre-pass).
- Group exit codes: `/tmp/orchestration-final-results.json`, all zero.
- Remaining isolated failures rerun: `/tmp/orchestration-decision-results.json` and its per-flag log paths. Its initial supervisor entry predates the final footer fix and is superseded by the final supervisor PASS above.
- Notification census/self-test, installed-version fixture check and git diff --check PASS.

Every build/group preflight met fewer than four swift-builds, >=25% free memory and >=20 GiB disk. Final sequence: zero swift-builds at each stage, 56–58% memory free, ~50 GiB disk available. SDKROOT exported; ARRAY_AGENT_ID/TMUX/TMUX_PANE unset; TERM=xterm-256color; stdin /dev/null. Managed crash marker preserved. Matrix groups own verified disposable tmux namespaces. Direct app retries disable terminal tmux. No default tmux socket or installed app touched. No processes stopped. Temporary stash preserved earlier repairs across merge and popped cleanly. Initial cleanup rm command was rejected; generated caches removed by individual-file deletion instead.

## Per-leg classification

| Leg | Final classification and evidence |
|---|---|
| scripts/capture-cli-fixtures.sh check | Pre-existing missing installed Claude capture reproduced on 0.7.49 export. Fresh installed-version captures committed; final check PASS. |
| python3 scripts/check-notification-map.py --self-test | Repaired candidate census regression: bundled scanner fixture literals were counted as senders. Root-only exact-path exemption plus adjacent-real-sender mutation witness PASS. Bundled resource restored unchanged to preserve authentication hash. |
| --agent-supervisor-check | Historical pre-existing failure per `/tmp/plan-117-land-gate-report.md` (0.7.48); effort-related fixture mismatches repaired without policy/golden changes. Full final supervisor PASS. |
| --agent-display-name-check | Repaired stale expected effort flags for capability-unknown synthetic models. Isolated PASS in `/tmp/orchestration-decision--agent-display-name-check.log`. |
| --agent-presence-check | Repaired fixture effort support using QA-catalogued Opus; unchanged lifecycle assertions PASS in `/tmp/orchestration-decision--agent-presence-check.log`. |
| --subagent-sidebar-open-check | Pre-existing on 0.7.48/0.7.49 per `/tmp/plan-117-land-gate-report.md`, citing `/tmp/gate-phase2-final-report.md`. Current isolated rerun repeats four placement assertions; `/tmp/orchestration-decision--subagent-sidebar-open-check.log`. Placement and witness source identical to 78d658fe, independently audited. Fresh base build would require another full compile, so skipped per explicit instruction; no new base runtime proof claimed. |
| --canvas-zoom-step-cost-check | Load flake: serial PASS, `/tmp/orchestration-decision--canvas-zoom-step-cost-check.log`. |
| --markdown-visible-rows-zoom-cost-check | Load flake: serial PASS, `/tmp/orchestration-decision--markdown-visible-rows-zoom-cost-check.log`. |
| --markdown-frame-observer-check | Load flake: serial PASS, `/tmp/orchestration-decision--markdown-frame-observer-check.log`. |
| --empty-workspace-creation-check | Documented KNOWN-RED, unchanged; not rerun. |
| --candidate-prepass-check | Interim failure caused by our bundled scanner edit invalidating pinned SHA256; repaired by restoring original bundled resource. Final app and managed group PASS. |
| python3 scripts/check-candidate-prepass-bundle.py | Same interim hash mismatch; final assembled dev bundle PASS in managed group. |

Focus load-flake classification follows the explicit decision. Original failures shared focus PID 75816 while assertions passed; direct serial retries did not repeat the external focus sampler, so they establish behavioral success, not a fresh sampler proof.

## OFF or deferred scope

- Chooser OFF; mandatory plan-first only applies when enabled.
- Live paired calibration, quality/efficiency/effort comparisons, provider obedience and fresh quota pilot deferred.
- All-harness strict write enforcement, Codex resume/pinning, parent-inclusive telemetry and universal nested prevention incomplete.
- Trusted write boundaries, Claude numeric exit, reservation and reviewer-contract exposure incomplete.
- Context quality/stage/task collection OFF; tool compaction/token savings and personal memory exclusion unproven.
- Automatic candidate emission/final merge workflow and representative p95 deferred; explicit candidate pre-pass OFF.
- All-helper isolation OFF; HEAD-only helpers omit dirty lead files; default overlap risk retained.
- Shared-map/reuse/adoption/adapters/cache audit and standards replacement decision deferred.
- Awake/display legs, external crash witnesses and a new full matrix remain unrun, by requested targeted scope.

Final benches inventory: `/tmp/orchestration-gaps-decision-benches.log`. Candidate bench retained because it has not landed. No test workflow or matrix lock holder remains. No release, push or production app operation performed.

## Exact pre-pass merge comparison

Completed the subsequently requested runtime comparison with fresh app and MCP builds at each exact revision. All exit codes were zero:

| Revision | App pre-pass | Real dev-bundle pre-pass |
|---|---|---|
| `8425cd28^1` = `c1937534` | PASS | PASS |
| `8425cd28` | PASS | PASS |
| Final candidate `19df389d` | PASS | PASS |

Machine-readable record: `/tmp/orchestration-exact-prepass-comparison.json`. Build and witness logs: `/tmp/orchestration-exact-{before,after,candidate}-{build,mcp-build,app,bundle}.log`. All three revisions' bundled resources independently matched their pinned SHA256. The launch-hang merge did not cause the pre-pass failure. It was the intervening uncommitted bundled-scanner edit from the census repair, already reverted before the final candidate. Production evaluator completion/hydration needed no change.

The comparison held the normal matrix lock, checked resources before each revision, preserved the managed crash marker, used isolated stores/project roots and disabled terminal tmux in direct app checks. The original candidate branch was restored in a finally block and its products rebuilt; no source edits were made during comparison. No full matrix or redundant managed-mode run: final source is unchanged from the already witnessed supervisor PASS, restore 24/24 and managed-mode 66/66. Final inventory `/tmp/orchestration-exact-final-benches.log`. No push.
