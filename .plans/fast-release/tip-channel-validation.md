# Release once and tip channel validation

Base: d41dad04. Branch: array/release-tip-channel. No remote mutations performed.

Passed:
- scripts/prepare-ghosttykit.sh linked the macOS framework.
- swift build --product Array (final build: 103.43 seconds).
- .build/debug/Array --update-channel-check (isolated preference suite; real,
  inert SPUUpdater and production delegate, Stable → Tip → Stable).
- bash -n for the six changed shell scripts.
- git diff --check.
- release-tip.sh --dry-run with temporary Info.plist fixture: build 96,
  0.7.45-tip.d41dad048682. Printed two DMG assets, prerelease upload,
  ledger row, commit and explicit HEAD pushes. No output artifacts/feed edits.
- Held fcntl matrix lock refuses release compile (exit 1).
- Running process named run-matrix.sh refuses release compile (exit 2).
- check-app-bundle.sh --configuration release without bundle refuses (exit 2).
- scripts/benches.sh ran at pickup and completion; bench retained for local commits.

Failed then corrected:
- First compile: misplaced @MainActor on updater static property; corrected.
- Second compile: SettingsPanes.swift edited during compilation; fresh build passed.
- Shell cleanup command was rejected; temporary fixture cleaned using Python.

Not run:
- Full matrix (nightly helper owns it); new leg registered in default matrix.
- Release optimized compilation, signing, notarization, non-dry tip packaging,
  live Sparkle download/update or real GitHub publication.
- Light/dark Settings visual verification. No preview is presented as verified.
- RED-before mutation proof; the new flag did not exist on the base revision.

Integration requirement: nightly runner must hold /tmp/array-matrix.lock (flock)
for its duration, or export ARRAY_MATRIX_LOCK pointing to its lock. Directory
locks also refuse. The process fallback handles the existing lockless matrix.
The lock interface has not been checked against the other helper's change.

The revised channel witness resolves the actual SettingsSchema field for
array.updateChannel and calls SettingsField.setValue into an isolated defaults
suite. It directly asserts the production delegate returns [] → ["tip"] → [].
There is no copied acceptance/filtering logic. Sparkle's public appcast API has
no channel-filtering operation; its network/parser/installer pipeline is not
exercised.

One-time rollout: ship the channel-capable stable app and website feed first,
then approve the first tip prerelease. No new website feed or service required.

## Review follow-up

- generate-appcast.sh defines PHASED_ROLLOUT_INTERVAL=3600 once, at the top.
  Only the newest previously unpublished stable item receives this interval.
  Seven groups reach full rollout in about six hours. Previously published
  items retain their prior interval or absence of one; old archive-only items
  do not acquire staging. Tip items remain preserved.
- Disposable XML fixture executed the script's actual embedded transformation:
  newest=3600, historic present/absent policies preserved, archive-only historic
  staging removed, and rerunning preserved those results. PASS.
- bash -n scripts/generate-appcast.sh and git diff --check: PASS.
- pgrep found no run-matrix.sh process immediately before starting the targeted
  debug rebuild. No preview bundle or release build was made.
- Revised swift build --product Array: PASS (108.25 seconds; existing warnings).
- Revised .build/debug/Array --update-channel-check: PASS, output:
  `update-channel-check passed: Settings writer → Sparkle delegate: Stable [] → Tip [tip] → Stable []`
- No full matrix, preview app build, release build, remote push or GitHub release.
  Earlier unverified signing, delivery and visual-QA limits remain unchanged.
