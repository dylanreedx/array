# Worker 8: COL-14 per-agent context freshness and provenance excerpts

30 October 2026. Bench `.worktrees/mp-w8-freshness`, branch
`array/mp-w8-freshness`, rebased onto `array/collaboration-finish` at
e17d0a52. The earlier commits (d1d8bba5, 7023cda1, 20c7fc46) were merged
there by the lead. Not pushed. The integrator (42F5389C) merges this branch.

Commits in this round:

- `c7d7f919 feat(collaboration): show per-agent agreement freshness and shared excerpts`
- the docs commit that records this report

## What a person sees

- **Agent selected.** The inspector shows "Agreement context". It reads, for
  example, "Last accepted revision 2 · Current revision 4 · Changed since
  sent", with this caveat underneath: "Accepted by the agent's host. Not a
  record that the agent read or followed it."
  - An in-flight send appears as a notice beside the baseline: "Revision 4 is
    waiting for the host to accept it."
  - So does a failed one: "Revision 4 was refused by the host and was not
    delivered."
  - Neither moves the baseline.
  - The panel has no send button. A newer revision reaches an agent only
    through the existing deliberate handoff.
- **No receipt on this device.** The panel says "No accepted revision recorded
  on this device", never "not sent". Receipts are visible only to their
  requester and the agent's owner; the lead decided to keep that.
- **Host session unconfirmed.** The panel says "Waiting for the agent's host to
  confirm its current session."
- **Discussion.** A post can carry a frozen agent result. The reader shows:
  - the note and the quote;
  - the source line, "Turn turn-7 · event 42 · host … · session … · artifact
    revision … (digest prefix)";
  - one availability line: from the agent's current session; original
    unavailable because the agent left or its session was replaced; original
    not checked; artifact changed, removed or not checked.

## Code

- **Protocol: excerpt field.** `SharedArea.Post.excerpt:
  Collaboration.ResultExcerpt?` is additive. Posts without it encode exactly
  as before, and old snapshots decode.
  - Snapshot validation checks well-formedness, area, author and that the
    source and artifact objects are known.
- **Protocol: export rule.** The reducer enforces it. Only the agent's owner may
  post its result, from an agent and artifact currently in the area, with
  `capturedBy == author`. The service already binds the author to the caller.
- **Protocol: availability.** It gained `sourceUnchecked` and
  `artifactUnchecked`. A lookup that wasn't confirmed is no longer reported as
  "replaced" or "removed".
- **Core: `SharedAgentFreshnessModel`.** This is the scene's read model over the
  ledger at `<handoff area directory>/freshness`. That is the path worker 4's
  `SharedAgentHandoffController` hook writes (col-provider-seams, confirmed).
  - It looks up the host generation through `transport.control(object:)`.
  - It looks up the artifact's latest revision through w6's `artifactState`,
    when the transport is the HTTP API.
  - It notices another connection's ledger writes via `PRAGMA data_version`,
    polled every 2s.
  - It re-reads identities on each document revision and every 30s.
  - It has no dispatch path.
- **App: panel.** `SharedAreaAgentFreshnessView` holds the panel and
  `SharedAreaExcerptPresentation`. `shareResultExcerpt(_:into:note:)` posts
  through the production controller.
- **Shared-file insertions.** `SharedAreaSceneView` gains the panel, its layout
  slot, the discussion entry mapping and a refresh hook (+23 lines).
  `ContinuumApp` gains one production line, `shared.scene.agentFreshness`, at
  the hub's area open, plus the native-check stage.

## Acceptance criteria → witness

| Criterion | Witness |
| --- | --- |
| Changed-since-sent is per agent and never implies receipt or compliance | Native stage 1–3: two agents show revisions 2 and 3 in one mounted scene, and both are stale after revision 4. Queued shows only as waiting. The caveat is asserted present and unclipped. Core HTTP steps 1–3 cover the same. |
| Editing never rewrites accepted execution input | Native stage 3: the frozen command still carries revision 2. Core step 3: the service copy and host journal match, and a rewrite is refused. |
| Excerpts keep source turn, host and artifact revision; unavailable originals are labelled | Native stage 5: the exact source line renders, and "not checked" shows for the artifact. Stage 7: a rebind shows "session was replaced". Core step 10: replay to the teammate keeps the exact source. Core steps 5 and 8 cover removed sources and artifacts. |
| Persists across restart | Native stage 6: scene, controller, handoff client and model are rebuilt from disk, with identical markers and the refusal notice. Core step 6. |
| No automatic extra dispatch | Native stages 3 and 6: send count is unchanged after the edit and the relaunch, and there are zero executors. Core steps 3 and 6: host pending is empty and acceptances are unchanged. |
| Export rule | Native stage 5: the teammate's share is rejected. Core step 10: the HTTP response is 400. |

Witness homes:

- `SharedAreaFreshnessSceneChecks` is a stage in `--collaboration-native-check`,
  mounted through `mountWorkspaceSceneAtBoot`. It makes 17 assertions.
- `SharedAgentFreshnessChecks` runs in `ContinuumRevivedCollaborationChecks`
  over real localhost HTTP. It makes 24 assertions.
- Both legs already run in `--collaboration` and in the full matrix. No new
  leg and no inventory change.

## Teeth (RED → restore → GREEN)

- **Ledger:** refused or uncertain receipts advance the baseline → RED.
- **Ledger:** the frozen-command digest guard is removed → RED.
- **Ledger:** the baseline is keyed by object only → RED. (These three ledger
  cases are from the earlier round.)
- **Reducer:** the owner-only export rule is removed → Core RED at "a teammate
  cannot export a result from an agent they do not own".
- **Panel:** the caveat frame is reduced to one line, which is the clipping bug
  the first render showed → native RED at "selecting an agent shows its
  agreement context with the host-acceptance caveat".
- **Scene:** the discussion reader goes back to `.map(\.text)` → native RED at
  "excerpt rendered".

Each mutation was restored, by `cmp` against the backup, before the commit.

## Gate

`scripts/run-matrix.sh --collaboration`, run once under the app-build lock
(isolated `CONTINUUM_APP_SUPPORT` and `TMUX_TMPDIR`,
`CONTINUUM_SKIP_UI_BASELINES=1`, at c7d7f919):

- "Collaboration matrix (targeted): 10 leg(s) run … passed."
- Exit 0.
- The log printed all 17 `PASS shared freshness scene` lines and all 24
  `PASS freshness` lines.
- One standing note: `--ui-probe-check` skips its display-dependent
  surface-cache witness.

Light and dark offscreen renders of the panel were inspected. The token text
colour re-resolves per appearance (asserted).

## Left

- **Composing excerpts.** No control picks an agent result to quote yet.
  `shareResultExcerpt` is the entry point; worker 7's live view owns the
  selection.
- **Turn shapes.** Turn and sequence are still provisional
  (`turn: String`, `sequence: UInt64?`). Worker 7 owns adjusting them, per the
  lead.
- **Teammate visibility.** It stays limited to the requester and the agent's
  owner. A wider projection is recorded as a decision for Dylan.
- **Same-binding restarts.** A runner restart under the same binding keeps its
  host generation. A per-session incarnation needs COL-13/15 identity.
- **Linux.** The container build was not run. The new protocol code uses only
  Foundation and Crypto.
