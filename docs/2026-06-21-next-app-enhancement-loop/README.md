# Next app enhancement loop — inspector, browser, and tile UX

Status: draft planning bundle for autonomous implementation loop

Purpose: define high-quality, implementation-ready tickets for the next overnight loop. These tickets bias toward bounded, verifiable slices and avoid broad architecture guesses.

Key decision: implement an in-app **Browser Inspector Tile** as a first-class tile type backed by Continuum-owned instrumentation, not Safari Web Inspector embedding. Do **not** introduce a generic connected-tiles architecture yet. Use a narrow `inspectedBrowserTileId` relationship for inspector tiles; generalize later only after a second proven use case.

Files in this bundle:

- `00-epics-and-queue.md` — ordered loop queue and epics
- `T01-browser-inspector-tile-shell.md`
- `T02-browser-inspector-dom-tree.md`
- `T03-browser-inspector-console.md`
- `T04-browser-inspector-styles.md`
- `T05-browser-inspector-network-lite.md`
- `T06-browser-inspector-link-lifecycle.md`
- `T07-browser-inspector-action-palette.md`
- `T08-browser-downloads-tile.md`
- `T09-browser-session-health.md`
- `T10-final-audit-and-dogfood.md`

Important non-goal: do not try to embed Safari/WebKit's private Web Inspector UI inside Continuum. WebKit exposes native inspector through Safari Develop. This loop builds a Continuum-native inspector surface with explicitly scoped capabilities.
