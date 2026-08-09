# Releasing Array

The one-page runbook for shipping a release. Program history and rationale live in
`docs/38-tickets/95-go-live.md`; this file is just the steps.

## Prerequisites (already provisioned)

- Developer ID Application identity in the login Keychain:
  `Developer ID Application: Dylan Reed (46TTB6J9DZ)`
- notarytool keychain profile: `array-notary`
- Sparkle private EdDSA key in the login Keychain
  ("Private key for signing Sparkle updates"). **Back it up. Never in the repo.**
- `releases/` dir at the repo root (gitignored) holding every shipped
  `Array-<version>.dmg` from 0.2.1 on — the appcast is generated from it.
- Public releases repo: `dylanreedx/array-releases` (code repo stays private).

## Ship a release

1. **Version numbers.** Pick `X.Y.Z` and a build number `N`. `N` (CFBundleVersion)
   MUST increase every release — it is the field Sparkle compares. Keep a simple
   +1 sequence (0.2.0 was build 2).

2. **Build, sign, notarize, staple:**

   ```sh
   scripts/release-app.sh \
     --identity "Developer ID Application: Dylan Reed (46TTB6J9DZ)" \
     --notary-profile array-notary \
     --set-version X.Y.Z --set-build N
   ```

   Ends with `spctl` verification. Artifacts land in `qa-runs/<stamp>/release/`.

3. **Archive the DMG:** copy `Array-X.Y.Z.dmg` into `releases/`.

4. **Publish on GitHub** (release notes = what changed, friend-readable):

   ```sh
   cp "qa-runs/<stamp>/release/Array-X.Y.Z.dmg" /tmp/Array.dmg
   gh release create vX.Y.Z --repo dylanreedx/array-releases \
     --title "Array X.Y.Z" --notes "..." \
     /tmp/Array.dmg "releases/Array-X.Y.Z.dmg"
   ```

   BOTH assets every time: `Array.dmg` (constant name — the site's
   latest-download URL depends on it) and `Array-X.Y.Z.dmg` (appcast permalink).

5. **Regenerate the appcast** (signs items with the Keychain EdDSA key):

   ```sh
   scripts/generate-appcast.sh
   ```

   Writes `website/public/appcast.xml` with per-version GitHub enclosure URLs.

6. **Deploy the feed + record the release:** append a row to the release ledger
   (`docs/VERSIONING.md` — the ledger is how the next release knows its build
   number), then commit it together with `website/public/appcast.xml`, push
   `array/integration`, fast-forward `main` (Vercel deploys arrayapp.dev from
   `main`).

7. **Spot-check:**
   - `curl -s https://arrayapp.dev/appcast.xml` shows the new item.
   - Download `https://github.com/dylanreedx/array-releases/releases/latest/download/Array.dmg`,
     confirm the version.
   - An installed previous version sees the update (Array → Check for Updates…).

## Verification gates before publishing

- `scripts/check-app-bundle.sh --configuration release` passes (bundle harness:
  self-checks, Sparkle embedding, codesign, launch smoke, pollution guards).
- For releases with app-code changes: the relevant matrix legs are green
  (`scripts/run-matrix.sh`; two KNOWN-RED pre-existing gates are documented in
  the go-live doc — don't chase them as regressions).

## Notes

- **Channels:** only `release-app.sh` produces a prod-identified bundle
  (`dev.arrayapp.macos`). Plain `make-app-bundle.sh` output is the DEV channel
  ("Array Dev", own state, updater inert) — safe to run next to the prod copy.
  Verify a release bundle with `check-app-bundle.sh --channel prod`.

- 0.2.0 shipped without Sparkle: those installs cannot auto-update and make one
  final manual download. Every install from 0.2.1 on updates in-app.
- Sparkle asks the user for permission to check automatically on second launch
  (`SUEnableAutomaticChecks` deliberately unset); "Check for Updates…" always
  works manually.
- If notarization fails, `release-app.sh` prints the log path; the notary
  history is available via `xcrun notarytool history --keychain-profile array-notary`.
