# Iteration time: making Array fast to change without weakening evidence

**Status:** analysis and design direction only — no implementation has started
**Written:** 2026-08-13
**Scope:** local edit loop, verification matrix, release construction, and publishing

Iteration time is part of the product. Array can become a large, capable application without making every change wait on the entire application, every UI surface, two platforms, packaging, signing, and Apple notarization. The current process has accumulated strong checks, but it uses too much of the release universe as the development loop and pays process/setup costs repeatedly.

This document consolidates:

- direct inspection of recent Claude session history;
- `/tmp/matrix*.log`, `/tmp/release.log`, and retained `qa-runs/` evidence;
- `scripts/run-matrix.sh`, `scripts/release-app.sh`, `RELEASE.md`, and `AGENTS.md`;
- a dedicated matrix redundancy audit;
- a dedicated test-layer and optimality review;
- comparison with the separation of development, CI, smoke, artifact, and release workflows in the local `t3code` repository.

It deliberately proposes no immediate deletion of checks. Shared setup is not the same thing as redundant coverage, and a fast matrix that silently loses release evidence would be a regression.

---

## Executive conclusion

The main problem is not simply that Swift or notarization is slow. The main problem is **verification orchestration**:

1. approximately 135–136 app checks launch as separate, serial Array processes;
2. normal changes are often judged with the full project-wide verification universe;
3. several checks repeat the same rendering or nested behavior;
4. many distinct assertions rebuild nearly identical fixtures and application state;
5. failures are discovered late and can force another full sweep;
6. passing results have no reusable receipt keyed to the candidate SHA and environment;
7. release construction is repeated for closely spaced snapshots;
8. the final public artifact can still ship without a completed green full-matrix candidate receipt.

The desired operating model is four explicit lanes:

| Lane | Purpose | Target |
|---|---|---:|
| Edit loop | Build and prove the behavior being changed | 15–30 seconds |
| Integration checkpoint | Cross-module and affected-area confidence | 2–3 minutes |
| Full candidate gate | Complete deterministic release evidence | 4–6 minutes |
| Distribution | Build, sign, notarize, publish, and verify the exact candidate | 7–10 unattended minutes |

The highest-leverage structural change is likely to be **running compatible named checks in a small number of long-lived harness processes**, rather than launching Array once per flag. The second is **selecting affected checks for normal iteration while preserving the complete matrix for candidate verification**. Parallelism should follow only after every check declares its resources and receives collision-free artifact and tmux namespaces.

---

## 1. What the latest cycle actually cost

### Focused matrix-to-release timeline

The latest 0.4.18 cycle can be reconstructed from:

- `/Users/dylan/.claude/projects/-Users-dylan-Documents-personal-Array/7152654b-c37d-4927-92b2-87678b224be2.jsonl`
- `/tmp/matrix.log`
- `/tmp/matrix2.log`
- `/tmp/matrix3.log`
- `/tmp/release.log`
- `qa-runs/20260813T023322Z/release/release.log`

| UTC time | Event | Elapsed/result |
|---|---|---:|
| 01:48:36 | Full matrix attempt 1 started | — |
| 01:53:58 | Attempt 1 result observed | 5m22s, exit 65; iOS compile failure because `PiAgentRunner` was unavailable in that target |
| 01:54:23 | Full matrix attempt 2 started | — |
| 02:03:39 | Attempt 2 completed | 9m16s, exit 1; 154 classified legs, 3 unexpected failures |
| 02:03–02:32 | Diagnosis and repair | about 28m34s |
| 02:32:13 | Full matrix attempt 3 started | — |
| 02:33:10 | Attempt 3 stopped intentionally | about 57s; no verdict |
| 02:33:22 | Release pipeline started | — |
| 02:40:25 | Release pipeline completed | 7m03s, exit 0 |
| 02:40–02:42 | GitHub release, appcast, ledger, push, and live checks | roughly 1–2 minutes |

From the first matrix launch to live-release confirmation, the focused cycle was approximately **53 minutes**.

### What those 53 minutes mean

They were not 53 minutes of release construction:

- about 15 minutes were consumed by two unsuccessful full matrix attempts;
- about 29 minutes were diagnosis and repair after the broad sweep exposed multiple failures;
- about one minute was spent on an abandoned third matrix;
- seven minutes were the successful signed/notarized artifact pipeline;
- the remaining time was publishing and verification administration.

Most importantly, the public release did **not** receive a completed final full matrix on the final release tree. Attempt 2 was red; attempt 3 was cancelled. The process was therefore expensive while still leaving a candidate-evidence gap.

That is the central warning: waiting longer did not automatically produce stronger evidence.

### Session wall-clock is not engineering time

The containing Claude session spans about 38h37m, and another related session spans about 49h54m. Those include overnight pauses, compactions, user activity, unrelated features, repeated releases, and idle time. They should not be used as active-work metrics. The focused timestamps above are the useful baseline.

---

## 2. Release pipeline cost

`scripts/release-app.sh` performs:

1. release Swift build and production bundle assembly;
2. inside-out hardened-runtime signing;
3. app ZIP construction;
4. app notarization with synchronous `notarytool --wait`;
5. app stapling;
6. DMG construction and signing;
7. DMG notarization with another synchronous wait;
8. DMG stapling;
9. Gatekeeper verification of app and DMG.

`RELEASE.md` then adds:

1. archiving the versioned DMG;
2. uploading both `Array.dmg` and `Array-X.Y.Z.dmg`;
3. generating and signing the Sparkle appcast;
4. appending the release ledger;
5. committing and pushing integration/main;
6. waiting for deployment;
7. checking the live feed, download, and updater path.

### Recent observed release durations

Duration is reconstructed from the UTC run-directory name to `release.log` mtime. The log itself has no per-stage timestamps, so this is total-pipeline evidence, not an exact stage profile.

| Version/run | Seconds |
|---|---:|
| 0.4.11 | 363 |
| 0.4.12 | 377 |
| 0.4.13 | 414 |
| 0.4.14 | 389 |
| 0.4.15 | 472 |
| 0.4.16 | 403 |
| 0.4.17 | 368 |
| 0.4.18 | 423 |

These eight release pipelines consumed approximately **53m29s** before counting most GitHub/appcast/git/deployment work.

`AGENTS.md` already records the local build contrast:

- incremental debug iteration: approximately 15–16 seconds;
- whole-module optimized release compilation: approximately six minutes.

The release pipeline is not wildly abnormal by itself. Building an optimized signed macOS app and waiting on Apple twice can reasonably take several minutes. The waste comes from invoking it repeatedly for closely spaced snapshots and manually shepherding all post-build steps.

### Release-specific questions to verify before optimization

- Is notarizing both the app archive and final DMG required for the supported Sparkle/Gatekeeper path, or can one submission safely be eliminated? Do not change this based on assumption.
- Can artifact construction and publishing run in CI from an immutable candidate SHA while keeping signing credentials secure?
- Can release build output be reused for packaging without allowing a candidate mismatch?
- Which clean-install and previous-version-update checks must remain supervised and release-blocking?

---

## 3. Current matrix architecture

`scripts/run-matrix.sh` currently contains four broad classes.

### 3.1 Inventory, policy, and hygiene

- agent-tile program check;
- sidebar-native program check;
- matrix inventory check;
- color hygiene;
- root-document markers;
- `git diff --check`;
- debug app-bundle validation.

### 3.2 Build and executable suites

- macOS Swift build;
- iOS simulator build;
- CoreChecks;
- AgentUIChecks;
- AgentContentChecks;
- SyncChecks;
- SyncIntegrationChecks;
- RelayChecks;
- PaletteChecks;
- FileTreeChecks;
- PerfChecks.

Several separate executable targets intentionally prove dependency direction. In particular, AgentUI and AgentContent must continue to compile and link without accidentally reaching back into forbidden modules. Combining all executable targets indiscriminately would weaken that evidence.

### 3.3 App self-checks

Static audits counted approximately 135–136 `run_app_check` legs depending on counting method and exact revision. The latest script has roughly 144 textual `run_app_check` occurrences when helper/conditional references are included. The meaningful architectural fact is stable: **well over one hundred checks launch a fresh debug Array process serially**.

