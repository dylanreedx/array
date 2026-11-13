# Boundary gaps audit

Bench: `array/gaps-lead-boundaries`, based on `83993fa5`.
No main checkout, production app, defaults domain, or default tmux state changed.

- **5 — shell edits: partial existing implementation.**
  `ManagedStrictLead.claudeSandbox` denies checkout and external git-directory
  writes. `ClaudeAgentRunner.arguments` passes that sandbox only when the
  strict experiment is enabled. It is OFF by default. Codex strict enforcement
  remains explicitly unsupported because resumed-thread sandbox ownership has
  not been proven. `ManagedChooser.toolReply` blocks command tools while an
  implementation helper owns the task. Neither proves universal enforcement.
- **6 — CLI subagents: partial existing implementation.**
  `ClaudeAgentRunner.arguments` excludes `Agent,Task,ListAgents` for a hooked
  chooser lead. Ordinary Managed leads still permit native children. Array
  mirrors provider children, but usage is parent-inclusive, as documented in
  `UsageReport`; this does not establish independent delegation cost attribution.
  No unproven native-child attribution or universal CLI policy is enabled here.
- **20 — lead choices: experiment exists, proof remains open.**
  `ManagedChooser` supplies solo/split plans and command-tool latching; its
  setting defaults OFF. `AgentSupervisor.ingestRuntimeObservation` also records
  lead shell writes through the shadow ledger. These do not establish that
  Managed improves quality or efficiency. No live quota was spent.
- **22 — checkout isolation: confirmed open by production path.**
  `AgentSupervisor.startSpawn.checkoutBusy` considers siblings, not the lead.
  First and sequential helpers share the lead checkout. Existing
  `HelperRetryWorktreeChecks` and `LeadCheckoutChecks.writers` deliberately
  assert this to preserve uncommitted lead changes. Universal isolation would
  silently hide those changes. The proposed opt-in experiment isolates every
  Managed helper from the lead HEAD, refuses non-git roots, and leaves Free
  behavior alone. It remains OFF pending live proof and review.
- **24 — empty delegation schema: existing fix.**
  `ManagedLeadHookState.alwaysLoadedTools` pins status, delegate and message;
  supervisor Claude launch calls `alwaysLoading`. Registered matrix leg:
  `--managed-lead-tool-loading-check`. Codex has no supported pin, documented
  in `docs/internals/managed-lead-tool-loading.md`; Pi receives eager extension
  schemas. Invalid arguments are still refused by the host.

## Review

`array_delegate` with Claude Code refused: account usage exhausted.
Fallback `array_delegate` with Codex refused: spawn depth 3 exceeds cap 2.
Asked the lead to arrange the independent review from its level.

## Verification

Initial fresh-bench build failed before compilation: missing ignored
`ThirdParty/GhosttyKit.xcframework`. Added only a bench-local ignored symlink
pointing to the canonical existing artifact. Builds use SDKROOT from xcrun,
4 jobs, and resource preflight (<4 swift-build processes, >=25% memory free,
>=20 GiB disk free). Managed crash marker retained.

## Candidate implementation and observed results

`Sources/ContinuumRevived/App/AgentSupervisor.swift:6259` reads the explicit
`agents.managedMode.isolateEveryHelper` opt-in (absent means OFF). It requires
worktree creation even for the first helper, uses the established sibling
container and created-worktree metadata, and refuses non-git roots. The
`checkoutNotice` result explicitly discloses that the helper starts at lead
HEAD and excludes uncommitted changes. No default setting was written.

`HelperRetryWorktreeChecks.firstHelperIsolation` drives the production MCP
request and captures the real fake-CLI runner cwd. It checks isolated file
writes, committed HEAD versus a dirty lead file, the disclosure and non-git
refusal without minting a child. Registered in full and Managed matrix runs,
and the narrow `scripts/run-matrix.sh --helper-isolation` target.

- Baseline behavioral RED: rebuilt app plus rebuilt `array-workspace-mcp`,
  `--first-helper-isolation-check` exited **1**, specifically
  `first helper shares its Managed lead's writable checkout`.
  Log: `/tmp/gaps-isolation-red.log`.
- GREEN rebuilt app: `swift build --product Array -j 4` completed in 125.86 s.
- Direct behavioral checks all exited **0**:
  `--first-helper-isolation-check`, `--helper-worktree-check`,
  `--managed-lead-tool-loading-check`, `--lead-checkout-ledger-check`.
  Log: `/tmp/gaps-isolation-green.log`.
- Every check used a unique temporary `CONTINUUM_APP_SUPPORT`, unset
  `ARRAY_AGENT_ID`, `TMUX`, `TMUX_PANE`, set `TERM=xterm-256color`,
  `CONTINUUM_SKIP_UI_BASELINES=1`, stdin `/dev/null`; managed crash marker
  retained. Direct checks disabled terminal tmux. No default server accessed.
- Matrix attempts (two, separated by the direct checks) refused immediately:
  `another matrix or release build holds /tmp/array-matrix.lock`.
  No lock bypass. Thus **the new leg has not yet been reported by a real
  matrix run**, and does not satisfy the final gate.
- `bash -n scripts/run-matrix.sh` and `git diff --check` pass.
- Initial build attempts also exposed missing Ghostty artifact, then Swift's
  input-modified guard because the witness was corrected during compilation.
  Both were corrected and the final sources rebuilt before checks ran.
- Successful ledger check logged two missing temporary `ledger.jsonl` writes
  during fixture teardown. These were warnings, not failing assertions, and
  were not changed here.

No live provider quota spent, no full matrix, no release/bundle/UI verification.
The isolation option remains OFF. Default sharing risk remains OPEN. Gaps 5,
6 and 20 remain partial/unproven as classified above; gap 24's existing
production-loading witness passed. Final independent review is lead-arranged
and pending; this candidate is not an integration approval. Bench retained
for that review; the lead must return it after integration/disposition.
