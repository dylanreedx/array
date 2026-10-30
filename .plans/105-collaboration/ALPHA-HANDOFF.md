# Coworker alpha: operator and two-Mac handoff

30 October 2026, worker 10, branch `array/mp-w10-acceptance`.

These are the steps only Dylan can take. Nothing here has been run against
Fly, a real Keychain item, or a second person. Every step was rehearsed
offline by a check, named under each section. Nothing is deployed or pushed.

## What you need to decide first

1. **Where the service runs.** Recommended: a separate Fly app for the alpha,
   for example `arrayapp-collab-staging`, with its own volume and keys. The
   production companion relay (`arrayapp-relay`) stays untouched. Enabling
   collaboration on the production relay instead would mean the same machine,
   volume and deploy carry both, and a bad collaboration deploy takes the
   companion down with it.
2. **Which build your coworker runs.** No released Array contains
   collaboration. Options: (a) the coworker builds the branch with
   `scripts/dev-app.sh` (needs Xcode and repo access; dev channel), or (b) a
   notarized build through RELEASE.md that is not published to the appcast.
   (a) is less work for an alpha. You run `~/Desktop/Array Dev.app`, never the
   copy in /Applications.
3. **Deploy commit.** The `array/collaboration-finish` tip after every worker
   branch is merged and `bash scripts/check-relay-linux.sh` passes on it.

## 1. Stand up the service (needs your go)

Facts the deploy depends on:

- The relay serves collaboration ONLY when both
  `RELAY_COLLABORATION_DATABASE_PATH` and `RELAY_COLLABORATION_MASTER_KEY` are
  set. The current `fly.toml` sets neither, so today's production relay has no
  collaboration routes.
- `RELAY_MASTER_KEY` is always required (companion side), even on a
  collaboration-only staging app. Use a NEW one; never reuse production's.
- The app refuses a non-HTTPS service URL unless it is loopback. Fly's
  `force_https` covers this.
- The held-read cap (4 per device, 1,024 global) is compiled in. Deploying an
  older commit brings back the 2-reader cap and the 429 failure.

Steps:

1. Run the Linux gate on the deploy commit: `bash scripts/check-relay-linux.sh`.
   It must end with the collaboration service checks passing, including the
   backup/restore and operator recovery lines.
2. Create the app and a volume (names are suggestions):

```sh
fly apps create arrayapp-collab-staging
fly volumes create collab_data --app arrayapp-collab-staging --region yyz --size 1
```

3. Write a config for it. Copy `fly.toml` to `fly.collab-staging.toml`, then change
   `app` to `arrayapp-collab-staging`, the mount `source` to `collab_data`, and
   add one line under `[env]`:

```toml
RELAY_COLLABORATION_DATABASE_PATH = "/data/collaboration.sqlite"
```

4. Make the two keys. **Save the collaboration key in your password manager
   before importing it.** Without that exact key, every backup is unreadable
   and there is no recovery.

```sh
umask 077
openssl rand -base64 32 > /tmp/collab-key
openssl rand -base64 32 > /tmp/companion-key
# copy /tmp/collab-key into the password manager now
printf 'RELAY_COLLABORATION_MASTER_KEY=%s\nRELAY_MASTER_KEY=%s\n' "$(cat /tmp/collab-key)" "$(cat /tmp/companion-key)" | fly secrets import --app arrayapp-collab-staging
rm -P /tmp/collab-key /tmp/companion-key
```

5. Deploy from the deploy-commit checkout:
   `fly deploy --config fly.collab-staging.toml --app arrayapp-collab-staging`.
6. Check health: `curl -fsS https://arrayapp-collab-staging.fly.dev/health`.

## 2. Operator commands on the machine

All of them run inside the machine, read only the collaboration database and
never open the companion database. Run them as the `relay` user so files keep
the right owner. **Check before first use:** the two variables are present in
the ssh session (names only):
`fly ssh console --app arrayapp-collab-staging --user relay -C "sh -c 'env | cut -d= -f1 | grep RELAY_'"`.

| Purpose | Command after `fly ssh console --app arrayapp-collab-staging --user relay -C` |
| --- | --- |
| Admit a new person | `"continuum-relay --collaboration-enroll 'Dylan'"` |
| List people, IDs, device and area counts | `"continuum-relay --collaboration-list-people"` |
| Recover a person with no working device | `"continuum-relay --collaboration-recover-person <person id>"` |
| Online backup (relay keeps serving) | `"continuum-relay --collaboration-backup /data/backups/<name>.sqlite"` |
| Verify a backup | `"continuum-relay --collaboration-verify-backup /data/backups/<name>.sqlite"` |
| Restore (then restart at once) | `"continuum-relay --collaboration-restore /data/backups/<name>.sqlite"` |

