# 113 — Sidebar sort and project filter

Started 2026-11-01 for the 0.7.39 preview. Branch `array/sidebar-sort`, on top
of `agent/agent-characters-build-ducks-679c0f0c` (0.7.38 plus agent characters).

Dylan: "something that should be easy to include is simple sidebar filtering…
i think most intuitive would be most active to not… but could be by project,
etc." This answers plan 87's open "Step 5 ordering": most active first.

## What it does

- **Sort button** in the sidebar header, icon-only (`arrow.up.arrow.down`),
  between the scope control and New Agent. It opens the shared choice list
  (`ChoicePopoverController`, compact choices) with three entries:
  - **Most active** (the app default). Leads that are working or need you come
    first, ordered by when their current turn started. Everything else follows,
    ordered by last activity, so quiet agents end up at the bottom. A lead
    counts as working while any of its subagents is.
  - **By project.** Project headings A to Z, then "No project". Inside each
    project, agents are in Most active order. The headings reuse the
    Snoozed/History heading view without its triangle, so the appearance census
    gets no new themed view.
  - **Newest first.** The old frozen spawn order (P3.4), kept as the third
    choice because it already existed.
- Only the live block is re-sorted. Snoozed and History keep their own orders,
  and subagents stay in their lead's card in the order plan 106 gives them.
- **Rows only move when an agent's state changes.** A working agent is keyed by
  when its turn started, not by its streaming activity, so it does not jump
  while it works.
- **No jumps under the pointer.** While the pointer is over the sidebar, or a
  row is being renamed, each row that is already drawn keeps its place and a
  new agent appears at the top. The held re-sort is applied when the pointer
  leaves, the window stops being key, or the rename ends, and rows slide to
  their new places (150 ms `slideSurvivors`; skipped above 40 rows and under
  Reduce Motion). A sort you pick yourself applies at once, with the same slide.
- **Project filter:** the existing one. The scope list's `Projects ›` drill-in
  already picks a single project (plan 87). It works in every sort mode and
  needed no second control.
- **Remembered** under `continuum.workspaceSidebar.sort` in the app's settings
  defaults (`WorkspaceSidebarConfig.resolveSortMode` / `setSortMode`), beside
  the scope. A value it cannot read falls back to Most active. A bare
  `AgentInboxView` starts on Newest first, so committed baselines and older
  checks still draw the frozen order. The app's sidebar wiring
  (`configureWorkspaceSidebar`) restores the stored choice.

## Stills

Rendered offscreen by the check, light and dark:

- `most-active-light.png`, `most-active-dark.png`: the header with the sort
  button, and the list in Most active order.
- `by-project-light.png`, `by-project-dark.png`: project headings, no repeated chip.
- `lead-glyph-light.png`, `lead-glyph-dark.png`: an idle, folded lead with a working helper.
- `sort-list-light.png`, `sort-list-dark.png`: the open sort list.

## The check

`.build/debug/Array --sidebar-sort-check [dir]` (`SidebarSortChecks.swift`;
registered in `scripts/run-matrix.sh` and the matrix inventory). It uses
the production `AgentInboxView` with six agents across three projects plus one
with no project, and covers:

- each order, picked through the header's real sort list, and the four headings;
- the Film filter through the scope list, in By project and in Most active;
- VoiceOver can reach the sort button;
- with the pointer over the list, a push that would re-sort keeps the drawn
  order and puts the new agent on top; when the pointer leaves, the re-sort
  happens and the moved row has its slide animation;
- a push during a rename keeps the order and leaves the rename open; once the
  rename ends, the list re-sorts;
- persistence through `AppDelegate.configureWorkspaceSidebar` in an isolated
  suite: first launch is Most active, a pick is stored, a second launch restores
  it, and an unreadable value falls back to Most active.

Teeth, confirmed: disabling the pointer hold, disabling the rename hold, or
removing the host's restore line each turns the check red with a specific
message.

## Added 2026-11-02

- **Working glyph on a lead whose helpers run.** A lead row shows the gyro (and
  a working character, with characters on) while it works or while any helper
  under it works, folded or open. The fact is the same rollup the card's
  outline sweep reads, and Most active already keys a lead by its helpers.
  Still: `lead-glyph-light.png`, `lead-glyph-dark.png` (a folded lead).
- **No repeated chip in By project.** A lead under its own project heading
  draws no project chip, and its line 2 no longer opens with a stray dot.
  VoiceOver still reads the project. A chip naming a different folder (a
  worktree) stays, and every other mode keeps the chip.

- **Header fit (preview matrix finding).** The sort button had its own slot in
  the header row, which squeezed search and scope to 102 pt each and failed
  `--sidebar-screenshot-check`. It now sits inside the search field's reserved
  trailing slot (24 pt, inset 4 pt like its top and bottom), so the row is back
  to search, scope and New Agent at their own widths (132 / 102 pt at 280 pt).
  While text is typed the clear button takes that slot and the sort button
  hides; clearing the search brings it back. Stills: `header-light.png`,
  `header-dark.png`, `header-typing-light.png`, `header-typing-dark.png`.

## Left out on purpose

- Changing the sort while a search is typed: clear the search first (the clear
  button and the sort button share one slot).

- Project headings do not collapse.
- The New Agent button is missing from the sidebar's hand-built accessibility
  children. That gap predates this work; the sort button is included.
