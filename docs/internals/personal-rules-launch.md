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
