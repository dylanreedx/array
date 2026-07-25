# 90-agent-ux — Ledger

Durable state. The conversation is NOT the source of truth: this file + `git log` are.

## heartbeat
last-touch 2026-07-25T05:45:00Z · ticket P0.10-explicit-model-id · attempt 1 · pid loop · status reviewing

## tickets

| ticket | state | commit | at | note |
|---|---|---|---|---|
| P0.1-ios-target-in-matrix | done | f61aff0 | 2026-07-25T04:43:14Z | iOS xcodebuild leg after `swift build`; negative test (`_ = Process()` in Core) turns the matrix red at exit 65 while `swift build` stays green; no-Xcode path prints SKIPPED and returns 0 |
| P0.2-uiprobe-harness | done | 20a311c | 2026-07-25T05:00:00Z | `UIProbe.render` + `--ui-probe-check`; 3 negative tests red-before-green; codex found `appResolvedCGColor` resolves via `NSApp.effectiveAppearance`, so render() also sets/restores NSApp.appearance and a luminance witness on auth.pairingToken guards it |
| P0.8-shared-selector-and-wait | done | 1096ba8 | 2026-07-25T05:26:00Z | `UITestSupport.swift`: shared `descendant(withIdentifier:)`/`descendants(withPrefix:)` + async `waitUntil` that suspends on a main-queue timer (Swift rejects the RunLoop spin in async, so the wrong pattern can't come back); managed-agent live check migrated. Its own `--managed-agent-live-check` verification is NOT runnable unattended — sampled blocking in `requestProjectFolderAccessIfNeeded` → `NSAlert runModal`; needs a supervised GUI + Pi auth, so it is SKIPPED here (it is not in run-matrix.sh; nothing passes silently). Added deterministic `--ui-test-support-check` in its place, 4 negative tests red-before-green |
| P0.10-explicit-model-id | in-progress | | | |
| P0.11-matrix-check-count-guard | pending | | | |
| P0.3-geometry-gates | pending | | | |
| P0.4-appearance-contrast-gate | pending | | | |
| P0.5-pixel-probes | pending | | | |
| P0.6-png-baselines | pending | | | |
| P0.9-ui-tour-check | pending | | | |
| P0.7-retire-isblank-gate | pending | | | |
| P1.1-agentui-module | pending | | | |
| P1.2-tokencolor-light-dark | pending | | | |
| P1.4-type-scale | pending | | | |
| P1.5-spacing-radius-scale | pending | | | |
| P1.3-surface-text-border-tokens | pending | | | |
| P1.6-token-contrast-gate | pending | | | |
| P1.7-raw-color-lint | pending | | | |
| P1.8-one-status-presenter | pending | | | |
| P1.9-live-appearance-switching | pending | | | |
| P1.10-adopt-tokens-tile | pending | | | |
| P1.11-adopt-tokens-chrome | pending | | | |
| P1.12-ios-consumes-tokens | pending | | | |

States: `pending` · `in-progress` · `done` · `blocked`
