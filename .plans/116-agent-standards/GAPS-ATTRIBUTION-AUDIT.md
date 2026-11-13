# Attribution gap audit at 83993fa5

No remaining production defect established for assigned gaps 7, 8, 9, 21.
This is a code audit, not a new behavioral verification claim.

| Gap | Existing implementation | Existing witness / commits |
| --- | --- | --- |
| 7 nested delegation | ManagedRunLedger.swift:334 resolves active[parent] or openTask(parent), records child task and immediate parent. | RunLedgerGapsChecks.nested; fa921901 |
| 8 active time | ManagedRunLedger.swift:123 binds wake turns to their task; fact at :680 closes at lead turn end. UsageReport.swift:238 calculates union of turns clipped at close, with explicit late-helper-wake accounting. | RunLedgerGapsChecks.activeTime; fa921901, 5d0a22d3 |
| 9 late usage | ManagedRunLedger.swift:483 requires open task for new turns; named historical turns retain their task. AgentSupervisor.swift:4108 subscribes to trailing usage. CodexAgentRunner.swift:924 drains after main turn, bounds shutdown at two seconds and marks truncation incomplete. | RunLedgerGapsChecks.afterClose, codexTrailing, codexDrainBound; fa921901, 1dff386d |
| 21 durable hooks | WorkspaceAPIService.swift:370 calls recordLeadHook, AgentSupervisor.swift:6825 enqueues ManagedRunLedger.hook, :379 appends compact hook rows to JSONL. | RunLedgerGapsChecks.hooksAfterClose; 4f4b75e4, 635d7382 |

Existing matrix registrations: scripts/run-matrix.sh:1369 invokes
--run-ledger-gaps-check; dispatch is ContinuumApp.swift:2500.
No new flags, defaults, production edits or tests were added.

Verification attempted: fresh `swift build --product Array -j 2`, SDKROOT
from xcrun, stdin /dev/null, ARRAY_AGENT_ID/TMUX/TMUX_PANE unset,
TERM=xterm-256color, CONTINUUM_SKIP_UI_BASELINES=1; managed crash marker preserved.
Preflight: 1 swift-build process, memory_pressure 33% free, disk 64 GiB available.
Stopped our build and its dependency-fetch processes during GRDB SQLiteLib
submodule setup after discovering this new bench lacks
ThirdParty/GhosttyKit.xcframework. No build success or behavioral test claimed.
Build log: /tmp/gaps-attribution-build.log. No matrix run.

Independent read-only array_delegate review attempted: Claude Code refused
because account usage window exhausted; Codex fallback refused because spawn
depth 3 exceeds cap 2. No reviewer started. Lead must arrange independent
review and behavioral execution in a prepared bench.
