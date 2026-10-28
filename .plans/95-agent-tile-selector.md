# Agent tile selector — actual Array menus

Base: `f62ba3f3` (Array 0.7.34/build 85). Branch: `array/agent-tile-selector`.

The previous agent-menu packet changed icon sizing and audited stock `NSMenu`
data; it did not deliver the requested Array-styled selector. This change
replaces the displayed agent actions menu and all cascading submenus with the
same shared AppKit Choice surfaces used by the workspace selector.

## Result

- The retained custom ellipsis control opens shared Choice panels on pointer,
  keyboard or accessibility press. Managed-agent header context clicks use the
  same presentation. Existing command order and original targets are preserved.
- Zoom, Color, Sounds → event → sound, and location/project trees use cascading
  panels with row checks, shortcuts, arrows, disabled states, real dividers,
  scrolling and screen-edge clamping. Source NSMenu objects are command data;
  no stock NSMenu popup presents the agent selector.
- Hover opens nested panels. Right/Left navigate levels, Escape and outside
  clicks close the whole chain, and re-clicking the trigger closes without
  reopening. Modified menu shortcuts dispatch their existing commands.
- Selection dismisses every level before invoking the original menu item and
  target. Closing restores focus; removing the tile dismisses all its panels.
- The existing CanvasSymbolImage bitmap cache, ellipsis ink sizing, custom
  titlebar renderer, native focus ring and token tint remain. Opening wakes
  cached controls; an open actions menu prevents the camera from resting them;
  closing allows the same retained controls to return to cached rendering.
- Shared menu rows cache shortcut width outside layout. Ordinary Choice clients
  keep their existing defaults and do not join a cascade group.

## Verification

The actual presentation witness was RED before integration:
`AX pressing Agent actions must open the shared Choice menu`. It drives the
real retained control, visible shared panels and production rows, rather than
asserting that the command model contains NSMenu items.

Final command: `scripts/run-matrix.sh --agent-tile-menu`.
**12 legs ran, all passed:** inventory, colour hygiene, tile chrome scale,
actual agent menus, agent page zoom, terminal face switching, identity colour,
location actions, camera chrome redraw, shared choice geometry, workspace
selector, and UI probe (including appearance/token checks).

The actual menu witness checks pointer/keyboard/AX opening, cached renderer
wake/rest, mouse hover through three levels, real command effects, disabled
rows, both appearances, Right/Left/Escape, trigger re-click while a child is
open, Command-equals through the app event queue, outside dismissal, and owner
teardown. It also retains the previous semantic action/persistence audit.
Actual root/Zoom captures were reviewed in both themes, plus the three-level
Sounds capture in dark appearance.

Initial implementation attempts failed compilation when a source changed during
an in-flight build and when a Swift override was placed in an extension; both
were corrected before the final successful rebuild/gate. The first baseline
probe looked only in the subview tree and correctly exposed that the current
renderer retains/detaches its controls; the witness now follows that production
owner. The subsequent intended AX RED above is the behavior regression proof.

## Pickup and limits

Cherry-pick this branch's final commit into the next release. The external
`.plans/95-agent-tile-selector/` packet contains the exact commit, a format-patch,
validation output and actual UI captures. The packet directory is separate
from this tracked note so pickup cannot overwrite the delivery artifacts.

This branch is based on the already-integrated 0.7.34 source; the old icon/menu
packet and workspace-selector patch must not be reapplied to it. Merge shared
Choice or matrix edits normally if later work touches the same files. The
existing source changes in the canonical dirty checkout, other worktrees and
the live production app were not modified by this task. No release, version bump, merge or push was performed.
Full release matrix, optimized build, signing/bundle checks and publication
remain the release owner's verification after combining changes. No baseline
images were updated. Checks used isolated project/support/defaults state; the
matrix's disposable tmux namespace was preserved and no default socket was used.
