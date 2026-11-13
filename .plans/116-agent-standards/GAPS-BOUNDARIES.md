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
  mirrors provider children. `RunLedgerGapsChecks.builtinClaude` and
  `builtinCodex` assert delegated rows with `via: harness` and parent/task
  identity. Claude usage explicitly says `reportedByParent`; the Codex fixture
  reports independent child tokens. Observed rows, accurate per-harness cost
  attribution, and prevention are separate properties; rows are implemented.
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

## Follow-up: lifecycle coverage and B6 correction

At the lead's request, the isolation witness now also sends two simultaneous
production MCP delegation requests, compares all checkout roots, advances an
isolated nested lead's HEAD and asserts a sibling checkout at that HEAD, then
resumes a dirty isolated helper through `array_message_agent` while siblings
run. It asserts the original checkout and private file survive without a new
worktree. This is test-only coverage; production policy remains `04dbe334`.

The first expanded build found a test typo (`resolved` returns `String`, not
`URL`); corrected after the build ended. The next preflight refused with
**4 swift-build processes**, 47% free memory, 64.4 GiB disk. No build was
started after that failed preflight. Expanded lifecycle coverage is therefore
**not yet compiled or run**; earlier four GREEN legs refer to the narrower
witness in `04dbe334`, not this extension.

B6 source correction was separately verified using the last successful
`04dbe334` app binary (these production/test sources were unchanged):

- `CONTINUUM_LEDGER_GAPS_CASE=builtin ... --run-ledger-gaps-check`: exit 0,
  observed delegated row via harness with parent=lead; one helper, included
  in parent, all 79,536 fixture tokens.
- `CONTINUUM_LEDGER_GAPS_CASE=builtin-codex ... --run-ledger-gaps-check`: exit 0,
  observed delegated row via harness with parent=lead; one helper, 32,707
  fixture tokens.

Both runs used separate temporary app-support roots, stdin `/dev/null`,
`TERM=xterm-256color`, UI baselines skipped, ARRAY_AGENT_ID/TMUX/TMUX_PANE
unset, terminal tmux disabled, and managed crash marker preserved.
Log: `/tmp/gaps-builtin-verified.log`. These establish observed ledger rows;
they do not establish universal native-child prevention or independent Claude
child accounting. Ordinary Managed, opt-in Claude Strict and Codex remain
distinct as described above.

Documented dependency bootstrap: `README.md:24`,
`GHOSTTY_SRC=/path/to/ghostty scripts/prepare-ghosttykit.sh`. It links an
already-built `<GHOSTTY_SRC>/macos/GhosttyKit.xcframework`; it does not copy
`.build` or build Ghostty. Ran that script successfully in this bench using
its default local Ghostty source checkout.

The lead subsequently requested explicit retry/Free opt-in cases. The witness
now stops the resumed helper, retries through production MCP, checks a distinct
checkout plus retry identity and retained old private file, and switches the
lead to Free with the preference still enabled to check shared Free placement.
These additional assertions are also uncompiled/unrun: the latest preflight
again refused four active builds (34% free memory, 59.3 GiB disk). No production
policy changes were made in either lifecycle extension.
