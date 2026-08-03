# 94-sidebar-native-ux — design contract

The sidebar is Continuum's agent inbox. Queue 90 built the runtime, queue 91 rebuilt the agent
tile; the sidebar was left behind because `AgentInboxView.swift` sat in no packet's file fence —
which is how P3.12's "no grey perimeter borders" correction was stranded for two phases. This
program owns that surface end to end: containment, row anatomy, status truthfulness, identity,
native interaction, and lifecycle.

Grounding evidence, read before authoring or implementing anything:

- `docs/38-tickets/91-agent-tile-ux/plan-sidebar-t3code-study.md` — five audits of T3 Code's
  sidebar at `origin/subagent-obs/05-thread-visibility` (`573255c6c`), with the transferable rules
  and the places where T3 Code has the same bug we do.
- `docs/38-tickets/91-agent-tile-ux/plan-sidebar-and-state-findings.md` — our own defects, with
  line numbers, and the gate gaps that let them ship.
- `docs/38-tickets/91-agent-tile-ux/plan-P5.5-review-corrections.md` and
  `plan-P5.5-composer-action-consolidation.md` — the tile patterns this program reuses.

## Where we start

The row **model** is already right. `AgentInboxRow` carries five states and three colours,
`InboxAttention` treats unread as a mark and gives `woke` a word, `RowVariant.forLifecycle`
derives density from lifecycle, `InboxSort` freezes creation order, and the project is metadata
rather than a group header. Independently, that is T3 Code's sidebar-v2 semantics. Two places are
ahead of it: `InboxState.state(for:pending:)` is a single total function where T3 Code inlines the
same predicate about twenty times in three incompatible variants, and `unobservedAgentIds` is
already computed correctly.

The **view** never caught up, and the **status pipeline** reads a frozen disk record. That is the
whole program.

## Locked decisions

**Surface is reserved for interaction.** A row paints no perimeter border in any appearance. At
rest it is unfilled. Hover, multi-selection, and route-active are fills from `AgentSurfaceRole`,
with selection quieter than hover, because hover is transient feedback and selection is a resting
state. Status is carried by content — a word and an accent inside the row — never by a background
or an edge. Any boundary the sidebar keeps is at most 0.5 pt and comes from `AgentLineRole`.

**The row's subject is its name.** The agent's name gets a line of its own and yields last. When
width runs out the caption, the project chip, the branch, and the metrics give way before the name
does. Truncation order is a decision recorded in the packet, never an emergent consequence of
compression priorities.

**Measured fit, never a width threshold.** Adaptive behaviour compares measured need against the
width actually available and steps through named tiers. Every hand-laid-out `NSTextField`
measurement adds the 4 pt cell inset, because the cell elides at draw time and a frame-only or
`stringValue` assertion cannot see it.

**One owner answers what an agent is doing.** The supervisor's `AgentTileTurnSnapshot` is the only
source of an agent's turn state. Activity drafts contribute the timeline, never the status. No
surface re-derives status from a persisted record at read time, and no second projection exists to
disagree.

**An unobserved agent is unconfirmed, never working.** An agent with no live snapshot renders as
unconfirmed. Its elapsed clock is frozen rather than ticking, because a ticking number asserts a
liveness nobody confirmed. `unobservedAgentIds` is the input, and it is rendered.

**Persisted state is evidence, never liveness.** At launch, every persisted agent whose recorded
status is non-terminal is swept to a terminal one with a stated reason before any surface can read
it. A record on disk proves something happened, never that something is happening. System-cancel
and user-stop stay distinct words.

**Elapsed is anchored to stamped work, and bounded.** A duration counts from a real turn start,
resolved by a first-valid ladder so a malformed timestamp falls through instead of poisoning the
clock, clamped at zero, and coarsened past a day. One formatter serves the sidebar, the tile
header, and the phone.

**A name is never an identifier.** `displayName` is what a human recognises. A model id, a role
id, a session id, or a UUID is metadata and may appear as such, but never as the row's title, and
never twice on one row. A nameless agent is born with a sentinel name from one shared constant,
and the sentinel is the only permission slip to overwrite it later.

**A generated name never clobbers a human one.** A rename disarms any pending generation, and a
generated name lands only if the in-flight request is still current and the title is still what it
was when generation started. Naming is best-effort: failure leaves the sentinel and logs.

**No stock AppKit chrome in the sidebar.** No visible `NSPopUpButton`, no stock `NSMenu` for a row's
context menu, no rounded-bezel `NSTextField`, no default focus ring. Interaction surfaces reuse the
tile's `ChoiceButton`/`ChoiceListView`/`ChoicePopoverController` family rather than inventing a
second control vocabulary.

**Activity never reorders the list.** A row holds its position from spawn until a lifecycle
transition. Ordering is by creation for active rows, by wake time for snoozed, by end time for
settled, always with a stable id tie-break. Status is carried by the row, never by position.

**Lifecycle is derived, never stored.** Only the raw fields persist; the lifecycle value is
computed from them plus `now` at every read. Activity blockers outrank every override in both
directions, and whatever the classifier refuses to call settled the action guard must refuse as a
settle target.

**Density comes from parking, not from importance.** Only settled and snoozed rows collapse. Row
height may vary with the content a row actually draws; it may never vary with how important the
sidebar guesses a row is.

**Hide, never disable, an affordance the runtime cannot honour.** Capability absence is read
explicitly, the affordance is omitted rather than shown dead, and no row is classified into a state
whose only exit is a missing button.

**Children stay visible; fan-out is bounded.** An agent that spawns agents keeps its children in
the list, indented, at depth ≤ 2. Fan-out is capped per parent with a priority order and an
explicit remainder, and a child's attention propagates to its parent — a child blocked on a human
must be visible from the parent's row.

**I5 remains absolute.** No transcript, prompt, path, tool argument, PID, or secret crosses phone
sync. A name derived from a prompt is prompt-derived text and is treated as such at the sync
boundary.

## What this program does not own

- Queue 90's runtime, RPC, and session capabilities. Missing capability blocks a packet; it is
  never simulated.
- The agent tile's transcript, composer, and header. Queue 91 closed those; this program consumes
  their patterns and may not reopen them.
- Queue 92's relay, and the phone client beyond keeping the existing payload contract honest.
- A global border sweep. `docs/38-tickets/93-global-border-audit.md` owns every surface outside
  this program's fence; the sidebar is its first consumer and defines the shared width token.

## Verification stance

Deterministic gates block; visual taste is decided only at supervised rows. Three properties this
program's gates must hold that the existing inbox gates do not:

1. **Gate at the widths that ship.** 220, 280, and 320 pt. Every current inbox check and baseline
   renders at 320 only, so the truncation regime is literally never exercised.
2. **Assert drawable width, not frames or strings.** A label that elides at draw time satisfies
   both a frame assertion and a `stringValue` comparison. `ChoiceButton.qaTitleDrawsWithoutTruncation`
   is the precedent.
3. **Fixtures must be able to express the defect.** A corpus with human titles, roles present,
   branches present, and a two-hour maximum elapsed cannot fail on any of the bugs this program
   exists to fix.

Offscreen renders never run a live display cycle: a list must be sized before content is applied,
and the list's own layout pass must drive collection layout, prepare, and attribute
re-application. Appearance and pixel floors are measured constants — re-measure them in the same
change that alters what surfaces render, with the reason in a comment.
