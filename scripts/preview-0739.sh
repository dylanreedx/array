#!/bin/bash
# The 0.7.39 preview (.plans/112-release-0739/PREVIEW.md): two Array apps on
# this Mac play two people, through a relay that runs on this Mac only.
#
#   scripts/preview-0739.sh build       # build both bundles and the relay (the agent did this)
#   scripts/preview-0739.sh relay       # fresh state, start the local relay
#   scripts/preview-0739.sh launch a --real   # open Array Preview A (the host) on your own claude and codex
#   scripts/preview-0739.sh launch b --real   # open Array Preview B (the guest) the same way
#   scripts/preview-0739.sh launch a          # the same on the check fakes (canned replies, no usage)
#   scripts/preview-0739.sh open-link   # give B the share link on the clipboard
#   scripts/preview-0739.sh stop        # quit both, stop the relay, leave nothing running
#
# - "Array Preview A" and "Array Preview B" in ~/array-scratch/apps/, each with
#   its own bundle id (own defaults, own TCC identity), app support, project
#   root and tmux namespace under ~/array-scratch/preview-0739/{a,b}. Never one
#   root for both (CLAUDE.md hazard 10), never ~/Documents.
# - The bundle ids carry the multiplayer preview prefix, so opening either app
#   from Finder is refused instead of falling onto the shared "Array Dev" store.
# - With --real, agents run your own claude and codex with their own logins
#   (Array stores no credential); every turn is a real one. Without it they
#   run the check fakes: no model, no login, no usage, and a plain prompt to
#   the Claude fake draws no reply (only TOOL prompts show a step).
# - Agent characters are switched on in both apps' defaults.
# - Terminals keep tmux persistence, each app with its own tmux server in
#   ~/array-scratch/preview-0739/{a,b}/tmux (TMUX and TMUX_PANE unset), never
#   the default socket. The script starts that server itself with no config
#   (-f /dev/null) before the app: a brand-new server reading a ~/.tmux.conf
#   that runs tpm can stop answering, and sharing a terminal then waits on it.
#
# Never touches /Applications/Array.app, ~/Desktop/Array Dev.app, ~/Documents,
# the default tmux socket, a real CLI login or the Keychain.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir)/../.worktrees/.locks/app-build.sh"
STATE="$HOME/array-scratch/preview-0739"
APPS="$HOME/array-scratch/apps"
APP_A="$APPS/Array Preview A.app"
APP_B="$APPS/Array Preview B.app"
ID_A="dev.arrayapp.macos.mp-preview-a"
ID_B="dev.arrayapp.macos.mp-preview-b"
RELAY_BIN="$APPS/array-preview-0739-relay"

app_pids() { pgrep -f "$1/Contents/MacOS/Array" 2>/dev/null || true; }
side_app() { [[ "$1" == b ]] && echo "$APP_B" || echo "$APP_A"; }
side_id() { [[ "$1" == b ]] && echo "$ID_B" || echo "$ID_A"; }

stop() {
  for app in "$APP_A" "$APP_B"; do
    for pid in $(app_pids "$app"); do kill -TERM "$pid" 2>/dev/null || true; done
  done
  for _ in $(seq 1 30); do
    [[ -z "$(app_pids "$APP_A")$(app_pids "$APP_B")" ]] && break
    sleep 0.2
  done
  for app in "$APP_A" "$APP_B"; do
    for pid in $(app_pids "$app"); do kill -KILL "$pid" 2>/dev/null || true; done
  done
  if [[ -f "$STATE/relay.env" ]]; then
    # shellcheck disable=SC1091
    source "$STATE/relay.env"
    kill -TERM "$RELAY_PID" 2>/dev/null || true
    for _ in $(seq 1 25); do kill -0 "$RELAY_PID" 2>/dev/null || break; sleep 0.2; done
    kill -KILL "$RELAY_PID" 2>/dev/null || true
    [[ "$RELAY_DATA" == /tmp/array-preview-0739-relay.* ]] && rm -rf "$RELAY_DATA"
    rm -f "$STATE/relay.env"
  fi
  for side in a b; do
    pkill -f "$STATE/$side/bin/" 2>/dev/null || true
    if [[ -S "$STATE/$side/tmux/tmux-$(id -u)/default" ]] && command -v tmux >/dev/null; then
      env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$STATE/$side/tmux" tmux kill-server >/dev/null 2>&1 || true
    fi
  done
  echo "==> 0.7.39 preview stopped; nothing left running"
}

