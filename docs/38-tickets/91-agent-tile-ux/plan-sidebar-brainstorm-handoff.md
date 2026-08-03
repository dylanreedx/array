# Sidebar brainstorm — handoff and pattern transfer

Written 2026-08-03 at the end of the P5.5 session, to resume a **design brainstorm** about the
agent sidebar (inbox). Companion to `plan-sidebar-and-state-findings.md` (the audit: what is
broken and why) — this doc adds what the tile work *taught us*, so the sidebar inherits the
patterns instead of re-deriving them.

## Where things stand (resume point)

- **Queue 91 is closed.** P5.5 supervised acceptance committed as `394b822` on `overnight/agent-ux`
  (local only, never pushed). 49/50 done; P5.3 blocked on Queue 90 todo/plan events. The loop is
  deliberately not restarted — it would report `queue-drained`.
- **v2 is the only tile.** Launch flag, construction seam, and the entire legacy card path are
  deleted (compose field/Run button, card stack, approval dock, user-input card,
  `TranscriptCardViews`). Provider requests render as reducer-projected transcript blocks.
- **The app Dylan is running** is `qa-runs/20260803T175656Z/app-bundle`, launched with no flag.
- **The sidebar is untouched by design.** `AgentInboxView.swift` (~4,200 lines) is in no packet's
  fence — which is exactly how P3.12's "sidebar/inbox rows without grey perimeter borders"
  correction got stranded for two phases. Sidebar work needs its own owner-fenced supervised
  packet; that is the decision to make next.

## What the brainstorm is for

Not "fix the five defects" — the audit already says how. The open question is **what a sidebar row
is for**, and therefore what belongs on it. Working hypothesis to argue with: *the sidebar is a
triage surface — it answers "which agent needs me, and what is it doing" at a glance, and nothing
else.* Everything on the row should earn its place against that job:

- The agent's **identity** (a name a human chose or recognises — today it is a model id).
- Its **state**, truthfully (today: "Working" for six days).
- Enough **context** to disambiguate two agents in the same project (branch? project? role?).
- An **attention** signal that outranks everything (needs-action first).

Open: does elapsed time earn a permanent column? Does the model belong on a triage row at all, or
is it tile/settings detail? Is the project chip more useful than the branch?

## Pattern catalog from the tile work (apply, don't re-derive)

### Visual / UX

1. **Quiet containment, not perimeter borders.** The v2 tile paints `borderWidth = 0` when idle;
   `ChoiceRowView` never paints a perimeter at all — "state is fill plus checkmark". Selection is
   a *fill step* (`AgentSurfaceRole.rowSelected`) plus a marker; hover/keyboard focus is
   `rowHover`; focus rings are 0.5 pt `AgentLineRole.focusRing` with a soft glow, never permanent.
   The inbox still paints 1 pt `LineToken.border` on every idle row and signals selection by
   swapping one grey for another. **Straight adoption available.**
2. **Semantic roles, not raw tokens.** Fills come from `AgentSurfaceRole` (rowBase/rowHover/
   rowSelected), lines from `AgentLineRole` (`controlBoundary` for interactive edges,
   `decorativeHairline` for decoration, `focusRing` for focus) — the roles carry the contrast-floor
   reasoning. The inbox reaches for `LineToken.border`/`borderStrong` directly, painting a
   decorative edge with a control-boundary colour.
3. **Measured fit in tiers, never a width threshold.** The footer picks full → abbreviated →
   caption-hidden by comparing measured need against the width it actually has. The inbox's only
   adaptive behaviour is a hard-coded 390 pt flip (and it is wrong at both ends).
4. **Truncation sacrifice order is a design decision, and it is currently backwards.** The tile
   decided the *caption* yields before any value. The inbox drops compression resistance on the
   agent **name** — the row's subject — so the project chip and elapsed time win. Whatever we
   choose, choose it explicitly.
5. **Derived metrics, not magic numbers.** `Metrics.rowHeight(for:lines:insets:)`,
   `providerControlHeight`. The row may vary height with *content* (how many lines it will draw)
   without violating "no importance-based density" — the 79 pt fixed row reserving three lines and
   drawing two is pure dead space.
6. **One row where the design says one row.** Footer + primary action share a line: action
   right-aligned at intrinsic width, footer absorbing the remainder through a bare `NSView()`
   spacer. The inbox headline has no absorber, so surplus strands right while the title clips.
7. **Custom controls, never Aqua.** `ChoiceButton`/`ChoicePopoverController` replaced the tile's
   `NSPopUpButton`s. The sidebar's "All agents" scope control and its bulk bar are still raw
   AppKit — the most visible remaining violation of design principle 18.
8. **Capability-truthful presentation.** Never render an affordance the transport cannot honour;
   reserve a blunt word like "Unavailable" for a true dead end; collapse mechanically-distinct
   states that a human experiences as one (Send → Stop → Send). Sidebar corollary: a row must not
   claim "Working" for a state that is really "we have never confirmed anything about this agent".
