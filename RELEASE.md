# Releasing Array

The standard: every feature is gated on its own branch at its risk tier, then
all of them are gated together as one candidate, Dylan approves a preview of
that candidate, and only then does it ship.

## Per-feature gate

The release board ("Next release X.Y.Z" in Array) is the release's single
source of truth. Every feature in the release has a card on it. The feature's
owner assigns themselves to the card, comments at each stage (built, witness
RED and GREEN, gate run, each review and what it changed), and moves the card
to Done only when its tier's gate below has passed and the release lead has
written PASS in its record. A feature with no card is not in the release.

Pick the tier by what the feature can break, not by how big the diff is. When
unsure, take the higher tier.

| Tier | What it covers | What it owes |
|---|---|---|
| 1 | State, persistence, supervisor or agent lifecycle, auth or accounts, anything that can lose user work or crash | A witness RED before and GREEN after through the production path. Every leg on that branch alone, awake group included. Two independent reviews given the diff, not the author's conclusions: one Codex, one Claude. A measurement on a COPY of a real store where state or persistence is touched. |
| 2 | User-visible behaviour: pointer, camera, sidebar, perf | A witness RED before and GREEN after through the real event path (`NSApp.sendEvent`, not a direct `mouseDown`). Every leg on the touched seams plus the affected legs. One independent review. Light and dark stills, or a short film of the real app. |
| 3 | Cosmetic or copy | An in-situ render in light and dark. Targeted legs. One review. |

One command runs the matrix part:

```sh
scripts/feature-gate.sh <branch> --tier 1|2|3 [--legs --a-check,--b-check] [--skip-awake] [--slug name]
```

- Tier 1 runs every leg. Tiers 2 and 3 run the legs `scripts/leg-coverage.py`
  says the branch reaches since it left `origin/array/integration` (`--base`
  changes that), plus any seam legs named with `--legs`. A change that reaches
  a path no specific leg covers (or `Package.swift`, `ThirdParty/`, dispatcher
  code that adds no flag, a removal from `run-matrix.sh`) runs every leg, and
  the record says why.
- Tiers 1 and 2 run the awake (display/focus) group, so they need an unlocked,
  awake Mac. `--skip-awake` runs without it; the record then lists each awake
  leg as unverified, and the feature is not done until an awake run covers it.
- It runs through `nightly-gate.sh --feature`: the same quiet wait, shared lock,
  warm checkout and environment as the release gate. It never builds a
  candidate and writes nothing a ship reads. A held lock refuses the run.
- Exit 0 means the selected legs are green, nothing more.

Every run appends to that feature's evidence record,
`~/array-scratch/release-features/<slug>.md` (slug: the branch name without
`array/`). Records live there because `releases/` is never committed. The
script writes the tier's checklist, each matrix run (selection, passed, failed,
known, retry-passed, not run, results path) and `Verdict: OPEN`. The feature's
owner pastes the witness RED and GREEN output, the reviews (who, which harness,
what they found, what was fixed) and the stills, film or store measurement. The
release lead reads the record and writes `PASS` or `HOLD` with the reason. A
change to the branch after a PASS needs a new run and a new verdict.

## Combined candidate

1. Cut one candidate branch from `origin/array/integration`
   (`array/candidate-X.Y.Z`) and merge every feature whose card is Done and
   whose record says PASS.
   A merge conflict resolved by hand reopens that feature's verdict.
2. Build the combined preview, `scripts/dev-app.sh` from the candidate bench
   (it rebuilds `~/Desktop/Array Dev.app`), and give Dylan that preview. Nothing
   below runs until he approves it.
3. Gate the exact candidate head:
   `ARRAY_NIGHTLY_REF=array/candidate-X.Y.Z scripts/nightly-gate.sh`, then
   `scripts/nightly-gate.sh --awake <candidate sha>` on an unlocked Mac. Green
   builds the optimized prod candidate for that commit. A red leg goes back to
   its feature branch, which is re-gated at its tier and merged again.
4. Dylan lands the candidate head on `array/integration`. A fast-forward keeps
   the gated commit, so the ship below reuses its gate and candidate. Then follow
   the fast path below: prepare, then publish on his go.

## Ship from a gated head (the fast path)

