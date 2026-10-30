# Multiplayer acceptance matrix

Living record, kept by worker 10 (COL-21/22) on `array/mp-w10-acceptance`.
Started 30 October 2026 at `cc168bed`; updated as worker branches land.

Each row is one ORIGINAL acceptance criterion from the board card, cut down to
its testable claim. Status:

- **W** — witnessed: a behavioural check reports it. The witness is named.
- **P** — partial: some of the claim is witnessed; the gap is named.
- **G** — gap: no witness. Who owns it, if anyone.
- **L** — "Later" card, deliberately out of scope until Dylan picks it up.

Evidence authority for rows marked W at `cc168bed`: the `Merged` section of
`PROGRESS.md` (10/10 collaboration gate, pair 3/3, kill/relaunch, 1,500-event
scale) and the retained reports in `validation/merged-cc168bed/`. Rows added
by this bench name their own run.

Witness short names:

- `svc` — `ContinuumRevivedCollaborationServiceChecks` (default run: A/B/C HTTP,
  updates, client boundaries, key, capabilities, handoff, usage, recovery/scale,
  backup/restore, operator recovery). Also runs on Linux via
  `scripts/check-relay-linux.sh`.
- `col` — `ContinuumRevivedCollaborationChecks` (reducer, publication,
  controller, local store, geometry ledger, host dispatch, kill/relaunch,
  overload, usage).
- `native` — `Array --collaboration-native-check`.
- `pair` — `scripts/check-collaboration-pair.py`, two real background Array
  processes on a local relay (15 behaviours).
- `features` — `scripts/check-collaboration-pair-features.py`, the second pair
  journey for features landing now. Stages are PENDING until their peer ops
  exist; see the contract at the end.
- `backup` — `svc --backup-restore-only` (this bench).
- `ui` — `Array --ui-probe-check`, `--menu-contract-check`.

## Phase 0–1

| Card | Criterion | St | Witness / gap |
| --- | --- | --- | --- |
| COL-01 | Three share entry points use one membership/manifest model; unsupported kinds explicit | W | `native` capture journey; `col` publication review lists unsupported rows |
| COL-01 | Server-visible content, retention, key lifecycle, revocation documented; companion ciphertext preserved; E2EE decision | P | `DECISIONS.md` + `docs/internals/collaboration.md` "Ownership and trust". Retention and key ROTATION are not written yet (COL-19/22). |
| COL-01 | Native-first, separate checkout, observation vs publication vs execution recorded | W | `DECISIONS.md` |
| COL-02 | No default tmux, production relay, real CLI login or live project state | W | `pair` (tmux socket asserted inside namespace; local relay; scripted provider) |
| COL-02 | Injected clocks, dropped/duplicated/reordered frames, host restarts, transaction failures | W | `svc` injected clock + operation-insert trigger; `pair` proxy hold/kill; `col --kill-relaunch-only` |
| COL-02 | Assertions on delivered bytes, mounted frames, source files, runner counts, outcomes | W | `svc`, `native`, `pair` |
| COL-03 | Multi-project capture keeps source ownership and area-relative geometry | W | `col` reducer + `native` capture |
| COL-03 | Atomic groups; nonfinite frames and dangling references refuse | W | `col` |
| COL-03 | Operation ID + digest separates retry from changed intent; deleted IDs cannot resurrect | W | `col`, `svc` |
| COL-04 | Two people with independent hosts join; a third cannot enumerate or fetch | W | `svc` A/B/C (identical 404 bytes) |
| COL-04 | Expired/consumed invites, forged authorship, cross-area IDs refuse; history-on-join explicit | W | `svc`; doc states "all retained history" |
| COL-04 | Removal invalidates reads/writes/pending actions on active clients | W | `svc` updates + handoff (queued prompt refused) |
| COL-05 | Discussion/layout survives restart, area-isolated | W | `svc` reconstructed HTTP service |
| COL-05 | Identical retry returns original; changed content under same ID refuses | W | `svc` |
| COL-05 | Snapshot replacement scoped to one area | W | `svc`, `backup` (three areas restore independently) |
| COL-06 | >500 retained operations replay with no gap or duplicate | W | `pair` 552 events; `svc --recovery-scale-only` 1,500 |
| COL-06 | Slow subscribers resync durable content; only presence drops | W | `svc` updates/overload |
| COL-06 | Access removal closes open streams | W | `svc` |
| COL-06 | Host liveness and pointer TTL expire independently | P | Pointer TTL W (`svc`). Host liveness: worker 5 (`mp-w5-liveness`, uncommitted). `features` stage `liveness`. |
| COL-07 | Region exposes only reviewed members/history, incl. attachments and nested artifact lookups | P | Text/reference allowlist W (`svc` capabilities). Nested artifacts: worker 6 + worker 9. |
| COL-07 | Pointer/source ID/client principal never grants access; host records stay local | W | `svc` forged grants; `col` sentinels |
| COL-07 | View/discuss/layout/prompt/stop/approval/terminal/sharing rights distinguishable | P | Capability enum W. Approval and terminal are named but have no actions yet (COL-26). |
| COL-08 | Join/remount preserves local registry ownership and source canvas bytes | W | `native`, `col` local store |
| COL-08 | One source, many views, exactly one runner | W | `native`, `pair` (recipient executors 0) |
| COL-08 | Missing objects render unavailable; removing a view never deletes or kills; incompatible schema preserves store | W | `col`, `native` |

