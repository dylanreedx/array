# 0.7.46 sidebar gate repairs

Base: `d7ee17d8598230ff04b3702eee663e4d5d82047e`. Removed the uncommitted STOP-STATUS.md as requested. No preview relaunch, push or full matrix.

Liveness: the scenario called its lead folded but relied on the former default; groups now start expanded. It now explicitly restores a collapsed choice (`false` means not open). Production also no longer lets the idle lead's older check report suppress the working count of its hidden helpers: both facts share the existing tail. No signal was moved elsewhere. The folded lane still shows working and clears it when the helper finishes.

Corners: the indicator edge subtracted 1.5pt from an already resolved outer radius. Rounded therefore yielded 9.5 rather than resolving the inset's own Default base (4.5) to 8.0. It now resolves that base through CornerRole. Default remains 4.5.

Optional chrome: the adopted and appearance fixtures never asked for a jump chord and their rows could not qualify for a settle nudge. A dedicated production inbox fixture enables jump hints, wires the settle action, and supplies a read, successfully completed agent older than the nudge delay. Owners and census assertions are retained. When targeting changes, showSettleNudge now reconciles the button's attachment after unhiding it, matching the optional-chrome removal during configuration.

Before: rebuilt base binary; sidebar-liveness failed scenario 2 with empty lane; corner-style failed Rounded 9.5 vs 8; ui-probe and isolated managed-setting failed with InboxJumpHintView and InboxSettleNudgeButton painting nothing. Initial managed-setting invocation without CONTINUUM_APP_SUPPORT refused isolation, so its actual RED was collected with a disposable support directory.

Final validation logs and process results: `qa-runs/sidebar-release-repair/`. These are targeted runs with disposable CONTINUUM_APP_SUPPORT directories, read for hidden failures as well as exit status. Final results are appended after the runs finish.

Final build passed. All eight targeted legs passed on the final source tree: `--sidebar-liveness-check`, `--corner-style-check`, `--ui-probe-check`, isolated `--managed-setting-check`, `--sidebar-row-presentation-check`, `--sidebar-screenshot-check`, `--inbox-parent-fold-check`, and `--sidebar-indicator-settings-check`. Parent-fold output explicitly reports the fold assertions and both Aqua/Dark Aqua glyph checks passing, with no hidden failure. Settings mouse events changed all four styles in both appearances and persisted fresh-suite reads. Screenshot leg rendered 48 images. Liveness measured the working push at 72ms, parent start/finish with zero disk rebuilds, and idle push with zero card builds/full reloads. Corner census covered 322 corners on 55 surfaces. Diff whitespace check passed.
