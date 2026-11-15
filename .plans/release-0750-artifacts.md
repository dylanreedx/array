# Array 0.7.50 / build 101 artifact preparation

Release ledger commit: `0ef0daf5ad5becf60c277b3dc78ecdae8bea6b16`. Packaging version defaults intentionally unchanged; app is stamped by the release script.

Apple notary history was checked before work: 0.7.49 app and DMG Accepted.

Fresh optimized build uses `.build-prod` (separate SwiftPM scratch from debug/matrix). Initial capacity: one Swift build, 58% memory free, 70 GiB disk free. Log `/tmp/release-0750-prod-build.log`.

Release notes and exact publish commands are staged for review in `qa-runs/release-0750/release-notes.txt` and `qa-runs/release-0750/publish.sh`; nothing published.

Artifacts ready; full matrix and final classification complete. No source changes after optimized build.

- Ledger/build commit `0ef0daf5ad5becf60c277b3dc78ecdae8bea6b16`. Feed commit `098d96f4`.
- Optimized app build PASS (1193.52s), optimized MCP build PASS.
- Developer ID signatures, app+DMG notarization/stapling, Gatekeeper PASS.
- App notary ID `1ad5fbf7-4152-4a0c-9d62-cc964e087594`; DMG `4ab2772f-1c79-4e61-993e-9c5c9a52e414`, both Accepted.
- Production bundle harness PASS: `qa-runs/release-0750/bundle-check/manifest.json`; verified disposable tmux, eight self-checks, launch smoke, resources, codesign and pollution guards.
- `qa-runs/release-0750/release/Array.dmg` and `Array-0.7.50.dmg`: 79,238,457 bytes, SHA256 `3a2a4765714395c333bac0ba668429bf38c97b0df41d3b687769d3e881087603`.
- Versioned copy `/Users/dylan/Documents/personal/Array/releases/Array-0.7.50.dmg`.
- Appcast signed build 101 first, one-hour phased rollout; all 99 previous items preserved verbatim, 100 total. Generator’s new item lacked expected formatting, so initial raw extraction failed; corrected via parsing the whole document and formatting only the new item. Incorrect intermediate local feed commit was amended before any push; final diff is exactly 12 inserted lines.
- Seven direct bubble/chrome/character witnesses PASS, managed66/66 PASS, restore24/24 PASS.
- Full matrix `/tmp/release-0750-full.log`, `qa-runs/matrix-20261115T015417Z-71320`. Start capacity: one Swift build, 42% free memory, ~68GiB disk.
- Display/awake coverage skipped per request; managed crash marker preserved. Previous-installed-version update flow remains unverified (no publishing authorized).


## Final gate and classification

Full foreground `scripts/run-matrix.sh --skip-awake`: **411 legs, 405 PASS, 1 KNOWN-RED, 5 FAIL**, exit 1, wall time 1785s. Raw result remains RED. JSON `qa-runs/matrix-20261115T015417Z-71320/results.json`, log `/tmp/release-0750-full.log`. Bubble and drag legs both explicitly PASS in the full report. No regression needing a code change found, so signed release rebuild was unnecessary.

| Failure | Classification | Evidence |
|---|---|---|
| `--empty-workspace-creation-check` | Expected KNOWN-RED | Matrix classification; supplied candidate/0.7.49 reports |
| `--agent-steering-recovery-check` | Load flake | Serial behavior=0, focus=0 in `/tmp/release-0750-rerun-results.txt`; same historical load failure in `/tmp/plan-117-land-gate-report.md` |
| `--subagent-sidebar-open-check` | Pre-existing | Same four WORLD-frame placement failures as supplied `.plans/116-agent-standards/GATE-0749-RESUMED.md` and 0.7.49 report; witness file unchanged from `78d658fe`. No fresh 0.7.49 runtime build claimed. |
| `--canvas-zoom-step-cost-check` | Pre-existing QA focus failure | Behavioral assertions PASS in full matrix and serial rerun, focus sampler RED; freshly rebuilt pre-bubble candidate `4b674df0` reproduces behavior=0/focus=1 |
| `--markdown-visible-rows-zoom-cost-check` | Pre-existing QA focus failure | Same current and pre-bubble result |
| `--markdown-frame-observer-check` | Pre-existing QA focus failure | Same current and pre-bubble result |

The supplied candidate report called the three sampler failures load flakes based on direct behavioral reruns without fresh sampling. This run retained the matrix’s exact frontmost-app sampler in serial retries and found persistent failures, each with its own test PID. The clean pre-bubble candidate was rebuilt with `swift build --product Array -j 2` (8.74s), then all three repeated serially with the same sampler and disposable verified tmux namespace. Logs `/tmp/release-0750-baseline-build.log`, `/tmp/release-0750-baseline-results.txt`, `/tmp/release-0750-baseline--*-focus.log`. These are pre-existing QA focus failures; no claim that focus suppression is green.

Initial serial-rerun preflight rejected its disposable tmux namespace because `/tmp` canonicalizes to `/private/tmp`; no checks ran in that attempt. The script then canonicalized and verified the namespace. Only that explicitly created disposable server was cleaned up; default tmux was never used. Serial rerun logs `/tmp/release-0750-reruns.log`, `/tmp/release-0750-rerun-results.txt`; each preserves the managed crash marker, disables terminal tmux, isolates project/support, uses TERM=xterm-256color and stdin /dev/null. The baseline candidate remained source-clean.

## Release notes

The agent icon now floats on each tile's top-left corner.

Array opens much faster when you have lots of agent history.

Orchestration groundwork: helper isolation, usage timing, an automatic pre-check, effort levels taken from each CLI's catalogue, a leaner helper context, and solo-or-split now asking the agent to decide first. These are off by default.

## Exact publish commands (NOT EXECUTED)

Run only after an explicit publish order. Both DMGs are uploaded in the release-create command. Integration push is an ordinary fast-forward-only push; `78d658fe` is an ancestor of this branch. Main is fast-forwarded without checking out or changing the dirty main worktree.

```sh
cd /Users/dylan/Documents/personal/Array/.worktrees/release-0750
gh release create v0.7.50 --repo dylanreedx/array-releases \
  --title 'Array 0.7.50' \
  --notes-file qa-runs/release-0750/release-notes.txt \
  qa-runs/release-0750/release/Array.dmg \
  qa-runs/release-0750/release/Array-0.7.50.dmg
git merge-base --is-ancestor 78d658fe array/release-0750
git push origin array/release-0750:array/integration
git fetch origin array/integration main
git merge-base --is-ancestor origin/main origin/array/integration
git push origin origin/array/integration:main
```

Bench retained because release remains local and unpushed. Initial inventory `/tmp/release-0750-benches-start.log`; artifact inventory `/tmp/release-0750-benches-artifacts.log`. Final inventory recorded separately. `/Applications/Array.app`, main checkout's uncommitted diff and default tmux socket were not modified. One check emitted undo-toast PNGs into a root directory named `-continuum.terminal.tmux.enabled`; those generated PNGs were moved into `qa-runs/release-0750/undo-toast-render`. Separate optimized scratch `.build-prod/` is retained as disposable release-bench build output, untracked and uncommitted.
