# Hands-on pointer comparison (prepared, not launched)

1. Set the baseline: `defaults write dev.arrayapp.macos.dev array.debug.browserPassivePointerIsolation -bool NO`.
2. Launch only the preview: `open --env CONTINUUM_PROJECT_ROOT="$HOME/array-scratch" "$HOME/Desktop/Array Dev.app"`.
3. In a Codex agent in that preview paste: “Open file:///Users/dylan/array-scratch/array-pointer-isolation-fixture.html with workspace browser tools only. Repeat 20 rounds: native-click CSS menu, pause 1 second, snapshot, then CSS item; repeat for Dropdown menu/Dropdown item. Also click Tooltip target and inspect its tooltip. Record misses; do not reopen to hide a miss. If native clicks cannot establish CSS hover/tooltip, report unsupported hover and continue the dropdown test. No evaluate, DOM edits or scripted clicks.”
4. During pauses, move your real pointer over the driven browser, across menu edges, then out of the tile; avoid clicking or scrolling in it.
5. Flip on: `defaults write dev.arrayapp.macos.dev array.debug.browserPassivePointerIsolation -bool YES`; wait two seconds, then repeat the same prompt with a freshly loaded fixture.
6. Failure: a menu closes and its item is missed, or its tooltip disappears. Evidence for the filter: misses with NO disappear with YES; both passing is inconclusive. The page shows native attempts and picks.
7. With YES, confirm hover still works in another unowned browser; click or type in the driven browser to confirm immediate agent pause. Use Return to agent plus a fresh snapshot to resume.
8. Finish: `defaults delete dev.arrayapp.macos.dev array.debug.browserPassivePointerIsolation`.

The toggle is polled at most once per second, defaults off, and is available only in DEBUG builds with exactly the dev bundle ID. Production cannot read the dev suite; release builds do not read it either. No defaults command above was executed during preparation. The fixture lives under the scratch root, not Dylan's live project. The filter is still an experiment, not a demonstrated fix.

Array currently exposes browser clicks, not a browser hover tool. The pure CSS menu and tooltip therefore test whether the native click establishes hover on this host. The prompt explicitly reports unsupported hover rather than fabricating it with JavaScript. The separate click-open/mouseleave-close dropdown can be repeated through the existing native click tools regardless of that capability.

Validation: `/tmp/pointer-manual-preview-build.log` exited 0 (52s), using `scripts/dev-app.sh --no-launch` with the default Desktop output; deep/strict codesign verification exited 0 and bundle ID is dev.arrayapp.macos.dev. `/tmp/pointer-manual-final-0.log` and `-1.log` both exited 0: existing matrix-registered durable-takeover checks, including isolated dev-toggle resolution and the Tier A key-counter regression. No activated check, preview launch, CGEvent creation, pointer warp, full matrix, or push occurred. Visual/manual behavior awaits Dylan's hands-on comparison.
