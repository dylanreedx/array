# Worker 5 — COL-06 host liveness

30 October 2026. Bench `.worktrees/mp-w5-liveness`, branch `array/mp-w5-liveness`,
rebased onto `array/collaboration-finish` at `e17d0a52`. Nothing pushed or
merged, no matrix inventory commit, no stash.

## What it does

Before this, the only sign that a teammate's machine was alive was their pointer,
which expires after 15 s for unrelated reasons (they stopped moving or closed the
view). A host machine now proves it is alive on its own:

- **Heartbeat.** The app's `SharedAreaHostSession` beats every 10 s for the host it
  publishes from, per area. Only the device that registered the host, while it is a
  current member, can beat for it (else 403/404/401).
- **Run generation.** Each hosting session mints a new generation. When a relaunched
  app beats, the relay retires the old generation and refuses any later packet from
  it (409), including after a relay restart, because the fence is in SQLite. A
  refused run stops; it never mints a replacement, so two runs cannot take turns
  owning a host. This is separate from the persisted *binding* generation that agent
  control CAS uses.
- **Projection.** `Collaboration.Updates.hosts` (optional, so older relays decode)
  carries online → stale (30 s without a beat) → offline (90 s, or at once on a
  clean end or loss of access). Held readers wake at the next transition with no
  other traffic.
- **Cards.** Agent cards and the reader say "Host online.", "Host not responding.
  Its agents may still be running.", "Host offline. Execution is unavailable." /
  "…Its owner closed the shared workspace." / "…It no longer has access.", or "Host
  has not checked in." Discussion stays readable while the host is offline.
- **Handoff dialog.** With Send now chosen and the host not online, a warning names
  the state and the action reads "Send now anyway". Queue for next turn shows no
  warning. The warning never blocks a deliberate send. The host session forwards
  every controller change to an open dialog.
- **Controller API for live views (worker 7).** `SharedAreaController`
  `hostLiveness` (all hosts), `hostLiveness(for: host)`, `hostLiveness(forObject:)`
  and `isHostOnline(forObject:)` — true only for `.online`; stale, offline and
  never-seen are all false. File: `SharedAreaController+HostLiveness.swift`.

## Commits

See `git log array/collaboration-finish..array/mp-w5-liveness`.

- feat(collaboration): add authenticated host heartbeats with run generations
- test(collaboration): witness a host lost, expired, rejoined and fenced over HTTP
- feat(collaboration): show host liveness on shared agent cards
- test(collaboration): witness host liveness through the production client
- feat(collaboration): warn before Send now to a host that is not online
- test(collaboration): render host liveness cards and the send-now warning
- test(collaboration): damage a page header in the backup verification check

## Witnesses (all inside existing default legs of `--collaboration`)

- `ContinuumRevivedCollaborationServiceChecks` (default; `--host-liveness-only`):
  31 `PASS host liveness:` lines, real localhost HTTP, injected relay clock. Auth
  refusals; pointer expires while the host beats; host stale while the pointer
  moves; a held 25 s read wakes at the offline transition in under 5 s; rejoin under
  a new generation; retired run refused before and after a relay restart; replayed
  sequence does not refresh last-seen; clean end immediate and not revivable; a
  removed member's host offline at once.
- `ContinuumRevivedCollaborationChecks` (default; `--host-liveness-only`): 11 `PASS
  host liveness client:` lines through the production account factories, the
  handoff-transport cast the session uses, `SharedAreaHostHeartbeat` and a
  teammate's real `SharedAreaController` session.
- `Array --collaboration-native-check`, stage "host liveness on cards and before
  Send now": 24 `PASS host liveness native:` lines. Production `SharedAreaHostSession`
  + `mountWorkspaceSceneAtBoot` scene. Four states each drawn as card text and
  reader text, rendered offscreen in light and dark, with distinct card pixels per
  state in each appearance; dialog opened by the session's coordinator warns for
  offline, clears live when online, returns for stale, none for Queue, fits its
  row, renders light/dark, and a warned Send now still sends.
  Renders: `validation/w5-liveness/renders/`.

## Teeth (compile-valid mutation → RED on the intended line → restored)

Logs in `validation/w5-liveness/teeth/`.

| Mutation | RED on |
| --- | --- |
| a: drop the retired-generation fence | a late beat from the retired run is refused |
| b: host offline after 15 s (pointer TTL) | host stale while the pointer is live |
| c: held read ignores host transitions | held reader woken at the offline transition |
| d: ignore revocation/removal | a removed member's host is offline without waiting |
| e: superseded run may re-mint | a superseded run does not mint a replacement |
| f: controller drops `hosts` | timeout: first run online for the teammate |
| g: coordinator does not wire the dialog provider | Send now to an offline host shows a warning |
| i: scene ignores liveness-only changes | card shows online (still drew "Host has not checked in.") |

## Gate

`scripts/run-matrix.sh --collaboration` under `.locks/app-build.sh`,
`CONTINUUM_SKIP_UI_BASELINES=1`:

- First run (`validation/w5-liveness/gate.log`): 10 legs, 1 failed, the service
  leg at "verification refuses a backup with damaged pages". That stopped the
  leg before the liveness section, so it is not evidence either way for COL-06.
- Cause: the backup check XORed 512 bytes at the file's exact midpoint. With an
  odd page count that is the unused middle of a page, which `integrity_check`
  never reads, so verification correctly accepted the backup. The page count
  moves with the number of concurrent writes. Measured on a throwaway worktree
  at `e17d0a52` with none of this work: 5 of 8 runs failed. Fixed in the check
  (damage the start of a middle page): 8 of 8 passed on this bench.
- Second run (`validation/w5-liveness/gate-2.log`): **passed, 10 legs, 0
  failures**, one note (theme surface-cache witness skipped with UI baselines).
  Reported: 31 `PASS host liveness:`, 11 `PASS host liveness client:`, 24 `PASS
  host liveness native:`.

## Left

- Real relay deployment and a two-Mac test remain Dylan's (COL-22).
- COL-15 should gate live controls on `isHostOnline(forObject:)`.

## Hunks in shared files

All small; new logic and UI are in new files.

- Service `CollaborationStore.swift`: `hostLivenessStates`; register
  `collaboration-host-liveness-v1` after the artifact migration.
- Service `CollaborationUpdates.swift`: held wait wakes at the next host
  transition; `readUpdates` passes `hosts:`.
- Protocol `CollaborationUpdates.swift`: optional `Updates.hosts`.
- Relay `CollaborationRoutes.swift`: one dispatch line.
- `CollaborationReplica.swift`: stores `hosts`.
- `SharedAreaController.swift`: `hostLiveness` property, set with presence,
  cleared at the three reset sites.
- `SharedAreaHostSession.swift`: heartbeat ownership; dialog provider; forwards
  controller changes to the dialog.
- `SharedAreaHandoffCoordinator.swift`: `hostLiveness` provider and
  `hostLivenessChanged()`.
- `SharedAreaHandoffView.swift`: warning label, Send-now relabel, mode change
  refresh, layout row.
- `SharedAreaSceneView.swift`: `knownHosts`, liveness-only reinstall, card/reader
  copy, `renderedCardPreview(for:)`.
- `ContinuumApp.swift`: one native stage after the handoff stage.
- Both checks `main.swift`: `--host-liveness-only` and one default call each.
- `docs/internals/collaboration.md`: two routes and the liveness rule.
