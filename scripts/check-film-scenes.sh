#!/usr/bin/env bash
set -euo pipefail

# Every film scene must still run on this checkout's app (.plans/73-film-studio).
#
# The film recorder drives the real app through its views, rects and production
# seams. A UI change that breaks a scene (a renamed view, a moved rect source, a
# changed spawn path) must fail the matrix the day it lands, not the day someone
# tries to film. So this leg builds the FILM build (-DARRAY_FILM, its own scratch
# path .build-film, exactly what scripts/film-capture.sh builds) and runs
# `--film-scene-check`, which stages and runs every scene in film/scenes/<video>/
# off-display with no capture, each in its own isolated child.
#
# The normal build never contains the recorder (scripts/check-film-absent.sh);
# this leg is the only place the matrix compiles it.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

start=$SECONDS
swift build --product Array --scratch-path .build-film -Xswiftc -DARRAY_FILM
built=$SECONDS

iso=$(mktemp -d /tmp/array-film-scenes.XXXXXX)
trap 'rm -rf "$iso"' EXIT
mkdir -p "$iso/support" "$iso/root" "$iso/tmux"
# This leg creates its own namespace instead of inheriting the matrix's.
# Verify tmux honored it before any staged terminal can start.
if command -v tmux >/dev/null 2>&1; then
  film_socket=$(env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$iso/tmux" tmux start-server \; display-message -p '#{socket_path}')
  film_root=$(cd "$iso/tmux" && pwd -P)
  film_socket_dir=$(cd "$(dirname "$film_socket")" && pwd -P)
  case "$film_socket_dir/" in
    "$film_root"/*) ;;
    *) printf 'Refusing Film check: tmux socket is outside its disposable namespace.\n' >&2; exit 1 ;;
  esac
fi
status=0
env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$iso/tmux" CONTINUUM_APP_SUPPORT="$iso/support" \
  CONTINUUM_PROJECT_ROOT="$iso/root" .build-film/debug/Array --film-scene-check || status=$?
printf 'check-film-scenes: film build %ds, scene check %ds\n' "$((built - start))" "$((SECONDS - built))"
exit "$status"