`scripts/nightly-gate.sh` (installed below) gates each new
`origin/array/integration` head within the hour. When the matrix is green it
builds the optimized prod candidate for that exact commit. A ship reuses both:

```sh
scripts/ship-release.sh --version X.Y.Z --notes notes.md   # prepare: no compile, no push
scripts/ship-release.sh --version X.Y.Z --publish          # only on Dylan's go
```

Prepare runs on a clean checkout at `origin/array/integration`. It finds the
green gate covering HEAD: that commit, or an ancestor whose later commits touch
only `.plans/`, `website/` or `docs/VERSIONING.md`. It runs the awake group
there if it has not run (an unlocked, awake screen), takes the next build
number, signs and notarizes the candidate, audits the bundle, appends one
appcast item and one ledger row, and commits locally. Publish uploads both
DMGs, pushes `array/integration` and `main`, and returns only once
arrayapp.dev serves the build and both downloads answer (15-minute timeout).

Prepare holds the shared matrix lock from finding the candidate until it is
signed, so a gate cannot prune that candidate meanwhile; it refuses while a
gate, matrix or release build holds the lock. A `gh` error other than "release
not found" stops it rather than reading as "not published". A GitHub release
that is in neither the ledger nor the feed also stops it, because its build
number is unknown: land its ledger row and feed item, or delete it, first.

Pre-existing reds classify from `scripts/matrix-known-failures.json`: each entry
has a reason, evidence and an expiry within 30 days, after which the leg counts
as a real failure again. A leg red in the parallel group gets one serial retry,
reported as `retry-passed`. Witnesses: `scripts/check-ship-release.py` (gate,
feature gate, ship) and `scripts/check-leg-coverage.py` (leg selection). The
manual steps below remain the fallback.

## Cut a preview and release candidate together

1. Run `scripts/nightly-gate.sh --latest-green` to select the newest green
   nightly commit on `origin/array/integration`. Inspect its report (see below),
   complete the awake checks, and cut the candidate from that exact commit.
   Record the report and commit in the release notes. Do not run the full matrix
   during publishing.
2. Reserve the next global build number in docs/VERSIONING.md: both tip and
   stable consume the same +1 sequence. Check published GitHub releases too,
   including prereleases; never reuse an allocated published number.
3. In the release bench run `scripts/prepare-ghosttykit.sh`, then
   `scripts/make-app-bundle.sh --configuration release --channel prod --output releases/candidate/Array.app`.
   This is the only optimized compile (budget 12–16 minutes, measured in the release audit).
   The script refuses while a matrix process runs or its lock is held
   (`ARRAY_MATRIX_LOCK`, default `/tmp/array-matrix.lock`; the nightly runner
   must use the same path). Preview the same source through
   `scripts/dev-app.sh` (roughly 16 seconds), on its scratch project only.
4. Stamp the candidate's Info.plist with the intended version and build before
   signing. Tip versions use `X.Y.Z-tip.<12-character-source-commit>`.
   Keep Packaging/Info.plist at its dev defaults. Never launch the prod candidate
   against Dylan's workspace. Use the isolated bundle harness below.
5. Sign/notarize and package without compiling:

   ```sh
   scripts/release-app.sh --bundle releases/candidate/Array.app \
     --identity "Developer ID Application: Dylan Reed (46TTB6J9DZ)" \
     --notary-profile array-notary --set-version X.Y.Z --set-build N
   scripts/check-app-bundle.sh --configuration release --channel prod \
     --bundle qa-runs/<stamp>/release/Array.app
   ```

   Budget 2–10 minutes for Apple notarization plus packaging; this is an estimate,
   not a measured guarantee. Keychain holds Developer ID, array-notary credentials
   and Sparkle EdDSA private key. Never commit signing material or releases/.
6. Publish to opted-in tip users first using the script below; allow dogfooding.
   Dylan reviews the preview and approves stable publication. Promote the same
   optimized executable; changing version metadata requires signing/notarizing
   again, never recompilation. Stable promotion consumes a fresh global build.

## Publish after Dylan approves

1. Stable: archive the notarized `Array-X.Y.Z.dmg` under releases/; upload BOTH
   `Array.dmg` and `Array-X.Y.Z.dmg` to `dylanreedx/array-releases`, tag `vX.Y.Z`,
   with friend-readable release notes. Use `gh release create` only after approval.
