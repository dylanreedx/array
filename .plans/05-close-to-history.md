# 05 · Closing a tile parks the agent in History

Status: **implemented, unreleased** (rides build 6 with the rest of
`.plans/backlog.md`'s unreleased set).

## The report

> "close/deleting agents seem weird, they go to unconfirmed… they should be
> deleted for the most part, there could be a recovery tab, history tab, to see
> closed previous sessions and to open and resume the tile, but i see so many
> agents in my sidebar but i dont have that many tiles opened"
>
> — Dylan, 2026-08-10, daily-driving `~/Desktop/Array Dev.app`

## What was actually happening

`deleteTile`'s `.managedAgent` branch (`ContinuumApp.swift`) implements P2A.5's
locked decision — *closing a tile is closing a window, not ending the work*. It
dropped the tile-keyed session record and cleared the agent's view binding, and
deliberately did **not** stop the runner or delete the `AgentRecord`.

Nothing then took the agent out of the live list. With no tile and no runner it
was *unobserved*, so `UnconfirmedElapsedFreeze` froze its clock and the row
painted `Unconfirmed` — permanently. Every tile you ever closed left one.

Three separate defects, which is why the fix is not one line:

1. **No way out of the live list.** Closing was a view event; the list is built
   from records, and no record ever left.
2. **`Unconfirmed` was the wrong word.** It means "no observer, so the app
   cannot say". For a deliberately closed agent the app *can* say: nothing is
   running. An honest admission of ignorance became wallpaper.
3. **A stale `tileId` made the row dead.** A record can outlive its tile
   (`revealAgentFromInbox` took `record.tileId` as gospel, `revealTileFromInbox`
   resolved nothing, and the click silently returned `false`). Measured on the
   owner's dev store.

## What T3 Code does, and what transfers

T3 Code has no tile concept — the thread list *is* the app — so it never had
defect 1. Of what it does have:

- `archive`/`unarchive` (sets `archivedAt`, reversible) is a **separate verb**
  from `delete` (permanent). Archiving is refused while a thread is running
  (`useThreadActions.ts`: *"Cannot archive a running thread."*).
- Archived threads leave the sidebar entirely and are not even in the main
  store — fetched lazily when you open Settings → Archived
  (`routes/settings.archived.tsx`, `ArchivedThreadsPanel`).
- `ProviderSessionReaper` stops the provider process after 30 min idle,
  independent of the thread record. **The record is permanent and cheap; the
  process is disposable.**

Taken: the two-verb split, the busy guard, and "leaving the list is a
deliberate, reversible act". Not taken: burying the archive in Settings — Array's
History is something you use, not a graveyard, so it is one click away in the
sidebar. Not taken (yet): the idle reaper.

## The decisions

1. **Close = "I'm done with this", unless the agent is busy.** An idle agent
   whose tile you close parks in History. A working one stays in the live list —
   Array's whole pitch is that parallel work stays visible, and hiding a running
   agent would be the worst possible version of this bug. When it finishes it
   lands in the settled tail (it has a result you have not seen); archiving it
   from there sends it to History.

   "Busy" is not a new opinion: `close` refuses exactly when
   `AgentLifecycleFacts.blocksSettlement` is true — a turn in flight, a pending
   human request, an unadopted prompt, or a descendant holding its parent open.
   The same predicate the Settle action uses.

2. **Archive and Delete stop being the same call.** They used to differ only in
   what the person was told. Now:

   | verb | what it does | confirmation |
   |---|---|---|
   | **Archive** (and closing a tile) | stamps `archivedAt`; record, transcript, provider session and worktree all survive | none — it is reversible |
   | **Delete** | `AgentSupervisor.archive`: stops the runner, deletes the record, tombstones the tile, cleans the worktree keeping anything unmerged | yes |

3. **A fourth section, not a tab.** The inbox is already one `NSTableView` with a
   counted collapsible heading (P4.7's shelf) and a paged tail (P4.8). History is
   a fourth section — `History (N)`, collapsed by default, drawn by the same
   heading view with a section parameter so no new `TokenThemed` conformer owes
   the appearance census a sweep surface. A tab would be a new navigation model
   for the same list.

4. **No retention limit.** Silently deleting the user's work to fix a
   list-length problem is the wrong trade. Records are tiny and History is shut
   by default. Unpaged for now: paging a section that is closed costs a second
   limit, a second footer, and a second thing that can disagree with its own
   count. `InboxSort.pageSettled` is there if it is ever needed.

5. **No boot migration.** An agent orphaned by the *old* close path has
   `tileId == nil`, which is indistinguishable from a legitimately headless
   agent (P2A.6). A sweep would have to guess, and guessing wrong hides running
   work. The stale-binding fix below repairs the reachable half; the rest ages
   out as tiles get closed under the new rule.

## What changed

**AgentUI (shared with iOS)**
- `InboxLifecycle.archived` → `archived(at: Date)`, and `endedAt` answers with
  it. History is ordered most-recently-closed first.
- `RowVariant.forLifecycle(.archived)` → `.slim`. A closed agent is the most
  parked row there is.
- `InboxSort`: a fourth sort block below history; `InboxSection.history`;
  `InboxPartition.history` / `historyCount` / `visible(shelfExpanded:historyExpanded:)`.
- `AgentStatusVocabulary.closed` = `"Closed"`, and `presentationLabel` returns it
  for an archived row instead of `Unconfirmed`.

**Core** — nothing. `AgentRecord.archivedAt` already existed and was already
threaded into `InboxLifecycle.resolve`; production simply never set it, because
the archive verb deleted the record first.

**App**
- `AgentSupervisor.close(agentID:)` / `.reopen(agentID:)` — the soft park and the
  way back out.
- `deleteTile`'s `.managedAgent` branch calls `close` before `detachView`.
- `revealAgentFromInbox` clears a binding no canvas can resolve (`tileIsReachable`)
  and calls `reopen` after a successful reveal.
- `UnconfirmedElapsedFreeze` skips archived rows.
- `parkAgentsFromInbox` — the Archive row/bulk action, no confirmation sheet.
- `AgentInboxView`: `.historyHeader` item, `historyExpanded`, `toggleHistory`,
  a second cached heading cell, QA accessors.

## Witnesses

| what | where | teeth verified by |
|---|---|---|
| closing an idle tile parks, durably; the row leaves the live list; `History (1)` appears; opening it shows a slim `Closed` row; clicking it returns the agent with a new tile and clears `archivedAt` | `--agent-inbox-check` section C·3c, driving the **real** `deleteTile` | removing the `close` call → red; removing the `reopen` call → red |
| closing the tile of a WORKING agent does **not** park it | `--agent-supervisor-check` §8 (`checkDetachOutlivesItsTile`) | deleting the `blocksSettlement` guard → red |
| the production branch still contains the park | `--agent-supervisor-check` §8 source scan | removing the call → red |
| a closed row is off screen but accounted for; the History heading opens in the live AppKit table | `--sidebar-ux-check` | — |
| lifecycle/section/order/vocabulary rules | `ContinuumRevivedAgentUIChecks` (`InboxSortChecks`, `AgentLifecycleChecks`, `AgentInboxRowChecks`) | — |

`--agent-supervisor-check` §8 is **not reachable in a normal run**: the leg halts
earlier at the KNOWN-RED naming section. It was verified by temporarily stubbing
the earlier reds (see `.plans/backlog.md`'s verification-debt section).

## Three unrelated reds this uncovered

`--agent-supervisor-check` halts at the KNOWN-RED naming section, which is
roughly a third of the way in. Everything after it has been unrun for a long
time. Reaching §8 to verify the park meant temporarily stubbing the naming legs,
and that exposed three stale assertions with nothing to do with this plan. All
three are fixed here; none was a product defect.

1. **`live-v2` asserted the footer still says "Responding".** `204b2ac` moved
   live status onto the gyro and left the footer only attention states. Red from
   the moment that shipped. Now asserts the word where it moved to *and* that the
   footer stays quiet. Two sibling assertions had the same problem: a detached
   tile said `"Unknown"` and a rebound one said `"Ready"`, both of which
   `92c07da`'s "go silent when idle" removed on purpose.
2. **The block-renderer roster count was 16, the roster is 18.** `ddbf83d` added
   `.image` and `.imageGallery` without moving the number. Now pins 18 *and*
   no-duplicates, which a bare count cannot distinguish.
3. **The context-telemetry seam constructed a supervisor and never restored it.**
   Red since `24b1b00` gave `contextWindowSnapshot(for:)` a record lookup: with
   no records the seam short-circuits to nil, so the leg was asserting
   `nil == snapshot`. Now calls `restore()`, which is what a relaunch does.

With those fixed, `--agent-supervisor-check` is green from §7 to §20; the naming
section remains the one documented KNOWN-RED holding the leg.

## Follow-ups

- `InboxRowAction.rename` is still unavailable on an archived row, with the
  comment *"a name lives on the record, and archiving deletes the record"* — that
  reason is now false. Behaviour left alone; the comment is wrong.
- Undo for Archive is now *possible* (the record survives) and still not wired;
  P4.11's "no toast for an archive whose record is gone" no longer describes it.
- `ComponentLab`'s corpus shape `archivedCard` was renamed `archivedSlim`, and
  `titleIsModelId` now states `variant: .card` so the coverage matrix keeps an
  explicit card row.
