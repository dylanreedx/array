#!/usr/bin/env bash
set -euo pipefail
# Film one scene of the REAL app: the app stages the scene, directs it on a fixed
# 60 fps clock and captures its own window frame by frame (.plans/68-launch-film,
# research/07-real-footage.md; .plans/73-film-studio).
#
# The recorder is compiled only into the film build: this script builds THIS
# checkout with -DARRAY_FILM in its own scratch path (.build-film), so any worktree
# or branch films its own code and a normal build never contains the recorder
# (witness: scripts/check-film-absent.sh).
#
# usage: scripts/film-capture.sh film/scenes/<video>/<scene>.json [options]
#   --no-build        reuse the film bundle (refused unless THIS checkout built it)
#   --proto           fast iteration: 1x, 30 fps, JPEG frames, no movie
#   --frames A-B      proto only: capture scene frames A..B of each take, then stop
#   --takes a,b       capture only these takes (the others still run, uncaptured)
#
# Output, the same shape every time and never dated in a name:
#   ~/array-scratch/film/takes/<video>/<take>/   frames/, frames.json, <take>.mov,
#                                                capture.log, take.json (the date,
#                                                the source commit, the mode, timing)
#   <take> is the scene's take name, prefixed by the scene file's name when that is
#   not the video's own name ("which-tab-bare.json" + "01-pullback" = "bare-01-pullback"),
#   and suffixed "-proto" for a proto capture. Capturing a take again replaces it and
#   keeps the previous one as <take>.prev. A take that fails is not installed; it
#   stays in the run's work folder, ~/array-scratch/film/work/<video>/<scene>/.
#
# Not a matrix leg: it needs a WindowServer and an unlocked session. It does NOT
# need Screen Recording (the app captures only its own window) and it does not take
# the screen: the window is parked off-display and the app is never activated.
# One film at a time per machine (one film bundle, one port 3000).
#
# Safety, enforced here and again in the app:
#   * its own bundle id, dev.arrayapp.macos.film, at ~/array-scratch/apps; never
#     dev.arrayapp.macos.dev (a second bundle on that id broke TCC folder grants);
#   * every root under ~/array-scratch/film (outside ~/Documents: no folder-grant
#     modal; never Dylan's workspace root);
#   * tmux off and TMUX_TMPDIR inside the run; Ghostty reads the run's own config;
#   * only processes running from the film bundle are ever killed.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { sed -n '12,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