build() {
  echo "==> building in $ROOT_DIR"
  [[ -e "$ROOT_DIR/ThirdParty/GhosttyKit.xcframework" ]] || "$ROOT_DIR/scripts/prepare-ghosttykit.sh"
  cd "$ROOT_DIR"
  mkdir -p "$APPS"
  env -u SDKROOT "$LOCK" swift build --product continuum-relay
  env -u SDKROOT "$LOCK" scripts/make-app-bundle.sh --configuration debug --bundle-id "$ID_A" --name "Array Preview A" --output "$APP_A"
  env -u SDKROOT "$LOCK" scripts/make-app-bundle.sh --configuration debug --bundle-id "$ID_B" --name "Array Preview B" --output "$APP_B"
  cp "$(swift build --show-bin-path)/continuum-relay" "$RELAY_BIN"
  echo "==> built $APP_A, $APP_B and $RELAY_BIN"
}

fresh_state() {
  rm -rf "$STATE/a" "$STATE/b"
  for side in a b; do mkdir -p "$STATE/$side/project" "$STATE/$side/support" "$STATE/$side/tmux"; done
  chmod 700 "$STATE/a" "$STATE/b"
  # A's project is a small git repo with one uncommitted change, so a file
  # tile and a diff tile have something to share.
  (
    cd "$STATE/a/project"
    git init -q
    printf '.array/\n' > .gitignore
    printf 'export function greet(name) {\n  return "Hello, " + name;\n}\n' > greet.js
    printf '# Checkout\n\nA scratch project for the 0.7.39 preview.\n' > README.md
    git add -A && git commit -q -m "chore(preview): seed the scratch project"
    printf 'export function greet(name) {\n  return `Hello, ${name}!`;\n}\n\nexport function bye(name) {\n  return `Bye, ${name}.`;\n}\n' > greet.js
  )
  for id in "$ID_A" "$ID_B"; do
    defaults delete "$id" >/dev/null 2>&1 || true
    defaults write "$id" agentCharacters.enabled -bool YES
    # Terminals keep tmux persistence, in this app's own TMUX_TMPDIR.
    defaults write "$id" continuum.terminal.tmux.enabled -bool YES
  done
}

start_relay() {
  [[ -x "$RELAY_BIN" ]] || { echo "no relay binary at $RELAY_BIN; run $0 build" >&2; exit 1; }
  RELAY_DATA="$(mktemp -d /tmp/array-preview-0739-relay.XXXXXX)"
  python3 -I - "$RELAY_BIN" "$RELAY_DATA" "$STATE/relay.env" <<'PY'
import base64, os, socket, subprocess, sys, time
relay, data, record = sys.argv[1:4]
def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0)); return s.getsockname()[1]
env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")
       and not k.startswith(("APNS_", "RELAY_")) and k.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
port = free_port()
env.update(RELAY_HOST="127.0.0.1", PORT=str(port), RELAY_ADMIN_PORT=str(free_port()),
    RELAY_DATABASE_PATH=f"{data}/relay.sqlite", RELAY_MASTER_KEY=base64.b64encode(os.urandom(32)).decode(),
    RELAY_COLLABORATION_DATABASE_PATH=f"{data}/collaboration.sqlite",
    RELAY_COLLABORATION_MASTER_KEY=base64.b64encode(os.urandom(32)).decode())
log = open(f"{data}/relay.log", "w")
process = subprocess.Popen([relay], env=env, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)
deadline = time.monotonic() + 15
while True:
    if process.poll() is not None: sys.exit("relay exited before it was ready; see " + data + "/relay.log")
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.2): break
    except OSError:
        if time.monotonic() > deadline: sys.exit("relay did not open its port")
        time.sleep(0.1)
with open(record, "w") as f:
    f.write(f"RELAY_PID={process.pid}\nRELAY_DATA={data}\nRELAY_PORT={port}\n")
PY
  # shellcheck disable=SC1091
  source "$STATE/relay.env"
  write_config a A host left
  write_config b B guest right
  echo "==> relay on http://127.0.0.1:$RELAY_PORT (data in $RELAY_DATA); fresh state in $STATE"
}

