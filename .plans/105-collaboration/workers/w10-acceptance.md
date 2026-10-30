# Worker 10: COL-21 acceptance and non-deploy COL-22

Branch `array/mp-w10-acceptance`, bench `.worktrees/mp-w10-acceptance`, off `cc168bed`.

## Landed on this branch

- Operator commands in `continuum-relay`: `--collaboration-backup`,
  `--collaboration-verify-backup`, `--collaboration-restore`,
  `--collaboration-list-people`, `--collaboration-recover-person`
  (`Sources/continuum-relay/CollaborationOperator.swift`; service side in
  `CollaborationBackup.swift` and `CollaborationOperatorRecovery.swift`).
- Witnesses inside the default `ContinuumRevivedCollaborationServiceChecks` run
  (and `--backup-restore-only`): multi-area online backup under writes,
  verification, replacement and in-place restore through HTTP; operator recovery.
  Teeth logs in `validation/backup-restore/`.
- `scripts/check-collaboration-pair-features.py`: second pair journey, one stage
  per landing feature, PENDING until its peer op exists.
- `ACCEPTANCE.md` (living matrix), `ALPHA-HANDOFF.md` (Dylan's steps).
- Linux fix: `CollaborationRecoveryScaleChecks.swift` did not compile on Linux
  since the merge (`Darwin.kill`, `SOCK_STREAM` type).

## Hunks for the lead

- `Sources/continuum-relay/main.swift`: one line before the configuration guard
  dispatching the operator commands.
- `Sources/ContinuumRevivedCollaborationServiceChecks/main.swift`: the
  `--backup-restore-only` branch and one call in the default run.
- `Sources/ContinuumRevivedCollaborationService/CollaborationStore.swift`:
  `insertEnrollment`, `hash`, `secret` lose `private` (commit `ee77db0d`).
- Proposed, not applied: add `run_leg bash scripts/check-relay-linux.sh` to the
  `--collaboration` block of `scripts/run-matrix.sh`; that is how the Linux
  break went unseen. Register the features journey only once no stage is pending.

## State at pause (30 October 2026, coordinator PAUSE)

- All work committed through `96d4f993`; tree clean.
- Mac: `--backup-restore-only` GREEN (backup/restore 33 + operator recovery
  assertions), both mutants RED as recorded.
- Linux: run 1 failed to COMPILE on the pre-existing `Darwin.kill`/`SOCK_STREAM`
  code in `CollaborationRecoveryScaleChecks.swift` (not this branch's code).
  Fixed in `f29188d3`. Run 2 was stopped mid-build at the pause, so **the Linux
  gate has not yet been seen passing**. `ACCEPTANCE.md` still says "result
  recorded when it finishes".
- `features` journey: smoke run on the cc168bed Array binary, all 8 stages
  PENDING, setup and final invariants PASS.
- Lead and coordinator not yet messaged with the milestone.

## Next, on resume

1. `bash scripts/check-relay-linux.sh` (takes about 10 minutes); record the result in
   `ACCEPTANCE.md`.
2. Message the lead + coordinator: the Linux break, the hunks above, the
   operator recovery addition.
3. As worker branches merge onto `array/collaboration-finish`: rebase, add each
   feature's peer op (contract table in `ACCEPTANCE.md`) to
   `SharedAreaPeerRuntime.swift`, turn its `features` stage green, update the
   matrix rows. Add artifacts to the backup dataset once COL-16 lands; extend
   the backup audit to any new sealed tables (retention/compaction from COL-19).
4. After worker 1 lands: the native budget/accessibility witnesses listed in
   `ACCEPTANCE.md` ("Native budgets and accessibility still owed").
