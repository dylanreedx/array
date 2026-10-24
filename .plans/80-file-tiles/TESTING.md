# Durable verification for file renderers

Read [START HERE](START-HERE.md) and live AGENTS.md before running checks. This document describes the durable strategy and broader release checklist. Implemented focused coverage is listed below; a checklist item is not itself a passing result. The [verification research](research/07-verification.md) provides the detailed fixture catalog and baseline check inventory.

## Implemented focused suites

- Core `--file-content-foundation-check`: shared initial load and strict incremental delimited parser.
- Core `--file-format-backends-check`: secure snapshot/race fixtures, UTF-8/UTF-16 paging and sparse index bounds, ZIP/CRC/expansion rejection, XLSX strings/formulas/dates/hidden data and XML/container boundaries.
- App `--file-initial-load-check`: controlled asynchronous completion and text/binary transition lifecycle.
- App `--file-image-check`: actual ImageIO orientation/alpha/frame labels, physical-pixel geometry, resize reuse, appearance rendering and disposal.
- App `--file-data-grid-check`: projected large row/column axes, exact selection/copy, sparse workbook search, shared scheduler cancellation/worker limits, suspended work and stable layout across scroller styles.
- App `--file-formats-scene-check`: actual production mount/API, four real backends, persisted world frames, workspace round-trip, source-byte preservation and lease/observer cleanup. CSV additionally drives external replacement, rename, deletion and rejects resurrection of a retired host.

Existing source/session, Markdown and workspace API suites remain separate. All fixtures are local and generated; no network downloads or visual-baseline updates are needed. The scene suite always renders both appearances through the shared UIProbe bitmap helper and checks that toolbar/inspector detail survives sibling drawing. It optionally writes complete renderer PNGs when `ARRAY_FILE_APPEARANCE_DIR` is set. Test outcomes and unavailable release evidence live in verification.json and CURRENT-IMPLEMENTATION.md.

## Test layers and execution cost

| Layer | Purpose | Run policy |
| --- | --- | --- |
| Core tables | Classification, parser fidelity, boundaries and cancellation | Small offline fixtures; run for affected backend while iterating |
| Shared host contract | Generation fencing, replacement, reload, suspend/resume/dispose | One reusable harness; exercise common host thoroughly |
| Real renderer contract | Actual mounted pixels/cells, controls and adapter wiring | Focused fixture per shipped renderer plus format-specific cases |
| Production scene/API | Placement, grants, restore, persistence and ownership | Representative cross-format coverage using real production mount |
| Resource/scaling | Work counts, retained bytes, bounded views and queue | Independent axes and deterministic generated large inputs |
| Appearance/accessibility | Styling, input ownership and usable navigation | Real light/dark surfaces, keyboard and VoiceOver |
| Platform/provider smoke | OS decoder and Quick Look behavior mocks cannot prove | Supported OS/fixture matrix; record environment |
| Full release matrix | Registration and combined regression gate | Integration/release, not once per parser case |

Avoid every format × every route × every failure × every theme. Route/grant semantics are shared; cover them in existing integration tests and representative new-format arms. Renderer-specific behavior needs direct evidence, not a duplicate copy of every host test. Keep focused checks independently runnable and failures separately reported within the gate.

## Reusable fixture and harness contract

Use one fixture manifest describing ID, bytes or deterministic generator, provenance/license, intended family, expected capabilities, exact expected values/pixels/errors, and whether support is guaranteed or conditional. Expected values must not come from the parser/decoder being tested. Small fixtures live with established check resources; large fixtures are generated in temporary roots and cleaned up. Do not download fixtures during offline checks.

The shared host harness controls file-change delivery and asynchronous completion order. Minimum scenarios: old load completes after new load; file changes during parsing; tile closes before success; suspend/resume; repeated dispose; supported format replaced with unsupported input; failed reload while old content is visible. Assert actual state/content and absence of late publication. Use barriers/explicit queues rather than sleeps as the main assertion.

Supply a minimal renderer fixture and observable result to that harness. Use a fake adapter to test host cleanup/failure deterministically, and a separate real mounted adapter case to prove production wiring. System-preview success cannot be inferred from a mock. Do not add general production instrumentation solely to mirror private helper calls; expose small work counters or injected resource boundaries where necessary for behavioral evidence.

Quick Look additionally needs real provider-boundary fixtures: replace the source path after authorization, mutate it while loading, and inspect documents with external references. Verify the chosen staged-snapshot/read-time policy, temporary byte/package limits and cleanup after failed load, replacement and disposal. Observe actual external-resource effects rather than asserting only that Array's own loader saw no requests. Measure provider/service retention separately from Array-owned cache counters; document opaque limits and unsupported cases. Failure to qualify this boundary means embedded support remains gated.

