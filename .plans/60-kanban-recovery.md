# KB-01 recovery — 2026-09-05

Work remains in `/Users/dylan/array-worktrees/kb01-board`, branch `array/kb01-board`.
No staging, commits, merges, or pushes were performed. Production Array was not
quit or rebuilt. The initial worktree was clean.

## 2026-09-09 — 0.7.17 release-readiness pass

The board slice is complete in `array/kb01-board`. The previously stale status
table is now corrected: task details, attachment editing, assignment drag, the
CX-01 surface contract, and the large-board drag gate are all landed.

- `BoardSurfaceSnapshot` exposes deterministic ordered columns/cards with the
  board revision; `BoardSurfaceCommandService` routes revision-checked commands
  through `BoardEngine` and returns the transaction plus updated snapshot.
- The board witness now includes CX-01 stale-revision and inverse checks and a
  `board.large-drag` scenario covering 1,000 cards / 1,005 slots. The latest
  p95 was 0.000147625 seconds, under the 50 ms gate.
- Fresh dev bundle `/private/tmp/array-0717-board-preview-1788963068/Array Dev.app`
  opened in an isolated project/support directory; the empty board visually
  showed To Do, Doing, Done, task creation, and the assignment/detail affordance.
- Focused app/editor checks pass: interaction (including zoom 1.0 and 0.35),
  lifecycle, task workflow, and both TaskEditor tests. `git diff --check` passes.

The 207-leg fast matrix completed with all board/editor legs green. It still
reports four unrelated failures: CoreChecks' existing full-run failure, missing
Beta in `--empty-workspace-creation-check`, empty notes in
`--palette-captures-keys-over-browser-check`, and the existing file-tile pinch
zoom p95 ceiling. Four expected known-red legs also remain. No production app
or production project state was touched; no staging, commit, or push was done.

## Current UX

- Click selects, double-click or Return edits the title. A repeated single click
  no longer opens editing. Pickup begins after four screen points of movement.
- Cards receive clicks over their text and measure wrapped titles at the actual
  card width. Width changes invalidate the height cache once.
- The board accounts only for the grab strip extending below the base title bar.
- The carried card lives on the canvas, preserving its local bounds and pointer
  offset through zoom. It can travel beyond the board without clipping.
- Agent hit testing uses the canvas parent's coordinates. An agent drop emits
  one assignment callback without a lane move. Empty-canvas drops cancel.
- A local event monitor owns drag/release after pickup. The actual screen test
  caught a sixth defect: hiding the source view could strand mouse-up delivery,
  leaving the carried copy floating. Escape/deactivation cancel the gesture.
- Selection is reapplied when a move replaces a card view in another lane.
- Quieter lane backgrounds, title-case headers, roomier cards, widths that fill
  the board, an inline Add task in each lane, and a footer explaining assignment.

## Verification performed

Before fixes, added and ran `--board-interaction-check`: all five reported defects
were reproduced at zoom 1 and 0.35 (14 failing assertions including consequences).
The final witness uses real NSViews and dispatches release through `NSApp.sendEvent`.

Passing checks:

- `swift build --product Array` (repeated after substantive changes).
- `scripts/make-app-bundle.sh --configuration debug --output "/tmp/kb01-preview/Array Dev.app"`.
- `.build/debug/Array --board-interaction-check`: 29 assertions; click target,
  height, grab strip, pickup threshold, transformed target hit, carried-card
  geometry, release, cancel, empty-canvas drop, and selection after rebuilding.
- `.build/debug/Array --board-tile-lifecycle-check`: spawn, hydrate, close, and
  card moves independent of canvas persistence.
- `.build/debug/ContinuumRevivedCoreChecks --board-model-check`: B1–B10, after a
  fresh full `swift build` by the matrix.
- `swift run ContinuumRevivedPaletteChecks`: passed after adding New Board to
  the expected action inventory and a direct kanban-search assertion.
- `.build/debug/Array --ui-probe-check`: passed after adding populated board
  surfaces to both appearance sweeps and owner-scoped token validation. The 11
  historical descriptor fill measurements remain intact; kanban is explicitly
  accounted for as a kind introduced on tokens. All 12 kinds are rendered in
  both appearances.
- `git diff --check`.

App checks used disposable project/app-support paths; targeted non-tmux app
checks passed `-continuum.terminal.tmux.enabled NO -continuum.terminal.tmux.path ''`
where applicable. The matrix created its own tmux namespace.

