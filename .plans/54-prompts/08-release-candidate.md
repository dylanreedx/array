# WS8 dispatch — integrated 0.8.0 release candidate

## Shared release-candidate contract

This packet defines **WS8: Array 0.8.0 release candidate**. It has no implementation-lead role. The rendered `<ROLE>` is `auditor`, `reviewer`, or `tester`; every role is read-only, does not execute the protocol's lead implementation/RED/tooth sequence, modify tracked source/configuration, leave new non-ignored checkout files, or commit, and uses `commits: []`, `red_witness: null`, and `tooth_proof: null`. Ignored build/cache outputs from named checks are allowed. No worker assembles, stamps, signs, notarizes, or publishes the canonical artifact. Begin from the root-supplied final I3 SHA `<BASE_SHA>` in a clean worktree and write all evidence to `<EVIDENCE_DIR>`.

The fully rendered common protocol prepended to this dispatch is binding. The checked-in `00-agent-protocol.md` is an unresolved reference template and never overrides rendered values.

Read `<WORKTREE>/AGENTS.md`, `RELEASE.md`, `docs/VERSIONING.md`, the master plan, all completed workstream reports, and `00-agent-protocol.md`.

### Outcome

Prove that the seven workstreams form one coherent morning-testable candidate. Proposed version is **0.8.0**, proposed build **56**, following shipped 0.7.4/build 55. Do not permanently edit `Packaging/Info.plist`; release scripts stamp artifacts. Do not tag, push, create a GitHub release, copy assets to the public release repo, mutate the appcast, or append the shipped ledger row. Those happen only after Dylan tests and explicitly approves publication.

### Pre-artifact auditor requirements — `ROLE=auditor`, `PHASE=pre-artifact-audit` only

Reviewer and tester roles treat the resulting auditor report as an input and **must not execute this section (including its command block, pre-artifact outputs, or root-only canonical build context)**. They execute only the common read-only rules plus their selected post-audit overlay/phase.

1. Read every lead/reviewer/tester `report.json`; verify candidate SHAs promoted exactly and all absolute artifacts still exist with matching SHA-256.
2. Inspect `scripts/run-matrix.sh` inventory. Confirm every new behavioral witness is invoked and visibly ran; list all eight baseline KNOWN-RED and their candidate disposition. All five performance-related entries must be green and removed from the allowlist. Any remaining known-red tied to a release claim is a blocker; a waiver cannot convert a failing behavior/performance gate to READY.
3. Run the full debug integration matrix and, separately, all named release-configuration builds/direct performance gates from the clean integrated checkout with isolated state. Never cite the debug matrix as release-binary evidence.
4. Run the complete compound performance scenario and an independent shorter final soak after the full matrix, detecting interaction regressions introduced by integration.
5. Run UI capture flows and inspect candidates for zones, awareness, page zoom, transcript parity, and backgrounds. Do not bless baselines.
6. Build and verify a release-configuration DEV-channel bundle as a pre-artifact packaging smoke using a scratch project/store. It is not the canonical RC and must not be reported as one.
7. Draft friend-readable release notes and a proposed ledger row under the evidence directory only.
8. Return and ingest the pre-artifact audit. Root validates the evidence root, then alone runs the documented release script with 0.8.0/56 and creates exactly one unpublished canonical DMG. A later independently rendered artifact-tester dispatch supplies and verifies the exact canonical DMG path; the pre-artifact auditor neither needs nor guesses it.

### Blocking verification

```sh
export CONTINUUM_PROJECT_ROOT="<QA_PROJECT_ROOT>"
export CONTINUUM_APP_SUPPORT="<QA_APP_SUPPORT>"
export TMUX_TMPDIR="<QA_TMUX_TMPDIR>"
unset TMUX TMUX_PANE
git status --short --branch
swift build
swift build -c release
scripts/run-matrix.sh
swift run -c release ContinuumRevivedPerfChecks
.build/release/Array --perf-budget-zoom-check
.build/release/Array --canvas-zoom-invalidation-probe-check
.build/release/Array --perf-budget-magnify-slope-check
.build/release/Array --perf-budget-gesture-transition-check
.build/release/Array --tile-surface-residency-check
.build/release/Array --perf-power-user-compound-check
CONTINUUM_PERF_CONFIGURATION=release \
CONTINUUM_PERF_APP="<WORKTREE>/.build/release/Array" \
CONTINUUM_PERF_OUT="<EVIDENCE_DIR>/perf-final" \
CONTINUUM_PERF_RUN_ID="<RUN_ID>-release" \
scripts/run-perf-ceilings.sh
scripts/check-app-bundle.sh --configuration release --channel dev --output-dir "<EVIDENCE_DIR>/bundle-preflight"
scripts/check-matrix-inventory.sh
node scripts/check-qa-flows.js
node scripts/release-evidence.js validate --root "<RUN_ROOT>"
git diff --check
```

