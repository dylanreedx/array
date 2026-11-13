# Managed orchestration: gaps 10–13

This is an implementation audit, not evidence of model compliance. The source
plan is `.plans/116-agent-standards/plans/README.md` on
`array/agent-standards`; its numbered parts below retain their original scope.

| Gap | Implemented and witnessed | Remaining work |
| --- | --- | --- |
| 10: withdrawn stall alerts | `HelperLivenessChecks` drives queued-store and in-flight withdrawal races; `--helper-liveness-check` is matrix registered. | Stalled-alert switch remains off. No live reliability claim follows from the fixture. |
| 11: host instructions | `AgentSupervisor` uses one production launch factory. Terminal Claude receives `terminalFaceHostText`; its argv has a witness in `AgentFaceChecks`. `ReplyRulesChecks` preserves unreadable Codex user instructions and exposes the skip reason. Its dedicated `PiRoleHostTextChecks` case exercises role-bearing production spawn, first launch, same-session-ID restore, compact RPC on the running session, post-compact restore and retry. It captures argv, actual cwd and task frames, preserves role/tool/provider metadata and fixture files, and checks reply/personal combinations plus exact OFF argv parity. | This covers the role-bearing launch case within Part 19 step 3 using a Pi protocol double, not the whole step. Real CLI role/project file loading, live Pi compression, Claude resume/Pi compaction obedience and the matched evaluation in parts 19/22 remain unproven. Personal/reply rules remain off. |
| 12: host evidence | The provider fixture replays a real covered-file write within a check's shell call. Unknown write visibility prevents a freshness claim; recorded check/edit boundaries and exits remain separate facts. A background job before a check remains unknown. | Part 8 steps 2/3 still need trusted write-boundary observation and conservative completeness handling before delivering evidence to leads or using it for acceptance. Snapshots taken on the asynchronous ledger queue cannot establish tool execution boundaries. Claude numeric exits remain unreported; no successful result is converted to exit zero. Evidence remains shadow only. |
| 13: part contracts | An implemented subset of Part 4 step 1 stores and renders optional contracts, inherits them on retry and advises about overlap. `PartContractChecks` drives Claude, Codex and Pi through first/resume/compaction delivery. The standard lead brief now names the real contract fields; `ManagedModeChecks.hooks` asserts their delivery through the production hook. | Part 4 step 2 reservations, lifecycle release and restart recovery are unbuilt. Step 3 reviewer/gate/ledger exposure of the stored claims and undeclared-write comparison is unbuilt. Persisting a contract on a helper is not evidence of these consumers. |

The master plan starts overlap handling as advisory. The later handoff explicitly
says a contract never refuses delegation. Mandatory reservations must reconcile
that policy before implementation; this audit does not silently introduce a
refusal, serialize helpers or enable an unproven control.

The contract-brief witness verifies the host delivered instructions. It does not
show that a model authored a contract, respected ownership, or followed a rule.