## Phase 2

| Card | Criterion | St | Witness / gap |
| --- | --- | --- | --- |
| COL-09 | Drag selection previews, permits correction; cancel changes nothing | W | `native` capture |
| COL-09 | Hover lift excluded; negative origins; multi-project ownership | W | `native` capture |
| COL-09 | Whole zone/workspace names unavailable/unsupported members; later border crossing never publishes | W | `native` inventory + capture |
| COL-10 | Different world origins see the same arrangement | W | `native` |
| COL-10 | Mount/close/removal never spawn a recipient executor or retidy source zones | W | `native`, `pair` |
| COL-10 | Shared clicks never fall back to an unrelated local project | W | `native` window command scope |
| COL-11 | Group action cannot partially commit or split frames | W | `col` geometry, `native` |
| COL-11 | Undo reverses only the local action, never a stale whole document | W | `pair` stale-Undo steps; `col` ABA guard |
| COL-11 | Permission loss mid-gesture cancels commit | G | Worker 1 (`mp-gate`, `array/col-scene-gestures`) |
| COL-11 | Failed-save schedules through mounted clients | G | Worker 1 |
| COL-11 | No divergent automatic-layout pushes on peers | W | `native` geometry |
| COL-12 | Discussion or @mention never dispatches to an agent | W | `pair` (zero runner calls from discussion/replay) |
| COL-12 | Concurrent agreement edits keep both drafts and surface a conflict | G | Worker 2 (`mp-pair`, `array/col-agreements`, 2 commits). `features` stage `endorsements`. |
| COL-12 | Endorsements identify the revision | P | Worker 2 committed `3a9abe8c`, `6f23b01f`; not merged; no pair witness yet |
| COL-12 | Accepted discussion readable after the execution host sleeps | G | Needs COL-06 liveness; `features` stage `liveness` asserts it |
| COL-12 | Boundaries described as instructions, not filesystem restrictions | P | Doc copy; no UI copy check |
| COL-13 | Own-agent dispatch and accepted teammate suggestions keep provenance and exact content | W | `pair` handoff; `svc` handoff |
| COL-13 | Host rejects removed membership, stale generation, invalid content; local paths cannot bypass | W | `svc` handoff |
| COL-13 | No blind resubmission; requested/accepted/queued/observed/unknown distinct | W | `col --kill-relaunch-only` four boundaries |
| COL-13 | Transport seam proof for Claude, Codex AND Pi | G | Worker 4 (`col-provider-seams`). The pair's source runner is the Codex scripted seam only. `features` stage `harnesses`. |
| COL-14 | Changed-since-sent per agent; never implies receipt/compliance | P | Worker 8 committed `d1d8bba5` (accepted revision per agent); not merged. `features` stage `freshness`. |
| COL-14 | Editing the agreement never rewrites accepted execution input | P | `svc` handoff immutable context W; per-agent record is worker 8 |
| COL-14 | Result excerpts keep source turn, host, artifact revision | G | Worker 8 |
| COL-15 | Late join gets snapshot + every allowed tail event or explicit resnapshot | G | Worker 7 (`mp-w7-live`). `features` stage `liveViews`. |
| COL-15 | Private history/raw side channels never cross; remount creates no executor | P | No-executor W (`pair`); history crossing is worker 7 |
| COL-15 | Controls follow the bound runner's real capabilities; interrupt is not kill | G | Worker 7 |
| COL-16 | Selected and explicitly included bytes have accurate coverage; excluded never uploads | G | Worker 6 (`mp-w6-artifacts`). `features` stage `artifacts`. |
| COL-16 | Live latest and revision under review stay distinct; changes invalidate applicability | G | Worker 6 |
| COL-16 | Recipient checkout byte-identical; large blobs use bounded storage | G | Worker 6; `features` asserts recipient `sourceFiles` unchanged |

