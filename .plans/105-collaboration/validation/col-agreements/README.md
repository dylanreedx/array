# COL-12 receipt: durable discussion, revisioned agreements, endorsements

30 October 2026. Bench `.worktrees/mp-pair`, branch `array/col-agreements`
from `cc168bed`. Local only; nothing pushed.

## What changed

- **Endorsement** (`SharedArea.Edit.endorse`): one authenticated person and
  one immutable agreement revision. The reducer refuses a superseded or
  unknown revision (`conflict` / `invalidReference`) and a repeat
  (`duplicateIdentity`). A new revision starts with none. Snapshots validate
  endorsements on decode. The field is additive: a document with no
  endorsements keeps its old canonical bytes, and older snapshots decode.
- **Service authoring**: `CollaborationStore.authorize` refuses an
  endorsement naming anyone but the caller. A viewer cannot endorse, because
  endorsing needs `discuss`.
- **Controller**: `endorse(_:)` endorses the displayed revision.
  `rebaseDraft(id:)` re-pins a stale agreement draft to the current revision
  without sending anything.
- **Native UI**: `SharedAreaAgreementView` shows the current revision, its
  endorsement count ("endorsed by you and 1 teammate") and an Endorse
  control. A stale draft gets a Rebase draft action. The copy reads "Shared
  instructions for people and their agents. Array does not enforce them."
  It uses `ComposerActionButton` and token text colours, and it is not a
  `TokenThemed` view.

## Witnesses (all in existing default runs)

| Acceptance | Witness |
| --- | --- |
| Endorsement bound to its revision, persisted, replayed, restored | `ContinuumRevivedCollaborationChecks`, `PASS agreements:` reducer lines |
| Concurrent edits: explicit conflict, both drafts kept, deliberate rebase | same, localhost HTTP A/B; `--collaboration-native-check` stage "agreements and endorsements" |
| Author validation (post, revision, endorsement) | HTTP A/B 403 lines; `ContinuumRevivedCollaborationServiceChecks` "endorsement authority" |
| Readable after the author's host sleeps; restart; late joiner | HTTP: A's controller, local store and host journal deleted, service restarted on the same SQLite, fresh B replica and late joiner C compare canonical bytes |
| @mention / agent-addressed posts dispatch nothing | HTTP: 100 posts, then the host dispatcher polls; runner callback 0, journal attempts unchanged, `agent_dispatches` rows 0, pending 0. Positive control: one deliberate prompt moves each counter by exactly one. Native: supervisor executor census unchanged |
| Boundaries read as instructions | native guidance assertion; renders below |

## Teeth (compile-valid mutation, RED, exact restore, rebuild, GREEN)

Logs are in `teeth/`.

| Mutation | RED on |
| --- | --- |
| `endorsements(of:)` returns every endorsement on the agreement | "an edit creates a new revision with zero endorsements…" |
| Reducer drops the agreement parent check (conflict overwrites) | reducer "expected refusal: conflict"; native "B's save against revision 1 conflicts…" |
| Service drops the endorsement author check | service "an editor cannot endorse on the owner's behalf" |
| Agreement strip counts endorsements of any revision | native "B's endorsement of revision 1 is not shown on revision 2" |
| `rebaseDraft` keeps the old base | native "rebasing pins B's exact text to revision 2…" |

Each restore was checked with `git diff --quiet HEAD -- <file>` before the
GREEN rebuild.

## Renders

Light and dark offscreen renders of the mounted scene were inspected. Both
show the revision line, the Endorse control and the two-line instruction
copy. The first copy was cut off at three lines and was shortened.

## Gate

`scripts/run-matrix.sh --collaboration` at `6f23b01f`: "Collaboration matrix
(targeted): 10 leg(s) run … passed", exit 0. Inside it, 32 `PASS agreements:`,
13 `PASS shared agreement scene:` and 4 `PASS endorsement authority:` lines
ran, and `--ui-probe-check` passed with the new strip mounted. The
"inventory grew: --menu-contract-check" note predates this branch. The
inventory file was not committed.

## Left open

- People are shown as "you" and "N teammates". The shared state carries no
  person labels yet.
- Endorsement has no withdraw. A withdraw would need its own edit.
- The scripted authority in the native check runs the real reducer. The
  real service's rules are witnessed over HTTP, not inside the app process.
