# Releasing Array

## Cut a preview and release candidate together

1. Choose a commit with a passing nightly matrix report. Record that report and
   commit in the release notes. Do not run the full matrix during publishing.
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
2. Run `scripts/generate-appcast.sh`. It signs stable archives using the Keychain
   key, preserves tip items, and adds a one-day phased rollout interval (seven
   Sparkle groups). Manual checks can see the update immediately.
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
