# Relay rollout: task alerts (schema 4) and its rollback

Written 2026-10-29 by the companion tile. **A plan only. Nothing here has been
run against production, and every step that touches Fly or the phone needs
Dylan's explicit go.**

## What changes for Dylan

Today the phone gets one alert per agent snapshot: every child finishing,
a parent finishing while children still run, replays after a restart. After
this rollout, with the 0.7.35 Mac app, the relay decides from task state:
one "needs you" when a task is blocked, one "finished" when the whole task is
done, silence in between, and a tap opens that exact agent and task.

Nothing changes until **both** halves are live. Either one alone is inert:

- New relay, old Mac app: no task publisher, so no owner is ever established
  and legacy alerts carry on exactly as now (OWN-02 applies only after an
  owner exists).
- New Mac app, old relay: the relay's health does not advertise
  `task.batch.v1`, so the Mac keeps legacy publication (HOST-07). Witnessed by
  `--companion-task-publication-check` with v15's exact health payload.

So the order does not matter for safety. Recommended: Mac release first (it is
already on the 0.7.35 line), then the relay.

## Production today

| | |
| --- | --- |
| App / region | `arrayapp-relay`, `yyz`, one machine `879206f11ed498`, shared-cpu-1x 512 MB |
| Release | v15, deployed 2026-10-29 03:24:54 UTC, schema 2 |
| Image | `registry.fly.io/arrayapp-relay@sha256:7002553c65e6c68b0bb74b39742a8a6231dd5110005dda4f5a45a66e65b4817f` |
| v15 source | Frozen archive, not a Git commit: `.plans/96-companion-relay-validation/payload-recovery/relay-source.tar.gz` in the main checkout (untracked; keep it until a relay ships from Git) |
| Volume | `vol_vgnxq0m5d1nmy514`, 1 GB encrypted, 51% used, ~446 MB free; `/data/relay.sqlite` ~462 MB |
| Snapshots | Daily, 5-day retention; last pre-deploy snapshot `vs_qwxBYB8OaeV6h78A9x6bQeAK`. **No restore has ever been exercised** |

## What the new relay does to the database

Two additive migrations on top of schema 2, from `RelayStore.migrator`:

- `relay-notification-outbox` (schema 3): `ALTER TABLE notification_claims ADD
  COLUMN disposition`, new `notification_outbox` and `notification_backoff`.
- `relay-task-notification-ownership` (schema 4): new `notification_ownership`
  and `notification_task_decisions`.

No table is rebuilt, so the migration needs no temp space near the 462 MB
database. The events table is untouched.

## Why rolling back to v15 is safe (checked in source, not yet rehearsed)

1. **GRDB tolerates a newer database.** `DatabaseMigrator.runMigrations`
   compares only migrations it knows (`appliedMigrations` filters to registered
   ids). v15 knows `relay-v1` and `relay-notification-deduplication`, both
   applied, so it neither re-runs nor aborts; unknown ids are ignored
   (GRDB 7.11.1, pinned exactly in `RelayPackage.swift`).
2. **v15 writes the changed table by column name.** Its only
   `notification_claims` insert names its four columns; the added nullable
   `disposition` column does not break it.
3. **v15 reports schema 2.** Its health returns a constant, with no
   `notificationPolicies`, so the Mac drops back to legacy publication within
   its 60-second health cache.

What a rollback does not undo: pending outbox intents stop being sent (v15
does not read the outbox), and the ownership row stays. See "Rolling forward
again".

## Gates before Dylan is asked

1. 0.7.35 Mac release shipped and installed (carries the task publisher).
2. Relay built from the release line's committed source, not a frozen
   directory. Record the commit, the image digest and a source manifest.
3. `scripts/run-matrix.sh --notifications` and `--notifications-linux` green on
   that exact commit; Linux suites also at 512 MiB with swap off.
4. **Rehearsal on a copy of production data (needs Dylan's go: it copies the
   encrypted database off the volume).**
   - `fly ssh sftp get /data/relay.sqlite` to a disposable local directory.
   - Run the new relay locally against the copy with a throwaway master key:
     migrations succeed, `/health` reports schema 4 with `task.batch.v1`, and
     row counts for instances, registrations and events are unchanged.
   - Run the v15 binary (built from the frozen archive) on the migrated copy:
     it boots, `/health` reports schema 2, and a legacy publish is accepted.
   - Delete the copy. Tokens stay encrypted throughout; the real master key is
     never fetched.

## Deploy (each step needs Dylan's go)

1. `fly volumes snapshots create vol_vgnxq0m5d1nmy514`; wait for `created`.
   Record the snapshot id.
2. `fly deploy --image <digest from gate 2>`. The image is built ahead of time;
   no build happens during the deploy.
3. Verify within 2 minutes:
   - `fly status`: same machine, 1/1 checks passing; `fly logs`: migrations ran,
     no crash or OOM.
   - Public `/health`: `{"schemaVersion":4,"notificationPolicies":["task.batch.v1"]}`.
   - Mac: companion diagnostics log `taskAlertsSupported` true and no
     `Task notification owner mismatch`; the first full batch establishes the
     owner (quiet baseline, so nothing old alerts).
4. Phone acceptance (Dylan, TestFlight build with exact-task navigation):
   - A task with children: no alert per child; one "finished" at the end.
   - Parent finishes while a child runs: no alert until the child is done.
   - An agent asks for input: one alert, tap opens that agent and task.
   - With the phone locked, backgrounded and force-quit: tap still lands.
   - Mac asleep, then woken: no duplicate alerts on reconnect.
   Record real banners separately from decision counts and Apple acceptances.

## Rollback

**Triggers:** crash loop or failing health check; 5xx on publish; alerts
missing, duplicated or wrong in the phone acceptance; memory over ~450 MB.

**A. Binary rollback (the default).** `fly deploy --image
registry.fly.io/arrayapp-relay@sha256:7002553c65e6c68b0bb74b39742a8a6231dd5110005dda4f5a45a66e65b4817f`.
Same volume, no data restore. Verify `/health` reports schema 2 and that the Mac
resumes legacy publication (diagnostics `taskAlertsSupported` false). Phone
behaviour returns to today's.

**B. Data restore (only if the database itself is damaged).** Create a volume
from the pre-deploy snapshot (`fly volumes create relay_data --snapshot-id
<id> --region yyz`), move the machine to it, deploy the v15 image. Everything
since the snapshot is lost: events (phones re-bootstrap from the Mac's next
publish) and any pairing made after it (that phone must pair again). Never
exercised; treat the first use as a drill and keep the old volume until it
works.

## Rolling forward again after a rollback

- Wait over an hour: outbox intents expire after one hour, so none queued
  before the rollback can be sent late.
- The ownership row survives, and the Mac's ledger revision only grows, so the
  same publisher resumes without a conflict. A task that changed state during
  the rollback may alert once more for a transition v15 already alerted for
  under the legacy path. Accept it, or restore from snapshot B instead.

## Not covered here

- `array_notify` needs no relay change: it rides the same task policy
  (NOTIFY-01…07 in `docs/internals/notification-paths.md`).
- Retention of compact claim, ownership and decision rows is still unbounded;
  disk is at 51%. Needs its own pruning decision before the volume fills.
- Apple accepting a push is not the phone displaying it; only gate 4 above
  establishes display.
