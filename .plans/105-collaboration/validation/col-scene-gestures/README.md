# COL-11 / COL-18 scene gestures — receipt

30 October 2026. Bench `.worktrees/mp-gate`, branch `array/col-scene-gestures`,
based on `cc168bed`. Commits:

- `c27e4927` fix(collaboration): cancel shared drags on access loss and failed saves
- `c69f9638` feat(collaboration): follow a teammate's view from their cursor

All witnesses run inside the existing `--collaboration-native-check`, so
`scripts/run-matrix.sh --collaboration` reports them. No new leg was added.

## COL-11 — shared geometry (SharedAreaGeometrySceneChecks)

Two production-mounted scenes (`mountWorkspaceSceneAtBoot`) on one scripted
authority. The authority can now downgrade or revoke a member and bumps the
membership epoch when it does.

- **Permission loss during a group drag.** B shift-selects two cards and drags.
  The authority downgrades B to viewer mid-drag. The gesture cancels on that
  authority frame; B's two cards are back on their exact pre-gesture frames;
  further drag and release send nothing; B's geometry ledger generation, Undo
  count and pending intent are unchanged; A's frames and both replicas are
  exact. B's access is then restored.
- **Revocation during a group resize.** B pulls the group's resize handle and
  is revoked mid-drag. The gesture cancels, the shared frames are withdrawn,
  release commits nothing, and A keeps exact frames.
- **Failed pre-effect ledger save.** `StoreFileWriter` fails A's ledger write
  at commit. Nothing reaches the authority; A's frames return to the last
  accepted state; B's replica and rendered frames are unchanged; the ledger
  generation is untouched. A second identical drag then commits exactly once
  and lands on exact frames on both clients.

Fixes behind them, in `SharedAreaSceneView`:

- every authority frame now rechecks edit permission, not only the release;
- a failed ledger save keeps geometry available when disk proves the write
  never landed (same generation, no pending intent). Before, any failure
  disabled every later move until a manual delivery check.

## COL-18 — voluntary follow (SharedAreaPresenceChecks.runFollow)

Leader 1000×760, follower 1280×700, different starting cameras and zooms,
both with live `SharedAreaPresencePublisher`s on a scripted presence
authority whose frames carry no document change.

- **Entry.** Pointer: hover the leader's cursor, press Follow in its card
  (only that button takes the pointer). Accessibility: the cursor element's
  custom action "Follow Peer Leader's view".
- **Tracking.** The follower's canvas centre equals the leader's viewport
  centre and its zoom fits that viewport; the same shared card resolves to the
  same area point on both; it follows three leader moves.
- **Exit.** Arrow-key pan, pointer pan, scroll, zoom to fit, and grabbing
  shared content each end follow at once; afterwards leader moves no longer
  move the follower, and the follower publishes its own viewport again.
- **No loop.** A follower publishes no viewport. Follower publications never
  move the leader's camera; the leader's attempt to follow back is refused
  with a visible reason.
- **Stops.** Viewport withdrawn ("view is off screen"), presence ended
  ("left"), and presence expired with no further frame ("is away", caught by
  the publisher's 1 s timer) each stop follow with a visible banner. The last
  view is kept and saved at most once.
- **Bounded work, across follow traffic.** Zero `StoreFileWriter` mutations
  under the fixture root except the leader's own camera navigation (covers
  canvas, shared-state and ledger saves); unchanged transcript measurement
  counters (`AgentTranscriptListView.qaTotalLayoutPasses`,
  `CodeTextView.qaUnwrappedMeasurementCount`, `BandTextWidth.qaMeasurements`,
  `FileMarkdownDocumentView.qaTotalMeasurePasses`,
  `AgentTableView.qaNaturalWidthSolves`); zero executor constructions; zero
  shared operations and usage reports; zero private camera writes per frame.

Follow lives in the publisher and the scene's private camera only. It never
writes the shared document or a source project.

Renders (`renders/`), inspected in light and dark: the active follow banner
with the card's Stop following button, and the "is away · stopped following"
banner. The overlay is not a `TokenThemed` view, so no census entry changed.

## Teeth (`teeth/`)

Each mutation is compile-valid; the exact source bytes were restored
(sha256 match) and rebuilt before GREEN.

| Mutation | RED on | Restored |
| --- | --- | --- |
| original code, no permission recheck | losing edit permission cancels the live group drag at once | GREEN |
| original code, failed save disables geometry | Timed out: a later gesture is accepted | GREEN |
| skip the permission-loss cancel | losing edit permission cancels the live group drag at once | GREEN |
| skip restoring frames after a failed save | frames return to the last accepted state and the peer's replica is unchanged | GREEN |
| always disable geometry after a failed save | Timed out: a later gesture is accepted | GREEN |
| local navigation does not stop follow | a keyboard camera pan exits follow immediately | GREEN |
| follower keeps publishing its viewport | Timed out: follower withdraws its own viewport | GREEN |
| save the private camera on every followed frame | tracked camera frames are applied without saving the private camera per frame | GREEN |
| ignore presence expiry | Timed out: stale presence stops follow without another frame | GREEN |

## Gate

`CONTINUUM_SKIP_UI_BASELINES=1 scripts/run-matrix.sh --collaboration`, run once
in the bench after both commits:

```
---- Collaboration matrix (targeted): 10 leg(s) run ----
NOTES (1):
  - --ui-probe-check: App theme surface-cache witness skipped with display-dependent checks; native theme persistence and token checks still run.
Collaboration matrix (targeted) passed.
```

10 legs, 10 passed, 0 failed. The one display-dependent theme witness was
skipped by the baseline flag. No baseline was updated.

Not exercised: real Keychain, providers, a production relay, the default tmux
server, a normal or preview app launch, and focus or activation.