## Core fidelity and safety cases

CSV/TSV: quoted delimiter/newline, doubled quotes, EOF without newline, empty/trailing fields, duplicate/no headers, ragged rows, invalid encoding, BOM-marked Unicode, chunk splits and over-budget field/record/index. Preserve leading zeroes, long integers, date-like and formula-like strings exactly. Verify header/dialect changes alter interpretation without changing bytes.

Images: orientation/mirroring, alpha, profile handling, dimensions, misleading/absent extension, actual promised codecs, invalid source and bounded decoded size. Workbook adapters: actual qualified containers, multiple/hidden sheets where promised, formula caches/date systems where inspected, missing provider, locked/corrupt input and close/recreate. Parser-specific ZIP/XML adversarial cases apply only if a custom workbook parser is introduced.

Shared loaders: missing/denied path, special files, unintended directories, package handling, read-time symlink/type swap, atomic replacement preserving size/time, rename/trash and stale completion. Assert no unauthorized bytes, execution, implicit network resource reads or inspection-induced file writes. Explicitly authorized standalone opens retain their own policy; agent/API paths cannot inherit it.

## Scene and persistence contract

Mount through `AppDelegate.mountWorkspaceSceneAtBoot`. New witnesses must not satisfy their own setup using the checks-only `install(into:)` entry point. Use two disposable projects with same relative filenames but different content, multiple zones with nonzero origins and a zone below the live tier.

Assert visible sentinel content, canonical identity, dedupe, correct project owner and tile WORLD frame against the target zone. Restore after workspace switch and renderer eviction. Confirm persistence retains non-installed zones. Preserve API explicit targets, grants and no-navigation outcomes. Any new persisted view-state field needs compatibility/default tests and WorkspaceAPIExposure classification.

Editing regressions include draft-preserving view switches, conflict refusal, save failure, missing-file refusal, explicit overwrite and recovery. Viewing an image/workbook must not create a text draft. Inspection, selection, copy and view transforms leave original bytes unchanged.

## Performance and durable assertions

Count work and report generous timing/RSS diagnostics separately. In an unchanged loaded scene, camera motion performs zero reads/parses/decodes. Assert viewport-bounded live cells, admitted decoded/index/cache bytes, bounded pending jobs and no retained-resource growth across repeated open/close/switch cycles. Include tile-owned resources, not just cache entries.

Vary rows, columns, field length, pixel dimensions, visible tiles and offscreen retained tiles independently. Keep gesture correctness assertions so a no-op camera cannot pass a zero-work budget. Adopt current scalability baseline ratchets; do not silently normalize a slower result. Measure durations before assigning suite budgets and avoid flaky tight stopwatch thresholds.

Appearance snapshots cover layout/chrome and known fixture states, not every system-rendered pixel. Verify loaded/error/partial controls in light/dark and adopted token probes. Check Retina actual-pixel behavior, legacy/overlay scrollers, narrow tiles, focused versus inactive gestures, keyboard escape/focus, and accessible row/column/value navigation.

## Safe command workflow

Enumerate actual app flags before invoking any. An unknown flag launches the full app. From the real implementation bench:

```sh
rg -o -- '--[a-z0-9-]+-check' Sources/ContinuumRevived/App/ContinuumApp.swift
/tmp/exc-probe/noexc swift build --product ContinuumRevivedCoreChecks
/tmp/exc-probe/noexc swift build --product Array
```

Build only the products relevant to the slice; the commands above are alternatives as needed, not a requirement to rebuild both for every case. Choose the current focused invocation from source and the actual matrix registration. Do not copy proposed flags from research into a shell. Register new checks in the dispatcher, matrix and literal inventory; run the real matrix at the integration gate and inspect its final report.

Before any CoreChecks or matrix invocation, inspect its current tmux isolation and crash-marker handling. Use a unique disposable TMUX_TMPDIR, unset inherited TMUX/TMUX_PANE where required, and verify the test server socket is inside that namespace. Never use the default socket or override CONTINUUM_ARRAY_MANAGED_AGENT. If the harness cannot provide the required isolation, leave that coverage unverified and report why. Do not invent isolation environment variables unsupported by the current harness.

## Required evidence before release

Record the red fixture result, rebuilt green result, implemented flags and final matrix coverage for each substantive slice. Include fixture manifest, supported/partial/unsupported table with OS/provider context, measured resource limits, mounted restore/API results and visual/accessibility artifacts. Mocks, documentation research and static source inspection each have useful but limited roles; none establishes runtime format support alone.

When handing off partial work, update [EXECUTION](EXECUTION.md#status-and-evidence-ledger) with what ran, failed, was skipped or remains unverified. Never update baselines or KNOWN-RED simply to make new behavior pass.
