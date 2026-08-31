# Release evidence CLI

`scripts/release-evidence.js` owns the immutable evidence root used by a release
run. It has no package dependencies. All paths passed to it must be absolute and
must resolve inside the initialized root; symlinks cannot escape that boundary.

```sh
scripts/release-evidence.js init --run-id "$run_id" --root "$run_root" --base-sha "$base_sha"
scripts/release-evidence.js inventory --root "$run_root" --file "$run_root/expected-inventory.json"
scripts/release-evidence.js ingest --root "$run_root" --report "$report" \
  --capture-manifest "$capture_manifest"
scripts/release-evidence.js validate --root "$run_root"
scripts/release-evidence.js summary --root "$run_root" --output "$run_root/morning-report.md"
```

The root-owned inventory is immutable and must be locked before ingestion. It
declares every expected workstream/role, visual state/appearance/role,
performance case/repetition/artifact role, and capture manifest. Empty visual or
performance inventories are valid only when the role explicitly sets
`allow_zero_performance: true`. A nonempty performance inventory is always a
release lane with a nonempty seed, at least five repetitions, global identity
binding, and the complete raw/profiler/signpost/sample/vmmap/soak/diagnostic/
visual-boundary role set. The hashed inventory file—not the convenience copy in
`manifest.json`—is authoritative. `ingest` is idempotent for the same path and bytes, but rejects a report or
capture manifest changed in place. `validate` re-hashes all ingested inputs and
their referenced artifacts before atomically recording validation. It rejects
partial visual inventories, unproven baselines or masks, incomplete performance
repetitions, and summaries that cannot be traced to their raw inputs. A missing
WindowServer capture is represented only by a `DISPLAY_DEFERRED` report with a
typed `capture_unavailable` failure.

Capture manifests use `kind: qacapture|external`, bind every artifact by unique
case/iteration/visual-state/role, and hash both image and semantic artifact. A
`PASS` capture contains only inspected-PASS actual artifacts; failures, deferrals,
and judgment states must use matching manifest and artifact statuses.

The release identity commands bind a clean source commit and exact release argv
and log to the app bundle, executable, signing/notary state, and DMG:

```sh
scripts/release-evidence.js artifact-create --root "$run_root" \
  --candidate-sha "$candidate_sha" --source-repo "$clean_i3_checkout" \
  --release-argv "$argv_file" \
  --release-log "$release_log" --app "$app" --dmg "$dmg" \
  --output "$run_root/release/canonical/manifest.json"

scripts/release-evidence.js artifact-verify --root "$run_root" --manifest "$canonical_manifest" \
  --candidate-sha "$candidate_sha" --dmg "$dmg" \
  --mounted-app "$mounted_app" --output "$verification_report"
```

Creation accepts only production identity `dev.arrayapp.macos`, version 0.8.0,
build 56, a clean checkout at the inventory's I3 SHA, exact NUL-delimited release
argv (release script, release configuration, Developer ID, notary profile,
version, and build), and fresh accepted app and DMG
notary records in the retained release log. It writes a conventional
`SHA256SUMS` beside the DMG using a temporary file and atomic rename. Verification
is anchored to the single canonical entry in the run manifest, rechecks notary,
staple, Gatekeeper, and signing results, and recomputes the DMG checksum and
mounted executable/bundle-tree/signing identity;
a matching filename or plist version is not sufficient.

Run the executable contract suite with:

```sh
node scripts/test-release-evidence.js
```
