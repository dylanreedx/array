# Replay gap audit

Base: 83993fa5. Bench: gaps-replay-proof, branch array/gaps-replay-proof.
Read branch array/agent-standards HANDOFF and master plan, and root CLAUDE.md.
No plan117 execution or edits. No live quota spent, app launch or Swift build.

| Gap | Current finding |
| --- | --- |
| 1 | Live pilot is rig proof only; no new comparative evidence. ReplayDriverChecks.swift:582 retains production live runner. No claim of quality improvement. |
| 2 | Paired reply/personal-rule live proof absent. PersonalRulesConfig.swift:11 requires explicit true; ReplyStandard.swift owns the opt-in reply switch. Defaults unchanged. |
| 3 | Full combined matrix, provider/bundle/preview proof not established here. Only five offline Python replay legs run. |
| 4 | No new medium/high effort comparison. Remains unproven. |
| 23 | live_claude.py:137 sets run-local TMPDIR; live-bin/mktemp redirects default and -t temp creation. Found missing -t operand hangs indefinitely because failed shift leaves argv unchanged. Fixed explicit arity refusal. Literal /tmp remains denied; this is not general filesystem remapping. |
| 25 | Original absent-MCP defect already fixed: ReplayDriverChecks.swift:582 retains workspace MCP for live solo and rejects delegation per call. Historical pilot figures remain skewed and must not be reinterpreted as corrected measurements. README still describes fake solo behavior. No paired live proof added. |
| 26 | Larger live pilot not run; quota authorization deferred to lead/owner. |

Section D: the master plan explicitly defers later product slices behind live
proof (waves 3/4). Current base already contains opt-in chooser/protected-path
work (1779ded2 through 83993fa5); the handoff's “not started” description is
historical for that part. This patch does not activate or implement shared map,
helper reuse, review/integration automation, reports, acceptance scorecards,
standards adoption, proposal adapters or build cache. Their end-to-end benefits
remain unproven; no blanket claim of their current implementation status.

## Behavioral evidence

Before fix: check_live_temp.py returned 1; missing-prefix case raised
subprocess.TimeoutExpired after 2 seconds. Valid temp cases passed.
After fix: same command returned 0, two tests passed (0.061s).

Exact invocation (stdin /dev/null):

```
env -u ARRAY_AGENT_ID -u TMUX -u TMUX_PANE TERM=xterm-256color CONTINUUM_SKIP_UI_BASELINES=1 PYTHONDONTWRITEBYTECODE=1 python3 benchmarks/replay/check_live_temp.py
```

Same environment with REPLAY_CHECKS_ONLY=1 scripts/run-matrix.sh: exit 0;
summary explicitly reports 5 legs, all pass, including check_live_temp.py.
Log: /tmp/gaps-replay-proof-matrix.log. Matrix results:
qa-runs/matrix-20261113T203859Z-19723/results.json (disposable, uncommitted).
Containment emitted a head broken-pipe diagnostic but its behavioral check passed.
git diff --check passed. No build required for Python/shell-only patch.

Independent review requested through array_delegate: Claude refused exhausted
account usage; explicit Codex fallback refused spawn depth 3 above cap 2.
Review is outstanding: lead must arrange read-only review before integrating.
