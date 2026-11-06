# Workspace API camera policy

Agent document opens, delegation and agent reveals use `defaultExplicitOpen`,
which preserves all presentation dimensions. The grant ceiling still permits
an explicit `camera: revealResult`; a grant does not request camera movement.
Device opens inherit their preserve policy. User inbox pop-outs keep their
existing navigation behavior.

Explicit presentation defers when the interaction generation is stale, keyboard
or pointer input occurred within three seconds, or camera/geometry gestures are
active. Input records monotonic uptime in constant time on the mounted workspace;
programmatic viewport changes do not advance interaction generation. Deferred
requests do not queue a later camera movement.

API result tiles fully outside the canvas receive a silent edge control (MAC-14).
It uses ComposerActionButton and visits through revealTileForWork on click or
Return. Visibility or a visit clears it. Camera tracking iterates only pending
indicators, using their retained tile view geometry. No startup UI is introduced.

Witnesses: workspace-api-grants-check (default, sendEvent keystroke, idle reveal),
workspace-api-agent-camera-check (new offscreen file, light/dark captures,
sendEvent mouse activation), workspace-api-contract-check (default vs ceiling).

## Verification on 2026-11-06

Debug Array build passed. The original implementation failed the default-open
assertion: `agent open must preserve camera by default` (exit 1). Removing the
engagement guard and indicator registration from the fixed service produced
`keystroke defers explicit reveal` and `offscreen API-created tile must have an
edge indicator` (each exit 1). Restoring the service made all three checks green.

Final targeted app legs: workspace-api-open-check, workspace-api-grants-check,
workspace-api-agent-camera-check passed. Rebuilt CoreChecks and its
workspace-api-contract-check passed. No full matrix or tmux checks were run.
The indicator leg is registered in both the permission subset and full matrix.
Captures: `qa-runs/agent-camera-policy/indicator-light.png` and
`qa-runs/agent-camera-policy/indicator-dark.png` (inspected).

An intermediate build failed because its source was edited during compilation;
the subsequent rebuild succeeded. The first contract run exposed an assertion
that still expected the former default; updated to check both the preserve
default and explicit reveal permission, then rebuilt and passed.

Remaining coverage limits: no live simulator/device UI run, no multi-indicator
crowding or sustained performance benchmark, and no full matrix summary.

Device prerequisite: first workspace-api-device-check failed with `rebuilt native
MCP helper required`. Built array-workspace-mcp (exit 0), then reran the device
leg with disposable CONTINUUM_APP_SUPPORT: passed (exit 0), including real helper
HTTP open/observe/tap/close and no-presentation assertions.
