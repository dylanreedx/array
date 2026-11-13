# Effort catalogue gap E

Base: d288e119. Branch: array/gaps-effort-catalog.

Production offered and launch efforts now come from the selected model's exact
harness catalogue. AgentModelConfig's global seven-value capability list and
the Claude/Codex backend capability ceilings are gone. Missing or empty
metadata and stale stored values omit the flag; no downgrade is substituted.
Stored strings and AgentRecord decoding remain intact. Explicit new effort
choices are validated at launchSelection, setProviderSettings, Settings writes,
role resolution, and the existing delegation admission boundary.

Callers audited: composer footer, Settings schema/model/picker, new-agent
selection, provider edits, role resolution/terminal role launches, automatic
titles, all three managed runners including Pi RPC, and legacy checks.
A harness switch submits only a changed effort, so an inherited stale value
survives switching. Artifact QA later found that missing metadata displays the generic Effort caption; the stored string remains intact without being added to choices.
Pi has no effort metadata in the current live catalogue: its efforts remain
unknown, its effort picker offers none, and both runner modes omit --thinking.
The Pi RPC command vocabulary and protocol types are unchanged. The remaining
seven-value list in a provider-settings self-check is an explicit QA fixture.

Witness: --effort-catalog-check, app dispatch and full/targeted matrix
registration, plus committed matrix inventory. Targeted invocation consumes a
freshly built app: scripts/run-matrix.sh --effort-catalog.

RED: /tmp/effort-red-direct.log and /tmp/effort-red-check.log show a fixture
catalogue offering only future-effort while the production picker offered all
seven hard-coded values too. The matrix reported this failing leg. Two other
RED-run pre-pass legs lacked the MCP executable because only Array had been
built at that point; array-workspace-mcp was built before GREEN verification.

GREEN direct checks (fresh builds, exited 0):

- Array --effort-catalog-check: /tmp/effort-final-direct.log. Catalogue-only
  effort offered and reaches Claude/Codex runner argv for Free/Managed,
  fresh/resumed/forked launches; missing/empty/stale metadata omits it; explicit
  unsupported requests refused, persisted strings preserved, Pi one-shot/RPC
  omit unknown effort, actual tile harness switch retains stale effort.
- Array --workspace-api-cross-harness-delegation-check:
  /tmp/effort-cross-delegation.log. Modified production delegation witness
  requests future-effort and observes it on first, resumed, compaction and
  post-compaction launches for Claude/Codex, alongside existing retry/stale/
  unsupported/no-metadata coverage.
- Array --workspace-api-delegation-check: /tmp/effort-delegation.log.
- Array --strict-agent-harness-check: /tmp/effort-strict-harness.log.
- CoreChecks --provider-context-support-check: /tmp/effort-provider-core.log.
- CoreChecks --live-model-catalog-check: /tmp/effort-catalog-core.log.
- CoreChecks --role-registry-check: /tmp/effort-role-core.log.

Builds: Array, array-workspace-mcp, ContinuumRevivedCoreChecks completed.
Final app build log: /tmp/effort-ui-final-build.log. Other build logs:
/tmp/effort-final-build.log, /tmp/effort-mcp-build.log,
/tmp/effort-core-build.log, /tmp/effort-relink-build.log.
Every build preflight passed (<4 swift-build processes, >=25% free memory,
>=20 GiB disk), SDKROOT from xcrun; tests unset ARRAY_AGENT_ID/TMUX/TMUX_PANE,
TERM=xterm-256color, CONTINUUM_SKIP_UI_BASELINES=1, stdin /dev/null. Managed
crash marker preserved. App-state/project test paths were disposable; app
checks disabled tmux, matrix used its own isolated namespace. No default
tmux interaction, prod app mutation, live provider request, or preview launch.
No light/dark visual preview claimed. Full matrix not run.

Sibling review requested, no child reviewer spawned. Questions:

1. Does any offered/explicit/launch path still impose a hand-kept ceiling or
   invent a fallback effort when model metadata is absent?
2. Do inherited stale values survive without admitting unsupported explicit
   changes, including a tile's harness switch and retry/resume/compaction?
3. Is the intentional unknown Pi behavior consistent across one-shot, RPC,
   role and Settings paths while preserving protocol vocabulary?
4. Do the witnesses cover the production boundaries without source assertions?

GREEN targeted matrix: /tmp/effort-green-matrix.log, exit 0, final report
16 legs run and passed, including --effort-catalog-check. An earlier attempt
refused the shared lock; it was honored and the completed run used the normal
lock after it became available.


## Render follow-up

Opt-in test-only hook: CONTINUUM_EFFORT_RENDER_DIR with the existing
--effort-catalog-check. Eight real AppKit UIProbe PNGs cover Claude/Codex,
advertised future-effort/missing metadata, and Aqua/Dark Aqua. The images use
AgentComposerFooterView and ChoiceListView, not reconstructed HTML. No policy,
production UI, styling, or defaults changed in this follow-up.

Artifacts: /Users/dylan/array-scratch/effort-catalog-qa-60fd4674/.
Exact filenames are in manifest.json and README.md there. Advertised-state
renders show Future-Effort on the button and selected ChoiceList row. Missing
metadata renders show the actual generic Effort caption and no choice list;
High remains stored and the launch flag is omitted. QA annotations outside
product chrome explain that state. This corrects the earlier source-based
claim that the stale caption remained visible. No production caption fix was
made or claimed.

All eight images were visually inspected: readable text in both appearances,
no observed clipping, and distinct light/dark renders. Manifest records actual
captions, offered items, selected model, launch effort and bitmap digests.
Build log: /tmp/effort-render-final-build.log; capture log:
/tmp/effort-render-check.log. Full combined gate remains owned by the lead.