Also run every new workstream flag directly and the final power-user/restart/visual flows. Classify `scripts/run-matrix.sh` as debug integration coverage; the direct `.build/release/Array` flags, release-configured ceiling run, and release DEV bundle are the pre-artifact release-configuration evidence. Read the matrix summary, not only the shell exit code: it exits zero for allowlisted failures and unexpected passes. Record commands, status, duration, and output. Do not test update publication against the live feed.

### Final artifact set

```text
<EVIDENCE_DIR>/report.json
<EVIDENCE_DIR>/matrix.log
<EVIDENCE_DIR>/matrix-summary.txt
<EVIDENCE_DIR>/release-build.log
<EVIDENCE_DIR>/bundle-check.log
<EVIDENCE_DIR>/perf-final/
<EVIDENCE_DIR>/visual-manifest.json
<EVIDENCE_DIR>/diagnostic-report-diff.txt
<EVIDENCE_DIR>/release-notes-draft.md
<EVIDENCE_DIR>/ledger-row-draft.md
<EVIDENCE_DIR>/pre-artifact-report.md
```

The pre-artifact auditor must not write a READY morning report. After its PASS is ingested and the root manifest validates, root uses the exact clean I3 checkout and one explicit canonical directory:

```sh
canonical_release_dir="<RUN_ROOT>/release/canonical"
release_argv_file="$canonical_release_dir/release-argv.txt"
if [[ -e "$canonical_release_dir" ]]; then
  echo "Refusing non-new canonical release directory: $canonical_release_dir" >&2
  exit 1
fi
mkdir -p "$canonical_release_dir"
printf '%s\n' \
  'scripts/release-app.sh' \
  '--configuration' 'release' \
  '--output-dir' "$canonical_release_dir" \
  '--identity' 'Developer ID Application: Dylan Reed (46TTB6J9DZ)' \
  '--notary-profile' 'array-notary' \
  '--set-version' '0.8.0' \
  '--set-build' '56' > "$release_argv_file"
scripts/release-app.sh \
  --configuration release \
  --output-dir "$canonical_release_dir" \
  --identity "Developer ID Application: Dylan Reed (46TTB6J9DZ)" \
  --notary-profile array-notary \
  --set-version 0.8.0 \
  --set-build 56
node scripts/release-evidence.js artifact-create \
  --root "<RUN_ROOT>" \
  --candidate-sha "<BASE_SHA>" \
  --release-argv "$release_argv_file" \
  --release-log "$canonical_release_dir/release.log" \
  --app "$canonical_release_dir/Array.app" \
  --dmg "$canonical_release_dir/Array-0.8.0.dmg" \
  --output "$canonical_release_dir/canonical-artifact-manifest.json"
```

Before the command, root proves HEAD equals I3, the checkout is clean, the canonical directory does not exist, and no other 0.8.0/56 artifact is marked canonical. Never reuse or partially overwrite an earlier app/log/argv/manifest directory. The canonical directory then contains exactly one DMG plus `Array.app`, the release log/intermediate outputs, atomically written `SHA256SUMS`, recorded argv, and `canonical-artifact-manifest.json`; the release log and manifest retain the signing/notary/staple/Gatekeeper evidence. The manifest binds I3 candidate commit, release-script path/hash/argv, release-log hash, bundle ID/channel/version/build, embedded executable SHA-256, deterministic bundle-tree inventory/hash, Team ID/signing identity/designated requirement, app and DMG notary submission/ticket status, staple validations, Gatekeeper assessments, and DMG SHA-256. Inventory every 0.8.0/56 output and fail if any report/test identifies a different build/path/hash as canonical.