For each ordinary app leg, `run_app_check`:

- creates a temporary project root;
- creates temporary app-support state;
- starts `.build/debug/Array` with one `--…-check` flag;
- usually disables tmux;
- waits for that process;
- deletes fixture roots;
- classifies the result.

This isolation is valuable, but it pays process launch, AppKit initialization, dispatch, fixture setup, and teardown for every named assertion group.

### 3.4 Special classification

The matrix includes:

- seven known-red entries at the inspected revision;
- an advisory UI tour;
- optional skipping of display-dependent baselines;
- optional skipping of real terminal/Ghostty surface checks.

A summary can say the matrix passed while known-red checks remain red or display/surface coverage was deferred. That may be a useful transition policy, but it is not equivalent to an all-green release receipt.

---

## 4. Proven redundancy

“Redundant” is used narrowly here: the implementation or documentation demonstrates nested execution or repeated mechanism/fixture work. It does not automatically mean one assertion should be deleted.

### 4.1 Component Lab repeats the visual probe gates

`Sources/ContinuumRevived/VisualSnapshot.swift` explicitly maps:

- `UIProbeGeometry` to `--ui-geometry-check`;
- `UIProbeContrast` to `--ui-contrast-check`;
- `UIProbePixels` to `--ui-pixel-check`;
- `UIProbeBaseline` to `--ui-baseline-check`;
- `--component-lab-check` to all four through `runStaticCardGates`.

Running Component Lab and all four standalone gates repeats rendering/probing across overlapping static-card fixtures.

**Direction:** render the fixture corpus once in one UI-probe process, then emit separately named geometry, contrast, pixel, and baseline results. Keep distinct result identities and diagnostics; do not collapse them into one opaque pass/fail.

### 4.2 PaletteChecks invokes the app restore check

The matrix comments document that `ContinuumRevivedPaletteChecks` runs model assertions and then shells out to `--palette-first-responder-restore-check`. The matrix also invokes that app flag independently.

This is a true nested execution relationship, and the outer suite inherits the inner red result.

**Direction:** separate Palette model checks from the AppKit first-responder integration probe. Run each behavior once and report both explicitly.

### 4.3 UI tour renders surfaces covered elsewhere without asserting them

`UITourCheck.swift` states that the tour has no visual assertion and points to probe/geometry/pixel/baseline as deterministic gates. The tour renders managed-agent, transcript, status-chip, sidebar, and settings surfaces already used by those checks.

**Direction:** make tour generation an optional artifact phase of the consolidated UI process. Its aesthetics remain advisory, but mechanical artifact generation should succeed in the supervised GUI lane.

### 4.4 Swift targets share build/link work

`swift build` and every `swift run …Checks` invocation touch overlapping target graphs. SwiftPM normally reuses compiled products, so this is not necessarily repeated full compilation, but there is repeated command planning and executable startup.

**Direction:** invoke already-built check binaries directly or use an explicit skip-build route where safe. Preserve separate target executables where the target boundary itself is the test.

---

## 5. High-confidence consolidation opportunities

These groups have shared subsystem setup and are natural candidates for one process with named, independently reset sub-suites. Their assertions are not necessarily duplicates.

### 5.1 Browser Inspector suite

Current independent legs include:

- inspector tile shell;
- DOM tree;
- console;
- styles;
- network-lite;
- link lifecycle;
- actions.

They target one Browser Inspector subsystem and likely repeat browser tile/WebKit fixture setup.

**Proposed form:** one Browser Inspector harness process, one resettable fixture factory, seven independently timed/resulted sub-suites.

### 5.2 Sidebar and inbox suite

Current legs include:

- sidebar UX;
- workspace sidebar shell;
- default visible state;
- actions;
- live status;
- top bar;
- agent inbox.

`WorkspaceSidebarView.swift` documents shared view-model/accessor paths for multiple checks. The expensive and fragile part—materializing the sidebar/view state—is repeated.

**Proposed form:** one sidebar process with distinct geometry, default-state, behavior, live-projection, inbox, and top-bar sections across required widths and appearances.

### 5.3 Agent observation suite

Current legs include:

- cross-project agents;
- inventory wiring;
- observer sweep badge preservation;
- incremental refresh;
- observer independence;
- inbox/status projections.

These checks repeatedly build disk fixtures, snapshots, observers, and projections.

**Proposed form:** one harness process with isolated subcontexts for cross-project inventory, unobserved records, sweep reconciliation, incremental events, and downstream projection agreement.

### 5.4 Agent lifecycle suite

Current legs include:

- supervisor ownership;
- restore;
- fanout;
- display names;
- completion semantics;
- managed-model spawn;
- strict harness ownership.

They share supervisor, runner, record, persistence, and admission setup.

**Proposed form:** one lifecycle harness executable or app process with fresh stores/runners per section. Preserve explicit process-boundary checks for true relaunch/recovery behavior.

### 5.5 Focus policy suite

Good initial batching candidates:

- focus broker activation;
- focus-scope dispatch;
- reserved dispatch;
- input gate.

These are primarily policy/routing behaviors. Surface-specific click focus, border rendering, browser capture, and palette first-responder checks should stay distinct until implementation mapping proves they can share setup without losing surface evidence.

### 5.6 Zone and workspace suites

Potential groups:

1. boot, persistence, topology migration;
2. zone create/move/breakout/close/resize/z-order/adaptive bounds;
3. hydration, lazy resume, registry/refcount;
4. workspace runtime install, switch, profile.

These repeatedly construct `WorkspaceRuntime`, `ZoneRuntimeController`, stores, registries, and temporary projects.

**Critical limitation:** migration, crash-safe persistence, and relaunch semantics may require a fresh process. Those should remain process-boundary tests even if pure model assertions move into batched suites.

---

## 6. Checks that should not be casually consolidated

### Target-boundary checks

AgentUI and AgentContent executables prove module dependency direction. A single omnibus executable that imports everything would make those failures invisible.

### Real terminal and Ghostty surface checks

Terminal live integration, theme fidelity, snapshot tier, fills-tile, and session resume are mechanism-distinct and display-sensitive. They belong in a supervised GUI/resource-isolated lane, not in a pure model batch.

### Persistence and migration across process boundaries

Crash-safe writes, migration, relaunch restoration, and clean-install/update behavior need genuine process/artifact boundaries. In-process reset methods are not equivalent evidence.

### Visual dimensions

Geometry, contrast, pixel presence, and baseline comparison share rendering, but assert different properties. Consolidate their rendering and process setup, not their semantic identities.

### Platform compilation

The iOS build caught a real target-specific break during the latest cycle. It must remain a first-class gate, but should run earlier or concurrently rather than appearing after several minutes of unrelated work.

---

## 7. Test-layer problems

A major optimization opportunity is moving checks to the lowest layer that still proves the behavior.

### Current anti-pattern

Many model, policy, parser, projection, or wiring checks are exposed as `Array --…-check`, requiring a full app process even when the assertion may not require AppKit or a real application lifecycle.

Static review found:

- roughly 136 matrix app flags;
- 10 check targets;
- 105 `*Checks.swift` files;
- 60 committed baseline PNGs;
- a large dispatch surface in `ContinuumApp.swift`.

The app-dispatch count alone is not proof that each check is misplaced. It is a strong signal that a complete layer/resource inventory is needed.

### Desired layer test

For each check, ask:

1. Can this be a pure value/model test?
2. Does it need filesystem/process fixtures but not AppKit?
3. Does it need an AppKit view but not a full `NSApplication` lifecycle?
4. Does it need a full app process?
5. Does it need a real browser, display, tmux server, Ghostty surface, or network/service?
6. Does it require a second process/relaunch or a signed artifact?

Only levels 4–6 should pay full application/process or artifact costs.

### Proposed test pyramid

#### Level A — pure and hermetic

- parsers;
- state transitions;
- policies;
- rankings;
- geometry math;
- projection logic;
- model filtering;
- serialization round trips using temporary stores.

These should be fast, parallel, and normally selected by affected source areas.

#### Level B — module and fixture integration

- isolated executable target boundaries;
- filesystem persistence;
- fake runner/provider flows;
- observer/store wiring;
- subprocess checks that do not require AppKit.

