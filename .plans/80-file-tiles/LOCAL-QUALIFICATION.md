# Local qualification and transfer record

Updated 2026-10-24. This is historical research-base implementation evidence, not release approval. Active work has moved to the real `file-tile-previews` worktree at `fe734156`; see START-HERE and verification.json `active_bench` for current-base results. The archive remains intact until Dylan confirms removal.

## Environment and source

The source bench is `.worktrees/file-tile-research`, an isolated archive of `81bb3717eec92bde6c987662d2771db57f591b0e`. It has no `.git`; Git operations inside it discover the canonical parent repository. Git worktree metadata writes were denied. Do not stage, commit, clean or remove this archive as though it were a landed worktree. The canonical checkout contains concurrent unrelated work and was not edited for this implementation.

`qa-runs/file-tiles-rich/implementation.patch` and `transfer-manifest.json` preserve the scoped source/document changes against that exact baseline. Regenerate them after changing this record. Apply in a real writable worktree, adapt to current integration/performance changes and rerun the gate before landing. Do not copy `.build`, `ThirdParty` symlinks or QA stores into a commit.

## Commands actually executed

Builds used the protected wrapper, two jobs and task-local SwiftPM/cache/module directories:

```sh
/tmp/exc-probe/noexc swift build --disable-sandbox --product Array --jobs 2 --cache-path /tmp/array-file-tiles-cache --config-path /tmp/array-file-tiles-config --security-path /tmp/array-file-tiles-security -Xswiftc -module-cache-path -Xswiftc /tmp/array-file-tiles-modules
```

The same invocation with `--product ContinuumRevivedCoreChecks` rebuilt the Core checks. Actual focused flags are registered in the dispatcher and matrix; see TESTING. All native descendants run through the wrapper. QA launches use disposable project roots. The production app was not rebuilt or replaced. Earlier inherited-handler failures reported by Dylan did terminate the host; SAFE-EXECUTION records the incident and mandatory wrapper.

Core backends passed. Native image, grid, initial load, Markdown preview, workspace API open/grants and production scene-owner checks passed. The format scene passed for PNG, CSV, UTF-16 TSV and XLSX, including exact values, persistence, workspace hydration and admission/observer cleanup. After a RED cleanup result, tracing identified a retired file host reacting to global rename notifications and allocating an offscreen preview. Retired hosts now ignore move/trash events; parked hosts update identity without loading. The scene asserts that rename cannot resurrect its retired host.

Visual review found macOS 14 default unclipped drawing allowed image/grid backgrounds to cover sibling controls. A behavioral pixel witness was RED (one flat edge colour instead of toolbar glyphs). Read-only renderer roots/content now explicitly clip to bounds and background fills intersect their own bounds. Image/workbook roots paint an opaque themed background: an independent AppKit probe proved transparent black glyphs had also fooled the RGB-only capture check (177 RGBA colours but one RGB colour). Both appearance renders are part of the regular scene leg, not only optional screenshot output. Final GREEN evidence is in verification.json.

Grid work-count checks include projected reads on independent row/column axes, shared scheduler bounds/cancellation and no new page reads during unchanged layout in legacy/overlay scroller styles. Image resize reuses the same decoded pixels. These are work bounds, not an exact OS decoder scratch-memory guarantee.

## Matrix limitation

The real `scripts/run-matrix.sh --fast` ran its inventory, program/self-test, colour-hygiene and macOS build gates successfully. It then stopped at the required iOS build (exit 74): Xcode attempted diagnostics in a denied user package-cache directory. Simulator services also reported unavailable. A second invocation with explicit derived-data, cloned-package and package-cache paths failed at the same default manifest-cache path. This is not a completed matrix run or an iOS compile pass.

A disposable `qa-runs/file-tiles-rich/matrix-continuation.sh` runs remaining literal test legs after recording the blocked iOS gate and already-passed setup. It changes no tracked release-gate behavior. Its summary is diagnostic evidence only. UI baseline legs, terminal surface checks and packaging are explicitly skipped in this headless fast run. Never present that continuation as a full release gate.

Final continuation, appearance and transfer outcomes are recorded in verification.json. Supported OS floor, optional image codecs, live VoiceOver interaction, preview bundle smoke and performance-branch integration remain release-owner qualifications. The existing editor-navigation WebKit timeout and Markdown clipboard assertion were reproduced on rebuilt baseline sources; they are not silently added to KNOWN-RED.

## Final focused result

The task-local focused runner reuses eleven exact registered matrix invocations and the actual matrix isolation/classification/report functions. It passed all eleven and printed `Focused file-tile gate passed.` after the final rebuild. It does not replace the full matrix. The broader continuation observed 130 invocations and recorded 22 red outcomes (including known reds) before hanging at `--palette-captures-keys-over-browser-check`: that check's JavaScript dispatch group has no timeout when WebKit cannot reply. SIGTERM to its identified QA PID 88369 was denied by the sandbox; it was not confirmed stopped. No attempt targeted the production app. The continuation has no final verdict; see its observation JSON for exact red legs, whose causes were not all baselined.

Final light/dark artifacts are in `qa-runs/file-tiles-rich/appearances-qualified/`. Image controls/status, CSV/TSV choices/values and XLSX sheet choice/cache notice are visible. The scene's toolbar pixel assertion is in the normal gate; PNG export runs only when the artifact directory is requested. Preview bundle smoke and live VoiceOver remain unverified.

## Real-bench transfer result

The 48 scoped paths moved into `.worktrees/file-tile-previews`, branch `array/file-tile-previews`, at `fe734156`. No whole-repository copy was used. Tracked source was validated against three-way merges of HEAD, original baseline and research delta; the existing far-parking method and newer multiselect changes remain. The matrix inventory was regenerated with 695 records. Fresh app/CoreChecks builds passed, followed by a 13-leg focused matrix report including both multiselect witnesses. New logs live in `qa-runs/file-tile-previews/`; historical logs are explicitly separated under `research-base-evidence/`.

The final own-hunks `landing.patch` passes `git apply --cached --check`. The index remains unchanged. Proposed subject: `feat(files): add bounded image and spreadsheet previews`. Nothing was staged, committed or pushed. Research source and its original evidence remain untouched pending Dylan’s confirmation. Remaining work is coordinator review/landing, the full integration release matrix and the platform/live accessibility qualifications already listed above.