9. **One owner per fact.** The supervisor snapshot owns turn state; the presenter maps snapshot →
   presentation; no parallel projections. The sidebar currently has *three* status arms, where a
   stamped activity draft silently outranks the derivation.
10. **Notify on state changes no event carries.** The capability seam fires when the runner slot
    changes; subscribers re-read the supervisor's own truth. No polling, no fabricated events. The
    sidebar's stale rows are the same shape of bug — a fact changed (or never existed) and nothing
    re-derived it.

### Engineering / gates

11. **Text truncation needs drawable-width assertions.** Frame-only checks pass on an ellipsised
    label, and comparing `stringValue` is vacuous because the cell elides at draw time. Precedent:
    `ChoiceButton.qaTitleDrawsWithoutTruncation` + the geometry-gate comparison.
12. **`+4` pt cell inset** in every hand-laid-out `NSTextField` measurement
    (`measuredTitleWidth`). The inbox's `minimumTextWidth` is missing it, so its guaranteed
    minimum ellipsises.
13. **Assert absence structurally**, over the live view tree, so a reintroduction fails the same
    assertion the removal satisfied.
14. **Offscreen renders need explicit materialization.** Size the subtree *before* applying
    content, and drive layout/prepare/attribute re-application from the list's own layout pass.
    This is why the semantic transcript had never appeared in a blessed baseline.
15. **Gate the production path, not a synthetic one.** `qaDeliver` could not represent the
    occupied-runner race; a real held-open runner could. Sidebar analogue: the row-status check
    only ever exercised the synthetic status arm, so the drafts-win arm is untested.
16. **Re-measure gate floors in the same change** that alters what surfaces render
    (owner census, foreground slot counts, probe minimums), with the reason in a comment.
17. **Witness discipline.** Every new assertion is observed red at the exact message, restored by
    SHA-256, then observed green — recorded in the ledger note.
18. **Gate at the widths that ship.** Every inbox check and baseline renders at 320 pt; the
    shipping sidebar default is **280** and its minimum **220**. The truncation regime is
    literally never gated.

## Brainstorm agenda (suggested order)

1. **Row anatomy from first principles** — what earns a place, at 220/280/320 pt. Sketch two or
   three layouts (single-line dense? two-line with meta? attention-first grouping?) before
   touching code.
2. **Naming.** Role-less spawns are seeded `displayName = role ?? model`, so the sidebar shows
   `openai-codex/gpt-5.6-sol` as a *name*, twice. Options: project + ordinal ("personal · agent
   2"), a friendly generated name, a name derived from the first prompt, or "model is metadata,
   never the name" plus a rename affordance. Both `AgentInboxRow.title` and
   `AgentRecord.displayName` document "never an identifier" — the writer violates its own contract.
3. **Status truthfulness.** Pick the ownership rules (audit recommends: fix the spawn-record
   writer, never-working-without-a-runner, cap/anchor elapsed, render `unobservedAgentIds` as
   unconfirmed). Also unify vocabulary: the same agent currently reads "Working" in the inbox,
   "Configuring" in the tree chip, and "Managed agent configuring" on the phone.
4. **Borders, selection, density** — adopt the `ChoiceRowView` treatment; decide whether the
   containment edge survives at 0.5 pt as ticket 93's first consumer, and where row density should
   land relative to the 36 pt choice rows.
5. **The scope control** — `ChoiceButton` + popover, matching the tile family.
6. **Packet shape** — one combined UI+state supervised packet, or UI and state separately? Fence
   list (`AgentInboxView.swift`, `AgentInboxRow.swift`, `AgentInboxRowBuilder.swift`, tokens, gate
   files), and the gate additions that must ride along: an inbox leg in `--ui-geometry-check` at
   220/280/320 with drawable-width assertions and a fixture that can actually express the bugs
   (provider/model title, nil role + nil branch, 3-digit-hour elapsed), un-pinning the 79 pt height
   assertions, and re-measuring the appearance floors that count each row's outline slot.

## Owner decisions still open

1. Sidebar packet shape: combined UI+state, or split (recommendation: split — the state rules
   touch the phone payload contract and deserve their own witness set).
2. Default agent naming scheme for role-less spawns.
3. Which status-ownership rules to adopt (audit recommends 2 + 1 + 3 + 4, deferring the
   "one arm, not three" refactor to its own packet).
4. Ticket 93 (`93-global-border-audit.md`, all borders ≤ 0.5 pt + a named width token) — land it
   first and make the sidebar its first consumer, or after?
5. Whether Queue 92 (relay) pre-arm work interleaves or waits.

## Preflight for any implementation session

Quit Dylan's running instance before any app probe or relaunch (shared store/tmux; the boot probe
hangs against a live instance). Never `swift build` while a matrix run is in flight. Baselines may
only be blessed at a supervised gate with `check-retina-main.swift` passing. Ledger rows stay
`pending` until the done-commit; one local commit, Dylan's identity, no trailers, never push;
`scripts/check-agent-tile-ux-program.sh --check` green before committing.
