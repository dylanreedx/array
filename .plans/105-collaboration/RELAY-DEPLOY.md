# Relay deploy: staging and production

31 October 2026. Authorised by Dylan ("deploy the fucking relay"), relayed by
the 0.7.36 lead orchestrator. Scope was the relay on Fly only: no git push, no
app release, no website deploy.

## What was deployed

| | App | Release | Source |
| --- | --- | --- | --- |
| Staging | `arrayapp-relay-staging` (yyz) | v3 | `7c008471` |
| Production | `arrayapp-relay` (yyz, relay.arrayapp.dev) | v16 | `cfbbe5a1` |

The branch tip moved from `7c008471` to `cfbbe5a1` during the session. The
only commit between them is docs (`docs(collaboration): record the canvas zone
and share entry gate`). `git diff 7c008471 cfbbe5a1` is empty for the
Dockerfile, RelayPackage.swift, fly.toml and every relay source target, so
production runs the same relay code that staging and the Linux gate tested.

## Production rollback target

- Previous release: **v15**, image
  `registry.fly.io/arrayapp-relay@sha256:7002553c65e6c68b0bb74b39742a8a6231dd5110005dda4f5a45a66e65b4817f`
- Volume snapshot taken before the deploy: **`vs_KDj1w1Q7mvq4tMj8egJZRlB`**
  (volume `vol_vgnxq0m5d1nmy514` / `relay_data`, 309 MiB stored, 5-day
  retention, so it expires around 5 November 2026)

Roll back the code (the database can stay; see the rehearsal below):

```sh
fly deploy --app arrayapp-relay --config fly.toml \
  --image registry.fly.io/arrayapp-relay@sha256:7002553c65e6c68b0bb74b39742a8a6231dd5110005dda4f5a45a66e65b4817f
```

Restore the data as well, only if the database itself is damaged: create a
volume from the snapshot (`fly volumes create relay_data --snapshot-id
vs_KDj1w1Q7mvq4tMj8egJZRlB --region yyz --app arrayapp-relay`), then move the
machine onto it. This discards every companion write since the snapshot.

## Checks and results

1. **Linux gate** (`scripts/check-relay-linux.sh` under
   `.worktrees/.locks/app-build.sh`, on `7c008471`): exit 0, 471 PASS, 0 FAIL,
   including the backup/restore and operator recovery lines. The two
   `outbox_worker_failed` log lines are from deliberate fault-injection checks.
2. **Staging deploy.** The app, its own 1 GB volume `relay_staging_data` and
   fresh staging-only `RELAY_MASTER_KEY` and `RELAY_COLLABORATION_MASTER_KEY`
   were created for this. No production secret was copied. Config:
   `deploy/fly.staging.toml` (collaboration on). Health 200, companion schema 4.
   The first deploy failed to allocate IPs (a flyctl `org_slug` error), so a
   shared v4 and a dedicated v6 were allocated by hand.
3. **Staging collaboration over HTTPS**, using throwaway people enrolled with
   `continuum-relay --collaboration-enroll`; codes and tokens were never
   printed. 15/15 passed: redeem enrollment 201; self 200; bad token 401;
   create area 201; create share link 201; duplicate live slug 409; join with a
   wrong token 410; 10 joins 201 each; the 11th join 429 `rateLimited`; list
   links 200; revoke 200; a once link revoked, then join 410
   `invalidInvitation`; owner reads area 200. The pair harnesses
   (`check-collaboration-pair*.py`) start their own local relay and take no
   base URL, so they were not run against staging.
4. **Staging companion routes**: same status codes as production's pre-deploy
   baseline on every route probed (below).
5. **Rollback rehearsal on staging**: production's v15 image deployed onto
   staging's schema-4 database booted, served health 200 and answered every
   companion route like production. The two new companion migrations
   (`relay-notification-outbox`, `relay-task-notification-ownership`) only add
   tables and one nullable column. Staging was then put back on the tip (v3) and
   the collaboration probe re-ran 15/15.
6. **Production deploy**: v16, same machine `879206f11ed498`.
   - Health 200, `schemaVersion` 4 (was 2).
   - Migrations: all four companion migration ids are recorded in
     `/data/relay.sqlite` (read-only check over ssh).
   - Companion routes compared with the pre-deploy baseline: unchanged.
     `GET /`, `/v2/devices`, `/v2/notification-owner`, `GET/POST /v2/events`,
     `/v2/commands`, `/v2/pairing-grants`, `/v2/push-registrations`, `/invites`
     still 401 without credentials; `/v2/invites/redeem` and
     `/v2/pairing/exchange` still 400 on an empty body; `/v2/socket` still
     upgrades (101).
   - Live phone traffic after the deploy: the Mac instance kept publishing (event
     sequence 90988 → 91214 within about six minutes) and the phone device's
     APNs registration kept receiving notification decisions.
   - Watched for 5 minutes: 30/30 health calls 200, slowest 0.6 s; Fly check
     passing.