Actual GUI observations through the isolated preview: created a board via Cmd-K,
added tasks in To Do and Doing, verified wrapped text, dragged from the middle of
card text into Done, observed lane counts change, undid the move with one Cmd-Z,
and double-clicked/renamed a task. The first GUI drag exposed the release defect;
the repaired version completed the same gesture. Scratch tasks survived relaunch.

## Broader matrix result — not a green release gate

Ran:

```sh
CONTINUUM_SKIP_UI_BASELINES=1 CONTINUUM_SKIP_SURFACE_CHECKS=1 scripts/run-matrix.sh --fast
```

205 legs ran. All three board legs are now registered, appeared in the real
matrix output, and passed. iOS built successfully. The run recorded five failures:

1. CoreChecks: safe-row performance took 0.10953s against a 0.100s ceiling.
2. PaletteChecks: missing New Board in expected action lists. **Fixed; targeted rerun passed.**
3. UI probe: kanban views absent from appearance coverage. **Fixed; targeted rerun passed**, also accounting for the new TileKind in historical fill evidence.
4. `--empty-workspace-creation-check`: expected registered project Beta absent
   from the palette results. Not investigated in this board UI slice.
5. `--palette-captures-keys-over-browser-check`: selected New Note but `notes=[]`.
   Not investigated in this board UI slice.

Four documented KNOWN-RED legs also failed: nav-mode, perf-budget-zoom,
perf-budget-gesture-transition, perf-budget-magnify-slope. No baselines were
updated. Display/surface legs were explicitly skipped via the environment above;
`--fast` skipped the packaging smoke harness. The complete matrix was not repeated
after the two coverage fixes; their targeted suites were rebuilt and rerun.

Logs: `/tmp/kb01-matrix.log`, `/tmp/kb01-interaction-red.log`,
`/tmp/kb01-interaction-green.log`, `/tmp/kb01-lifecycle.log`,
`/tmp/kb01-model.log`, `/tmp/kb01-palette.log`, `/tmp/kb01-appearance.log`,
`/tmp/kb01-final-bundle.log`.

## Preview and remaining product work

```sh
open --env CONTINUUM_PROJECT_ROOT=/Users/dylan/kb01-scratch \
  --env CONTINUUM_APP_SUPPORT=/tmp/kb01-preview/support \
  "/tmp/kb01-preview/Array Dev.app"
```

The original preview had inherited a shared dev registry with unrelated projects;
this launch is pinned to its own support directory and scratch project. The
existing shared development registry and its projects were not edited.

I did not send a live agent prompt during QA. The final read-only UI observation
showed the scratch task assigned to a newly present agent, with a stopped-run
error ("Stopped before Pi saved anything"). This confirms the visible assignee
state, not successful provider execution. The view's handoff callback and
unchanged lane membership are witnessed; successful provider execution is not.
Body editing and attachments remain unimplemented, as do the unresolved product
choices in the original design document. The visual treatment is a first recovery
pass, not a claim that Dylan has approved the design.

## Task details expansion — 2026-09-08

The current slice supersedes the original click/edit and assignment behavior above.
It remains in this same isolated worktree, without staging, commits, or pushes.

- Click opens the task document; pickup still requires four screen points. Cards
  expose an independent Assign agent control, grip/grab cursor, one bounded image
  thumbnail and image count. Eligible agent tiles gain drop hints during pickup.
  Long assignee names truncate; board scroll views use overlay scrollers.
- Assignment writes only `assignCard`. It never sends a prompt. The picker searches
  this board's project across zones, with current-zone agents first and current
  operational state in each choice. Create agent uses the existing spawn flow
  after focusing and checking the board's project.
- The local Tiptap/WKWebView task document includes formatting, status, assignee,
  image file selection/paste/drop, inline images, gallery, and preview. CSP denies
  network requests. The native image scheme only resolves attachment IDs belonging
  to the open task and uses the bounded thumbnail pipeline.
- Markdown remains canonical. Imported HTML and tables outside the authoring
  palette survive as visible literal source blocks. The source, exact lockfile,
  generated offline bundle and dependency notices are kept together.
- Board schema v2 decodes v1 cards with no attachments. Project-owned immutable
  originals live in `.array/boards/assets/<board UUID>/<attachment UUID>`; removing
  an image from a task preserves bytes for undo. No automatic asset deletion was
  added in this slice.
- Atomic `editTask` saves title/body/image metadata with one undo. Autosave waits
  300 ms and close/prepare flush immediately. Disjoint title/document edits merge;
  overlapping changes show a conflict with explicit keep/reload choices. Failed
  writes retain local edits and keep the window open.
