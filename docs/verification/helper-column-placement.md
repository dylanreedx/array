# Preset-independent helper docking

This follow-up is on array/spawn-framing-release, after cf86ae08, 0d5187d1,
507d1365 and 8675b50a. Merge the branch's fixes together: 0d5187d1 removes
the earlier nearest-visible shortcut; this change also removes automatic
fan-out ranking from the explicit beside-parent route.

## Cause and fix

Even after the nearest-visible shortcut was removed, the helper path still
ranked fan-out slots by visibility and the user's automatic growth direction.
Down growth could therefore place the first helper below its lead. That is
not the explicit beside intent, regardless of the helper's height.

TileSpawnPlacement.besideLead now chooses unoccupied columns to the lead's
right, starting at its top. Existing helpers provide the remaining row edges;
a full column wraps to the right at the lead's top. Positions derive from
actual lead/helper/sibling frames and the resolved gap, with no creation-size
constants. The caller keeps model B's half-height/minimum-size calculation.
Unrelated tiles are avoided; camera visibility never changes the chosen side.

## Witness and presets

The existing --subagent-tile-zone-check is stronger:

- Exercises Fan Out, Right and Down growth, plus auto layout off.
- Requires the exact configured first-helper gap, the right side and top alignment.
- Preserves half-height/width, world-zone membership, persistence, non-overlap,
  overflow adjacency and the existing no-single-row assertions.
- Requires the second helper to fill the same right column when two fit.
- Computes column capacity from actual frame heights rather than a preset count.
- Adds pure placement controls for helpers shorter and taller than their lead.
  Their expected positions are relative to the lead and configured gap.

For compatibility verification only, the exact TileGeometry.swift from night
commit 5e1accbd was temporarily used (blob
1b872b42f114bc8f4ec7d1b287c6e1954dd7b9c2). This supplies the actual night
browser/terminal/managed/shared-agent presets, including the 576x640 lead.
It was restored byte-for-byte before the final release-preset build and is
not part of this commit. No full night-branch merge/build is claimed.

Before the production fix, the expanded Down case was RED (exit 1):

`the first child must open docked beside its parent (2112, 880) 576x640; got (2112, 1528) 576x316`

After the fix, the strengthened flag is GREEN with both the night presets
and the release presets, including Down growth. The night-preset
--auto-layout-fanout-app-check also passes. The earlier default Fan Out case
already passed with the previous shortcut fix; the expanded direction
coverage exposes the remaining violation of explicit intent.

The night makeProjectTilePlacement(fitting:) path was inspected: explicit
worldPoint/size returns before roomFit. This route supplies both, so fitting
does not resize or reposition the chosen helper. No call signature was changed.

## Final release-preset sweep

All 74 previously enumerated app legs reran: 72 passed, with the same two
known outstanding failures from the preceding repair report:

- --spawn-placement-check demands a legacy 24-point gap (x=5344) while the lead's
  standard-gap ruling and fixed code produce 8 points (x=5328). Unchanged check.
- --agent-tile-click-focus-check fails the padding-click first-responder assertion;
  the earlier untouched-baseline comparison already reproduces it. Unchanged check.

All five original regression legs pass, as do --spawn-framing-check,
--spawn-live-framing-check, --zone-arming-check and --auto-layout-fanout-app-check.

CoreChecks was rebuilt with SDKROOT exported. The concurrent attempt failed
its unrelated 100 ms safe-row timing guard at 126.337 ms; it was not changed.
A serial rerun completed GREEN, exit 0 (226.93 seconds). The inherited managed
agent marker was preserved, including the required crash-witness skips.

Evidence and full per-leg exit codes remain in qa-runs/spawn-release-repair/:
helper-direction-red/, helper-night-final/, helper-night-green/,
helper-final-sweep/, helper-final-core/ and helper-final-core-serial/.
Debug builds only; isolated tmux namespaces, verified socket paths, PID-only
server cleanup, isolated app support, ARRAY_AGENT_ID unset and stdin /dev/null.
No push, full matrix, installed-app change, release build or weakened assertion.