7. **Collaboration on production: off, by design.** Production's `fly.toml` sets
   neither `RELAY_COLLABORATION_DATABASE_PATH` nor
   `RELAY_COLLABORATION_MASTER_KEY`, so `/collaboration/v1/*` answers 404
   `notFound` (v15 answered 401 there because it had no such prefix).
   Collaboration runs on staging. Turning it on in production needs a new
   collaboration master key that Dylan saves in his password manager first
   (ALPHA-HANDOFF.md §1), plus the database path in the config.

## One incident: about two minutes of slow production after the deploy

**What happened.** Right after v16 started, Fly's health check timed out
(`context deadline exceeded`). One of my health calls timed out at 5 s and the
next took 4.3 s. The check failed until **16:38:18 UTC** and has passed
since.

**Why, most likely.** A burst of notification decisions (all `suppressed`) for
a single event, just after the 484 MB companion database was migrated.
Requests queued behind that work. Staging couldn't show this beforehand: its
database was empty. **Corrected below:** this is not only a startup effect. It
recurs whenever a burst runs (see "Collaboration turned on in production").

**Effect.** For roughly 16:35–16:38 UTC the phone companion may have seen slow
or failed requests. Nothing was lost, and traffic resumed on its own. No
rollback was needed because every route came back unchanged and stayed healthy.

**Still worth a look.** Every published event logs about 100
`relay.notification` lines (T-02/T-06 suppressions for one registration). It
is correct, but noisy.

## Staging app

`arrayapp-relay-staging` stays up for the coworker alpha. Its collaboration
key exists only as a Fly secret and nobody holds a copy, so its backups are
not restorable off the machine. Rotate it before staging holds real work.
Throwaway people "Staging Owner", "Staging Owner 2", "Staging Owner 3" and
"Probe 0–9" exist in its collaboration database.

## Collaboration turned on in production

Later on 31 October 2026, Dylan said yes to collaboration on production.

- **Key.** A new 32-byte key, base64, generated locally and piped straight into
  `fly secrets import --stage`. It was never written to a file, log or commit.
  The only copy outside Fly went to Dylan's clipboard for his password manager.
  Without that copy, collaboration backups cannot be restored off the machine.
- **Variables**, both set as Fly secrets so `fly.toml` stays unchanged:
  `RELAY_COLLABORATION_MASTER_KEY` and `RELAY_COLLABORATION_DATABASE_PATH`
  (`/data/collaboration.sqlite`, on `relay_data` next to `relay.sqlite`).
- **Applied** with `fly secrets deploy`: release **v17**, same image as v16,
  one restart. All 18 health calls during the restart returned 200.
- **Turn it off again** (companion unaffected; the collaboration database
  stays on the volume):
  `fly secrets unset RELAY_COLLABORATION_MASTER_KEY RELAY_COLLABORATION_DATABASE_PATH -a arrayapp-relay`.
  Unset both together: the relay refuses to start with only one of them.

### Verification

- Health 200, schema 4.
- Companion routes: identical status codes to the pre-deploy baseline.
- `/collaboration/v1/self` → 401 and `/collaboration/v1/links/join` → 400 on an
  empty body (both were 404 with collaboration off).
- One throwaway round trip, 11/12. Passed: enroll, redeem, create area, create
  link, join 201, joiner reads area 200, revoke 200, join after revoke 410.
  The one "failure" was my cleanup step: revoking the link had already removed
  the joiner and bumped the epoch (`revokeShareLink` cuts every admission), so
  removing them again correctly returned 404. Cleanup then revoked both
  devices, and the owner token answers 401. There is no route to delete an
  area or a person, so production keeps one inert area
  (`A0924B21-6E6C-4E6E-B454-80C02E4EE9B8`) and two people with no live
  device ("Deploy probe (throwaway)", "Deploy probe joiner").

### Open: the relay stalls during notification bursts

**What.** In the 5-minute watch after v17, 3 of 28 health calls timed out at
5 s and one took 4.4 s, between 17:52:58 and 17:53:42 UTC. Fly's health check
failed twice, then recovered. This matches the stall right after v16.