- Prepare prompt reveals the existing assigned composer, imports independent agent
  copies of task images, and attaches a frozen context summary. Typed instructions
  and independent composer images remain separate. Same-task preparation refreshes
  and deduplicates; another task requires Replace/Cancel. Preparation is serialized
  and explicit persistence errors keep the source window open. Only the existing
  Send/Queue route assembles and submits the combined prompt.

Witnesses added and observed:

- RED: `--board-model-check` failed B11 before attachment decoding/storage was
  implemented (`/tmp/kb02-core-red.log`). GREEN: B1–B13 pass, including atomic undo,
  disjoint merge, overlapping conflict, and prepared-context draft round trip
  (`/tmp/kb02-core-green.log`).
- `--board-task-workflow-check` exercises the actual composer against a mock sink:
  no send during preparation, refreshed context, preserved instructions and an
  independent image, no duplicate task images, persistence through a fresh store,
  one explicit send containing all content, and retained project-owned original.
  `/tmp/kb02-workflow.log` records all eight assertions passing.
- The local editor tests cover formatting/checklist/image/source round trips and
  native bridge messages, including a quiet initial load.
- `--board-interaction-check` passes at zoom 1 and 0.35. The final witness also
  checks the independent assignee hit target.
- `--ui-probe-check` passes the existing live light/dark appearance census and
  composer behavior checks (`/tmp/kb02-ui-probe.log`).

Observed through CUA in the isolated preview: a normal card click opens details;
editing the description autosaves; a local image fixture imports into the gallery
and inserts inline; assigning leaves the agent idle; close/reopen preserves the
content; Prepare prompt preserves the separately typed “Keep this keyboard-friendly.”
text and displays task context plus image in the real composer. Relaunch preserves
both the task and prepared draft. No live prompt was sent during this QA.

Preview: `/tmp/kb01-preview/Array Dev.app`, pinned by launch environment to
`/Users/dylan/kb01-scratch` and `/tmp/kb01-preview/support`. One accidental CUA
background launch without the environment hit the existing-project lock warning
and was quit without opening that project. All subsequent launches use the explicit
isolated environment.

Build notes: one check invocation was rejected by the old binary's unknown-flag
protection before the new build completed. Incremental builds interrupted by source
edits were rejected; a stale caller object also required recompilation. These were
re-run, not treated as successful builds. Final bundle and gate results follow below.

### Final verification result

`CONTINUUM_SKIP_UI_BASELINES=1 CONTINUUM_SKIP_SURFACE_CHECKS=1 scripts/run-matrix.sh --fast`
completed with **207 legs** (`/tmp/kb02-matrix-final.log`). All five registered board
and editor legs ran and passed: task workflow, editor JavaScript tests, pointer
interaction (31 assertions), tile lifecycle, and board model (B1–B13). App and iOS
builds, UI appearance, and UI geometry passed. Geometry took several minutes in its
existing compact-status appearance sweep; a sample of that check process confirmed
that path, and it subsequently completed successfully.

The full matrix is **not green**. It reported:

1. CoreChecks: `KindClassifier classifies real tmux shell pane as shell, got unknown`.
   This is outside the changed board/composer code; it was not repaired here.
2. `--empty-workspace-creation-check`: Beta missing from palette results (same
   finding as the prior recovery run).
3. `--palette-captures-keys-over-browser-check`: New Note selected with `notes=[]`
   (same finding as the prior recovery run).

Four expected KNOWN-RED legs also failed: nav-mode, perf-budget-zoom,
perf-budget-gesture-transition, and perf-budget-magnify-slope. Supervised visual
baseline/surface legs and the slow bundle probe were explicitly skipped by the
command above. No baselines were updated.

The final review caught one additional packaging defect: SwiftPM's generated
`Bundle.module` accessor was falling back to this checkout's `.build` resources.
The task editor now uses the existing CodeEditorHostView-style installed/bare
resource lookup. After that narrow correction, rebuilt the bundle successfully
(`/tmp/kb02-bundle-packaged-assets.log`) and ran the actual bundled executable's
`--board-task-workflow-check`: all **10 assertions** pass, including resolving
strictly beneath the installed app's Resources directory
(`/tmp/kb02-packaged-workflow.log`). The bare executable passes all 9 applicable
assertions (`/tmp/kb02-bare-workflow.log`). The 207-leg run preceded that final lookup
correction; it was not repeated for this resource-only path change.

