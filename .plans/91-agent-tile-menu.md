# Agent tile menu and ellipsis — release pickup

Base: `61de0eb61fc4aee2f59e6141063b0c48a848e097` (`array/integration`, 2026-10-28).

## Scope

The agent title-bar ellipsis now follows the existing geometric chrome buckets
with a 13pt visual-width floor, independently of its existing 22pt hit target.
The custom `AgentTileOverflowButton`, `CanvasSymbolImage` shared bitmap/template
cache, token tint, focus ring, action routing and native AppKit menus remain.
One shared bitmap serves every chrome size; its transparent margins are measured once.
Layout preserves the symbol aspect ratio
and centers it, avoiding the previous natural-image-size cap while zooming out.

The dropdown and all existing submenus already use `NSMenu`. A behavioral audit
found that AppKit automatically re-enabled page-zoom end-stop commands after
menu validation. The Zoom submenu now keeps its explicitly assigned enabled
states. No menu hierarchy, action semantics, workspace selector, provider auth,
project state, packaging identity, or version number changes.

## Isolation and pickup

The session could not create a normal worktree: the sandbox forbids writing the
canonical `.git` directory (`cannot lock ref ... Operation not permitted`). Work
was performed in a source snapshot of the base above, with private temporary Git
metadata borrowing the canonical object store read-only. The delivery bundle
and format-patch preserve the resulting commit independently of that snapshot.
No changes were staged or committed in the canonical repository. No merge, push,
release, app install, production app launch or production state access occurred.

Fetch the delivered bundle into the release checkout and cherry-pick its commit,
or apply the accompanying format-patch with `git am --3way`. The bundle contains
branch `array/agent-tile-native-menu`; it requires the base above to exist in the
receiving repository. The release pickup note alongside the bundle gives the
exact commit ID and commands.

Potential overlapping files when combining other work: `ContinuumApp.swift`
(self-check dispatch), `TileNSView.swift` (ellipsis sizing/QA only),
`ManagedAgentTileNSView.swift` (Zoom submenu validation only), `run-matrix.sh`
(new targeted selector and check registration), and the generated matrix inventory.
Preserve other edits and regenerate the inventory after combining registrations.

## Verification

The existing `--tile-chrome-scale-check` now calls a pixel witness on a real
managed-agent tile across fractional zooms and both sides of chrome bucket
boundaries, in light and dark appearances. It checks visible dimensions,
centering, hit size, separation from ×, unchanged outer chrome across page zoom,
and shared bitmap/template ownership and identity within each bucket. Narrow
tiles exercise visible/hidden controls, spacing and the fallback context menu. Selected
zoom levels produce PNGs of the dots and complete title bar.

New `--agent-native-menu-check` recursively audits production native rows after
AppKit validation, exercises Zoom commands, nested Sounds selection, Color
persistence and visible tint, Workspace Tools, and distinct Stop/Detach callbacks.
It uses temporary stores/defaults and starts no provider or tmux process.

Run the scoped gate with:

```sh
scripts/run-matrix.sh --agent-tile-menu
```

It rebuilds the app and reports seven app legs plus inventory/color guards using
the usual per-leg isolated stores. It does not replace the full release matrix.
Final observed results and remaining verification are in the external pickup note.

## Observed outcome (2026-10-28)

- App debug build passed.
- Scoped matrix: **9 legs run, 8 passed, 1 failing Terminal-face leg**. Both the new menu
  leg and the expanded chrome-scale leg ran and passed. Inventory/color guards,
  page zoom, identity color, location actions and camera chrome redraw passed.
- `--agent-face-switch-check` failed at “the hidden-toggle preference must still
  allow returning to chat”. A separate rebuild with all three changed production
  files restored to the base (retaining only the QA view accessor) reproduced
  exactly that failure. The last matrix invocation exited 139 in the same leg;
  its macOS crash report starts in `objc_msgSend` / CFPreferences dictionary
  merging. A subsequent direct candidate run reproduced the baseline assertion.
  The crash itself has not been reproduced on the base or classified. No new
  KNOWN-RED was added and the targeted gate still returns 1 and reports this leg.
- The new pixel sweep covers 74 appearance/zoom combinations, plus narrow tile
  hide/show/spacing. Shared bitmap ownership, template tint support and image
  identity survived both camera and page zoom. Light/dark captures were reviewed.
- Before the fix, the pixel witness failed at 10% zoom (no painted dots), and the
  native menu audit failed because native validation re-enabled Zoom Out at 80%.
- `git diff --check`, matrix inventory validation and shell syntax checks passed.
- The full matrix, iOS build, bundle packaging, live popup anchoring/tracking,
  and release integration remain unverified. No baseline images were updated.

The sandbox rejects SwiftPM's nested `sandbox-exec`; the successful matrix run
used a temporary PATH wrapper that adds `--disable-sandbox` to `swift build`.
This only avoids nesting SwiftPM's build sandbox inside the session sandbox;
it does not change the session's filesystem restrictions or repository scripts.
The first matrix attempt halted at the build for this reason. An initial copied
build cache was also discarded after precompiled-module path mismatch errors.
One check edit initially missed an AgentUI import; adding it fixed compilation.
Intermediate pixel checks exposed transparent-margin sizing and optical centering
issues; the final code normalizes both once against the cached bitmap. A first
contact-sheet attempt lacked Pillow; a standalone AppKit script produced the
review sheet instead. No dependency installation was needed.
