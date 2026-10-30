# Boards release port: 0.7.35

Base: `f8892555` on `array/release-0735`. Feature branch: `array/boards-nav`.

Only board-library lifecycle/navigation/rename, board references, their behavioral witnesses, board documentation and matrix dispatch were ported. The main checkout's unrelated collaboration, film, account, sidebar and terminal changes were excluded. Shared files were merged against the release baseline rather than copied wholesale. No matrix-inventory file or known-red list was changed.

Array Dev was quit for the sidebar agent and was never relaunched or brought forward. Production Array and its project state were left alone. App checks use isolated project/app-support roots; no check uses the default tmux socket.

## Verification

Feature commit: `2f1615ae` (Dylan's configured identity). `scripts/run-matrix.sh --boards` passed **14/14 legs**, including the new `--board-library-check` in the real matrix report. The check drives production mounts, board ownership, persistence/rollback, rename/undo/redo, close/reopen, unloaded-zone reveal, permanent deletion and visible table cells in light/dark. The existing reference check now drives board-header hover/drop, deduplication, draft/queue/steer persistence, all harness envelopes and transcript parity.

Additional feature checks passed:

- Core `--workspace-api-contract-check`, `--workspace-api-canvas-contract-check`, `--workspace-api-board-contract-check`, `--workspace-api-agents-contract-check`, `--workspace-api-exposure-check` (99 real coding keys classified).
- App `--workspace-api-open-check`, `--workspace-api-grants-check`, `--workspace-api-agents-check`, `--workspace-api-canvas-check`, `--workspace-api-board-check`.
- `--ui-geometry-check` (217.41 seconds); `--layout-pressure-check` (2.578 ms auto-layout p95); full palette contracts and strict harness.
- `CONTINUUM_SKIP_UI_BASELINES=1 --ui-probe-check`: passed, including the board library. It reports the theme surface-cache witness as skipped. Without this permitted headless setting, BOTH feature and baseline fail `theme witness requires all four real agent bodies surfaced`; that is an additional reproduced host prerequisite, not a clean unskipped appearance gate.
- Actual light/dark board-library captures were visually inspected. No display baseline was updated.
- Both feature and untouched baseline app builds passed. Color hygiene, inventory growth guard and `git diff --check` passed. The inventory file was not committed.

The old negative rename witness is retained in `qa-runs/board-refresh-2026-10-30/`: restoring the prior stale-index-title behavior failed `rename must update the durable index title`. The port's board hunks were verified identical to the tested original change. Raw logs and source-only port patch: `qa-runs/boards-release-0735/` in the canonical checkout. The baseline was an untouched `git archive f8892555`, with its own cloned build cache and GhosttyKit link. Relocating the build caches initially produced PCM path errors; only the private caches were cleared before rebuilding.

## Prior broad-matrix failures

These are the seven unexpected failures recorded in `qa-runs/board-refresh-2026-10-30/validation.md`. That older run used an older integration checkout with unrelated in-progress changes and a resumed runner; it is not a release-line baseline. The table below will record direct release-line evidence rather than assume those failures are inherited.

| Earlier failing leg | Untouched `f8892555` | Board feature |
| --- | --- | --- |
| `scripts/check-film-scenes.sh` | FAIL: 2/12 scenes (`full-day/full-day.json`: missing adopted child tile; `v2-smoke/v2-smoke.json`: no production camera reveal). The scoped original v2-smoke scene also failed, 1/1. Eight guided scenes from the older main checkout do not exist on this release baseline. | Normal app and board checks pass; no feature film-gate claim. |
| `swift run ContinuumRevivedCollaborationServiceChecks` | Not applicable: collaboration package/target is absent from this release baseline. | Not introduced by this port. The earlier failure was a source-snapshot executable-path issue and its supplemental recheck passed. |
| `scripts/capture-cli-fixtures.sh check` | FAIL: missing installed Claude 2.1.314 context-meter fixture; Codex 0.165.0 and Pi 1.4.0 captures found. | Same failure. |
| `--layout-pressure-check` | PASS: 3.406 ms auto-layout p95. | PASS: 2.578 ms auto-layout p95. The older load-sensitive failure is not reproduced here. |
| `swift run ContinuumRevivedPaletteChecks` | PASS. | PASS, including Open Board discovery and all three app contracts. |
| `--strict-agent-harness-check` | PASS. | PASS. The older Pi tool-list mismatch is not reproduced on the release line. |
| `--sidebar-screenshot-check` | FAIL: directory icon/text optical-centre difference 0.63134765625 pt for “work whose name generation is still in flight”. | Identical failure, in the existing workspace sidebar. |

## Historical known-red legs, checked on the release baseline

Every one of the ten known-red outcomes observed in the earlier broad run also exits 1 on untouched `f8892555`. The flags were enumerated from the app source; CoreChecks was freshly rebuilt, the managed-agent crash-suppression marker was retained, and real tmux coverage used a unique `/tmp` namespace whose actual socket path was verified before execution. No default socket was inspected or touched.

| Leg | Release-baseline outcome |
| --- | --- |
| `--nav-mode-check` | FAIL: `nav a` chooses the wrong current agent tile. |
| `--empty-workspace-creation-check` | FAIL: Palette omits already-registered Beta project. |
| `--palette-captures-keys-over-browser-check` | FAIL: Browser keeps focus; palette key capture contract fails. |
| `--note-click-focus-check` | FAIL: keyDown should edit note text; got "" |
| `--agent-tile-click-focus-check` | FAIL: padding click alone should focus the editor; firstResponder=Optional(<NSWindow: 0x77c28c0f00>) |
| `--perf-budget-zoom-check` | FAIL: 2 budget(s) over: zoom.stepDuration, zoom.tileLayoutPasses |
| `--file-tile-zoom-check` | FAIL: title compositor drift; difference 2.4398558758314857 |
| `--perf-budget-gesture-transition-check` | FAIL: 1 budget(s) over: gesture-transition.worstStepDuration |
| `--perf-budget-magnify-slope-check` | FAIL: 1 budget(s) over: magnify-slope.durationSlope |
| `swift run ContinuumRevivedCoreChecks` | FAIL: Dependency-source guard expects exactly AgentContent/AgentUI/GRDB/PiExtensions. This fails before re-establishing the old canonical-byte assertion. |

## Main-checkout cleanup

After committing, the added/removed lines in all 23 original board-only diff sections were compared against `2f1615ae` and matched exactly. The current main checkout accepted the inverse patch, including the concurrently edited app file. Only those hunks, the board-only appearance/matrix additions and their two inventory records were removed. Four newly added files were removed only after byte comparison with the committed blobs. Every candidate file was checked again immediately before mutation. Unrelated hunks remain; no main-checkout staging, commit, stash, reset, or push was performed. `main-cleanup.json` and before/candidate copies retain the audit. The feature branch itself is untouched by that cleanup.

This is targeted feature verification plus direct baseline reproductions, not a claim of a clean full release matrix. No new known-red entry was added.

## Film comparison and completion

The untouched release film variant built successfully in 581.93 seconds. The complete `scripts/check-film-scenes.sh` baseline run then finished with exit 1: **2 of 12 scenes failed** after 547 seconds of scene execution. `full-day/full-day.json` failed `adopt emails2: child toolu_emails has no tile yet (open it: click its chip)`; `v2-smoke/v2-smoke.json` failed `open placement: production presented no camera reveal (unavailable)`, exactly the original camera-reveal failure. The other ten scenes passed, including `board-story/board-story.json`. A separate scoped v2-smoke run also exited 1 after 60 seconds. The full run completed before an attempted stop; the stop script found its parent already gone and sent no signals. Its complete summary supersedes the interim intention to stop it.

No feature-film or clean full-release-matrix pass is claimed. This port did not add the eight unrelated guided scenes in the older main checkout, and the collaboration target is likewise absent on this release line.

Feature code is committed as `2f1615ae`; no push or stash was used. The preview was handed off at the beginning. The main-checkout board cleanup and final whitespace check passed. Report and logs are retained in the canonical QA directory; disposable build/source copies are removed after verification.
