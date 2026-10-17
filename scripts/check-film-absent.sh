#!/usr/bin/env bash
set -euo pipefail

# The film recorder must be absent from every normal build (.plans/73-film-studio,
# decision 1: the shipped app never contains it).
#
# The recorder (Sources/ContinuumRevived/App/Film/) and every hook it has in the
# app are compiled only with -DARRAY_FILM, which only scripts/film-capture.sh
# passes (through make-app-bundle.sh --film, scratch path .build-film). This leg
# reads the binary a normal `swift build` produced and asserts the outcome:
#
#   1. no Swift symbol names a Film type or a film hook (FilmDirector, FilmScene,
#      filmNavigationCamera, ...), with a positive control that the symbol table
#      is readable at all;
#   2. none of the recorder's own strings (its env names, its output schema, its
#      source paths);
#   3. `--film` is refused as an unknown flag, and `--film-scene-check` is refused
#      by the unknown-check guard, both before anything boots.
#
# Probe 3 can never boot the app: a sentinel check flag rides along, so a binary
# that does not refuse `--film` still stops at the unknown-check guard (and is
# reported as such) instead of falling through to a full launch. It runs only
# when 1 and 2 found no recorder, so a film binary is never launched either.
#
# usage: scripts/check-film-absent.sh [binary]   (default .build/debug/Array)

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
BINARY="${1:-.build/debug/Array}"
[[ -x "$BINARY" ]] || { printf 'FAIL: no binary at %s (run swift build first)\n' "$BINARY" >&2; exit 1; }

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# 1. Symbols. Captured first, then searched (hazard 4: no grep -q on a pipe).
symbols=$(nm "$BINARY" 2>/dev/null || true)
if ! grep -F '12CanvasNSViewC' <<<"$symbols" >/dev/null; then
  fail "positive control: no CanvasNSView symbol in $BINARY, so a symbol search proves nothing (stripped?)"
fi
# A Swift mangled identifier is length-prefixed ("12FilmDirectorC"): read exactly
# that many characters, so the report names the type or member itself.
film_symbols=$(perl -ne 'while (/(\d+)((?:Film|film)[A-Z]\w*)/g) { print substr($2, 0, $1), "\n" if length($2) >= $1 }' <<<"$symbols" | sort -u || true)
if [[ -n "$film_symbols" ]]; then
  fail "the binary carries film code: $(head -8 <<<"$film_symbols" | tr '\n' ' ')($(wc -l <<<"$film_symbols" | tr -d ' ') names)"
fi

# 2. Strings only the recorder carries.
strings_found=$(strings -a "$BINARY" | grep -E 'ARRAY_FILM_(GHOSTTY_CONFIG|CHECK_ROOT|SCENE|TAKES)|array\.film\.(frames|run|scene)|/App/Film/' | sort -u || true)
if [[ -n "$strings_found" ]]; then
  fail "the binary carries film strings: $(head -4 <<<"$strings_found" | tr '\n' ' ')"
fi

# 3. Refusals, only when 1 and 2 found nothing (never launch a recorder).
probe() {
  # probe <out-file> <args...>: run the binary isolated, kill it after 30 s.
  local out="$1"; shift
  local iso status=0 pid waited=0
  iso=$(mktemp -d /tmp/array-film-absent.XXXXXX)
  mkdir -p "$iso/support" "$iso/root" "$iso/tmux"
  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$iso/tmux" CONTINUUM_APP_SUPPORT="$iso/support" \
    CONTINUUM_PROJECT_ROOT="$iso/root" "$BINARY" "$@" >"$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= 300 )); then
      kill -9 "$pid" 2>/dev/null || true
      printf '\n[probe killed after 30 s: the binary did not exit]\n' >>"$out"
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null || status=$?
  rm -rf "$iso"
  return "$status"
}

if (( failures == 0 )); then
  out=$(mktemp /tmp/array-film-absent-out.XXXXXX)
  status=0
  probe "$out" --film /nonexistent/scene.json --film-out /nonexistent/out --film-absent-sentinel-check || status=$?
  if [[ "$status" != 2 ]] || ! grep -F 'unknown flag --film: this build has no film recorder' "$out" >/dev/null; then
    fail "--film was not refused as an unknown flag (exit $status): $(tr '\n' ' ' <"$out" | cut -c1-240)"
  fi
  status=0
  probe "$out" --film-scene-check || status=$?
  if [[ "$status" != 1 ]] || ! grep -F 'unknown check flag(s): --film-scene-check' "$out" >/dev/null; then
    fail "--film-scene-check was not refused as an unknown check flag (exit $status): $(tr '\n' ' ' <"$out" | cut -c1-240)"
  fi
  rm -f "$out"
fi

if (( failures > 0 )); then
  printf 'check-film-absent: %d failure(s) in %s\n' "$failures" "$BINARY" >&2
  exit 1
fi
printf 'check-film-absent passed: %s has no Film symbols or strings, refuses --film and --film-scene-check\n' "$BINARY"
