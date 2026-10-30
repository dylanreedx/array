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
