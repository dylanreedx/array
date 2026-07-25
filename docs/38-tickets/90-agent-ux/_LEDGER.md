# 90-agent-ux — Ledger

Durable state. The conversation is NOT the source of truth: this file + `git log` are.

## heartbeat
last-touch 2026-07-25T06:25:00Z · ticket P0.3-geometry-gates · attempt 1 · pid loop · status implementing

## tickets

| ticket | state | commit | at | note |
|---|---|---|---|---|
| P0.1-ios-target-in-matrix | done | f61aff0 | 2026-07-25T04:43:14Z | iOS xcodebuild leg after `swift build`; negative test (`_ = Process()` in Core) turns the matrix red at exit 65 while `swift build` stays green; no-Xcode path prints SKIPPED and returns 0 |
| P0.2-uiprobe-harness | done | 20a311c | 2026-07-25T05:00:00Z | `UIProbe.render` + `--ui-probe-check`; 3 negative tests red-before-green; codex found `appResolvedCGColor` resolves via `NSApp.effectiveAppearance`, so render() also sets/restores NSApp.appearance and a luminance witness on auth.pairingToken guards it |
| P0.8-shared-selector-and-wait | done | 1096ba8 | 2026-07-25T05:26:00Z | `UITestSupport.swift`: shared `descendant(withIdentifier:)`/`descendants(withPrefix:)` + async `waitUntil` that suspends on a main-queue timer (Swift rejects the RunLoop spin in async, so the wrong pattern can't come back); managed-agent live check migrated. Its own `--managed-agent-live-check` verification is NOT runnable unattended — sampled blocking in `requestProjectFolderAccessIfNeeded` → `NSAlert runModal`; needs a supervised GUI + Pi auth, so it is SKIPPED here (it is not in run-matrix.sh; nothing passes silently). Added deterministic `--ui-test-support-check` in its place, 4 negative tests red-before-green |
| P0.10-explicit-model-id | done | 7c3d75d | 2026-07-25T05:58:00Z | `AgentModelConfig` (FocusBorderConfig shape) + two `.choice` fields under Agents; default is now the exact id `openai-codex/gpt-5.6-sol` — the old `gpt-5.6` was a non-id prefix of three catalogue entries, so Pi's fuzzy matcher chose silently. Beyond the packet: `processArguments` also emits `--thinking <level>` (precedent: HarnessRoleRunBuilder), otherwise the reasoning-effort picker the packet asked for would be inert. Catalogue pinned as a literal in the check (matrix stays offline) — refresh when the provider catalogue changes. 5 negative tests red-before-green. Codex: no correctness bugs; its 2 medium verification gaps + 1 low fixed before commit |
| P0.11-matrix-check-count-guard | done | abfdb93 | 2026-07-25T06:20:00Z | `scripts/check-matrix-inventory.sh` as the first matrix leg vs a committed 248-record inventory: 112 `check` flags, 125 `leg` invocations (env prefixes stripped), 4 `bundle-check` (see below), 7 `count <target> <n>` floors of run*Checks() call sites per `Sources/*Checks/main.swift`. Disappearance or a decreased count = red naming it; growth prints "inventory grew" and passes; blessing = `CONTINUUM_UPDATE_MATRIX_INVENTORY=1 ./scripts/run-matrix.sh` in the same commit. The guard is a normal leg, so deleting it drops its own record. Beyond the packet: `bundle-check` covers check-app-bundle.sh's `self_checks` array, because `--menu-contract-check` and `--delete-confirm-policy-defaults-check` run only there and a run-matrix.sh-only inventory could not see them. 7 negative tests red-before-green (delete a leg; comment out that leg; comment out a run*Checks() call; delete the guard's own leg; delete the inventory; drop 2 bundle self_checks; leave those flags only in a trailing comment) + growth case exits 0. Codex found 2 real holes, both fixed pre-commit: raw-token greps counted commented-out calls and `func run…Checks` declarations — comments are now stripped from all three sources and `func` lines excluded, hence true counts 21 (Core) / 1 (SyncIntegration). Owner: renames read as delete+add by design; a `count … 0` floor only catches the target vanishing, not a shrinking inline suite |
| P0.3-geometry-gates | done | 4bda832 | 2026-07-25T06:30:00Z | Geometry gates + `--ui-geometry-check`; verified green by the supervisor. ATTRIBUTION ERROR: the supervisor's `git commit` swept this ticket's staged files into docs commit 4bda832 mid-flight (bare `git commit` commits the whole index, not just newly `git add`-ed paths). Code inspected against the packet and matrix re-run green; the worker for this ticket was terminated because its index was taken out from under it. |
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
