# Effort fixture integration repair

Base 841854f8; branch array/gaps-effort-integration.

The actual combined managed run reported 66 legs: 64 passed, two failed.
RED evidence: /tmp/orchestration-final-combined-00mvzewf/managed.log:547
(--managed-mode-launch-check) and :1006-1007 (--part-contract-check).
A preserved excerpt is at
/Users/dylan/array-scratch/effort-integration-841854f8/combined-red-excerpt.log.
The contract failure is a Claude argv mismatch, not a delegation refusal.

Production selected-model effort validation is correct: no metadata means no
flag. Both failing parity checks expected --effort medium while their synthetic
Claude catalogue omitted effort metadata. The contract golden remains intact.

The test bench helper now accepts optional advertised efforts; nil retains its
previous missing-metadata behavior. The helper-worktree test wrapper forwards
that optional parameter. Only managed-launch and part-contract-shape request
[AgentModelConfig.defaultThinking] (medium). No other fixture opts in.
Production policy and the frozen argv/contract assertions are unchanged.

The existing --effort-catalog focused matrix now also runs the two already
registered failing legs. Its original effort witness still checks unknown
metadata omission and arbitrary catalogue-advertised efforts, alongside the
parity fixtures' explicit medium declaration.

Build commands: swift build --product Array -j 2, then
swift build --product array-workspace-mcp -j 2. Each build's guard records
<4 swift-build processes, >=25% free memory, >=20 GiB disk; SDKROOT is read
from xcrun before each build. Build logs:
/tmp/effort-integration-app-build.log and /tmp/effort-integration-mcp-build.log.
Tests unset ARRAY_AGENT_ID/TMUX/TMUX_PANE, set TERM=xterm-256color and
CONTINUUM_SKIP_UI_BASELINES=1, and read stdin from /dev/null. Managed-agent
crash marker remains inherited. Matrix owns its disposable tmux namespace and
app-check state; no default tmux, prod app, live provider or preview action.

Static validation: bash -n scripts/run-matrix.sh, git diff --check and matrix
inventory check passed. The inventory check reports four existing base context
accounting additions; this patch adds no unique inventory records and does not
regenerate unrelated inventory.

Independent sibling review requested from lead, no reviewer spawned. Questions:

1. Does nil preserve every pre-existing fixture's unknown effort metadata?
2. Do only the two failing parity captures advertise medium?
3. Are production policy, golden argv and assertions unchanged?
4. Does the focused matrix report both repaired legs plus the negative/unknown
   capability witness?

GREEN: scripts/run-matrix.sh --effort-catalog completed with exit 0 and a
17-leg PASS summary. It explicitly reported --effort-catalog-check,
--managed-mode-launch-check and --part-contract-check. The managed check
retained real argv/free byte equality/deferred switch/resume assertions; the
contract check retained omitted-contract golden equality for Claude/Codex and
resumed/compaction delivery coverage for Claude/Codex/Pi.

Exact log: /tmp/effort-integration-matrix.log. Durable copies of this log and
both successful build logs are under
/Users/dylan/array-scratch/effort-integration-841854f8/.
Preflight for Array: 0 builds, 69% free memory, 62017568 KiB disk available;
for MCP: 0 builds, 59% free memory, 59798784 KiB disk available.
No full combined rerun or live provider request was made; lead owns that gate.
