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
