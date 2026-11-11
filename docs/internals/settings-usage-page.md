# Settings ▸ Usage (first slice)

`.plans/116` part 21. The page shows how Array did the work on this Mac: tasks
closed, how they were split, tokens by kind for the lead and the helpers, and
recent tasks with their times, helpers, tokens, harness and model.

## A reader only

The page records nothing. `RunLedgerUsageReader` (Core) reads a snapshot of
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
  marked incomplete, and all four kinds are known. Codex never reports cache
  writes, so a Codex task is never fully counted; its other kinds still count.
- **Unknown** is never zero. A total that is partly unknown shows the known part
  and how many tasks are missing from it.
- **Lead and helpers**: a usage row whose agent opened the task is the lead's;
  any other is a helper's. A provider-run subagent's tokens are its parent's.
- **Split**: solo, one helper, two or more, by `delegated` rows. Counts only,
  never averages side by side.
- **Time to answer**: the task's first submission (`taskOpened`) to its close.
  Because a task closes when the lead's turn ends with no open parts, there is
  no user wait inside it.
- **Active time**: the union of every agent's turns (`working` to `turnEnded`),
  overlap counted once. Unknown if any turn has no end.

## Not recorded yet

- The stage the lead's answer named (integrated, verified) and integrated to
  verified: no stage rows exist (part 12 step 3).
- Wall time to acceptance: acceptance is optional and not recorded.
- Time in build and check commands (part 20).
- Since when recording has been off: the switch keeps no date.
- Delete: the ledger writer owns the one delete path (part 12), not built.

## Witness

`--settings-usage-check` drives the production Settings model and pane in the
offscreen fixture window over a ledger it writes with the writer's own row type
into a temporary directory, and asserts the rendered words: exact totals by
kind, lead against helpers, unknown never zero, the period chooser through the
real choice button, the recording switch, the empty ledger, export holding ids
only, no count on the main thread or while another pane is shown, and both
appearances (renders in `/tmp/usage-page/`). It prints timings for a
300,000-row ledger and asserts nothing about time.