**Why, most likely.** The companion notification code in `413e56e0` ("send one
alert per finished task") does heavy work for every event the Mac publishes.
Each event writes about 336 decision lines, almost all `T-02` (taskUnknown)
`suppressed` for the one phone registration: 22,840 lines in 5 minutes. The
stalls line up with those bursts. Collaboration traffic in that window was
only the probe. v15 (schema 2) did not have this code.

**Effect.** The phone keeps working (event sequence 91214 → 92328, alerts still
decided), but its requests can stall for up to about 45 s while a burst runs.

**Not rolled back.** Turning collaboration off would not fix it. Rolling back
to v15 would also remove the per-task alerts the 0.7.36 app shipped with.
Decision passed to the orchestrator: fix the per-event fan-out and the
per-suppression logging, or roll back to v15 with the command at the top.

**Resolved in v18.** See the next section.

## Fix deployed: decide only changed tasks (v18)

Commit `32d54661`, `perf(relay): decide only changed tasks in a task batch`, on
`array/relay-batch-fanout` (branched from `array/collaboration-finish` at
`05206dc9`).

**What changed.** The ownership row keeps each task's last decided identity
(`notification_ownership.task_keys`, migration `relay-task-decision-keys`,
schema 5). A task whose decision hasn't changed is skipped. An alert the outbox
refused for capacity stays undecided, so the next batch retries it. Delivery
drains once per batch and logs one `relay.notification.batch` line (task count
per T-path), instead of a registrations read, a drain and a `suppressed` line
for every task. `docs/internals/notification-paths.md` records this.

**Measured, local fixture, per event:**

| Known tasks | Before: SQL statements / log lines | After |
| --- | --- | --- |
| 40 | 566 / 41 | 30 / 0 |
| 400 | 5,318 / 401 | 30 / 0 |

**Gates.**
- Linux gate (`check-relay-linux.sh`, under the build lock): exit 0, 473 PASS,
  0 FAIL.
- New witnesses: `task batch load` and `task batch capacity`.
- Mutations, each RED: deciding every task again (1,634 statements/event at
  400 tasks), draining per task (1,233), and recording a capacity-refused task
  as decided (256 alerts instead of 257).
- One existing check changed: the HTTP task-policy check asserted the removed
  per-task `suppressed`/`deduplicated` lines. It now reads T-paths from the
  batch line. Its alert-count assertions are unchanged.

**Staging.** `arrayapp-relay-staging` v5 is on `32d54661`. Staging now has a
throwaway, locally generated APNs key
(`APNS_KEY_ID`/`APNS_TEAM_ID`=`STAGINGFAKE`, sandbox), so the delivery half
runs there. Nothing in the burst contacts Apple. Burst replay: a throwaway Mac
and phone, a 336-task baseline, then 40 batches back to back that each change
one task.

| | Publish p50 / max | Health p50 / max | Health timeouts |
| --- | --- | --- | --- |
| Before (old code) | 0.71 / 0.79 s | 0.45 / 0.52 s | 0 |
| After | 0.49 / 0.86 s | 0.22 / 0.49 s | 0 |

Staging could not reproduce the 45 s stall: its database is nearly empty, while
production's is 484 MB. Production is the real test, below.

**Production v18.**
- Snapshot first: `vs_o7xVGVmzo6MLFnlxN0N0bAk1`.
- Rollback target: v17 image
  `registry.fly.io/arrayapp-relay:deployment-01M69D1CAYQDHNZ2E48W955GCZ`. The
  old code opens schema 5, because the new column is additive.
- The pre-deploy route probe on v17 itself hit two 5 s timeouts (`/`,
  `/v2/notification-owner`): the stall, live.
- After deploy:
  - Health 200, schema 5; migration recorded in `/data/relay.sqlite`.
  - Every companion route identical to this morning's baseline; collaboration
    routes answer (401/400).
  - 10-minute watch: 116/116 health calls 200, slowest 0.45 s, none over 1 s,
    zero timeouts. Fly check passing.
  - Live traffic: Mac events 93000 → 93217, 115 batches of 347–349 tasks, one
    batch line each; zero per-task lines from the new process. The remaining
    `relay.notification` lines are one `taskOwnerSuppressed` per legacy activity
    event, the same as before.
  - The deploy-window errors (machine lease held, connection refused) are the
    18:29 restart. The two `DecodingError`s are my probe's empty bodies.

```sh
fly deploy --app arrayapp-relay --config fly.toml \
  --image registry.fly.io/arrayapp-relay:deployment-01M69D1CAYQDHNZ2E48W955GCZ
```

**Staging keeps the fake APNs secrets, on purpose** (orchestrator's call,
31 October 2026). `APNS_KEY_ID`, `APNS_TEAM_ID` (`STAGINGFAKE`),
`APNS_ENVIRONMENT=sandbox` and `APNS_PRIVATE_KEY_BASE64` (a P-256 key generated
on this Mac for staging only) let staging run the delivery half. The key is not
an Apple key, so any real push from staging fails at Apple; nothing in the
burst replay sends one. Remove all four before staging ever needs real pushes:
`fly secrets unset APNS_KEY_ID APNS_TEAM_ID APNS_ENVIRONMENT APNS_PRIVATE_KEY_BASE64 -a arrayapp-relay-staging`.

**Still open.**
- The Mac's batch grows with every task it knows (349 now), and the relay
  rejects a batch over 512 tasks (`invalidNotificationBatch`). At this rate the
  Mac will hit that cap and task alerts will stop. **Fixed in source for 0.7.37**
  (Mac side, not deployed): the real growth was unknown tasks orphaned by
  restarts (290 of 349), not settled ones, which were already capped at 128.
  The batch now carries live work always, and everything else for 24 h after
  its last change. Witness: `task batch retention` in
  ContinuumRevivedRelayChecks. It is RED (`capacityExceeded`) with the window
  removed. It takes effect only once Dylan runs a build that contains it.
- Every publish still decodes and evaluates the whole batch: CPU, not database
  work. Measured only end to end: the Linux-gate fixture's 400-task burst takes
  0.73 s for 6 events (about 0.12 s each, release build under amd64
  emulation).
- If production is ever rolled back to v17, the old code leaves `task_keys`
  untouched. A later redeploy trusts those keys, so a task that changed and
  changed back during the rollback is skipped once.