write_config() { # side label role screen-side
  python3 -I - "$STATE/$1/preview.json" "$2" "$3" "http://127.0.0.1:$RELAY_PORT" "$STATE/$1" "$4" <<'PY'
import json, sys
path, label, role, endpoint, root, side = sys.argv[1:7]
json.dump({"label": label, "role": role, "endpoint": endpoint, "enrollmentCode": "", "root": root,
           "exchange": root, "areaLabel": "", "side": side}, open(path, "w"))
PY
}

start_tmux() { # side: this app's own tmux server, with no user config
  local dir="$STATE/$1/tmux" sockfile sock
  # Only ever these two folders: an empty or relative TMUX_TMPDIR would send
  # tmux to the default socket, which runs your own terminals.
  [[ "$dir" == "$HOME/array-scratch/preview-0739/a/tmux" || "$dir" == "$HOME/array-scratch/preview-0739/b/tmux" ]] \
    || { echo "refusing tmux namespace $dir" >&2; exit 1; }
  mkdir -p "$dir"
  sockfile="$dir/tmux-$(id -u)/default"
  if [[ ! -S "$sockfile" ]] || ! env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$dir" tmux display-message -p '#{socket_path}' >/dev/null 2>&1; then
    rm -f "$sockfile"
    env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$dir" tmux -f /dev/null new-session -d -s preview-hold
  fi
  sock="$(env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$dir" tmux display-message -p '#{socket_path}')"
  [[ "$(cd "$(dirname "$sock")/.." && pwd -P)" == "$(cd "$dir" && pwd -P)" ]] \
    || { echo "tmux socket $sock is outside $dir; not launching" >&2; exit 1; }
}

launch() { # side [--real]
  local side="$1" real="${2:-}" app
  local mode=(--env "CONTINUUM_MULTIPLAYER_PREVIEW_REAL_CLIS=0")
  [[ "$real" == --real ]] && mode=(--env "CONTINUUM_MULTIPLAYER_PREVIEW_REAL_CLIS=1")
  app="$(side_app "$side")"
  [[ -f "$STATE/relay.env" ]] || { echo "the relay is not running; run $0 relay first" >&2; exit 1; }
  [[ -z "$(app_pids "$app")" ]] || { echo "$(basename "$app" .app) is already running" >&2; exit 1; }
  # Characters on, every launch: the setting lives in this bundle's own defaults.
  defaults write "$(side_id "$side")" agentCharacters.enabled -bool YES
  # shellcheck disable=SC1091
  source "$STATE/relay.env"
  rm -f "$STATE/$side/ready.json"
  start_tmux "$side"
  env -u TMUX -u TMUX_PANE open -n \
    --env "CONTINUUM_PROJECT_ROOT=$STATE/$side/project" \
    --env "CONTINUUM_APP_SUPPORT=$STATE/$side/support" \
    --env "CONTINUUM_MULTIPLAYER_PREVIEW=$STATE/$side/preview.json" \
    --env "CONTINUUM_COLLABORATION_ENDPOINT=http://127.0.0.1:$RELAY_PORT" \
    --env "TMUX_TMPDIR=$STATE/$side/tmux" \
    "${mode[@]}" \
    --stdout "$STATE/$side/app.log" --stderr "$STATE/$side/app.log" \
    "$app" --args -ApplePersistenceIgnoreState YES
  echo "==> opened $(basename "$app" .app) ($([[ "$real" == --real ]] && echo "your own claude and codex" || echo "the check fakes")); its log is $STATE/$side/app.log"
}

case "${1:-}" in
  build) build ;;
  relay) stop >/dev/null; fresh_state; start_relay ;;
  launch)
    side="${2:-}"; [[ "$side" == a || "$side" == b ]] || { echo "usage: $0 launch a|b [--real]" >&2; exit 2; }
    [[ -z "${3:-}" || "${3:-}" == --real ]] || { echo "usage: $0 launch a|b [--real]" >&2; exit 2; }
    launch "$side" "${3:-}" ;;
  open-link)
    link="$(pbpaste)"
    [[ "$link" == https://arrayapp.dev/s/* || "$link" == array*://s/* ]] || { echo "the clipboard holds no share link: $link" >&2; exit 1; }
    [[ -n "$(app_pids "$APP_B")" ]] || { echo "Array Preview B is not running; run $0 launch b first" >&2; exit 1; }
    open -a "$APP_B" "$link"
    echo "==> gave Array Preview B the link" ;;
  stop) stop ;;
  *) echo "usage: $0 build | relay | launch a|b [--real] | open-link | stop" >&2; exit 2 ;;
esac
