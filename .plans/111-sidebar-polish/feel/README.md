Sidebar feel, based on d41dad04 (0.7.44).

Implemented: focus changes repaint existing cards when row identities stay the same, preserving selection and avoiding a full table reload. Untouched leads and their capped helper groups start expanded; saved per-lead manual fold choices still win. Card gap is 4pt instead of 8pt (2pt intercell + 2pt card inset). The sidebar enforces overlay scrolling through its scrollerStyle setter, autohides, and uses a small scroller.

Temporary CFAbsoluteTime timers surrounded the synchronous openAgentId didSet and toggleFanout bodies. Both appearances used the existing fold-expand fixture (43 helpers, 16 neighboring leads). Timers were removed before commit. Raw measurements are in before.txt and after.txt; the first fanout timing per appearance in after.txt is fixture setup collapsing the new default-open group, not a user opening it.

Focus set: dark 11.273 -> 1.365ms, light 9.491 -> 1.287ms.
Focus clear: dark 1.812 -> 1.165ms, light 1.770 -> 1.169ms.
Helper remainder open: dark 10.514 -> 13.995ms, light 7.678 -> 9.467ms.
Helper remainder close: dark 72.815 -> 85.418ms, light 71.531 -> 81.503ms.

The focus lag came from rebuilding the list to change which card looked active. This is fixed. The expansion performance requirement remains unresolved: opening/closing the helper remainder is slightly slower with the denser layout. An experiment reusing the existing incremental scope updater built 4 cards instead of 16 but took longer (22–34ms open, 82–84ms close), so it was discarded. Lead disclosure's bitmap animation path was inspected but not separately timed or changed. These measurements cover the sidebar's synchronous focus update, not canvas navigation or end-to-end display latency.

Validation: swift build --product Array; --sidebar-fold-expand-check with -AppleShowScrollBars Always and a unique CONTINUUM_APP_SUPPORT directory. final-check.txt records the final run. Added outcomes in that existing check: default-open helpers, no full reload or card builds on focus changes, and overlay style surviving an attempted legacy setter write. The check already covers manual folds, real clicks, live pushes and scroll anchoring in light/dark. A density-dependent half-the-list assertion was removed; its visible-rows-plus-one build bound remains.

Before/after light and dark stills are in before/ and after/. Inspected the open stills in both appearances. These are existing check offscreen window captures, not live production screenshots. Actual WKWebView layer commits and scrollbar fade timing were not exercised. No full matrix, tmux checks, app bundle build or preview launch was performed. Neither installed app was touched. The requested background plan directories were absent at this base.

Initial build failed because temporary profiling edits were made while compilation ran; rebuilding stable sources succeeded. One interim check failed its density-dependent half-list threshold as described above; final check passes. Benches inventory was run at pickup and completion. Bench retained to deliver the requested commits and still paths. No push.
