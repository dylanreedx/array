# Helper context diet (experimental, OFF)

Gap 18 / master part 5. This is a launch policy for helpers, not a claim that
personal memory has been removed. Gap 19's draft rule adoption stays OPEN.

`agents.helpers.contextDiet` defaults to false. New delegated children snapshot
that request in their host-owned delegation context before their first prompt.
Existing children keep their snapshot across later settings changes, restores,
resume and compaction. Retry inherits the old child's snapshot. Top-level leads
are unaffected. There is no per-launch help process or configuration-file edit.

The first supported scope is **Pi automatic skill discovery only**:
`--no-skills` is added to both native RPC and diagnostic one-shot launches.
Project AGENTS.md / CLAUDE.md discovery, explicit skills, host instructions,
contracts, task briefs, OAuth, workspace extensions and session identifiers
remain owned by their existing paths. Explicit skills can still load; this is
not total skill exclusion or a filesystem boundary.

`agent.inspect` reports requested state and its scope. Claude and Codex are
explicitly unsupported in this first scope; they receive no new CLI overrides.
Personal-memory exclusion remains unknown on every harness. Keeping the feature
OFF is required until paired task, payload and latency proof establishes safety.

## Local capability evidence

Read installed CLI help, feature listing and the historical probe via
`git show array/helper-launch-probes:.plans/116-agent-standards/evidence/probe-helper-context.md`.

- Pi help documents `--no-skills` and separately `--no-context-files`. Its
  installed resource loader branches on `noSkills` to exclude automatically
  enabled paths, retaining explicit/additional skill paths. An offline loader
  probe in disposable `/tmp/array-diet-loader-*` roots seeded a synthetic skill
  and project hazard: baseline found the skill; `noSkills` removed it; both
  retained the project hazard. No provider inference or user's config used.
- Claude help's `--disable-slash-commands` disables both skills and commands.
  Historical init output confirms catalog removal, but resume/compaction and
  full provider payload were not proved. `--bare` breaks OAuth/hooks/project
  context. No Claude diet switch applied here.
- Codex features offer experimental/under-development candidates. Historical
  accepted overrides and token differences do not establish complete memory
  exclusion or compaction behavior. No Codex override applied here.
- Pi help also emitted a pre-existing user extension import error. This probe
  did not repair or modify that extension. The independent resource-loader
  test used only synthetic local state.

## Witness and limits

`--helper-context-diet-check` drives production delegation and a real production
Pi RPC runner into an offline scripted CLI, captures actual process argv, and
checks the persisted policy and unchanged lead launch. A fake CLI proves what
Array sends; the installed loader probe establishes only that installed loader's
resource discovery semantics. Neither proves model obedience or a speed/quality
gain. Live OAuth provider tasks, real payload capture, real compaction and paired
hazard/quality trials remain OPEN before default rollout.

## Candidate verification record

Implementation `dd39d279`; atomic persistence correction `3cf1080f`.
Defaults remain OFF; complete personal-memory exclusion and gap 19 adoption
remain OPEN. Independent reviewer CD692146 requested the persistence correction;
re-review is pending through the lead.

Behavioral results on the corrected source:

- RED before policy wiring: production delegation reached a real scripted Pi
  RPC process, captured argv and failed `enabled helper must disable Pi
  automatic skill discovery` (`/tmp/gaps-helper-diet-red.log`).
- Independent review exposed a second failure. A production `upsertRecord`
  fault rejecting the snapshot reproduced RED: `failed policy write must
  refuse delegation, never report a child`
  (`/tmp/gaps-helper-diet-write-red.log`). The correction puts policy and the
  initial task brief in the first durable child claim, before the ordinal
  advances. The witness asserts an actual attempted write, no returned child,
  no runner, only the parent durable, and its unchanged ordinal.
- GREEN after correction: `--helper-context-diet-check` exits 0, including the
  write-failure scenario, real delegated RPC argv, default OFF and lead
  isolation, retained contract, stored record reconstruction, actual restored
  process and native compaction protocol, resumed turn, ON-policy retry after
  changing the default OFF, and unknown/unsupported inspection scope.
  Log: `/tmp/gaps-helper-diet-fixed-green.log`.
