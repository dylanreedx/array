# Project standards on demand (shadow)

Part 16 of `.plans/116-agent-standards`, the wave-2 shadow step. An agent can
read its own checkout's written standards through the workspace API. Nothing
tells an agent to use it, no always-loaded text is removed, and a checkout
with no standards sees exactly what it sees today.

## Where standards are looked for

Only in the calling agent's own checkout (`AgentRecord.checkoutRoot`), in
`docs/standards/`, one directory level deep (`docs/standards/project/x.md`).
Never Array's own repository, never the active project, never a bundled copy.

A file is a standard when its header, the lines between its `# Title` and its
first `## ` heading, has an `Applies when:` line. Its id is its path under
`docs/standards/` without `.md` (`project/benches-and-storage`). A file with no
`Applies when:`, `Status:` or `Layer:` line (a README, an index) is not a
standard and is skipped; so is any `README.md`, the conventional index. One with `Status:` or `Layer:` but no usable
`Applies when:` is reported as an issue.

Rules sit under `## Rules`. A rule starts at a line `N.` or `N.M.` and runs to
the next rule or heading. Its id is `<standard id>#<number>`
(`project/benches-and-storage#3`). The text is returned verbatim, `Why` and
`Enforced by` included.

Every file is resolved with `AgentLocalFileLinkResolver`, the API's existing
path rule: canonical, symlink-aware, component containment, regular files only.
A symlink or directory pointing outside the checkout is an issue, never read.

## Explicit failures

Reported as `issues` (path, code, message, line) beside whatever did parse:
`missing_trigger`, `empty_trigger`, `multiline_trigger`, `no_rules`,
`unnumbered_rule`, `duplicate_rule_id`, `outside_checkout`, `unreadable`.
A broken standard never disappears silently and is never replaced by another
repository's rules. No `docs/standards/` at all is `not_found`.

## The operation

`standards.read`, tool `array_standards`, self-checkout read only, in the
session preset (no prompt).

- No arguments: the index. Each standard's id, path, title, `appliesWhen`,
  rule ids and `version` (`sha256:` of the file bytes, first 16 hex), plus
  `issues`.
- `standards: [id]`: those standards with every rule's text.
- `rules: [ruleId]`: only those rules.
- Any id that does not resolve comes back in `unresolved`; nothing is guessed.

No matching, no excerpt ranking, no model call. Matching is wave 4.

## Advertised only where there are standards

`ProjectStandards.isPresent(checkoutRoot:)` decides, once per launch:

- Claude and Codex: the MCP server's environment gets
  `ARRAY_WORKSPACE_PROJECT_STANDARDS=1`, and only then lists `array_standards`.
- Pi: the agent process gets the same variable; the bundled extension
  registers the tool only then, and a roled agent's `--tools` gains it only then.
- `workspace.context` lists `standards.read` in capabilities only then.

The catalog entry carries `"advertisedWhen": "projectStandards"`; the tool's
description is the only always-loaded text added, and only for such checkouts.

## Observation seam

Each answered call hands a `StandardsRetrieval` (agent, time, standard ids,
rule ids, versions, unresolved ids; no rule text) to
`WorkspaceAPIService.standardsRetrievalObserver`. Production sets none. The
run ledger (part 12) or telemetry (part 14) attaches there when it exists.

## Witnesses

- CoreChecks `--project-standards-index-check`: the production parser over
  fixtures written into a temporary directory: valid, missing trigger,
  duplicate and unnumbered rules, no rules, a symlink out, a README.
- App `--standards-resolution-check`: a temporary non-Array git repository,
  standards written by the check; Claude, Codex and Pi launch configuration
  through the production supervisor paths; `standards.read` through the
  production dispatch; a missing-standards checkout; traversal ids; the
  observer record.

## Not done here

Bundled Array agent RFCs (drafts, not on integration), trigger matching and
diff matching (wave 4), ordering of retrieval against edits, and the paired
trial. Agents with workspace tools disabled cannot reach this operation;
plain file reads remain their path.
