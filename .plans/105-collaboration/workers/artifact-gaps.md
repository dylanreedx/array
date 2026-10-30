# Artifact gaps — receipt

30 October 2026. Branch `array/mp-artifact-gaps` off `array/mp-w6-artifacts`
(6d2c9d18). Closes the two gaps worker 6 left in "Round 2".

## 1. Retry a failed upload after relaunch

**What was wrong.** After the arrangement was accepted, the capture review
uploaded each snapshot from bytes it held only in memory. If an upload failed,
those bytes were gone once the review closed or the app quit. The item stayed
without a revision for good.

**Fix (a7ee9817).**

- Before the command is sent, the coordinator stages each confirmed capture on
  disk, under the revision ID reserved at review. The file is
  `uploads/<revision>.json` beside the area's `state.json`, mode 0600 in a 0700
  directory (`SharedAreaLocalStore.stageUpload`).
- After acceptance, the coordinator calls `SharedAreaController.uploadStagedArtifacts()`.
  The controller also runs that pass:
  - at the end of `recoverPendingOperations`, which every `open()` runs, so
    after a relaunch;
  - on reconnect, the first `.connected` frame after the stream was
    reconnecting.
- Before sending, the controller asks the service for the object's state.
  - Revision already there (reply lost, or the app quit before forgetting it):
    the staged file is deleted and no bytes are sent.
  - Another revision already leads: the staged file is deleted, because this
    first revision can never land.
  - Item never admitted (command refused or never sent) or since removed: the
    staged file is dropped, unless its operation is still pending.
  - Any failure: the file stays staged for the next attempt.
- Passes are serialised, so a reconnect pass and the coordinator's pass never
  send the same file at once.
- The retry sends the confirmed capture, never a fresh one, so edits made after
  sharing do not leak into revision 1.

**Witness.** `SharedAreaArtifactChecks.runUploadRecovery`, in
`--collaboration-native-check` under "STAGE collaboration native: shared
artifact upload recovery". It drives the production coordinator and controller
against the scripted authority, which now has the service's idempotency on the
revision ID:

1. One upload is refused before it commits; the other commits but its reply is
   lost. The arrangement is accepted and the owner is told the snapshots will
   upload later. The owner then edits the file.
2. Relaunch (a new controller over the same local cache), with the service
   still refusing. The missing snapshot is tried once. The landed one is not
   sent again: 3 publish calls, 1 revision.
3. Reconnect with the service healthy. The remaining snapshot lands: 4 calls,
   exactly one revision per artifact.
4. Each revision carries the ID reserved at review and the confirmed bytes, not
   the post-share edit.
5. A second relaunch sends nothing.

**RED today.** The witness on 6d2c9d18's production files (witness only):
`FAIL: the owner is told the snapshots upload later instead of being lost`. The
old code had no staging at all.

**Teeth** (each restored after):

| Change | Result |
| --- | --- |
| No pass after `recoverPendingOperations` | RED "timeout: relaunch retries the upload that never landed" |
| No pass on reconnect | RED "timeout: reconnect uploads the remaining snapshot" |
| Skip the service check before sending | RED "relaunch retries the missing snapshot once and never resends the one whose reply was lost" |

## 2. Dark render: the white header

**Finding: not real.** The panel draws no background; it sits on the scene's
panel surface, which `SharedAreaSceneView.applyTokens` themes per appearance.
The old evidence capture painted the panel colour into an image and then drew
the bitmap over it with `NSImageRep.draw(in:)`. That draw copies pixels instead
of blending them, so the panel's transparent header replaced the painted
surface. Measured on the old `artifact-dark.png`: header pixels have alpha 0,
and viewers show transparent as white. Nothing in the app paints white.

**Fix (ffe5481c).** The check now moves the mounted scene into a real borderless
window, ordered in with `orderFrontOffscreenForChecks()`. It sets the window's
appearance, which drives the production appearance-change path rather than a
manual call. It then reads the window back from the window server
(`CGWindowListCreateImage`) and crops to the panel. New assertion per theme:
"window shows the artifact header on that theme's panel surface", from a header
pixel within 0.04 of `SurfaceToken.panel`.

Teeth: pinning the scene surface to the light colour gives RED "dark window
shows the artifact header on that theme's panel surface".

**Looked at.** Both new renders are in `validation/artifacts/`, replacing the
old ones.

- Dark: the header is on #131313, the dark panel surface. Labels, choice
  buttons and the diff body are all dark-themed. No light strip.
- Light: the header is on #F6F6F6, the light panel surface, with a light body.
- One thing visible only in a real window: a horizontal scroller at the bottom
  of the text view. That is real behaviour (the text container is unbounded in
  width), not a capture artefact. Not changed here.

## Gate

`scripts/run-matrix.sh --collaboration`, run once on ffe5481c under
`.worktrees/.locks/app-build.sh`, with isolated `TMUX_TMPDIR` and
`CONTINUUM_APP_SUPPORT` and `CONTINUUM_SKIP_UI_BASELINES=1`. Result:
"Collaboration matrix (targeted): 10 leg(s) run". 9 legs passed, 1 failed, gate
exit 1.

- `--collaboration-native-check` passed, including all 6 upload-recovery
  assertions and both real-window header assertions.
- Note: the ui-probe theme surface-cache witness is skipped with
  display-dependent checks, as in round 2.
- **Failed: `ContinuumRevivedCollaborationServiceChecks`**, at "verification
  refuses a backup with damaged pages"
  (`CollaborationBackupRestoreChecks.swift:188`). This branch changes no service
  code (`git diff 6d2c9d18 HEAD -- Sources/ContinuumRevivedCollaborationService*`
  is empty).
  - Standalone reruns of that binary: fail, pass, pass. It is a flake.
  - Likely cause: the check flips 512 bytes in the middle of the backup file.
    When those bytes land on a page that verification never reads (free or
    unused space), the damaged backup verifies. It needs a deterministic
    corruption of a page verification reads; that belongs to the backup
    checks' owner, not this branch.

## Not done

- The native journey still uses a scripted authority. The real routes are
  witnessed in the service and Core legs; the staged-upload pass itself is
  witnessed only natively.
- A refused share's staged files are dropped on the next connected pass rather
  than immediately. They hold no capability; they are the owner's own bytes, in
  their own app-support directory.