#### Level C — app integration

- first-responder behavior;
- menu validation;
- actual view hierarchy wiring;
- browser/WebKit integration;
- app lifecycle and workspace switching where process semantics matter.

Batch compatible checks but reset subcontexts.

#### Level D — supervised GUI and real surfaces

- visual baselines;
- contact-sheet generation;
- real Ghostty surfaces;
- terminal rendering;
- display-dependent probes.

Run on a known GUI host with controlled topology and mandatory artifact receipts for release candidates.

#### Level E — signed artifact and distribution

- Sparkle embedding;
- codesign/notarization/stapling;
- Gatekeeper;
- clean install;
- update from previous production version;
- live appcast/download.

Run exactly on the candidate artifact, not as part of normal editing.

---

## 8. Why immediate parallelism is unsafe

The matrix is serial, but it cannot simply be wrapped in `xargs -P`.

Static review found collision risks:

- shared `qa-runs/` naming and artifact roots;
- shared `.build/checks-manifests` output;
- one matrix-wide `TMUX_TMPDIR`;
- display and first-responder state;
- possible WebKit/browser resource coupling;
- process-sensitive workspace and persistence fixtures.

Before parallel execution, every check or suite needs metadata:

```text
id
layer
source ownership
resources: filesystem | appkit | display | webkit | tmux | network | keychain
artifact root
exclusive locks
platforms
timeout
retry policy
determinism classification
candidate/release requirement
```

Then a scheduler can safely provide:

- unbounded or high concurrency for pure checks;
- bounded concurrency for filesystem/process checks;
- one AppKit/display worker where necessary;
- one isolated tmux namespace per worker;
- exclusive execution for signed artifact and live distribution checks.

Each worker needs a unique run ID and artifact directory. A matrix-wide disposable tmux namespace is safe for serial execution but should become worker-specific before terminal parallelism.

---

## 9. Failure policy and evidence quality

### Fast-fail versus collect-all

The current matrix records most failures and continues. That is useful for a nightly or candidate diagnostic sweep because one failure does not hide later failures. It is inefficient for active development.

Both modes are needed:

- **developer mode:** stop after the first actionable unexpected failure in the selected affected set;
- **candidate mode:** collect every deterministic result and publish a complete receipt.

### Known-red semantics

A known-red result should not be described as green evidence. Candidate output should distinguish:

- all required deterministic checks green;
- quarantined known defect observed;
- supervised lane owed;
- skipped due to unavailable resource;
- advisory artifact generated;
- unexpected failure;
- stale allowlist entry unexpectedly passed.

Long-term, every quarantine needs:

- owner;
- reason;
- date introduced;
- linked issue;
- affected evidence;
- expiration/review date.

### Environmental and live-provider assertions

The latest matrix exposed a provider-model-picker failure tied to a changing external model catalogue. The deterministic gate should prove filtering/selection semantics using a fixture. A separate monitor can exercise the live provider catalogue and report drift without turning an unrelated release candidate red unexpectedly.

### Inventory limitations

`check-matrix-inventory.sh` protects presence and minimum call counts. It does not prove:

- that every matrix flag maps to a valid dispatch path;
- that a flag executes its intended behavior;
- that two flags are semantically independent;
- that a check is at the correct layer;
- that an inventory record is release-required.

The future metadata registry should generate or validate both matrix selection and app/harness dispatch from one source of truth.

---

## 10. Proposed four-lane operating model

### Lane 1: edit loop

**Budget:** 15–30 seconds.

Run:

1. incremental debug build of affected targets;
2. the new or directly relevant behavioral witness;
3. nearby pure/module checks selected by source ownership;
4. optional `scripts/dev-app.sh` preview against `~/array-scratch`.

Do not run:

- release optimization;
- notarization;
- the entire app-check universe;
- visual baselines unless the visual fixture itself changed;
- real terminal surfaces unless working on that subsystem.

### Lane 2: integration checkpoint

**Budget:** 2–3 minutes.

Run concurrently where safe:

- inventory and hygiene;
- macOS debug build;
- iOS compile;
- changed-area suites;
- module-boundary executables;
- a small critical smoke group for boot, persistence, and state isolation.

