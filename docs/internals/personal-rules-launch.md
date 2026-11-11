# Personal rules launch experiment

Default off. Opt in for the host process with
`CONTINUUM_PERSONAL_RULES_ENABLED=1` and
`CONTINUUM_PERSONAL_RULES_FILE=/absolute/path/to/user-maintained-rules`.
Array never creates or edits that file. Select a short UTF-8 file containing
personal working rules, without orchestration or memory. No CLI home is changed.
This experiment has no Settings UI or workspace API property.

A utility queue reads at most 65,537 bytes once per host lifetime. The in-memory
snapshot is limited to 65,536 bytes and labelled “Personal working rules”.
Restart to reload. Until loaded, launches proceed without rules. Status is
available on the source; diagnostics record status only. Missing, unreadable,
invalid UTF-8 and oversized files never refuse launch or truncate the payload.

`HostLaunchInstructions` is the single host-owned launch seam. It holds separate
sources in fixed registration order and obtains named blocks from each. Each
block retains its own raw text and label; duplicate names are delivered once.
Joining happens only while rendering the transient argv payload. The only
production registration is `personal-rules`; no Array guidance block is added.
The personal cache stores the original text without adding or rewriting prose.

Codex receives a per-process `-c developer_instructions` override on both exec
and app-server; Pi receives `--append-system-prompt` on JSON and RPC launches.
Claude's configuration is untouched. These arguments do not edit provider
configuration. They add context and tokens; they cannot guarantee obedience.

The fixture check covers production configuration/argument builders and inspects
fake-runner launches through workspace API cross-harness delegation. Actual
provider context retention across retry/compaction and matched live timing
remain rollout requirements; this experiment must stay off until those pass.
The layer audit and memory suppression belong to later programme steps.

Observed verification:

- RED with both production config builders omitting the rule arguments:
  `--personal-rules-delegation-check` exited 1, “Codex rules not delivered once”.
  The first assertion stopped that run; Pi was not independently observed RED.
- GREEN after restoring delivery: the same leg exited 0, including Codex exec
  fresh/resume and app-server, Pi JSON/RPC, API-created fixture helpers,
  disabled/missing/oversized sources and unchanged source bytes/modification time.
- Existing legs passed: `--managed-mode-launch-check`,
  `--managed-mode-hooks-check`, `--managed-codex-launch-check`,
  `--managed-codex-hooks-check`, `--workspace-api-delegation-check`,
  `--workspace-api-cross-harness-delegation-check`, `--helper-retry-check`,
  `--helper-provider-retry-check`, `--managed-compaction-tools-check`,
  `--managed-lead-context-transition-check`, `--live-compaction-replay-check`,
  and CoreChecks `--workspace-api-contract-check`.
- Debug Array, CoreChecks and array-workspace-mcp builds passed. The initial
  Array build missed a newly added source; the next found missing required
  fixture initializer arguments (fixed). Initial integration checks failed
  because the MCP executable was not built; all passed after building it.
- Matrix inventory regenerated and validated. Full matrix and live benchmark
  were not run. No real providers, apps, personal files or default tmux server
  were used. Existing checks establish their own fixtures; rules-specific
  retention through actual provider compaction is still unverified.

Plan correction: Claude receives no injected personal payload, per the master
plan. Oversized/unreadable sources record status and continue, following the
owner's instruction rather than the individual plan's visible-failure wording.

The seam fixture supplies two independent named sources and a duplicate. It
asserts registration order, one delivery per name, unchanged source blocks,
empty-source behavior and decoded Codex/Pi argument payloads. A reversed-order
mutation was observed RED (exit 1); production rendering was GREEN in the
standalone source harness. The initial standalone RED driver left its error
uncaught and trapped; it was corrected to catch and exit 1 before rerunning.
The parallel CLI probe now supports the chosen switch semantics described below;
argument-builder checks still do not establish provider obedience.

After introducing the ordered host seam, every app leg listed above and the
Core workspace API contract arm were rerun successfully. Debug Array,
array-workspace-mcp and CoreChecks builds and matrix inventory validation passed.


Probe alignment

Evidence: `array/helper-launch-probes`,
`.plans/116-agent-standards/evidence/probe-host-text-seams.md`.
Codex's `developer_instructions` override is supported on first turn, resume and
confirmed app-server compaction in that controlled probe. Repeated overrides
replace earlier values. Array currently sets no earlier developer-instructions
key: the Managed lead brief uses hooks and the computer-use overrides use
other keys. The host seam nevertheless accepts existing launch arguments,
joins their instruction text before the registered blocks, and emits one value.
The fixture drives production Codex exec/resume and app-server builders with an
existing developer block followed by personal rules; both must remain in order.
Existing Array-owned JSON-string overrides are decoded without reading CLI
configuration. An unfamiliar existing encoding is preserved unchanged and
injection skipped with a content-free diagnostic rather than overwritten.

The same seam composes an existing `--append-system-prompt` value for a later
Claude caller, because repeated Claude flags replace. Claude production launch
remains untouched in this step. Pi JSON/RPC receive the append flag on every
launch, including resumes, retries and launches after compaction. The fixture
asserts these launch arguments; Pi behavior after actual compaction is UNKNOWN.
This work runs no live Pi process and does not repair its missing extension
import or invalid Anthropic login reported by the probe.

The probe measured an 80-word block adding 149 input tokens on Claude, 82 on
Codex and 95 on the Pi fallback. These single-condition measurements are neither
a latency result nor a guarantee for this experiment's arbitrary rules file.
No harness relies on retention when launch arguments are omitted.

Probe-follow-up verification: discarding the earlier instruction text was RED
(exit 1, “existing Codex instructions lost order”); the production merger was
GREEN in the standalone source harness. The extended app delegation leg passed
with the production configuration and argument builders. All existing app legs
listed above, Core workspace API contract, Debug builds and matrix inventory
validation passed again. The first extended delegation run failed the reused
cross-harness fixture's “cross parent must use the selected app-wide policy”
assertion after the new instruction checks had passed. A rerun without an
explicit app-support directory was refused by its isolation guard; the correctly
isolated rerun passed. The initial mode-policy failure's cause is unconfirmed.
No new live provider calls, Pi repairs or full matrix run were performed.