2. Run `scripts/generate-appcast.sh --dmg releases/Array-X.Y.Z.dmg --version X.Y.Z
   --build N`. It signs the new DMG using the Keychain key, leaves every existing
   item byte-for-byte, and adds a one-hour phased rollout interval on the new item only (seven
   Sparkle groups, reaching all groups in about six hours). Manual checks can see the update immediately.
3. Append the stable row to docs/VERSIONING.md. Review the feed, then commit ledger
   and website/public/appcast.xml. With Dylan's approval push array/integration,
   fast-forward main, and push main. Vercel deploys the feed from main.
4. Verify the deployed appcast, both downloadable assets, and an older installed
   copy's Check for Updates. Do not replace /Applications/Array.app yourself.

## Tip and rollback

Settings → General → Updates → Update channel offers Stable (default) or Tip.
The single appcast uses Sparkle's `tip` channel. Tip also receives stable items;
Stable ignores tip items. Dev builds and QA never start the updater. Switching
back to Stable waits for a higher stable build; it does not downgrade.

For a built, signed, stapled tip bundle (already stamped before signing):

```sh
scripts/release-tip.sh --dry-run <notarized-Array.app> <source-commit>
scripts/release-tip.sh <notarized-Array.app> <source-commit>
```

Dry run only reads metadata and prints the planned artifacts, ledger row and exact
remote commands. Normal execution validates the app, makes both DMG assets, signs
the enclosure and edits the feed and ledger locally. It STOPS before upload,
commit or push. Review the diff and obtain Dylan's approval before executing the
printed commands. Tip is a GitHub prerelease so the website latest-download URL
continues to serve stable. The app inside the DMG is stapled; the tip DMG itself
is not notarized separately.

One-time rollout: ship a stable version containing the channel setting, deploy
its appcast, then publish the first tip with the next global build. There is no
second feed or website setting to provision. Preserve the releases/ archive and
back up the Keychain Sparkle key.

Rollback means roll forward: revert the faulty change, build a new candidate with
an unused higher global number, and add `<sparkle:criticalUpdate/>` to its item.
Remove its phasedRolloutInterval to bypass staging. Publish both assets, append
ledger, deploy feed after approval. Never lower a version number or replace an
existing download in place. A critical item cannot be skipped. Confirm the update
from an affected installed build. Older pre-Sparkle 0.2.0 installs need a manual
replacement.

## Promote a nightly checked commit

One-time setup: run `scripts/nightly-gate.sh --install` from the landed repository
(`--install --dry-run` previews paths and launchctl commands). This checks
hourly in the logged-in user's session and gates only a new head (an
already-gated head exits in seconds); `--uninstall` removes the job.
The Mac must be awake to start it; caffeinate prevents idle system sleep during
the run. The installed wrapper is copied to `~/array-scratch/nightly-gate`;
rerun install after wrapper changes. Installation only sets up the scheduled job.
Install records your shell's PATH for the job, so legs find claude, codex and pi;
reinstall after moving those CLIs. The checkout runs on the local branch
`gate/nightly-checkout`. To gate a branch before it lands, run it by hand with
`ARRAY_NIGHTLY_REF=<branch> scripts/nightly-gate.sh`.

Before the matrix, and before taking the shared lock, the gate waits until no other
`swift-build` is compiling (an idle one does not count) and `fseventsd` stays
under 50% CPU for two samples 30 s apart, for at most 30 minutes, then runs
even if the Mac is still busy. It then takes the lock as usual; if another gate
or release holds it, this run is skipped. `summary.json` records the wait under `contention` (`quiet`, `waited_seconds`, the worst
load seen). A red leg from a run with `quiet: false` is worth re-gating before
it is treated as a regression.

Run `scripts/nightly-gate.sh --latest-green` to print the newest integration
ancestor with a green nightly result. Inspect `~/array-scratch/nightly-gate/latest.json`
and `results/<commit>/summary.md` before selecting that exact commit for promotion.
Nightlies run the independent matrix group; complete
`scripts/run-matrix.sh --awake-only` at that same commit while unlocked before release.
A managed-agent run retains crash-witness deferrals and is not complete crash
coverage. Missing results or a red nightly do not authorize promotion.
Results expire after 14 days. The job requires the parallel matrix cleanup on
integration and uses its shared release/matrix lock; contention skips the run.