This is the normal pre-merge or “feature now coherent” checkpoint.

### Lane 3: full candidate gate

**Budget:** initially under 8 minutes, then target 4–6.

Run:

- all deterministic suites;
- all required platform builds;
- supervised GUI/surface lane where required;
- candidate bundle validation that does not yet require public release;
- collect-all reporting.

Produce an immutable receipt keyed by:

- git SHA and dirty-tree state;
- Swift/Xcode/macOS versions;
- dependency lock hashes;
- check registry version;
- environment/resource classification;
- start/end and per-suite duration;
- artifacts and manifest hashes;
- skips/quarantines/failures.

Any code change invalidates the candidate receipt. Documentation-only changes may use an explicitly defined narrower invalidation policy, not an ad hoc judgment.

### Lane 4: distribution

**Budget:** 7–10 minutes, unattended.

From the exact verified candidate SHA:

1. optimized release build;
2. signing and notarization;
3. package and Gatekeeper verification;
4. GitHub dual-asset publication;
5. appcast generation;
6. ledger and deployment update;
7. live feed and download polling;
8. clean install/update evidence where required;
9. one final release receipt linking candidate and artifact hashes.

A human should authorize the release, then receive a final success/failure report rather than manually polling each step.

---

## 11. Comparison with T3 Code

The local `t3code` repository does not provide a one-to-one blueprint for a Swift/AppKit product, but its workflow separation is useful:

- dedicated development runners (`dev`, `dev:desktop`, `dev:web`);
- separate typecheck, lint, test, and build commands;
- filtered workspace builds;
- multiple parallel CI jobs;
- a release-only smoke workflow;
- distribution artifact commands separate from development builds;
- some production builds delegated to CI rather than a laptop.

The transferable principle is:

> Development feedback, integration evidence, release smoke, artifact construction, and public distribution are separate products with separate latency and isolation requirements.

Array should adopt that separation without weakening its unusually valuable real-app, visual, tmux, and persistence evidence.

---

## 12. Recommended migration sequence

### Phase 0: instrument without changing behavior

Add:

- matrix start/end timestamps;
- per-leg start/end/duration;
- stable attempt and run IDs;
- git/environment fingerprints;
- artifact paths;
- explicit resource classifications;
- machine-readable final receipt.

This establishes where time is actually spent. Current evidence can recover total duration but cannot say whether five checks dominate or process startup dominates broadly.

### Phase 1: create one check registry

Map every check to:

- flag/result ID;
- implementation symbol;
- subsystem/source ownership;
- layer;
- resources;
- timeout;
- artifact outputs;
- candidate requirement;
- quarantine status.

Validate matrix entries against real dispatch. Stop relying on independent handwritten lists and count thresholds as the only guard.

### Phase 2: remove proven duplicate execution

First candidates:

1. separate Palette model checks from the once-only first-responder app probe;
2. consolidate Component Lab/probe rendering while retaining named assertion groups;
3. attach UI tour generation to the shared UI render pass;
4. avoid repeated SwiftPM planning after a successful build.

These have the strongest static evidence and lowest conceptual risk.

### Phase 3: batch one low-risk family

Start with Browser Inspector or pure focus-policy checks:

- one process;
- one fixture factory;
- fresh subcontext per named check;
- separately timed results;
- prove identical pass/fail behavior against the old independent legs for a transition period.

Do not delete the old path until equivalence is demonstrated on real candidate runs.

### Phase 4: affected-check selection

Build a conservative source-to-suite dependency map. Unknown ownership means run more, not less. Keep the full candidate matrix unchanged until selection has demonstrated that it catches known historical regressions.

### Phase 5: safe parallel scheduler

Only after resource metadata and artifact isolation exist:

- parallel pure/model suites;
- bounded process suites;
- serialized AppKit/display suites as needed;
- isolated tmux namespace per worker;
- exclusive distribution lane.

### Phase 6: automate distribution

Make release publishing one command or CI workflow operating on a verified SHA. Preserve explicit authorization, signing security, rollback visibility, and final live checks.

---

## 13. Success metrics

Measure percentiles, not one unusually warm or cold run.

