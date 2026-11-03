# Helper completion wakes — 0.7.41 decision

Board card: 506B1042-91B1-4169-9F75-30BF67D94CEC.

This reverses P4's file-only decision. Waiting for all handles groups a tool
reply, but it only helps while the lead is blocked in that tool. In practice
leads need to accept messages and continue other work. Timed polling spends
lead turns even when no helper has changed.

Completion updates follow the existing watchdog delivery path: start an idle
lead or persist a composer queue item for a busy lead. Updates collected during
a fixed eight-second window become one lead turn. Each contains helper identity,
outcome and a bounded report or final message; failure includes its error.
Runner generations deduplicate terminal delivery, including Stop/unwind races.
The watchdog keeps its independent ten-minute no-progress clock and queue.

Each accepted message handle owns a result file for the work it started. A new
handle cannot inherit a preceding result, and a later turn cannot overwrite a
settled message handle. `operation.get` and `wait_agents` consume the same result.

The per-lead "Wake me when helpers finish" choice lives in the sidebar's existing
Array choice menu. Managed leads default on; plain agents default off. Explicit
choices persist in the app's settings suite, separate from the agent record,
harness, model and provider session. Turning it off drops pending completion
batches; the existing result-file collection path remains available.

Provider retries resume the existing helper session with a short continuation,
with a pause and at most two host retries. Intermediate provider failures do not
settle the handle or wake the lead. Work failures do not retry. Exhaustion is
reported as "failed after 2 retries" with the provider error.

Each wake spends one lead turn. Short updates and grouping reduce that cost;
there is no background model summarizer or periodic completion polling turn.

Inspired by Ali Alsalkhadi's Duckherd, inspected at ea44e83 (`hooks/register.tsx`
and `hooks/text.ts`): independent helpers report back to the lead, nearby reports
are grouped, and stalled work is surfaced. Array uses its own persisted CLI
sessions and supervisor, and leaves each CLI's authentication with that CLI.

These are model messages, not direct user notifications. No Mac alert, phone
push, sound, badge, widget or Live Activity delivery path is added or changed.
Existing policies still apply to ordinary agent activity and terminal events.

Witnesses and actual results are recorded in ~/array-scratch/lead-wakeups/REPORT.md.
A source/document assertion is not a behavioral witness.
