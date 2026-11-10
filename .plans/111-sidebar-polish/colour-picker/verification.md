# Agent colour picker verification

Branch: array/colour-picker, based on origin/array/integration d41dad04.

Both entry points now obtain their palette from AgentIdentityColourPicker and render using ChoiceListView / ChoicePopoverController. The tile's command model carries the same swatch data into ChoiceMenuController. Choice rows route decorative child hits to the row while retaining accessory targets. Both writes retain the supervisor setter used by agent.update.

Root cause remains unconfirmed. The baseline at d41dad04 offers text menu entries in the tile and circle icons in the sidebar, rather than a dedicated swatch picker. Inspection suggested decorative children could intercept clicks, but the real-event witness also PASSED against the original production files. That hypothesis is not established as the cause of the reported failure. Do not claim RED/GREEN reproduction or that the reported bug is conclusively fixed.

Extended --agent-identity-color-check sends NSApp.sendEvent mouse-down events at rendered swatches, with mouse-up queued first. It asserts record colour, fresh disk reload (both entry points), tile paint, sidebar dot and clearing. Check windows use orderFrontOffscreenForChecks. Tile menu presentation uses the production ChoiceMenuController mapping. Existing menu-opening QA seams remain; swatch selection uses events.

Commands/results:
- scripts/prepare-ghosttykit.sh: passed.
- scripts/benches.sh: run at pickup and finish; inventory saved temporarily outside the bench.
- swift build --product Array: first build failed because a newly added source was not in its initial file census and an insertion landed in the list initializer. Corrected; interrupted the already failing build.
- swift build --product Array -j 6: final PASS.
- --agent-identity-color-check: initial witness setup failed before interaction because the temporary menu tree was released; corrected. Final PASS. Original production files with the event witness also PASS: required RED reproduction remains missing.
- --workspace-api-agent-colour-check: first refused missing isolated CONTINUUM_APP_SUPPORT; rerun with a unique /tmp directory PASS, including its intentional filesystem failure arm.
- git diff --check: PASS.
- Full matrix: skipped as requested.
- No installed apps rebuilt or launched. No push.

Stills: tile-light.png, tile-dark.png, sidebar-light.png, sidebar-dark.png in this directory. Captured from the picker panel content view and visually inspected in both appearances.

Next: reproduce the failing click in the affected build/session before declaring the original report resolved.