## Phase 3–4

| Card | Criterion | St | Witness / gap |
| --- | --- | --- | --- |
| COL-17 | Claude not double-counted; Codex cumulative differenced; Pi duplicates/cache defined | P | Codex high-water and Pi translation W (`col`, CoreChecks `--collaboration-usage-telemetry-check`). Claude request/run overlap: worker 4. |
| COL-17 | Reconnect, subagent overlap, forks and repeated views do not inflate | P | Reconnect + repeated views W (`pair` 200/40). Forks/subagents/counter reset: worker 4. |
| COL-17 | Day boundaries, timezone and aggregate scope explicit | W | `col` UTC fixtures |
| COL-18 | Different anchors/zooms point at the same content | W | `native` hover |
| COL-18 | Local navigation exits follow without feedback loops | G | Worker 1. `features` stage `follow`. |
| COL-18 | Token period/scope/coverage on hover/focus only; no permanent overlay | W | `native` hover + always-visible mutant RED; `pair` |
| COL-18 | Offscreen/away/stale usable; pointer traffic = zero transcript measurements, saves, model calls | G | No count-based presence budget exists. See "Native budgets" below. |
| COL-19 | >500-event and post-compaction reconnect loses nothing, resurrects no deletion | P | >500 W. Post-compaction: worker 3 (`mp-recovery`). `features` stage `compaction`. |
| COL-19 | Revocation/epoch and receipts survive compaction; unsupported schema keeps state | P | Unsupported schema W (`col`). Revocations/receipts survive RESTORE W (`backup`). Compaction: worker 3. |
| COL-19 | Offline executable actions expire/reconfirm; ambiguous submission never repeats | W | `col --kill-relaunch-only` |
| COL-20 | Excluded participant gets no bytes through guessed IDs, history, previews, caches | P | A/B/C W for areas. Artifacts/previews: worker 9 after worker 6. |
| COL-20 | Removed member loses socket/blob/action; stale queued work cannot regain authority | P | Socket/action W. Blob: worker 9. |
| COL-20 | Logs carry no content or credentials; storage/key/retention matches the trust contract | P | DB bytes exclude plaintext and tokens W (`svc`, `backup`). Log audit: worker 9. Retention: worker 3. |
| COL-21 | Two people replace prompt-file exchange (discussion, agreement, own-agent delivery, pinned artifacts); C excluded | P | Everything but pinned artifacts W (`pair`). Artifacts: worker 6. |
| COL-21 | Actual production mount and visible frames; no checks-only path | W | `native` drives `mountWorkspaceSceneAtBoot`; `pair` uses real processes |
| COL-21 | Native light/dark, token census, keyboard, Reduce Motion, presence/transcript budgets; matrix reports new legs | P | Light/dark + census + keyboard W (`ui`, `native`). Reduce Motion and count budgets: G, see below. New legs: registration hunks pending with lead. |
| COL-22 | Disposable multi-area dataset restores with membership, artifacts, outcomes intact; revoked credentials stay invalid | P | `backup` W on Mac (33 assertions; mutant RED). Linux run: see below. Artifacts not in the dataset until worker 6 lands. |
| COL-22 | Linux packaging and companion regression checks pass; no production instance silently migrated | P | `scripts/check-relay-linux.sh`: see Linux line below. Production untouched: the operator commands never open the companion DB (asserted). |
| COL-22 | Measure usage/storage/fanout before capacity claims; notification IDs if invites deliver; release runbook | G | No measurement yet. Invites send no notification (doc), so no path ID owed today. |
| COL-22 | Staged operational rehearsal under separate authorization | G | Needs Dylan. Steps in `ALPHA-HANDOFF.md`. |
| COL-23–26 | (Later) | L | Not started by instruction |