Enrollment and recovery print a one-time code, valid for ten minutes. It is
admission material: send it to the person over a private channel, never in a
shared doc. The printed JSON also contains the person ID; keep it, because
invitations are addressed by that ID.

Witness: `ContinuumRevivedCollaborationServiceChecks --backup-restore-only`
drives every command above as a real `continuum-relay` process.

## 3. Real two-person, two-Mac test

Use two people with two Macs, each on their own project root, never a shared
folder (hazard 10).

1. Operator: enroll both people (`--collaboration-enroll` twice). Note both
   person IDs. Send each person their code.
2. Each person: File > Collaboration… → service URL
   `https://arrayapp-collab-staging.fly.dev`, the code, a device name →
   connect. **This is the first real Keychain write.** Quit and relaunch the
   app: the account must still be listed under "Choose an account" without a
   prompt. Rebuild the dev app once (ad-hoc signature changes) and relaunch:
   record whether macOS asks for Keychain access or the account is lost.
3. Dylan: Create a workspace, then invite the coworker by their person ID
   ("Teammate's collaboration ID"), role Editor. Send the invitation code.
4. Coworker: Join with an invitation → paste the code.
5. Dylan: File > Share zone (or Capture area to share) on a zone with one note
   and one managed agent → review → publish. Both Macs should show the same
   arrangement at their own camera.
6. Walk the workflow the pair witness runs locally, and record what happens
   on each Mac:
   - both edit the agreement;
   - both drag tiles, then Undo and Redo;
   - each moves the same tile at the same time;
   - Dylan hands the agent to the coworker, who sends one prompt; it must run
     once, on Dylan's Mac only;
   - hover the teammate's cursor to see their token usage;
   - one Mac sleeps or quits mid-session, then comes back.
7. Remove the coworker from the area (owner action). Their window must lose
   the content, and their queued work must be refused.

Record for each step: worked / failed / confusing, with a screenshot. That
record is the real-person evidence COL-21 and COL-22 still need.

Witnesses rehearsing this offline: `scripts/check-collaboration-pair.py`
(15 behaviours on two local background peers) and
`scripts/check-collaboration-pair-features.py` (features as they land).

## 4. Operator recovery rehearsal

Do this once with the coworker's consent, on staging:

1. Coworker: note one area they belong to. Then pretend the Mac is lost: do
   not use it again for this account.
2. Operator: `--collaboration-list-people` → find their ID →
   `--collaboration-recover-person <id>` → send the new code privately.
3. Coworker, on another Mac or a fresh dev store: File > Collaboration… →
   same URL, new code. They must land in the SAME person: same areas, same
   role. The old device must now fail (it was revoked by recovery).

What recovery does: revokes EVERY device of that person, kills any enrollment
those devices issued, and issues one new enrollment for the same person ID.
Making a new person instead is not recovery: it loses every membership and
published source.

## 5. Backup and restore rehearsal

1. Make a backup and verify it (table above).
2. Copy it off the machine. A backup on the same volume is not a backup:
   `fly ssh sftp get /data/backups/<name>.sqlite --app arrayapp-collab-staging`.
   Fly's own volume snapshots are a second, crash-consistent layer, not a
   replacement.
3. Restore rehearsal on staging only: run `--collaboration-restore`, then
   immediately `fly machine restart <machine id> --app arrayapp-collab-staging`.
   The previous database is kept beside it as `collaboration.sqlite.before-restore`.

Known limits of restore, each pinned by the witness:

- **Point in time.** Anything written after the backup is not in it.
- **Re-apply revocations made after the backup.** A device revoked or a member
  removed after the backup point is valid again after restore. Keep a log of
  every revocation and removal, and redo the ones newer than the backup right
  after restoring. The witness asserts that such a device works again until it
  is re-revoked.
- **Writes between restore and restart** go to the moved-aside file, not the
  restored one. Restart immediately.
- **Restore refuses** if a rollback journal (`collaboration.sqlite-journal`)
  shows an interrupted write; restart the relay once to recover it first.
- No automatic backup schedule exists yet. For the alpha, back up by hand
  before and after each test session.

## 6. Not covered yet

- Artifacts (COL-16) are not in the backup dataset until that branch lands.
- No usage/storage/fanout measurement exists, so no capacity or cost claim.
- Key rotation for `RELAY_COLLABORATION_MASTER_KEY` is not implemented.
- Invitations send no notification; codes travel by hand.
