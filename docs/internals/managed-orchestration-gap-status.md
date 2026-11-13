# Managed orchestration: gaps 10–13

This is an implementation audit, not evidence of model compliance. The source
plan is `.plans/116-agent-standards/plans/README.md` on
`array/agent-standards`; its numbered parts below retain their original scope.

| Gap | Implemented and witnessed | Remaining work |
| --- | --- | --- |
| 10: withdrawn stall alerts | `HelperLivenessChecks` drives queued-store and in-flight withdrawal races; `--helper-liveness-check` is matrix registered. | Stalled-alert switch remains off. No live reliability claim follows from the fixture. |
| 11: host instructions | `AgentSupervisor` uses one production launch factory. Terminal Claude receives `terminalFaceHostText`; its argv has a witness in `AgentFaceChecks`. `ReplyRulesChecks` witnesses first/resume/compaction launch arguments and preserves unreadable Codex user instructions, exposing the skip reason. | Part 19 step 3 still needs a dedicated role-bearing Pi host-text launch case. Pi roles use `runnerConfig`, which attaches the common launch-arguments closure after role tool arguments; code inspection establishes this route, not a runtime witness for that role case. Real Claude resume and Pi compaction obedience require the matched live evaluation in parts 19/22, not additional source-string assertions. Personal/reply rules remain off. |
| 12: host evidence | The provider fixture replays a real covered-file write within a check's shell call. Unknown write visibility prevents a freshness claim; recorded check/edit boundaries and exits remain separate facts. A background job before a check remains unknown. | Part 8 steps 2/3 still need trusted write-boundary observation and conservative completeness handling before delivering evidence to leads or using it for acceptance. Snapshots taken on the asynchronous ledger queue cannot establish tool execution boundaries. Claude numeric exits remain unreported; no successful result is converted to exit zero. Evidence remains shadow only. |
| 13: part contracts | Part 4 step 1 stores and renders optional contracts, inherits them on retry and advises about overlap. `PartContractChecks` drives Claude, Codex and Pi through first/resume/compaction delivery. The standard lead brief now names the real contract fields; `ManagedModeChecks.hooks` asserts their delivery through the production hook. | Part 4 step 2 reservations, lifecycle release and restart recovery are unbuilt. Step 3 reviewer/gate/ledger exposure of the stored claims and undeclared-write comparison is unbuilt. Persisting a contract on a helper is not evidence of these consumers. |

The master plan starts overlap handling as advisory. The later handoff explicitly
says a contract never refuses delegation. Mandatory reservations must reconcile
that policy before implementation; this audit does not silently introduce a
refusal, serialize helpers or enable an unproven control.

The contract-brief witness verifies the host delivered instructions. It does not
show that a model authored a contract, respected ownership, or followed a rule.
