# Personal rules for Codex and Pi

Claude Code agents read the user's own Claude instructions; Codex and Pi agents
do not. This feature hands Codex and Pi agents a short rules file the user keeps.
Default off. Claude launches are never changed.

## Where it is switched on

Settings ▸ Agents ▸ Personal rules: a toggle (`agents.personalRules.enabled`,
default off) and the file's full path (`agents.personalRules.path`), drawn by the
schema's existing toggle and text rows. The line under the toggle shows the
outcome of the last read (loaded with its word count, missing, unreadable, empty,
over 64 KB, not UTF-8 text) and, when it happened, why the last Codex launch went
without it. Nothing is modal and nothing blocks or delays a launch. Array only
reads the file; it never creates, edits or copies it. The plan left placement
open; this is the one Settings toggle under Agents. These are app settings, not
agent, tile or zone properties, so the workspace API exposure audit has nothing
to classify.

## When the file is read

At every Codex or Pi process launch, never at app start or runner construction.
`CodexAgentRunner.Config.launchArguments` and `PiAgentRunner.Config.launchArguments`
are resolved by each spawn (`resolvedExtraArgs()`): Codex `run`, its self-heal
and `compact`, the Pi one-shot runner and `PiRpcAgentRunner.ensureStarted`. Those
run on the supervisor's background turn/compaction queues, never the main thread.
The read is one bounded `read(upToCount: 65_537)`. An edit therefore reaches the
next launched process. A Pi RPC session that is already running keeps the text it
was launched with until it relaunches (idle reaping, restore, mode change).

## The seam

`HostLaunchInstructions` holds named sources (`HostLaunchInstructionSource`),
each kept separately and resolved per launch. One option per harness is rendered
at launch, in this fixed order:

1. the user's own Codex `developer_instructions` (Codex only, see below),
2. instruction text Array already passes in the runner's extra arguments,
3. each source's block in registration order (Array's `reply-rules`, then the
   user's `personal-rules`); duplicate names are dropped.

Codex gets one `-c developer_instructions=<TOML basic string>` (a repeated key
replaces the earlier one); every control byte, including DEL, is escaped. Pi gets
one `--append-system-prompt`. A file with a NUL byte is rejected (it cannot
travel in argv). `HostLaunchInstructions.production(reply:personal:)` is the one
place that order is set.

## Array's reply rules

A second block, owned by Array: `ReplyStandard` in Core, the one place its text
lives (RFC 6's reply rules, compressed). Settings ▸ Agents ▸ Reply rules
(`agents.replyRules.enabled`, default off), the group just above Personal
rules; the two switches are independent. The block never enters the user's
files and the personal text never enters it.

It reaches every Array-run agent: Codex and Pi through the seam above, and
Claude through `ClaudeAgentRunner.Config.hostInstructions`, resolved at each
Claude spawn. On Claude it is joined after `WorkspaceMCPConfiguration.agentGuidance`
in the ONE `--append-system-prompt` value (a second flag replaces the first);
with workspace tools off it is that flag's only value. Personal rules never
reach Claude (`HostLaunchInstructionSource.reachesClaude`). With both switches
off every argv equals the base launch element by element. The switch applies
from an agent's next launch; a running agent keeps what it started with.

What does not receive the block today:

- Terminal-face agents (an agent flipped to an interactive terminal). They get
  no Array text at all.
- Pi role runs (`HarnessRoleRunBuilder`), which run `pi` in a terminal tile, not
  through the managed runner.
- Codex launches in two cases, where passing text would replace instructions
  Array cannot keep: the user's own Codex setting cannot be read with
  confidence, or instruction text already in the launch's arguments cannot be
  decoded. Both record the reason, shown under both switches in Settings.

`--reply-rules-launch-check` drives the same production path and fake CLIs as
the personal-rules witness: Claude with and without workspace tools, Codex and
Pi; solo (first, idle reuse, resumed, compaction), lead, helper and `retryOf`;
both blocks on; the switch read per launch; both off against the base argv.

## The user's own Codex setting

`-c developer_instructions=…` replaces that key from `config.toml` for the
launch. Codex 0.167's `--help`, `exec --help`, `app-server --help` and its
generated app-server schema show no per-launch way to add to it: `-c` overrides,
`--profile` layers a file that would have to be written under `CODEX_HOME`,
`additionalDeveloperInstructions` exists only in admin requirements, and
`thread/start`'s `developerInstructions` is undocumented as add or replace.

So Array reads, never writes, `<CODEX_HOME or ~/.codex>/config.toml` at launch
and joins a top-level `developer_instructions` string first. If that key appears
anywhere else (a profile, a table, a dotted or quoted key, a project
`.codex/config.toml` in the working directory or an ancestor, `/etc/codex`), or
its value is not a string Array can parse with confidence, that launch gets no
host text and the reason is shown under the switch.

## Witness

`--personal-rules-delegation-check` drives `AgentSupervisor` →
`productionRunner(for:hostInstructions:)` → the real runners → spawned fake CLIs
(`AgentSteeringQAFakes`, extended in the check to log each spawn's argv with its
owning agent). All files live in a temporary directory the check creates; on/off
go through `PersonalRulesConfig.selectedPath` with isolated defaults suites.

It covers Codex first, resumed, compaction and edited-file launches; Pi RPC idle
reuse, relaunch after reaping with the edited file, and a restored agent's
compaction launch; a real `retryOf` for Pi and Codex helpers; a first launch
with no earlier read; Claude argv equal element by element to the base with the
feature on and off; Codex and Pi argv equal to the base when off; an unreadable
user Codex setting left alone; the config reader's forms; a fixture second
block; every outcome and the switch's status line; and that `.shared` reads
nothing in a check run.

RED by mutation, each restored byte for byte: the old read-once-at-startup
source; runners spawning with frozen arguments; Claude given the rules; JSON
instead of TOML (DEL left raw); blocks reversed; outcome not kept; the QA guard
removed; the user's Codex setting ignored; the off switch ignored.

Not established: provider obedience, Pi behaviour after real compaction, and
live timing. Those remain rollout requirements; the feature stays off until then.