Final CUA observation after relaunch: clicking the task opens the editor at
`file:///tmp/kb01-preview/Array%20Dev.app/Contents/Resources/continuum-revived_ContinuumRevived.bundle/TaskEditor/index.html`,
with the saved inline image/gallery, assignee, and Done status. Changing status in
the detail view was also observed moving the task from Doing into Done. The final
preview is left open on that task. The agent remains idle with the independent
instruction and prepared context in its composer.

`git diff --check` passes. No staging, commit, merge, push, or new worktree was made.

## 2026-09-08 — custom in-app task modal (KB-03)

Replaced the separate task-details NSWindow with a centered AppKit overlay in the existing window's plain content host. Rounded document shell, shadow, dim backdrop, fixed screen-space size capped at 960×720, 24-point margins, resize handling and a narrow-width stacked editor layout. Canvas click/gesture/hotkey monitors defer while it is mounted; the HTML dialog cycles keyboard focus internally. Escape retains the existing image-preview/picker-first behavior. Backdrop and Cmd-W close only the task; normal close restores source focus, while Prepare/Create preserve their destination focus. Image picking is a sheet on the existing host window.

A GUI witness caught native Cmd-W racing queued WebKit changes. Native dismissal now reads the live document snapshot before saving and removing the bridge. Save failure retains the editor. Existing undo, image ownership and explicit-send behavior are preserved.

Witnesses:
- RED: `/tmp/kb03-red.log`, existing separate-window implementation fails “task details use the existing canvas window”.
- GREEN: `/tmp/kb03-green-final.log`, 37 interaction assertions including same-window mounting, backdrop hit interception, resizing and removal without losing the canvas.
- `/tmp/kb03-workflow-final.log`: 13 installed-bundle workflow assertions, including actual WKWebView load, native dismissal saving a DOM change that has not crossed the bridge, and failed save retaining the modal. Existing mock-sink handoff/send assertions pass.
- `npm run build --prefix Tools/TaskEditor` and `npm test --prefix Tools/TaskEditor`: passed; 2 existing bridge/document tests. `/tmp/kb03-editor-build.log`, `/tmp/kb03-editor-test.log`.
- Isolated bundle build passed: `/tmp/kb03-build-final.log`. Production app and project untouched; no Git mutations.
- CUA on `/tmp/kb01-preview/Array Dev.app`, `/Users/dylan/kb01-scratch`, `/tmp/kb01-preview/support`: same-window rounded modal visually inspected; Cmd-K does not open the canvas palette while editing; immediate paste then Cmd-W saves the complete title; reopen confirms persistence; original fixture title restored; agent picker Escape; image-picker sheet Cancel returns to modal; Prepare returns focus to the existing composer with independent text/image preserved and agent idle; backdrop closes; Return reopens the selected task; reverse Tab wraps to Prepare within modal. Preview left open on task details. No real agent prompt sent.
- Broader matrix run: `/tmp/kb03-matrix-final.log` (result recorded below when complete). An earlier run `/tmp/kb03-matrix.log` was interrupted before application legs to fix the witnessed close race.

Final matrix result: `CONTINUUM_SKIP_UI_BASELINES=1 CONTINUUM_SKIP_SURFACE_CHECKS=1 scripts/run-matrix.sh --fast` completed all 207 legs. All five board/editor legs passed (workflow, npm, interaction, lifecycle, core board model), along with UI appearance, geometry, contrast, pixel checks and stray-window audit. Four expected KNOWN-RED legs remained. Four additional failures were reported: CoreChecks seed-1 canonical byte count 1644 versus pinned 1639; empty-workspace creation missing Beta; palette-over-browser New Note leaves notes empty; file-tile zoom p95 35.75/36.25 ms versus a 33 ms ceiling. The two palette failures were also in the previous run; the core failure differs from that run and the file-zoom budget failure is newly observed. These were not investigated or changed as part of the modal request. Full gate is not green. Display baseline/surface legs and packaging harness were skipped by the stated flags; the isolated bundle build and installed workflow check were run separately. `git diff --check` passed.

## 2026-09-08 — assignment feedback and modal first-paint follow-up

