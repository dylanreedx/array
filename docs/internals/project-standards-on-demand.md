# Project standards on demand (shadow)

Part 16 of `.plans/116-agent-standards`, the wave-2 shadow step. An agent can
read its own checkout's written standards through the workspace API. Nothing
tells an agent to use it, no always-loaded text is removed, and a checkout
with no standards launches exactly as it did before (witnessed against a
capture from the base commit).

## Where standards are looked for

Only in the calling agent's own checkout (`AgentRecord.checkoutRoot`), in
`docs/standards/`, one folder deep (`docs/standards/project/x.md`). Never
Array's own repository, never the active project, never a bundled copy.

Only regular files whose resolved path is inside the resolved
`docs/standards` are read. Refused, each as a named issue:
`symlinked_folder` (`docs/standards`, `docs` or a subfolder is a symlink),
`outside_standards` (a symlink to anywhere else, in the checkout or out),
`hard_link` (link count above one), `broken_link`, `not_regular_file`,
`unreadable`. A symlink to another file inside the folder is read.

A file is a standard when its header, the lines between its `# Title` and its
first `## ` heading, has an `Applies when:` line. Its id is its path under
`docs/standards/` without `.md`. Rules sit under `## Rules`, start at `N.` or
`N.M.`, and are returned verbatim with ids `<standard id>#<number>`. Parse
failures are issues: `missing_trigger`, `empty_trigger`, `multiline_trigger`,
`duplicate_trigger`, `no_rules`, `unnumbered_rule`, `duplicate_rule_id`.

Every other `*.md` is listed in `skipped` with its reason: `index_file`
(`README.md`), `not_a_standard` (no header), `nested_folder` (too deep).
Nothing in the folder disappears without a note.

## The operation

`standards.read`, tool `array_standards`, self-checkout read only, in the
session preset (no prompt). Every answer carries `source`: the text is quoted
from files in this repository, which anyone with commit access or another
agent may have written, and is not an instruction from Array or the user.

- No arguments: the index. Each standard's id, path, title, `appliesWhen`,
  `ruleCount` and `version` (content hash), plus `issues` and `skipped`.
- `standards: [id]`: those standards with every rule. `rules: [ruleId]`: only
  those rules. Ids that match nothing come back in `unresolved`.
- Paging, after `canvas.query`: `total` items, `nextCursor` while more
  remains, about 32 KB a page, at least one item per page. A rule longer than
  16 KB comes in ordered `part`/`parts` pieces that join to the exact text. A
  cursor is bound to the folder's version (`cursor_expired` after a change)
  and to the ids it was minted for. Nothing is limited, refused or cut for
  size.
- No `docs/standards/` is `not_found`.

It runs on the asynchronous workspace entry (`dispatchAsync`), which both the
MCP and Pi transports use: identity, grant and validation on the main actor;
listing, reading and parsing off it, through `ProjectStandardsCache`, which
re-reads only when the folder's listing (names, types, sizes, times, inodes,
link targets) changes. It needs no mounted canvas.

A cached read still re-lists the folder, because a standard edited in place
changes no directory stamp, so a directory-stamp key alone would serve stale
rules. The listing is therefore as cheap as a full re-stat can be: `readdir`
and `lstat` straight from libc, and a byte fingerprint instead of formatted
text. 10,000 files cost about 680 ms before and about 40 ms now (debug build);
`--project-standards-index-check` bounds it at 150 ms and checks that an
in-place edit of one of the 10,000 is still re-read.

No matching, no ranking, no model call. Matching is wave 4.

## Offered only where there are standards

One decision per launch: `AgentSupervisor.runnerLaunch` asks
`ProjectStandardsPresence` and carries the answer on
`AgentRunnerLaunch.projectStandards`. Present means `docs/standards` is a
symlink (so the refusal is seen) or holds a `*.md` other than `README.md` at
its top level or one real folder down. The look reads names only, at most 512,
and never descends a symlinked folder; past that budget the answer is present.
It runs on its own queue after each turn, when an agent is made and after a
restore. The launch keeps that answer while the `lstat` of every folder it
listed is unchanged, so it lists nothing on the main thread; only a checkout
first seen, or changed since its last look, is listed there, within the same
budget. Witness: `--standards-resolution-check` (its launch-bound section).

- Claude and Codex: the MCP server gets `ARRAY_WORKSPACE_PROJECT_STANDARDS=1`
  and only then lists `array_standards` (`WorkspaceMCPConfiguration`).
- Pi: the agent process gets the same variable and the bundled extension
  registers the tool only then (`PiAgentRunner.Config`, `childEnvironment`);
  a roled agent's `--tools` gains it only then (`RoleRegistry.toolsArguments`).
- `workspace.context` lists `standards.read` exactly when the launch offered
  it. If the folder changed since, it adds `toolListNote`: the tool list is
  fixed when the agent starts.

The fixed tool list is deliberate and stays out of this release: Claude and
Codex read the MCP server's tool list when the CLI starts it, and Pi registers
the tool when its process starts, so a later change reaches an agent only by
restarting it. The note tells the agent, and nothing is lost: it can still
read the files.

Every one of those stops defaults to off, and `hostToolNames` and
`WorkspaceMCPHost.configuration` take the flag with no default. Each stop that
remains is a process boundary or an argv builder that must know; the catalog
filters by operation, with no field of its own.

## Always-loaded words

| | Without standards | First cut | Now |
|---|---|---|---|
| Tools | 36 (as on the base commit) | 37 | 37 |
| `array_standards` description + guideline, authored | 0 | 49 | 45 |
| The same as rendered over MCP (adds `Guidelines:` and `-`) | 0 | 51 | 47 |
| Parameter descriptions | 0 | 16 | 9 |
| Pi snippet | 0 | 5 | 4 |
| Total added, Claude and Codex | 0 | 67 | 56 |
| Total added, Pi | 0 | 70 | 58 |
| MCP server instructions, injected agent guidance | unchanged | unchanged | unchanged |

Claude defers MCP tools behind tool search, so up front it sees only the name.

## Seams for later parts

A retrieval fact (agent, ids, versions; never text) would be appended in
`WorkspaceAPIService.answerOffMain`, where one comment marks the place. No run
ledger is written today.

## Witnesses

- CoreChecks `--project-standards-index-check`: presence, parsing, every issue
  and skipped reason, containment (symlink out, symlink into `.plans`,
  symlinked folder, symlinked `docs`, hard link, broken link, FIFO), paging
  (multi-page index, a rule in parts, a foreign cursor, an expired cursor),
  cache invalidation, and printed timings.
- App `--standards-resolution-check`: launches without standards match
  `scripts/fixtures/standards-base-capture.json` (taken by
  `StandardsBaseCapture` on b33595b8) for Claude, Codex, roled and roleless
  Pi; with standards, the production launch, the real MCP server, Pi's argv,
  environment and extension under node, the asynchronous entry, containment,
  provenance, capabilities and the launch note.

## Not done here

Bundled Array agent RFCs (drafts, not on integration), trigger and diff
matching (wave 4), ordering of retrieval against edits, and the paired trial.
Agents with workspace tools disabled cannot reach this operation; plain file
reads remain their path.