### Latency

- edit-loop p50 and p95;
- affected-check checkpoint p50 and p95;
- full deterministic candidate-gate p50 and p95;
- release build/sign/notarize total;
- publish-to-live-feed total.

### Waste

- number of process launches per candidate;
- repeated fixture renders;
- repeated full matrix attempts;
- checks rerun with unchanged inputs;
- release pipelines per public candidate;
- time spent waiting for the first actionable failure.

### Evidence quality

- percentage of releases tied to a completed candidate receipt;
- number of skipped/owed supervised gates;
- quarantine count and age;
- flake rate by check;
- live-provider/environment failures separated from deterministic product regressions;
- percentage of check registry entries with declared resources and source ownership.

### Initial targets

- edit loop: 15–30 seconds;
- integration checkpoint: 2–3 minutes;
- full candidate matrix: first below 8 minutes, then 4–6;
- distribution: 7–10 unattended minutes;
- zero public releases without an immutable final candidate receipt.

---

## 14. Decisions still needed

1. Should the complete deterministic matrix be mandatory before every public release, or can a candidate receipt be reused across documentation/appcast-only commits under a defined invalidation rule?
2. Which current known-red checks are release-blocking debts versus temporarily quarantined evidence?
3. Which GUI/surface checks require a dedicated always-awake Retina host?
4. Should distribution move to CI, remain local but fully automated, or use a hybrid where local signing/notarization publishes an immutable artifact for CI administration?
5. Which first batching pilot is preferable: Browser Inspector, sidebar, focus policy, or agent observation?
6. What is the accepted policy for live external catalogue checks versus deterministic fixtures?
7. Is dual app-and-DMG notarization required for the supported distribution path?

---

## 15. Immediate recommendation

Do not begin by deleting tests or adding parallel shell syntax.

The safest first implementation package is:

1. matrix and per-leg timing receipts;
2. a declarative check registry with layer/resource/source ownership;
3. validation that every matrix check maps to a real harness dispatch;
4. removal of the proven Palette nested duplicate;
5. one consolidated UI render pass with separately named probe results;
6. one batched pilot suite, run temporarily alongside the old path to prove equivalence.

That package creates the evidence needed to optimize aggressively without guessing.

---

## Evidence index

### Project files

- `scripts/run-matrix.sh`
- `scripts/check-matrix-inventory.sh`
- `scripts/release-app.sh`
- `scripts/dev-app.sh`
- `RELEASE.md`
- `AGENTS.md`
- `Package.swift`
- `docs/38-tickets/90-agent-ux/matrix-inventory.txt`
- `docs/38-tickets/95-go-live.md`
- `.plans/12-dogfood-playbook.md`
- `.plans/17-session-handoff-2026-08-12.md`
- `Sources/ContinuumRevived/VisualSnapshot.swift`
- `Sources/ContinuumRevived/App/ComponentLab.swift`
- `Sources/ContinuumRevived/App/UITourCheck.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `Sources/ContinuumRevived/App/WorkspaceSidebarView.swift`

### Runtime evidence

- `/tmp/matrix.log`
- `/tmp/matrix2.log`
- `/tmp/matrix3.log`
- `/tmp/release.log`
- `qa-runs/20260813T023322Z/release/release.log`
- recent `qa-runs/*/release/release.log` files
- Claude session `7152654b-c37d-4927-92b2-87678b224be2.jsonl`

### Independent read-only audits

- `.pi/agent-runs/explorer-20260813T025045Z-42cf87/final.md` — recent session timeline
- `.pi/agent-runs/explorer-20260813T025045Z-a52c82/final.md` — release pipeline timing and bottlenecks
- `.pi/agent-runs/explorer-20260813T025940Z-6522c2/final.md` — matrix redundancy taxonomy
- `.pi/agent-runs/code-reviewer-20260813T025940Z-312d9c/final.md` — matrix layer/resource review

### Evidence limitations

- Existing release logs lack per-stage timestamps.
- Existing matrix logs lack stable per-leg timing and attempt IDs.
- Static shared-setup findings do not prove identical assertions.
- No tests, builds, app checks, or releases were executed for this analysis.