- Removed the separate Prepare prompt action and redundant handoff explanation from task details. Assignment now attaches the task context and its task-owned images to the destination agent composer automatically. It never sends, does not replace the agent's own text/images, and does not steal focus. Reassignment/unassignment removes the matching task context from the previous agent only.
- The task chip is painted before image copying completes, so the drop has immediate visible feedback even for a large attachment. The persisted composer draft retains it across relaunch.
- Hid the WKWebView until the local task document and snapshot are populated, removing the empty WebKit first-paint flash when task details open.
- Removed the obsolete `Hand this task directly to an agent` fixture card from the isolated `/Users/dylan/kb01-scratch` preview board. No production state was touched.
- Installed workflow witness: `/tmp/kb04-workflow-final2.log`, 19 assertions. New assertions cover covered first paint/reveal, assignment context, preserving independent text, task-only image removal, and no background focus theft. Interaction (`/tmp/kb04-interaction-final2.log`), editor (`/tmp/kb04-editor-final.log`), UI appearance (`/tmp/kb04-ui-final2.log`), isolated app bundle (`/tmp/kb04-bundle-final2.log`), and `git diff --check` pass.
- CUA on the isolated preview witnessed the actual drag: the destination agent tile immediately gained the named task-context chip and the image rail. Relaunch retained both. Task details show only Status, Assignee, and the concise send-explicit note; the old Prepare prompt control is absent. The preview remains isolated at `/tmp/kb01-preview/Array Dev.app`.
- QA mistake: after the drag, Return was pressed while the scratch agent composer still had focus. This submitted the prepared task to the isolated scratch agent; it failed immediately and did not modify repository or production state. The preview record was renamed back to `New agent`. No production agent or project was touched.

## 2026-09-08 — card context menu, assignee icon, modal flicker follow-up

- Every task card now provides a native context menu with Open Details, Move to, Assign to, and Delete Task. Move and assignee submenus mark the current value. Delete routes through `.deleteCard`, so the board undo manager can restore it; move and assignment use the same reducer/app assignment paths as pointer interactions.
- Replaced the wide badge symbol with a configured 12-point `person.crop.circle` and proportional-down scaling.
- Removed the remaining modal flicker source: the entire overlay is now detached while the local WK document loads. After the task snapshot and initial focus script complete, the already-populated modal is mounted in one frame. The previous fix hid WebKit but still mounted an empty modal shell.
- Deterministic interaction witness `/tmp/kb05-interaction-final.log` passes 37 assertions, including the complete menu structure, actual move/assign/delete actions, undoable delete command, and proportional icon at zoom 1 and 0.35. Installed workflow witness `/tmp/kb05-workflow-final.log` passes 22 assertions, including fully detached first paint, populated reveal, same-window containment, backdrop blocking, resizing, latest-edit save, and failed-save retention. Editor tests and UI appearance pass (`/tmp/kb05-editor.log`, `/tmp/kb05-ui-final.log`); isolated bundle passed (`/tmp/kb05-bundle-final.log`); `git diff --check` passed.

## 2026-09-08 — custom card context menu correction

The stock `NSMenu` implementation was replaced after direct product feedback. A
right-click or Control-click now opens Array's token-painted
`ChoicePopoverController` at the pointer. Open Details, Move to, Assign to, and
Delete Task use the same hover, keyboard, accessibility, destructive styling,
edge placement, and outside-click dismissal behavior as the app's other custom
command surfaces. Move and Assign drill into second custom command panels at the
same anchor; current destinations are visibly checked and disabled. Actions still
route through the board command/assignment paths, including undoable delete.

`/tmp/kb06-interaction-final.log` passes 40 assertions. This includes a real
`rightMouseDown` presentation witness against the production custom list, exact
root and drill-down contents, move/assign/delete routing, and the prior drag and
assignee-icon checks at zoom 1 and 0.35. The 21-assertion installed task workflow
also passes in `/tmp/kb06-workflow-final.log`, including the detached-until-ready
modal first paint. `/tmp/kb06-bundle-final.log` records the isolated preview
bundle build, and `git diff --check` passed.
- CUA inspected the refreshed isolated preview. Clicking a card showed the populated details modal directly with no empty shell frame. CUA's click API did not expose a working secondary-button event for the live menu, so the custom panel presentation is covered by the real `rightMouseDown` view witness rather than claimed as a GUI click observation.

## 2026-09-08 — custom metadata selects

The task detail editor no longer contains any native HTML `select` or `Option`
path. Status and Assignee now share one custom control pattern: token-painted
trigger and floating listbox, selected checkmark, hover/focus treatment, arrow,
Home/End and Escape keys, focus return, outside-click dismissal, and ARIA expanded,
listbox, option and selected state. The assignee version retains search and Create
Agent inside the custom panel. Selection continues to emit the existing typed
`status` and `assign` bridge messages.

