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

**Why, most likely.** The new relay worked through a backlog when it started:
the logs show a burst of notification decisions (all `suppressed`) for one
event, while the 484 MB companion database had just been migrated. Requests
queued behind that work. This was not tested beforehand: staging's database
was empty, so it had no backlog to work through.

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
