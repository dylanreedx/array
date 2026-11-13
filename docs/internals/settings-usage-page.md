# Settings ▸ Usage (first slice)

`.plans/116` part 21. The page shows how Array did the work on this Mac: tasks
closed, how they were split, tokens by kind for the lead and the helpers, and
recent tasks with their times, helpers, tokens, harness and model.

## A reader only

The page records nothing, and deletes through the writer (below). `RunLedgerUsageReader` (Core) reads a snapshot of
`run-ledger/ledger.jsonl` (see [managed-run-ledger.md](managed-run-ledger.md))
and is the only file that knows the row shapes; its header lists the mapping.
`UsageReport.make` is the one report function; a scorecard command should call
it too, so the two can never disagree.

The count runs on a utility queue, only while the pane is on screen (it starts
in the pane's `onAppear`, is cancelled in `onDisappear`), and the parsed ledger
is cached while the file's size and modification date are unchanged. Nothing
runs on a request or event path, and opening Settings starts no count.

## Definitions

- **Counted tasks** are tasks with a `taskClosed` row whose time falls in the
  period (last 7 days, last 30 days, all time). Open and interrupted tasks are
  listed and never counted.
- **Fully counted**: every agent that ran a turn left a usage row, no row is
  marked incomplete, and every kind its harness reports is known. A kind a
  harness never reports (`UsageReport.notReported`: Codex cache writes) shows
  as a dash, explained once under the table, and does not make a task partial.
- **Unknown** is never zero. A total missing part of its count reads "at least"
  the known part; one line under the table says how many tasks are missing
  something. Figures are compact on the page (5.4M, 320K, 139) and exact in an
  opened task and in the export.
- **Task rows**: one aligned row per task (closed, time to answer, solo or
  helpers, total tokens, model); clicking it opens the Lead / Helpers / All
  table for that task. One page of 30 rows, then "Show more".
- **Lead and helpers**: a usage row whose agent opened the task is the lead's;
  any other, at any depth, is a helper's. A helper's own helper has a
  `delegated` row naming its parent helper. A child the CLI started itself
  (`via: harness`) is a helper too. A Claude in-process subagent's tokens are
  inside its parent's result: its `reportedByParent` rows are not missing, and
  where they are all a role has, that cell reads "included in parent", never 0.
- **Split and mode**: solo, one helper, two or more, by every agent under the
  lead; Managed or Free from `taskOpened.mode` ("not recorded" on older rows).
  Counts only, never averages side by side.
- **Late rows**: every usage row of a task is summed, each `source` once. A
  turn's `noUsage` row is dropped once a row with tokens names the same turn.
- **Missing, not unreported**: `noBaseline` (a resumed Codex thread with no
  trusted start), `reset`, `noUsage` and the like make a figure "at least".
- **No task**: usage under the all-zero task id is never listed; one line says
  how much of it fell in the period. It includes turns that started after their
  task closed and that no helper result of the task woke (a turn an agent
  message started). A lead's wake on a helper result is the task's; one on a
  result that came after the close rejoins it, flagged `lateHelperWake`, and
  counts (`TaskLine.lateHelperWakes`).
  `trailingFramesCut` (Codex frames still unread when the runner's bound ended)
  makes a figure "at least", like `noUsage`.
- **Model**: a blank id reads unknown and never borrows a helper's; a model
  named by the agent's settings rather than the stream says so when opened.
- **Time to answer**: the task's first submission (`taskOpened`) to its close.
  Because a task closes when the lead's turn ends with no open parts, there is
  no user wait inside it.
- **Active time**: the union of every agent's turns (`working` to `turnEnded`),
  overlap counted once, cut at the close: a turn still running then counts up to
  it, and a turn that starts later is not the task's, so it never exceeds time
  to answer, except by a late helper's wake, which counts whole. A task closes
  when the lead's wake that reads its helpers' results ends, so time to answer
  includes that wake. Unknown if any turn has no end.

## Not recorded yet

- The stage the lead's answer named (integrated, verified) and integrated to
  verified: no stage rows exist (part 12 step 3).
- Wall time to acceptance: acceptance is optional and not recorded.
- Time in build and check commands (part 20).
- Since when recording has been off: the switch keeps no date.

Left out of this release, each on purpose:

- The stage an answer named, integrated-to-verified time and build time need
  new ledger rows (part 12 step 3, part 20). The page never shows a figure it
  cannot read, so they stay absent until those rows exist.
- Later slices (quality, context, one task opened): not this release's page.
- Since when recording has been off: the switch keeps no date; adding one is a
  settings change, not a usage-page change.

## Delete

`ManagedRunLedger.delete(.task(id))` and `.allUsage` are the one delete path.
The page only asks; it never edits the file. On the ledger's queue the writer
rewrites the file without the rows (atomically; the file itself is removed when
nothing is left), then forgets them in memory so a later fact starts clean. A
task whose lead is mid-task, or whose turns still hold counters, is refused
(one) or kept and counted in the notice (all): its next row would land in a
half-deleted task. A restart interrupts every older task, so those can always
go. "Delete all" also removes usage no task owns and unreadable lines; a single
task delete keeps a torn final append, as the writer does.

The controls are Array's `ChoiceButton` holding one destructive command that
names what goes and that it cannot be undone, so choosing it is the
confirmation: "Delete usage records" under Recording, and "Delete this task…"
inside an opened row (not offered for a task still open). A notice line says what
happened, quiet outcomes included.

## The row that opens

Each task row is a button with a rotating chevron, the same disclosure anatomy the
transcript's tool calls use, but Settings has no shared disclosure component,
so this one is built in the pane. It is the one new pattern on the page: **needs
the owner's look in the preview.** The alternative, SwiftUI's stock
`DisclosureGroup`, is a default control the UI rules rule out.

## Witness

`--settings-usage-check` drives the production Settings model and pane in the
offscreen fixture window over a ledger it writes with the writer's own row type
into a temporary directory, and asserts the rendered words: exact totals by
kind, lead against helpers, unknown never zero, the period chooser through the
real choice button, the recording switch, the empty ledger, export holding ids
only, no count on the main thread or while another pane is shown, and both
appearances (renders in `/tmp/usage-page/`). Delete is witnessed through the
page's own control and the production writer: one task's rows leave the disk
and the page while every other line is byte-identical; a running task is
refused; "delete all" keeps only the running task, then removes the file once it
closes; the ledger records a new task afterwards and a restart finds nothing. It prints timings for a
300,000-row ledger and asserts nothing about time.