`npm run build && npm test` passes both TaskEditor suites, including explicit
assertions that no native select remains and that both custom controls present and
emit their bridge values. `/tmp/kb07-workflow.log` passes all 21 installed workflow
assertions, `/tmp/kb07-bundle.log` records the isolated bundle build, and
`git diff --check` passed. The packaged preview was inspected with both custom
listboxes exposed through WebKit accessibility.

## 2026-09-08 — picker pattern alignment

Audited the task-editor controls against the established native `ChoiceButton`.
The first web pass used a rotating text `⌄`, a 39-point trigger, and a permanent
outline. Both task selectors now mirror the shared control contract: a drawn
12-by-12 `chevron.up.chevron.down`, 32-point height, 12-point side padding,
6-point radius, quiet resting boundary, and the same half-point accent line plus
3-point focus/open glow. The list surface now uses the shared 4-point anchor gap,
220-point minimum width, 8-point container padding/radius, half-point boundary,
and 36-point value rows.

TaskEditor build and both npm tests pass in `/tmp/kb08-editor-build.log` and
`/tmp/kb08-editor-test.log`; the bridge test pins the two shared chevron paths and
continues to reject native selects. `/tmp/kb08-workflow.log` passes all 21 workflow
assertions, `/tmp/kb08-bundle.log` records the isolated bundle, and
`git diff --check` passed.

## 2026-09-09 — board tasks in the Array workspace API

- Added provider-neutral `board.query` / `board.apply` contracts and the
  `array_board_query` / `array_board_apply` tools. Pi, native Claude, and native
  Codex share the same names, schemas, host dispatch and role allowlist. Canvas
  kanban tile projections now include `boardId`.
- `board.query` discovers open or closed project boards through the durable board
  index and returns deterministic summaries or revision-bound paginated task
  snapshots. Task snapshots include Markdown, typed path-free links, attachment
  metadata, assignee, column and card identity.
- `board.apply` supports create, edit, move, assign, unassign and delete. Complete
  create/edit operations are atomic BoardEngine commands. The host validates
  operation-specific fields, project agent/tile identities, revisions and retry
  keys; positional writes can rebase surviving anchors. Every successful call
  persists before broadcast, updates every open tile, and registers one board undo.
- Board assignment side effects now run from one post-commit callback regardless
  of whether the commit came from UI, API, lifecycle automation, undo or redo.
  Assigned task content refreshes the composer without sending or stealing focus;
  reassignment, unassignment and deletion remove only that task from the old agent.
- The composer captures `BoardTaskContext` at the accepted-send boundary. The
  runtime advances a still-assigned task from the first ordered lane to the end of
  the second through the normal durable command path. Refused sends, stale owners,
  pointer-held tasks, one-column boards and tasks already beyond the first lane do
  not move. Completion does not mark Done; the agent must call `board.apply`.
- Attached prompt context now carries `boardId`, `cardId` and `observedRevision`,
  so the working agent can query the exact task again before changing it.

Verification:

- Builds passed for `Array`, `ContinuumRevivedCoreChecks`, and
  `array-workspace-mcp`.
- Targeted gates passed: `--board-model-check`,
  `--workspace-api-board-contract-check`, `--workspace-api-contract-check`,
  `--workspace-api-canvas-contract-check`, `--workspace-mcp-check`,
  `--role-registry-check`, `--pi-host-tool-bridge-check`,
  `--workspace-api-board-check`, `--board-task-workflow-check`,
  `--workspace-api-canvas-check`, `--workspace-mcp-host-check`,
  `--pi-extension-load-check`, and `--strict-agent-harness-check`.
- The board host witness exercises Workspace Tools denial/enabling, closed-board
  discovery, create/edit/move/assign/unassign/delete, persistence, live broadcast,
  undo, strict conflicts, anchor rebasing, cursor expiry, idempotent replay and
  payload conflicts, missing identities, pointer refusal, automatic start-work,
  explicit Done and the one-column/stale-owner guards.
- The packaged task workflow and packaged native MCP transport both passed from
  `/tmp/kb01-preview/Array Dev.app`. The isolated preview was rebuilt and relaunched
  with `/Users/dylan/kb01-scratch` and `/tmp/kb01-preview/support`.
- The new board API leg is registered in `scripts/run-matrix.sh`.
- `git diff --check` passes. No staging, commit, merge, push, global provider
  configuration change, production app change, or production project change was
  made.