Final order is mandatory: pre-artifact PASS → root canonical build → ingest canonical manifest/logs → independent artifact tester → ingest tester report → independent post-artifact identity review → ingest reviewer report → `release-evidence validate` → root generates `<RUN_ROOT>/release/final/morning-report.md` from that validated manifest → ingest the morning report → final validation. Only then may the morning report begin `READY TO TEST` or `READY WITH NAMED WAIVER`; otherwise it begins `NOT READY`. It names candidate SHA and one canonical DMG path/hash, lists real checks/results, links primary screenshots absolutely, includes before/after performance and soak/diagnostic results, names every skipped/unverified item, and states that publication was intentionally not performed.

### Stop rules

Stop on any unexpected matrix failure, requested known-red, missing evidence, dirty candidate, state isolation doubt, release-build failure, version/build mismatch, bundle identity failure, missing identity-chain field, required `DISPLAY_DEFERRED`/`capture_unavailable`, missing raw performance item, or missing primary/diff screenshot. Do not modify implementation to repair failures; return the owning workstream and exact evidence to root. A subjective visual judgment may be named for Dylan only after all objective evidence exists; no other skipped/deferred gate can yield READY.

## Independent release reviewer overlay

Root renders this role twice and strips the irrelevant phase subsection.

### Pre-artifact review — `ROLE=reviewer`, `PHASE=pre-artifact-review`

Audit the auditor report and every release claim against a workstream witness and actual matrix invocation. Verify version/build monotonicity, dev defaults unchanged, proposed notes accurate, no unapproved appcast/ledger/tag/push/publication mutation, and no KNOWN-RED contradicts “ready.” Report any claim whose only support is a screenshot or a lead's prose. This review must PASS and be ingested before root creates an artifact.

### Post-artifact identity review — `ROLE=reviewer`, `PHASE=post-artifact-review`

After artifact testing, perform a second read-only reconciliation of the canonical manifest, root release command/log, tester recomputation, exact I3 SHA, single-canonical inventory, and final evidence inventory. Do not rerun the pre-artifact auditor steps. READY is blocked until this report is ingested.

## Independent release tester overlay

This overlay is only `ROLE=tester`, `PHASE=artifact-test`; do not execute the pre-artifact auditor section. From a second clean checkout at the exact candidate SHA, rerun the full matrix/inventory, release build, final performance scenario, restart persistence smoke, and representative visual flows. Then mount and verify the one exact `<CANONICAL_RC>` DMG with this explicit isolated path (install cleanup traps before attaching):

```sh
canonical_mount_dir="<EVIDENCE_DIR>/canonical-mount"
canonical_check_dir="<EVIDENCE_DIR>/canonical-bundle-check"
mkdir -p "$canonical_mount_dir" "$canonical_check_dir"
canonical_attached=0
cleanup_canonical_mount() {
  if [[ "$canonical_attached" == 1 ]]; then
    hdiutil detach "$canonical_mount_dir" >/dev/null 2>&1 || true
  fi
}
trap cleanup_canonical_mount EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$canonical_mount_dir" "<CANONICAL_RC>"
canonical_attached=1
scripts/check-app-bundle.sh --configuration release --bundle "$canonical_mount_dir/Array.app" --channel prod --output-dir "$canonical_check_dir"
node scripts/release-evidence.js artifact-verify \
  --manifest "<RUN_ROOT>/release/canonical/canonical-artifact-manifest.json" \
  --candidate-sha "<BASE_SHA>" \
  --dmg "<CANONICAL_RC>" \
  --mounted-app "$canonical_mount_dir/Array.app" \
  --output "<EVIDENCE_DIR>/canonical-identity-verification.json"
cleanup_canonical_mount
canonical_attached=0
trap - EXIT
```

Independently recompute signature identity/designated requirement/Team ID, notarization submission/ticket and staple validity, Gatekeeper, exact bundle ID/channel and 0.8.0/build 56, embedded executable hash, sorted mounted bundle-tree hash/inventory, DMG SHA-256/content, release-script/log provenance, and launch with a scratch store. Inventory all 0.8.0/56 outputs and FAIL if any report or test references a different source/build/path/hash or a second artifact is marked canonical. Do not publish. Return absolute logs and a binary READY/NOT READY recommendation.
