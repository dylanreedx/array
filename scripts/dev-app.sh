#!/bin/bash
# Rebuild and relaunch the dev app. ~15s, not ~6min.
#
# WHY DEBUG. The release configuration builds with whole-module optimization,
# which is what makes a bundle take minutes: every edit recompiles the world.
# Debug is incremental — touching one file rebuilds that file. Release mode is
# for shipping (scripts/release-app.sh); it buys nothing for looking at a change.
#
# BUT NEVER JUDGE PERFORMANCE ON A DEBUG BUILD. Unoptimized Swift through this
# much view code is several times slower than release, so a debug preview app can
# feel unusable while the same code ships fine — which happened on 2026-08-18,
# costing a session's worth of hunting a phantom regression. `--release` exists
# for exactly that: behaviour on debug, feel on release.
#
# The bundle is DEV channel (`dev.arrayapp.macos.dev`, "Array Dev" store,
# updater inert) because that is make-app-bundle.sh's default. It cannot touch
# the prod app's state. It CAN touch a project's own state — `<project>/.array/`
# is per-project-root, not per-channel — so keep the dev app on a project the
# prod app never opens.
#
# THE PROJECT IS PINNED, and that is the point. `CONTINUUM_PROJECT_ROOT` is the
# first rung of `ProjectRootResolver.resolve()`, ahead of the registry's
# last-active project — so the preview app opens the scratch root and cannot
# wander into a real one even if its registry still remembers it. Wiping the dev
# store is NOT enough on its own: the app re-adopts the last root it knows.
#
# Why that matters: a project's canvas, tiles, notes and managed sessions live in
# `<root>/.array/`, which is NOT channel-split. Two apps on one root share those
# files and the last writer wins.
#
# Usage:
#   scripts/dev-app.sh              # rebuild + relaunch on the scratch project
#   scripts/dev-app.sh --no-launch  # rebuild only
#   scripts/dev-app.sh --release    # ~6 min, for judging FEEL rather than behaviour
#   scripts/dev-app.sh --env KEY=VALUE   # extra env for the launch, repeatable
#   DEV_PROJECT_ROOT=/path scripts/dev-app.sh
#   DEV_APP_PATH=... scripts/dev-app.sh
#
# `--env` exists because a default-off feature flag is only dogfoodable if it can
# reach the launch, and `open` starts a detached process that inherits nothing
# from this shell:
#   scripts/dev-app.sh --env ARRAY_TILE_SURFACE_RESIDENCY=1
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${DEV_APP_PATH:-$HOME/Desktop/Array Dev.app}"
PROJECT_ROOT="${DEV_PROJECT_ROOT:-$HOME/array-scratch}"
LAUNCH=1
CONFIGURATION=debug
EXTRA_ENV=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-launch) LAUNCH=0; shift ;;
    --release) CONFIGURATION=release; shift ;;
    --debug) CONFIGURATION=debug; shift ;;
    --env) EXTRA_ENV+=("${2:?--env needs KEY=VALUE}"); shift 2 ;;
    --env=*) EXTRA_ENV+=("${1#--env=}"); shift ;;
    # Unknown arguments were ignored before this parser existed, and
    # `sidebar-96-preview.sh` forwards its own "$@" here. Warn, do not fail.
    *) echo "dev-app.sh: ignoring unknown argument: $1" >&2; shift ;;
  esac
done

started=$(date +%s)

# Quit first: swapping the bundle under a running instance leaves it running the
# old binary from an inode that no longer has a path, which looks exactly like
# "my change did nothing".
if pgrep -f "$APP_PATH/Contents/MacOS/Array" >/dev/null 2>&1; then
  echo "==> quitting the running dev app"
  pkill -f "$APP_PATH/Contents/MacOS/Array" || true
  # Give it a moment to release its project lock (.array/lock is an exclusive
  # flock; relaunching into a held lock fails to open the project).
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$APP_PATH/Contents/MacOS/Array" >/dev/null 2>&1 || break
    sleep 0.3
  done
fi

if [[ "$CONFIGURATION" == release ]]; then
  echo "==> building (release, whole-module — minutes, not seconds)"
else
  echo "==> building (debug, incremental)"
fi
"$ROOT_DIR/scripts/make-app-bundle.sh" --configuration "$CONFIGURATION" --output "$APP_PATH"

if [[ $LAUNCH -eq 1 ]]; then
  mkdir -p "$PROJECT_ROOT"
  echo "==> launching $APP_PATH on $PROJECT_ROOT"
  # `open --env`, NOT the executable directly. Running
  # `Array.app/Contents/MacOS/Array` from a script makes the app a child of that
  # shell: it dies with the shell, and `nohup`/`disown` is not enough when the
  # caller's whole process group is torn down (which is what happens when an
  # agent runs this). `open` hands the launch to LaunchServices, which detaches
  # it properly, and `--env` still gets the pin through.
  # `${arr[@]+...}` because macOS ships bash 3.2, where an empty array under
  # `set -u` is an unbound variable rather than nothing.
  open_args=(--env "CONTINUUM_PROJECT_ROOT=$PROJECT_ROOT")
  for kv in ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}; do
    echo "==> extra env: $kv"
    open_args+=(--env "$kv")
  done
  open "${open_args[@]}" "$APP_PATH"
fi

echo "==> done in $(( $(date +%s) - started ))s"
