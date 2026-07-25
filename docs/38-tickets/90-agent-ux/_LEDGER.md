# 90-agent-ux — Ledger

Durable state. The conversation is NOT the source of truth: this file + `git log` are.

## heartbeat
last-touch 2026-07-25T05:05:00Z · ticket P0.2-uiprobe-harness · attempt 1 · pid loop · status implementing

## tickets

| ticket | state | commit | at | note |
|---|---|---|---|---|
| P0.1-ios-target-in-matrix | done | f61aff0 | 2026-07-25T04:43:14Z | iOS xcodebuild leg after `swift build`; negative test (`_ = Process()` in Core) turns the matrix red at exit 65 while `swift build` stays green; no-Xcode path prints SKIPPED and returns 0 |
| P0.2-uiprobe-harness | in-progress | | | |
| P0.8-shared-selector-and-wait | pending | | | |
| P0.10-explicit-model-id | pending | | | |
| P0.11-matrix-check-count-guard | pending | | | |
| P0.3-geometry-gates | pending | | | |
| P0.4-appearance-contrast-gate | pending | | | |
| P0.5-pixel-probes | pending | | | |
| P0.6-png-baselines | pending | | | |
| P0.9-ui-tour-check | pending | | | |
| P0.7-retire-isblank-gate | pending | | | |

States: `pending` · `in-progress` · `done` · `blocked`