## This bench's evidence

- `backup` on Mac: `validation/backup-restore/green.log`. Teeth:
  `mutant-no-audit-red.log` (verification without the record audit accepts a
  damaged backup → RED on that assertion) and
  `mutant-recovery-keeps-devices-red.log` (recovery that keeps the lost devices
  → RED).
- Linux (`bash scripts/check-relay-linux.sh`): run 1 used the bench before the
  recovery commits. Result recorded here when it finishes.
- `features` smoke on the cc168bed Array binary: setup + final invariant PASS,
  all 8 stages PENDING (`--allow-pending`).

## Native budgets and accessibility still owed (COL-18/21)

None of these exist. They need counters in `SharedAreaPresenceOverlay` /
`SharedAreaSceneView`, which worker 1 is editing, so they wait for that branch.

1. Presence flood: N cursor updates inside one display interval cause at most
   one overlay redraw per visible teammate and show the last position; zero
   canvas saves, zero transcript measurements, zero model writes. Teeth: an
   overlay that redraws per update.
2. Closed hover: usage reports advance the ledger but mount no card and measure
   no text while nothing is inspected.
3. Follow under Reduce Motion: following jumps the camera instead of animating.
4. Keyboard parity: every teammate cursor reachable and inspectable without a
   pointer (exists for inspection; repeat for follow once it lands).
5. Shared live view (after COL-15): one delta visits changed + visible rows
   only, flat across 10 / 100 / 1,000 rows.

## Pair feature journey contract

The peer runtime (`SharedAreaPeerRuntime.swift`) answers an unknown op with
"unknown peer command", which makes a `features` stage PENDING. Once a feature
merges, its mailbox op and status field get added to the peer runtime with
these names. Names can change; change them here and in the script together.

| Stage | Card | New ops (peer) | New status fields |
| --- | --- | --- | --- |
| liveness | COL-06/12 | A `hostSleep`, `hostWake` | B `hostLiveness`: `live` / `unavailable` |
| artifacts | COL-16/07 | A `publishArtifact {path, text}` → `{digest}` | B `artifacts`: `[{digest, latest}]` |
| liveViews | COL-15 | — (uses `localSend`) | B `agentView`: `{generation, sequence}` |
| freshness | COL-14 | A `localSendWithContext` | A `deliveredRevision`; B `changedSinceSent` |
| endorsements | COL-12 | B `endorse` | A `endorsements`: `[{revision, person}]`; B `agreementConflict`, `agreementDraft` |
| follow | COL-18 | B `follow {device}` | B `following`: device or null |
| compaction | COL-19 | A `compact` (drives the service's compaction) | — |
| harnesses | COL-13 | A `handoffReclaim`; config `sourceHarness` | ready/status `sourceHarness` |
