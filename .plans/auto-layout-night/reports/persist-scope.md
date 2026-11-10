# Scope the layout save

Date: 2026-11-09. Branch: array/aln-persist-scope (local, not pushed).
Base: array/auto-layout-night 932a6fee, then merged up to 65f1da43.

## What changed

A drag or tidy commit now loads, merges and writes only the projects that
own the committed tiles, plus the workspace document when a zone or an
ambient tile changed.

Why it was slow: `AppDelegate.persistLayoutTransaction` loaded and
verified every project canvas in the workspace on each commit, only to
find which files owned the changed tiles. Each load is a read, decode,
schema check and sanitize, on the main thread, right after the movement.
The workspace document was also written on every commit.

How:
- Each committed tile's owner comes from the live canvas
  (`zoneId(containing:)`, then that zone's project in the document).
  Only those projects' canvases are loaded and merged.
- A tile the canvas cannot place falls back to the old full scan, over
  the remaining projects only, so nothing the old commit saved is now
  refused. The refusal ("tiles without a store") is unchanged.
- Rollback on a refused write is unchanged: written projects are restored
  if the document write fails.
- Frames stay WORLD on disk; the merge per tile and the membership restamp
  are unchanged.
- `WorkspaceRuntime.commitLayoutTransaction` skips the document write when
  the document is unchanged, and still calls `noteStructuralCommit()`
  (CX-01 revisions).

One behaviour difference: a tile id present in two projects' files (a
copy) used to get its new frame in both. Now only the owner on the canvas
is written. The other is a copy, and the stranded-tile logic already
treats it so.

Commits:
- d939debf perf(layout): load and write only the projects a layout commit touched
- 251455b2 test(layout): witness a layout commit reading only its own project
- c6998fa9 chore(layout): merge the auto-layout night branch into the scope bench
- c820de41 test(layout): register the layout commit scope leg in the matrix

## Witness: --layout-commit-scope-check

A mounted workspace (WorkspaceInvariantsFixture) with 1, 5 and 20 extra
projects, each owned by the workspace with one zone and one note; auto
layout on; the default live budget of 4 zones. Through production:
`performGeometryEdit` -> `commitGeometryEdit` -> `persistLayoutTransaction`,
and the palette's Tidy.

Per commit it records the `StoreReadProbe` delta, the projects loaded and
written, and every project's canvas.json bytes before and after.
- A move of one note in project A1: loads and writes only A1; every other
  canvas.json is byte-identical; A1's file holds the on-screen frame.
- Tidy with only A1 untidy: loads at most A1; nothing else changes.
- Positive control: one commit moving notes in A1 and A2 loads and writes
  both, and both files hold the on-screen frames.
- Flat: a one-project move costs the same store reads at every size.

Before (old commit code with the same recording added, run once):
| extra projects | store reads | move ms | tidy ms |
|---|---|---|---|
| 1 | 4 | 7.8 | 13.3 |
| 5 | 8 | 12.0 | 15.1 |
| 20 | 23 | 6.9 | 8.2 |
Red: 10 failures; every commit loaded every project.

After:
| extra projects | store reads | move ms | tidy ms |
|---|---|---|---|
| 1 | 2 | 5.6 | 5.4 |
| 5 | 2 | 4.7 | 7.3 |
| 20 | 2 | 6.1 | 8.2 |

The read count is the proof. Wall time in this fixture is noise-level
either way, because each extra canvas holds one note; a real project
canvas (89 tiles in Dylan's) costs far more per load. The witness only
rules out time growing with project count (20 extra ≤ 2 × 1 extra + 5 ms).

## Checks (merged tree, offscreen, isolated app support and TMUX_TMPDIR)

All exit 0: layout-commit-scope, canvas-undo, workspace-scene-owner,
auto-layout-tidy-latency, layout-commit-truth, spawn-arrange-commit,
ambient-tile-frame-space, canvas-save-receipt, persistence-crash-safe,
zone-save-isolation, canvas-persistence-model, zone-runtime-duplication,
workspace-runtime-install, zone-arming, spawn-framing, spawn-placement,
auto-layout-fanout-app, workspace-api-open; CoreChecks
--unreadable-canvas-store-check.

Base regressions from the lead's list, after merging 65f1da43: all five
now PASS (subagent-tile-zone, leader-jump, tile-reveal-work,
agent-local-file-link, canvas-zoom-momentum).

Matrix inventory regenerated (C locale): adds this leg, and corrects the
CoreChecks count 204 -> 205 that the merged night branch had left stale.
