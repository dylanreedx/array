# Tidy film tools

These record a real-app tidy film from the window server. They made
`tidy-before.mov` at 01:01. They take the screen, so run them only when nobody
is using the Mac.

## Setup

Run `setup.sh`. It rebuilds the Swift helpers into `/tmp/aln/tools`, which
`film.sh` calls by absolute path. These helpers post keys and clicks with
CGEvent, find a window by its pid, list on-screen windows, and frame-diff a
movie.

## Make a film app

Bundle the app under its own id, never the shared dev id. A second app under
`dev.arrayapp.macos.dev` cost an agent shell its `~/Documents` access.

    DEV_APP_PATH="$HOME/array-scratch/apps/Array After.app" \
    DEV_BUNDLE_ID=dev.arrayapp.macos.aln-after DEV_BUNDLE_NAME="Array After" \
    scripts/dev-app.sh --no-launch

## Scene

1. Run `film.sh "<app>" <label>` once. On a fresh scene it boots the app once,
   quits it by PID, lists the workspace document under
   `/tmp/aln/film-<label>-support/workspaces/*/canvas.json`, and exits with 10.
2. In that document:
   - set the zone to 2300×1480 at origin 0,0;
   - set `lastActiveZoneId` to the zone;
   - set `viewport` to x −80, y −90, zoom 0.42.
3. Seed the messy zone:

       python3 -I film_seed.py ~/array-scratch/aln-film-<label> <zoneId> 0 0

4. Turn off onboarding for the film bundle id. Write
   `array.onboarding.progress.v1` as data JSON with
   `explicitlyDismissedIntro` and `explicitlySkippedStarter` true and every
   task skipped:

       defaults write <bundle id> array.onboarding.progress.v1 -data <hex>

5. Run `touch ~/array-scratch/aln-film-<label>/.aln-seeded`.

## Film

    /tmp/aln/tools/film.sh "$HOME/array-scratch/apps/Array After.app" after
    ALN_TRIGGER=key /tmp/aln/tools/film.sh "…" after-key   # ⌥⌘T instead of the zone menu

- The app is launched with `ARRAY_SKIP_USER_GHOSTTY_CONFIG=1` and its own
  `TMUX_TMPDIR`.
- A watchdog aborts the take if a `UserNotificationCenter` window appears.
  Never click a prompt by script.
- The idle guard reads HID idle time, which the script's own synthetic keys
  reset. `ALN_SKIP_IDLE=1` skips the guard for retakes inside one session.

## Measure

    /tmp/aln/tools/framediff <movie>

It prints, per frame, the time, the mean luminance change and the changed
cells. The menu fade, the first tile motion and the settle show up as bursts.
