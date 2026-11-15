# Fast ship: results

Written 2026-11-15. Branch `array/fast-ship`, on `origin/array/integration` at
`2e280397`, fast-forwards cleanly. Nothing pushed. Nothing installed.

Goal: from a reviewed, green integration head, publish in under 30 minutes, with
no hand-classification and no hand-repair.

## Done

| Item | What it does | Time saved per release (ESTIMATE) | Commit |
|---|---|---|---|
| Continuous gate builds the candidate | `nightly-gate.sh` runs hourly and at 03:00. When green, it builds the optimized prod bundle for that exact commit. | Matrix (28 min to 2 h) plus release build (20–27 min) leave ship time: about 50–90 min | `543b658b` |
| Gate covers release-prep commits | `--ship-base` reuses a green gate when later commits touch only `.plans/`, `website/` or `docs/VERSIONING.md`. | Removes "no gate for the exact head" full reruns: 1–2 h when it happens | `543b658b` |
| Known-failure list + serial retry | `scripts/matrix-known-failures.json` with reason, evidence, and an expiry of 30 days or less. A parallel-group red is retried once alone and reported as `retry-passed`. | 15–40 min of triage per release, plus reruns | `41604fe4` |
| Append-only appcast | Signs only the new DMG and splices one item. Old bytes stay identical, so 0.2.0 and the old dates survive. | The hand repair, about 10–20 min | `8c92c12b` |
| `ship-release.sh` + live wait | Prepare: sign the candidate, audit, appcast, ledger, local commit. `--publish`: upload, push, wait until arrayapp.dev serves the build and both DMGs answer. | About 7 min of agent turns, and no more false "publish failed" alarms | `543b658b` |
| Review fixes | Awake skip on a held lock, rename hiding live code, future-dated known failure, half-uploaded release pushed. | — | `fd30a209` |

Expected ship time from a gated head: awake group 0–13 min, notarize about 3,
audit under 1, publish plus feed about 5. That is about 10–25 min. It is an
estimate and has not been measured on a real release.

Not built: an affected-legs gate for code changes. The coverage map links only
about 15 of about 450 legs.

## Witnesses

All are registered as `run_leg` in `run-matrix.sh`. The inventory adds 4 records.

- `check-ship-release.py`: drives the real gate and ship scripts in a throwaway repo. It has 10 cases. Mutants that went red:
  - a red gate builds a candidate;
  - `--ship-base` ignores code;
  - the wait is always live;
  - prepare skips the awake group;
  - publish skips the upload;
  - the pre-fix rename, lock-exit and missing-asset behaviour.
- `check-matrix-known-failures.py`: 7 cases, including a future-dated entry, which is red on the pre-fix matrix.
- `check-appcast-append.py`, `check-wait-live-release.py`: green.
- `check-matrix-build-ordering.py`: green after its fixture also copies the known-failure list.

Not run:
- a full matrix;
- a real gate (the LaunchAgent is not installed, so installing it is Dylan's call);
- a real signed release.

The new legs have not yet been seen in a real matrix summary.

## Left open (minor, from the review)

- `--ship-base` takes no lock. The gate's candidate pruning could delete a candidate while it is being signed. This is unlikely and would fail loudly.
- In prepare, a `gh release view` network error reads as "not published".
- Build numbers come from the ledger and the feed only, not from GitHub-only uploads.
