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

The new legs print in a real matrix summary: see the real gate proof below.

## Left open (minor, from the review)

- `--ship-base` takes no lock. The gate's candidate pruning could delete a candidate while it is being signed. This is unlikely and would fail loudly.
- In prepare, a `gh release view` network error reads as "not published".
- Build numbers come from the ledger and the feed only, not from GitHub-only uploads.

## Real gate proof, 2026-11-15

`scripts/nightly-gate.sh` ran by hand on the real repo, detached, as the
LaunchAgent would run it. The settings were:
- `ARRAY_NIGHTLY_REF=array/fast-ship`;
- `ARRAY_AGENT_ID`, `TMUX` and `TMUX_PANE` unset;
- `TERM=xterm-256color`, stdin from `/dev/null`, `SDKROOT` exported.

The managed-agent marker stayed set, so crash witnesses were deferred
(`managed_agent: true`). Evidence: `~/array-scratch/gate-proof/` (15-second
samples) and `~/array-scratch/nightly-gate/results/<commit>/`.

| Run | Commit | Result | Matrix | Candidate | Total |
|---|---|---|---|---|---|
| 1 (cold checkout) | `0ae0c265` | red: 410 pass, 4 fail, each red again on serial retry | 31m58s (cold debug build 244 s) | not built (correct) | 31m58s |
| 2 | `bef08b32` | refused at checkout: the branch name belonged to a bench | — | — | 0.1 s |
| 3 | `313f9511` | red: 411 pass, 2 known, 2 retry-passed, 2 fail | 25m29s | not built (correct) | 25m29s |
| 4 (warm) | `beb3ee2f` | **green: 413 pass, 2 known, 0 fail** | **23m43s** | **16m19s**, prod `dev.arrayapp.macos`, 220 MB | **40m02s** |

The run 4 summary printed all 4 new legs as pass (`check-matrix-known-failures`
11 s, `check-appcast-append` 1 s, `check-wait-live-release` 4 s,
`check-ship-release` 5 s). It printed `KNOWN-RED, expected (2)` with no hand
classification. The candidate's checkout HEAD was `beb3ee2f` on
`gate/nightly-checkout`.

What the real runs found. Every one was a gate defect, now fixed, with a witness
case that fails on the old code:
- A hardcoded minimal PATH hid claude, codex and pi, so the CLI fixture leg went red. `--install` now records the shell's PATH.
- A detached checkout gave agent tiles no branch chip, so `--agent-supervisor-check` went red. The checkout now uses `gate/nightly-checkout`.
- Untracked leg output marked the checkout as dirty, which would have refused every later hourly run.
- `ARRAY_NIGHTLY_REF` leaked into the matrix.
- `checkout -B array/nightly-gate` would have reset an existing bench branch. Git refused only because that branch was checked out elsewhere.
- Putting the caller's PATH first made `python3` Apple's 3.9 when started from an agent shell. System directories now lead.

One real red was listed. `--subagent-sidebar-open-check` shows the same four
WORLD-frame failures as the 0.7.49 and 0.7.50 gates. Its entry expires
2026-12-15.

Machine cost, run 4. These are 15-second samples of the gate's process tree.
It was 02:05–02:45, so Dylan was not working.
- Matrix: median 0.4 cores, p90 2.1, peak 7.4. RSS median 354 MB, p90 1.4 GB, peak 12 GB during the build. Above one core for 29% of the time.
- Candidate: median 1 core (one whole-module compile), short peak of 14. RSS 8–9.8 GB for 16 minutes.
- Free memory never fell below 54% on this 24 GB Mac. The 8–10 GB release compile is about 40% of RAM.
- Run 1 (cold, with other agents building): peak 10 cores and 10 GB, load 72.

Screen and tmux:
- The frontmost app stayed Array, Dylan's own copy, in every sample.
- The display and focus legs are excluded under `--skip-awake`.
- No process from the gate ever held `/private/tmp/tmux-501/default`. Matrix tmux uses `/tmp/array-matrix-tmux.*`.

Left open:
- `--undo-toast-bottom-bar-*` writes screenshots into a checkout directory literally named `-continuum.terminal.tmux.enabled/`. It takes the next argument as its output path. This is a pre-existing check bug; the gate now ignores untracked output.
- `check-prepass-source-patterns.py` breaks under Apple's python3 because of `pycache_prefix`. It is pre-existing; the gate avoids it.
- The plist's 03:00 slot collides with this Mac's daily `pmset` sleep at 03:00.
