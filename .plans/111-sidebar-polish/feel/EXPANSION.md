Before implementation changes (follow-up to 12b109b9): staged CFAbsoluteTime timers around the existing fold fixture, debug, Always scrollbars, both appearances. Raw: expand-before.txt. Machine under concurrent Swift compiler load, so these wall times exceed the earlier 80ms run.

User close: preparation 0.07ms; filter/sort/model projection 2.15–2.50ms; full render 25.71–31.32ms; forced layout and scroll-anchor restoration 168.17–173.89ms. User open: preparation 0.01ms; projection 1.96–3.43ms; full render 13.75–63.77ms; no closing layout tail. Lead disclosure: 104–381ms including bitmap snapshots and forced layouts. Main-thread sample shows AgentInbox96CellView allocation building buttons, symbol images and constraints. Most close time is synchronous AppKit materialization/layout after the full reload; it is not transcript I/O or the ~2ms sort. The old remainder handler discards all card views; lead disclosure additionally photographs cards before/after the change.

Planned experiment: reuse AppKit table cells by presentation type; use the existing incremental row splice for remainder changes and preserve the changed remainder affordance; avoid bitmap-based lead animation on this immediate interaction. Re-measure with the identical staged timers.

Deeper main-thread sample of the slower close (before backing-scale fix): NSTableView.endUpdates calls _removeViewAndAddToReuse, then view removal calls AgentInbox96CellView.viewDidMoveToWindow -> refreshMetadataBackingScale. When the card has no window, this asks NSScreen.main for a scale. The sample shows synchronous WindowServer display queries (SLSGetOnlineDisplayList / mach_msg2_trap) repeated on detach. Cell construction also asks NSScreen.main once per new card. This explains why card reuse and zero animation duration alone did not remove the close stall. A detached view should retain its last backing scale; attachment supplies the actual window scale.

Retained implementation: incremental helper-row changes, bounded reuse of 128 recent card views (including lending an offscreen helper to a newly visible helper), direct remapping of materialized row references, and a single settle-nudge derivation per fold. Unchanged non-parent cards keep their content during a fold, with clocks, selection, ownership, peek, and interaction presentation refreshed. Cached cards keep the sidebar appearance and follow its appearance changes. Hidden optional controls are mounted only while shown. Detached cards keep their last backing scale rather than querying NSScreen.main. Production ownership leads use immediate disclosure instead of bitmap snapshots; other card previews retain their existing motion.

Final synchronous handler timings, same debug fixture and CFAbsoluteTime handler timer method, dark / light in ms:

| Path | Follow-up before | After |
| --- | --- | --- |
| Helper open | 67.22 / 15.71 | 6.23 / 4.05 |
| Helper close after live updates | 207.78 / 196.11 | 14.73 / 13.17 |
| Lead close | 380.63 / 192.44 | 8.78 / 6.82 |
| Lead open | 161.81 / 104.34 | 3.39 / 2.95 |

The original lighter-load baseline was 7.7–10.5ms open and 71.5–85.4ms close. The follow-up before run competed with other Swift compiler processes. These are wall times in unoptimized debug code, not a controlled speedup ratio or latency through the next display. The same fixture has 43 helpers plus 16 neighboring leads; its setup materializes the full list. Raw follow-up before/after measurements are expand-before.txt and expand-after.txt. The first helper toggle in each after appearance is setup collapsing the new default-expanded group (3.68 / 3.37ms), not user opening or final closing.

The <8ms target remains unmet for helper close and the first dark lead close. No claim that the performance objective is complete. The retained work materially reduces the original close stall, but the remaining synchronous AppKit view removal/reattachment work still needs attention.

Discarded experiments: zero-duration animation contexts, pre-restoring the closing viewport inside the row-update transaction, and a full table reload with cached cards did not improve closing. Removing the group background failed the existing hover-fill equality witness; restored it. One final build caught calling a concrete clock method through the row-cell protocol; corrected to the concrete card cast. No new verifier or benchmark tooling is committed; temporary timers were removed.

Validation: rebuilt Array, existing --sidebar-fold-expand-check with -AppleShowScrollBars Always and isolated CONTINUUM_APP_SUPPORT; both appearances passed. final-check.txt is the final uninstrumented run. Updated after/ stills were inspected in light and dark. git diff --check and bench inventory also run. No full matrix, live app launch, tmux, production state, installed apps, push, or external messaging.

Live scrollbar result: NOT RUN. Only the existing attempted legacy-style setter rewrite witness passed under Always. No WKWebView browser tile was opened in a separate preview app, so actual live WebKit layer-commit behavior remains unverified.
