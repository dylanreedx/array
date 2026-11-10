The unfold regression was mine: 551e4511 disabled motion for production ownership cards. Untouched d41dad04 was rebuilt in this bench with no source modifications and passed --inbox-parent-fold-check. The 551e4511 binary failed the opening-motion assertion. Logs are integration-check.txt and branch-before-check.txt.

Production now animates native row layers using sampled spring keyframes on the render server. The clicked parent stays live. Removed children use their existing views in a click-through overlay for the exit. No bitmap snapshots, display-link callback, per-frame native layout, or new verifier tooling is used for production unfolds. The existing check asserts real layer animations are installed and no frame callback is active, alongside its existing travel, reversal, stream, no-rebuild, Reduce Motion and cleanup assertions. The manual advance seam controls the native animation timeline for that existing deterministic check; user reversals use real elapsed presentation time.

The explicit legacy folding opt-in is restored for fixtures. Production is explicitly default-open, with persisted manual choices taking priority. Its existing wiring assertions now guard that intended default-open behavior and saved collapse. This fixes the earlier blanket bypass of the legacy policy without undoing expanded defaults.

Same CFAbsoluteTime synchronous-handler timing method and 43-helper/16-neighbor debug fixture, dark / light, before -> after:

- Lead open: 3.39 / 2.95 -> 3.32 / 3.24ms.
- Lead close: 8.78 / 6.82 -> 7.78 / 6.73ms.
- Helper remainder open: 6.23 / 4.05 -> 4.36 / 3.36ms.
- Helper remainder close after live pushes: 14.73 / 13.17 -> 20.68 / 13.09ms.

Load varied; these are wall times, not controlled speedup ratios or latency through the next display. The dark helper-close outlier remains above target. This change restores parent motion without adding that cost back to lead opening. Raw after handler times: handler-timings.txt. Before: ../expand-after.txt. Temporary handler timers were removed.

Existing 20-card parent-fold latency loop (ten alternating folds): untouched integration 29.6ms fastest / 38.9 median / 49.4 worst. Final branch 3.1 / 4.0 / 12.8ms; all motion assertions passed (branch-after-check.txt). An earlier candidate passed at 1.9 / 2.2 / 8.7ms; machine load varied, so the final run is the reported result. The initial native-motion candidate failed the reversal assertion; corrected the existing manual-clock seam and reran successfully.

Screenshot check expectation: use AgentInboxView.rowSpacing (2pt) instead of Space.s (4pt), changing the expected pitch from 56pt to 54pt. No rendering geometry changed in this correction.

Preview merge/build/check/launch results are recorded by the final report. No full matrix or push. Dev SidebarActiveIndicatorStyle was read as duplex and left unchanged.