SCENE_ARG="" BUILD=1 PROTO=0 FRAMES="" TAKES="${FILM_TAKES:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) BUILD=0; shift ;;
    --proto) PROTO=1; shift ;;
    --frames) [[ $# -ge 2 ]] || usage; FRAMES="$2"; shift 2 ;;
    --takes) [[ $# -ge 2 ]] || usage; TAKES="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "unknown option $1" >&2; usage ;;
    *) [[ -z "$SCENE_ARG" ]] || usage; SCENE_ARG="$1"; shift ;;
  esac
done
[[ -n "$SCENE_ARG" ]] || usage
if [[ -n "$FRAMES" ]]; then
  [[ $PROTO == 1 ]] || { echo "--frames is a proto option: add --proto" >&2; exit 2; }
  [[ "$FRAMES" =~ ^[0-9]+-[0-9]+$ ]] || { echo "--frames wants A-B, got $FRAMES" >&2; exit 2; }
fi

SCENE_SRC="$(cd "$(dirname "$SCENE_ARG")" && pwd)/$(basename "$SCENE_ARG")"
[[ -f "$SCENE_SRC" ]] || { echo "no scene at $SCENE_SRC" >&2; exit 2; }
VIDEO="$(basename "$(dirname "$SCENE_SRC")")"
SCENES_SRC="$(dirname "$(dirname "$SCENE_SRC")")"
[[ "$(basename "$SCENES_SRC")" == scenes ]] || { echo "a scene lives at film/scenes/<video>/<scene>.json" >&2; exit 2; }
STEM="$(basename "$SCENE_SRC" .json)"
TAKE_PREFIX=""
if [[ "$STEM" != "$VIDEO" ]]; then TAKE_PREFIX="${STEM#"$VIDEO"-}-"; fi
TAKE_SUFFIX=""
[[ $PROTO == 1 ]] && TAKE_SUFFIX="-proto"

FILM_ROOT="$HOME/array-scratch/film"
APP_PATH="$HOME/array-scratch/apps/Array Film.app"
APP_SOURCE="$APP_PATH.source"   # which checkout and commit built the bundle
BUNDLE_ID="dev.arrayapp.macos.film"
WORK="$FILM_ROOT/work/$VIDEO/$STEM"
TAKES_DIR="$FILM_ROOT/takes/$VIDEO"
OUT="$WORK/out"
TIMEOUT="${FILM_TIMEOUT:-2400}"
case "$WORK" in */Documents/*) echo "refusing a Documents root" >&2; exit 2 ;; esac
case "$WORK" in "$HOME"/array-scratch/film/work/*) rm -rf "$WORK" ;; *) echo "refusing to clear $WORK" >&2; exit 2 ;; esac

SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
SOURCE_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
# The working tree's own changes count as source too: hash them into the stamp.
SOURCE_DIRTY="$({ git -C "$REPO_ROOT" diff HEAD -- Sources Package.swift; git -C "$REPO_ROOT" ls-files --others --exclude-standard -z -- Sources | xargs -0 cat 2>/dev/null; } | shasum | cut -c1-12)"
SOURCE_STAMP="$REPO_ROOT $SOURCE_COMMIT $SOURCE_DIRTY"

FIRST_PROJECT="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["projects"][0]["name"])' "$SCENE_SRC")"
# The workspace sidebar follows the scene's "sidebar" key (hidden when absent), at its
# "sidebarWidth" (default 300, clamped to the app's 220...420), through the production
# preferences in the launch's argument domain. Auto-layout follows "autoLayout".
read -r SIDEBAR_VISIBLE SIDEBAR_WIDTH AUTO_LAYOUT < <(/usr/bin/python3 -c '
import json, sys
scene = json.load(open(sys.argv[1]))
width = min(max(float(scene.get("sidebarWidth", 300)), 220), 420)
print("YES" if scene.get("sidebar") is True else "NO", int(width) if width == int(width) else width,
      "YES" if scene.get("autoLayout") is True else "NO")
' "$SCENE_SRC")
mkdir -p "$WORK"/{app-support,tmux,bin,out,tap} "$WORK/xdg/ghostty"
# Project roots live at a short fixed path, because the app shows them (the project
# picker, folder chips): ~/array-scratch/film/code/<name>, emptied at the start of every
# run. $WORK/projects links to it so a run's folder still holds everything.
PROJECTS="$FILM_ROOT/code"
case "$PROJECTS" in "$HOME"/array-scratch/film/*) rm -rf "$PROJECTS" ;; *) echo "refusing to clear $PROJECTS" >&2; exit 2 ;; esac
mkdir -p "$PROJECTS"
ln -s "$PROJECTS" "$WORK/projects"

# The app reads the scene and its assets from a copy inside the run. A bench under
# ~/Documents is TCC-protected, and every rebuild re-signs the bundle ad hoc, so
# reading it in place blocks the app's first open() on a consent prompt. Scenes share
# assets across videos (../full-day/projects), so the whole scenes tree comes along.
cp -R "$SCENES_SRC" "$WORK/scenes"
SCENE="$WORK/scenes/$VIDEO/$STEM.json"

# The terminal tap: whatever the director writes into the tile's FIFO is printed
# through the pty and rendered by Ghostty for real.
cat > "$WORK/bin/film-tap" <<'EOF'
#!/bin/sh
# Film terminal tap: the director types this tile's key, then writes its output into
# $FILM_TAP_DIR/<key>.fifo; cat hands the raw bytes (ANSI included) to Ghostty.
stty -echo
IFS= read -r key
fifo="$FILM_TAP_DIR/$key.fifo"
rm -f "$fifo"; mkfifo "$fifo"
printf 'FILM-TAP-READY'
while :; do cat "$fifo"; done
EOF
chmod +x "$WORK/bin/film-tap"
cat > "$WORK/ghostty.conf" <<'EOF'
font-family = SF Mono
font-size = 13
cursor-style = block
cursor-style-blink = false
background-opacity = 1
window-padding-x = 8
window-padding-y = 6
shell-integration = none
EOF

film_pids() {
  # The executable path must START the command, or this awk would match itself.
  ps -axo pid=,command= | awk -v p="$APP_PATH/Contents/MacOS/" '{ pid = $1; sub(/^ *[0-9]+ +/, ""); if (index($0, p) == 1) print pid }'
}
stop_film_app() {
  local pids
  pids="$(film_pids)"
  [[ -n "$pids" ]] || return 0
  kill $pids 2>/dev/null || true
  for _ in $(seq 1 20); do [[ -z "$(film_pids)" ]] && return 0; sleep 0.25; done
  kill -9 $(film_pids) 2>/dev/null || true
}

SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

if [[ $BUILD == 1 ]]; then
  [[ -e "$REPO_ROOT/ThirdParty/GhosttyKit.xcframework" ]] \
    || { echo "no GhosttyKit in this checkout: run scripts/prepare-ghosttykit.sh first" >&2; exit 1; }
  stop_film_app
  mkdir -p "$(dirname "$APP_PATH")"
  BUILD_START=$SECONDS
  "$REPO_ROOT/scripts/make-app-bundle.sh" --configuration debug --film --output "$APP_PATH" >"$WORK/bundle.log" 2>&1 \
    || { tail -30 "$WORK/bundle.log" >&2; exit 1; }
  printf '%s\n' "$SOURCE_STAMP" >"$APP_SOURCE"
  echo "built the film bundle from $REPO_ROOT ($SOURCE_BRANCH) in $((SECONDS - BUILD_START))s"
elif [[ "$(cat "$APP_SOURCE" 2>/dev/null)" != "$SOURCE_STAMP" ]]; then
  echo "refusing --no-build: the film bundle was built from '$(cat "$APP_SOURCE" 2>/dev/null)', not from this checkout's code ($SOURCE_STAMP)" >&2
  exit 2
fi
ACTUAL_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
[[ "$ACTUAL_ID" == "$BUNDLE_ID" ]] || { echo "refusing: $APP_PATH is $ACTUAL_ID, not $BUNDLE_ID" >&2; exit 2; }
[[ -z "$(film_pids)" ]] || stop_film_app
# Every take starts from the same preferences: the film bundle's own defaults domain
# (dev.arrayapp.macos.film, used by nothing else) is emptied before each launch. A run
# writes into it (onboarding progress, the palette's recent rows), and the next run
# used to start from those leftovers, which showed the Getting Started checklist over
# full-day's zone header and reordered ⌘K.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true

# The scene's static site, if it has one, on localhost:3000 (what its browser tiles load):
# the scene's "site" key (relative to the scene file), else site/ beside it; or
# {"project": key, "path": sub} = that staged project's folder in THIS run, so a `write`
# into it is what the page serves (the app stages it at launch, after the server starts).
SITE_SPEC="$(/usr/bin/python3 -c '
import json, sys
scene = json.load(open(sys.argv[1]))
site = scene.get("site", "")
if isinstance(site, dict):
    name = next(p["name"] for p in scene["projects"] if p["key"] == site["project"])
    print("project\t" + name + "/" + site.get("path", "."))
else:
    print("path\t" + site)
' "$SCENE")"
SITE_KIND="${SITE_SPEC%%$'\t'*}"
SITE_REL="${SITE_SPEC#*$'\t'}"
if [[ "$SITE_KIND" == project ]]; then
  SITE="$PROJECTS/$SITE_REL"
else
  SITE="$(dirname "$SCENE")/${SITE_REL:-site}"
fi
if [[ "$SITE_KIND" == project || -d "$SITE" ]]; then
  if lsof -nP -iTCP:3000 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port 3000 is busy; the scene's browser tiles load http://localhost:3000/" >&2; exit 2
  fi
  # Like a dev server, every response says no-cache, so a reload after a `write`
  # revalidates the stylesheet instead of reusing WebKit's heuristic-fresh copy.
  /usr/bin/python3 -c '
import functools, http.server, sys
class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()
http.server.ThreadingHTTPServer(("127.0.0.1", 3000), functools.partial(Handler, directory=sys.argv[1])).serve_forever()
' "$SITE" >"$WORK/site.log" 2>&1 &
  SERVER_PID=$!
fi

CAPTURE_START=$SECONDS
open -g -n "$APP_PATH" \
  --stdout "$WORK/stdout.txt" --stderr "$WORK/stderr.txt" \
  --env "CONTINUUM_PROJECT_ROOT=$PROJECTS/$FIRST_PROJECT" \
  --env "CONTINUUM_APP_SUPPORT=$WORK/app-support" \
  --env "SHELL=$WORK/bin/film-tap" \
  --env "FILM_TAP_DIR=$WORK/tap" \
  --env "TMUX_TMPDIR=$WORK/tmux" \
  ${FILM_INPUT_DEBUG:+--env "FILM_INPUT_DEBUG=1"} \
  --env "XDG_CONFIG_HOME=$WORK/xdg" \
  --env "ARRAY_FILM_GHOSTTY_CONFIG=$WORK/ghostty.conf" \
  --env "ARRAY_TILE_SURFACE_RESIDENCY=0" \
  ${TAKES:+--env "ARRAY_FILM_TAKES=$TAKES"} \
  --env "ARRAY_FILM_PROTO=$PROTO" \
  ${FRAMES:+--env "ARRAY_FILM_FRAMES=$FRAMES"} \
  --args --film "$SCENE" --film-out "$OUT" \
  -AppleShowScrollBars WhenScrolling \
  -continuum.deleteConfirmPolicy never \
  -continuum.terminal.tmux.enabled NO \
  -continuum.onboarding.shown YES \
  -continuum.agentSounds.enabled NO \
  -continuum.workspaceSidebar.visible "$SIDEBAR_VISIBLE" \
  -continuum.workspaceSidebar.width "$SIDEBAR_WIDTH" \
  -continuum.canvas.shortcutRail.visible NO \
  -continuum.canvas.autoLayout.enabled "$AUTO_LAYOUT" \
  -continuum.agents.backend "Claude Code" \
  -continuum.topology.migrationNoteShown YES

echo "filming $VIDEO/$STEM$([[ $PROTO == 1 ]] && echo " (proto${FRAMES:+, frames $FRAMES})") -> $OUT (log: $OUT/log.txt)"
for _ in $(seq 1 "$TIMEOUT"); do
  [[ -f "$OUT/run.json" ]] && break
  if [[ -z "$(film_pids)" ]]; then sleep 1; [[ -f "$OUT/run.json" ]] && break; echo "the film app exited without run.json" >&2; break; fi
  sleep 1
done
CAPTURE_SECONDS=$((SECONDS - CAPTURE_START))
if [[ ! -f "$OUT/run.json" ]]; then
  stop_film_app
  echo "no run.json after ${CAPTURE_SECONDS}s; see $OUT/log.txt" >&2
  exit 1
fi
for _ in $(seq 1 20); do [[ -z "$(film_pids)" ]] && break; sleep 0.5; done

# Install every take that passed: takes/<video>/<take>/, the previous one kept as .prev.
mkdir -p "$TAKES_DIR"
/usr/bin/python3 - "$OUT/run.json" "$TAKES_DIR" "$TAKE_PREFIX" "$TAKE_SUFFIX" "$WORK" "$CAPTURE_SECONDS" \
  "$VIDEO" "${SCENE_SRC#"$REPO_ROOT"/}" "$PROTO" "$FRAMES" "$REPO_ROOT" "$SOURCE_BRANCH" "$SOURCE_COMMIT" "$SOURCE_DIRTY" <<'EOF'
import datetime, json, os, shutil, sys
(run_json, takes_dir, prefix, suffix, work, seconds, video, scene_file, proto, frames,
 root, branch, commit, dirty) = sys.argv[1:]
run = json.load(open(run_json))
print("verdict:", run.get("verdict"), run.get("error", ""))
log = os.path.join(work, "out", "log.txt")
for take in run.get("takes", []):
    name = prefix + take["take"] + suffix
    dest = os.path.join(takes_dir, name)
    if take["verdict"] != "PASS":
        print(f"  {name}: {take['frames']} frames {take['verdict']}, NOT installed: {take['dir']}")
        continue
    if os.path.exists(dest):
        shutil.rmtree(dest + ".prev", ignore_errors=True)
        os.rename(dest, dest + ".prev")
    shutil.move(take["dir"], dest)
    with open(os.path.join(dest, "capture.log"), "w") as out:
        for part in (log, os.path.join(work, "stderr.txt")):
            if os.path.exists(part):
                out.write(f"=== {os.path.basename(part)}\n" + open(part).read())
    meta = json.load(open(os.path.join(dest, "frames.json")))
    json.dump({
        "schema": "array.film.take.v1", "video": video, "take": name, "sceneTake": take["take"],
        "scene": run.get("scene"), "sceneFile": scene_file,
        "capturedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "mode": "proto" if proto == "1" else "full", "frameRange": frames or None,
        "frames": take["frames"], "fps": meta.get("fps"), "pixelSize": meta.get("pixelSize"),
        "runSeconds": int(seconds),
        "source": {"root": root, "branch": branch, "commit": commit, "uncommittedHash": dirty},
        "bundleId": run.get("bundleId"),
    }, open(os.path.join(dest, "take.json"), "w"), indent=2)
    print(f"  {name}: {take['frames']} frames PASS -> {dest}")
EOF
echo "run: $WORK (${CAPTURE_SECONDS}s from launch to run.json)"
[[ "$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "$OUT/run.json")" == "PASS" ]]
