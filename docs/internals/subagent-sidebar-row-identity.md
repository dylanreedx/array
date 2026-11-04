# Subagent sidebar identity (0.7.43)

Board ticket `50A5B7B7-CDF2-4D82-A980-EC882C02D3CF` accompanies the queued
message preview hotfix in 0.7.43. A popped-out helper in a scoped sidebar could
be promoted to depth zero when its lead was omitted from the list. Styling
used depth alone, so that helper acquired the taller lead presentation.

Compact helper layout now follows parent identity as well as nesting depth.
The same predicate controls row height, helper typography, character sizing,
clock and tail. The scope can still promote a helper for navigation; it does
not turn that helper into a lead.

The existing `--subagent-sidebar-open-check` drives real row clicks and
pop-outs, refreshes the sidebar and then scopes out the lead. With the new
assertions alone, the scoped helper enlarged to 54 points (RED). With the
fix, the helper remains a compact one-line row under 40 points (GREEN).
All eight click scenarios pass, including the tmux-disabled and broken-shim
cases. Ownership, parent-fold and fold-expand checks also pass. Before/after
light/dark sidebar captures were inspected. Evidence is retained under the
release owner's gitignored `releases/0.7.43-evidence/` directory.

The existing full-matrix leg is also included in the targeted
`--sidebar-refinements` gate, so that gate reports the regression witness.
This is an offline AppKit fixture, not a live production screenshot or a
claim that the full matrix ran.
