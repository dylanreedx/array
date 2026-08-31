# Wave 0 dispatch — evidence CLI and GUI preflight

## Shared Wave-0 target

This packet defines **Wave 0: durable evidence aggregation and native GUI preflight**. The rendered `<ROLE>` controls authority: a lead implements this bounded testing infrastructure; a reviewer or tester treats every lead-directed requirement below as an acceptance criterion and follows only its selected overlay.

The fully rendered common protocol prepended to this dispatch is binding. The checked-in `00-agent-protocol.md` is an unresolved reference template and never overrides rendered values.

Read `<WORKTREE>/AGENTS.md`, the master plan, `00-agent-protocol.md`, `qa/README.md`, `qa/flows/lib.sh`, `qa/setup.sh`, `Sources/ContinuumRevived/App/QACapture.swift`, `Sources/ContinuumRevived/App/UIProbe.swift`, `Sources/ContinuumRevived/App/UIProbeBaseline.swift`, and `scripts/check-qa-flows.js`. Work at `<BASE_SHA>` in `<WORKTREE>` and retain proof under `<EVIDENCE_DIR>`.

### Outcome

Before feature agents start, provide one tested path that:

1. reserves one immutable `<RUN_ID>` and explicit absolute run root;
2. normalizes lead/reviewer/tester reports plus QACapture/external-flow manifests and their expected visual/performance inventories;
3. hashes every referenced artifact, reconciles expected unique states and performance repetitions, rejects missing/nonabsolute/out-of-root paths and schema errors, and atomically writes the root `manifest.json`;
4. verifies the host can actually drive and capture the native app overnight;
5. removes current QA runner ambiguity around executable identity, window targeting, arbitrary boot sleeps, and timestamp-owned run roots;
6. makes the existing performance runner explicitly honor debug/release configuration so all later release measurements use the intended checks executable and app binary.

### Required implementation

Create a dependency-free Node CLI at `scripts/release-evidence.js` with commands:

```text
init --run-id ID --root ABS --base-sha SHA
ingest --root ABS --report ABS [--capture-manifest ABS ...]
validate --root ABS
summary --root ABS --output ABS
artifact-create --root ABS --candidate-sha SHA --release-argv ABS --release-log ABS --app ABS --dmg ABS --output ABS
artifact-verify --manifest ABS --candidate-sha SHA --dmg ABS --mounted-app ABS --output ABS
```

The CLI uses Node standard libraries only, writes via temporary-file + atomic rename, and has executable fixtures/tests for valid report, null reviewer/tester lead-only fields, duplicate ingestion, missing file, relative/out-of-root path, symlink escape, hash mismatch, malformed JSON, non-PNG image, interrupted write, missing unique visual state, missing/nonzero diff path, candidate-only baseline, mask provenance, extra/missing performance repetition, summary/raw mismatch, aborted-flow failure image, and typed `capture_unavailable`. `validate` exits nonzero for any invalid artifact and records no partial success.

The canonical schema is the report contract in `00-agent-protocol.md`. `validate` must:

- require one actual PNG or declared contact-sheet membership for every expected unique state/appearance;
- require every nonzero/failing diff and every primary representative path absolutely, with hashes and semantic-artifact links;
- pin checked-in baseline path/blob hash/commit, classify absent baselines as `candidate_only/NEEDS_JUDGMENT`, and retain any mask file/hash/rationale;
- link each visual failure to case, iteration, command log, semantic snapshot, and reason, while treating `capture_unavailable` as a blocker;
- enumerate and hash every expected performance run 01–05, raw profiler/signpost/sample/vmmap file, soak JSONL/summary, diagnostic before/after/diff, and visual boundary; reject missing/extra repetitions and binary/configuration/seed mismatch;
- reject a summary that does not name its raw inputs or whose claimed sample count disagrees with them.

`artifact-create` and `artifact-verify` provide the final source-to-DMG identity chain. Using Node standard libraries plus read-only macOS system tools, they record/recompute: exact candidate commit and clean status; release-script path/hash and complete argv file; release-log hash; bundle ID/channel/version/build; embedded executable SHA-256; a deterministic sorted bundle tree inventory/hash (regular file hashes, modes, and symlink targets); Team ID, signing identity, designated requirement and verification output; app and DMG notary submission IDs/status; staple validation; Gatekeeper assessment; DMG SHA-256; and the mounted DMG's embedded app/executable/tree values. `artifact-create` must also atomically write conventional `SHA256SUMS` for the single relative DMG filename (temporary file + rename), and both commands verify that file against the manifest and bytes. The verifier rejects any mismatch, a non-0.8.0/56 identity, an I3 SHA mismatch, or more than one artifact marked canonical. Fixtures cover interrupted checksum write, mismatched checksum, a renamed-only impostor, modified executable after signing, wrong source SHA, second-canonical conflict, and stale notary log.

Add a GUI preflight flow, preferably `qa/flows/release-preflight.sh`, and make the smallest required changes to `qa/flows/lib.sh`:

- require an explicit executable or use the current `.build/debug/Array`, never stale `.build/debug/continuum-revived`;
- target the launched PID and resolved CGWindowID, not an owner-name substring and not the whole screen;
- accept an explicit absolute run directory supplied by root rather than silently minting a competing timestamp root;
- replace the fixed boot sleep as the success condition with bounded readiness polling and a named manifest/sentinel; retain a timeout with useful diagnostics;
- preserve at least one positive machine assertion per flow;
- capture the specific app window with nonblank expected bounds;
- verify a deterministic bundled/local WKWebView fixture appears in the pixels;
- verify Accessibility can focus/click/drag the scratch app;
- set and read back `1440×900 pt` and `960×720 pt` content sizes when the display can contain them;
- report actual backing scale and require 2× for the Retina visual lane; otherwise mark `DISPLAY_DEFERRED` without faking it;
- verify Aqua/Dark Aqua switching, isolated project/app-support roots, and QACapture plus external capture;
- check Screen Recording access through actual nonblank pixels and actionable failure output;
- start a scoped sleep-prevention assertion for the run and guarantee cleanup on exit.

Update `scripts/run-perf-ceilings.sh` with a tested `CONTINUUM_PERF_CONFIGURATION=debug|release` contract. It must invoke `swift run -c "$configuration" ContinuumRevivedPerfChecks`, build/select the matching Array binary when no explicit app is supplied, and reject an explicit app whose resolved build path/configuration conflicts with the requested configuration. Preserve the existing default as debug for ordinary developer use.

Do not request or alter system privacy permissions automatically. Detect and report. Do not touch `/Applications/Array.app` or production state.

### Owned scope

- new `scripts/release-evidence.js` and focused report/visual/performance/canonical-artifact test fixtures;
- new Wave-0 QA flow/expectation files;
- narrow `qa/flows/lib.sh`, `qa/setup.sh`, `qa/README.md`, and `scripts/check-qa-flows.js` changes needed for the contract;
- narrow QACapture manifest/readiness fields only if existing external state cannot supply them.
- narrow `scripts/run-perf-ceilings.sh` plus executable contract tests for debug/release selection; do not alter budgets or product scenarios.

Do not change product feature code, UI baselines, performance budgets, or matrix known-reds.

### Required witnesses

- CLI RED/GREEN/tooth tests for every invalid-input case above.
- Performance runner RED/GREEN tests prove the requested checks executable and app configuration match; a release request cannot silently run the debug checks target.
- Canonical-artifact fixtures prove source/bundle/executable/signing/notary/DMG identity mismatches cannot validate merely because filename, version, and build look right.
- Run-root isolation: two test run IDs cannot overwrite each other.
- App process/window identity: a decoy window cannot be captured.
- Readiness timeout and successful named readiness.
- QACapture and external window images are nonblank, expected size, and include the local WKWebView ruler fixture.
- Accessibility action changes a semantic state that the manifest records.
- Permission failure produces `DISPLAY_DEFERRED` with the missing capability, not PASS.
- Cleanup proves no scratch app, sleep assertion, or temporary isolated state remains unless `KEEP` is explicitly set.

### Required commands

```sh
export CONTINUUM_PROJECT_ROOT="<QA_PROJECT_ROOT>"
export CONTINUUM_APP_SUPPORT="<QA_APP_SUPPORT>"
export TMUX_TMPDIR="<QA_TMUX_TMPDIR>"
unset TMUX TMUX_PANE
swift build
qa/setup.sh
node scripts/check-qa-flows.js
node scripts/release-evidence.js validate --root "<EVIDENCE_DIR>/fixture-valid"
CONTINUUM_PERF_CONFIGURATION=release CONTINUUM_PERF_OUT="<EVIDENCE_DIR>/perf-runner-smoke" scripts/run-perf-ceilings.sh
qa/flows/release-preflight.sh
git diff --check
```

Register the new flow in the existing QA inventory. Do not add a product self-check unless a production seam genuinely requires it.

### Success

Root can allocate one run root, all later agents can ingest/validate reports deterministically, release performance invocations cannot fall back to debug, and the native display lane is either proven ready with concrete screenshots or fails early with `DISPLAY_DEFERRED`. Independent reviewer and tester reports are clean/read-only and use null lead-only evidence fields.

## Independent reviewer overlay

Audit path containment, symlink handling, hash validation, atomic writes, duplicate/idempotent ingest, visual/performance inventory reconciliation, baseline/mask provenance, source-to-DMG canonical identity fields, schema role distinctions, PID/window identity, readiness polling, cleanup/traps, privacy detection, state isolation, and debug/release runner selection. Reject whole-screen capture, arbitrary sleep as readiness, stale process-name matching, or a tool that can accept missing artifacts.

## Independent tester overlay

From a clean candidate, execute every CLI negative fixture and the debug/release performance-runner contract tests, then run the GUI preflight with a decoy window present. Verify exact launched PID/window capture, both window sizes/appearances, 2× or honest deferral, WKWebView pixels, Accessibility action, QACapture/external manifests, root aggregation/hashes, and cleanup. Do not grant permissions or edit code. Return the preflight PNG and manifest paths absolutely.