- Array and MCP were rebuilt before GREEN, with SDKROOT exported and stdin
  `/dev/null`; ARRAY_AGENT_ID, TMUX and TMUX_PANE unset; TERM=xterm-256color;
  CONTINUUM_SKIP_UI_BASELINES=1. Managed crash marker was preserved. Before
  each corrected-source build: Array 1 existing build / 56% free memory /
  51.7 GiB disk; MCP 1 / 51% / 50.9 GiB. GhosttyKit was prepared with the
  repository script. Build log: `/tmp/gaps-helper-diet-fixed-build.log`.
- Neighbor app checks all exit 0: `--managed-mode-launch-check`,
  `--managed-agent-model-spawn-check`, `--workspace-api-delegation-check`, and
  `--workspace-api-cross-harness-delegation-check`. Their environment used a
  unique verified private tmux socket under `/private/tmp/array-diet-tmux-*`;
  only that namespace was cleaned up. Results:
  `/tmp/gaps-helper-diet-neighbors.json`.
- Installed Pi loader compatibility probe: automatic skill discovery OFF/ON
  and explicit-skill case all pass; project hazard retained in all three.
  Runnable with `scripts/probe-helper-diet-pi.mjs` and the installed package
  root. No provider inference, personal text capture, or user config edits.
- Pre-pass fixtures: 44 passed, 0 failed, manifest 12 checks / 0 stale.
  Range pre-pass: 0 failures, 2 advisories (unmapped scripts; notification-map
  heuristic on a dispatcher-only edit). No notification path changed.

Discarded attempts are not behavioral proof: one GREEN build refused because
its check source changed during compilation; a failure-fixture compile attempt
used a private property, corrected to `configureManagedMode` before the actual
write-failure RED. Final source was frozen through successful builds/checks.

The witness is registered both in full `scripts/run-matrix.sh` and focused
`--helper-context-diet` mode, whose builds check resources individually. A
normal-lock focused run reached global fixture checks (44 PASS) but its build
was the discarded modified-input attempt. Later normal-lock runs were refused
because another matrix held `/tmp/array-matrix.lock`; no lock was bypassed.
**No successful matrix summary reports this leg yet.** Gate verification stays
OPEN until the lead runs it on the combined candidate. Direct passes above do
not substitute for that report. Full matrix, live payload, paired task quality,
real provider compaction and no-added-latency proof were not run here.

## Explicit nested exposure and retained-context follow-up

`2187be8e` adds the real `AgentDelegationContext.CodingKeys` census and nine
explicit internal decisions. The policy key is
`agent.delegationContext.contextDietRequested`: host-owned state, not a writable
API property. RED before the census: rebuilt `--workspace-api-exposure-check`
failed `exposure census must include the real persisted helper diet key`.
GREEN after: the same rebuilt arm reports **146 real coding keys classified**.
It round-trips the actual Codable snapshot, checks its actual encoded policy
key, and proves that removing the policy decision makes the real audit fail.
Logs: `/tmp/gaps-helper-diet-exposure-red.log` and
`/tmp/gaps-helper-diet-exposure-green.log`.

`3ccd77e2` strengthens the runtime witness with positive captured-process
assertions: first, retry and restored Pi launches carry `-e` for the workspace
extension, the contract marker reaches the helper prompt, and synthetic supplied
host rules survive actual restored-process injection. App and MCP were rebuilt
and the full arm exits 0 on this source, including the atomic write-failure case.
Preflights: Array 0 existing builds / 65% memory free / 50.2 GiB disk; MCP
0 / 59% / 50.2 GiB. Log:
`/tmp/gaps-helper-diet-exposure-app-green.log`; process witness output:
`/tmp/gaps-helper-diet-context-preserved-green.log`.

`6df8773c` adds a separately resource-gated CoreChecks build and the exposure
arm to the focused diet matrix, and maps delegation-context changes to that
exposure arm. The normal-lock attempt remained refused by another holder;
there is still no successful reported matrix leg in this bench. Integration
must preserve that pending gate status. CLI help and the installed-loader probe
establish the bounded discovery semantics; full provider payload, real-provider
compaction, obedience and paired latency/quality remain unproved. No personal
or project files were replaced or deleted. No child review agent was spawned;
exact commits and RED/GREEN evidence were sent to the lead for sibling review.
