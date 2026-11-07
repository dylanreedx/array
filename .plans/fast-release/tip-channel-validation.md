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

The channel witness checks delegate output and acceptance semantics; it does
not exercise Sparkle's network/parser/installer pipeline.

One-time rollout: ship the channel-capable stable app and website feed first,
then approve the first tip prerelease. No new website feed or service required.
