# Release evidence CLI

`scripts/release-evidence.js` owns the immutable evidence root used by a release
run. It has no package dependencies. All paths passed to it must be absolute and
must resolve inside the initialized root; symlinks cannot escape that boundary.

```sh
scripts/release-evidence.js init --run-id "$run_id" --root "$run_root" --base-sha "$base_sha"
scripts/release-evidence.js ingest --root "$run_root" --report "$report" \
  --capture-manifest "$capture_manifest"
scripts/release-evidence.js validate --root "$run_root"
scripts/release-evidence.js summary --root "$run_root" --output "$run_root/morning-report.md"
```

`ingest` is idempotent for the same path and bytes, but rejects a report or
capture manifest changed in place. `validate` re-hashes all ingested inputs and
their referenced artifacts before atomically recording validation. It rejects
partial visual inventories, unproven baselines or masks, incomplete performance
repetitions, and summaries that cannot be traced to their raw inputs. A missing
WindowServer capture is represented only by a `DISPLAY_DEFERRED` report with a
typed `capture_unavailable` failure.

The release identity commands bind a clean source commit and exact release argv
and log to the app bundle, executable, signing/notary state, and DMG:

```sh
scripts/release-evidence.js artifact-create --root "$run_root" \
  --candidate-sha "$candidate_sha" --release-argv "$argv_file" \
  --release-log "$release_log" --app "$app" --dmg "$dmg" \
  --output "$run_root/release/canonical/manifest.json"

scripts/release-evidence.js artifact-verify --manifest "$canonical_manifest" \
  --candidate-sha "$candidate_sha" --dmg "$dmg" \
  --mounted-app "$mounted_app" --output "$verification_report"
```

Creation accepts only production identity `dev.arrayapp.macos`, version 0.8.0,
build 56, a clean checkout at the candidate SHA, and fresh accepted app and DMG
notary records in the retained release log. It writes a conventional
`SHA256SUMS` beside the DMG using a temporary file and atomic rename. Verification
recomputes the DMG checksum and mounted executable/bundle-tree/signing identity;
a matching filename or plist version is not sufficient.

Run the executable contract suite with:

```sh
node scripts/test-release-evidence.js
```
