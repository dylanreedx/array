#!/bin/bash
# Try "Share one agent" (.plans/105-collaboration/SHARE-REDESIGN.md, mode A) by
# hand: two Array windows on this Mac play two people, through a relay that
# runs on this Mac only.
#
#   scripts/share-agent-preview.sh              # build, start the relay, launch A and B
#   scripts/share-agent-preview.sh open-link    # give B the link on the clipboard (what clicking it would do)
#   scripts/share-agent-preview.sh relaunch a   # bring A (or b) back after quitting it, state kept
#   scripts/share-agent-preview.sh stop         # quit both, stop the relay, leave nothing running
#
# - "Array Share A" and "Array Share B" in ~/array-scratch/apps/, each with its
#   own dev bundle id, app support, project root and tmux namespace
#   (~/array-scratch/mp-share-preview/{a,b}; never one root for both, CLAUDE.md
#   hazard 10).
# - continuum-relay on a free 127.0.0.1 port, its data in /tmp.
# - First use, as a person meets it: nobody has an account. A has a Claude and
#   a Codex agent on the check fakes (no real model, no usage). A's first Share
#   asks for a name and signs A up; B joins from the link and picks a name.
#
# Never touches /Applications/Array.app, ~/Desktop/Array Dev.app, ~/Documents,
# the default tmux socket, a real CLI login or the Keychain.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir)/../.worktrees/.locks/app-build.sh"
STATE="$HOME/array-scratch/mp-share-preview"
APPS="$HOME/array-scratch/apps"
APP_A="$APPS/Array Share A.app"
APP_B="$APPS/Array Share B.app"
ID_A="dev.arrayapp.macos.mp-share-a"
ID_B="dev.arrayapp.macos.mp-share-b"

app_pids() { pgrep -f "$1/Contents/MacOS/Array" 2>/dev/null || true; }

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
    [[ "$RELAY_DATA" == /tmp/array-share-relay.* ]] && rm -rf "$RELAY_DATA"
    rm -f "$STATE/relay.env"
  fi
  for side in a b; do
    pkill -f "$STATE/$side/bin/" 2>/dev/null || true
    if [[ -d "$STATE/$side/tmux" ]] && command -v tmux >/dev/null; then
      env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$STATE/$side/tmux" tmux kill-server >/dev/null 2>&1 || true
    fi
  done
  echo "==> share preview stopped; nothing left running"
}

launch() { # app side
  # shellcheck disable=SC1091
  source "$STATE/relay.env"
  env -u TMUX -u TMUX_PANE open -n -g \
    --env "CONTINUUM_PROJECT_ROOT=$STATE/$2/project" \
    --env "CONTINUUM_APP_SUPPORT=$STATE/$2/support" \
    --env "CONTINUUM_MULTIPLAYER_PREVIEW=$STATE/$2/preview.json" \
    --env "CONTINUUM_COLLABORATION_ENDPOINT=http://127.0.0.1:$RELAY_PORT" \
    --env "TMUX_TMPDIR=$STATE/$2/tmux" \
    --stdout "$STATE/$2/app.log" --stderr "$STATE/$2/app.log" \
    "$1" --args -ApplePersistenceIgnoreState YES
}
wait_ready() { # sides...
  for _ in $(seq 1 600); do
    local all=1
    for side in "$@"; do [[ -f "$STATE/$side/ready.json" ]] || all=0; done
    [[ $all -eq 1 ]] && return 0
    sleep 0.3
  done
  echo "FAIL: timed out; logs in $STATE/{a,b}/app.log" >&2; exit 1
}

case "${1:-start}" in
  stop) stop; exit ;;
  open-link)
    # Clicking a share link on B's Mac hands it to Array. Here: the link on
    # the clipboard (A's Copy put it there) goes to Array Share B.
    link="$(pbpaste)"
    [[ "$link" == https://arrayapp.dev/s/* || "$link" == array*://s/* ]] || { echo "the clipboard holds no share link: $link" >&2; exit 1; }
    open -a "$APP_B" "$link"
    echo "==> gave Array Share B the link"
    exit ;;
  relaunch)
    side="${2:-}"; [[ "$side" == a || "$side" == b ]] || { echo "usage: $0 relaunch a|b" >&2; exit 2; }
    [[ -f "$STATE/relay.env" ]] || { echo "no preview is running; use $0 start" >&2; exit 1; }
    app="$APP_A"; [[ "$side" == b ]] && app="$APP_B"
    [[ -z "$(app_pids "$app")" ]] || { echo "Array Share $(echo "$side" | tr ab AB) is still running; quit it first" >&2; exit 1; }
    rm -f "$STATE/$side/ready.json"
    launch "$app" "$side"
    wait_ready "$side"
    echo "==> Array Share $(echo "$side" | tr ab AB) is back, in the background"
    exit ;;
  start) ;;
  *) echo "usage: $0 [start|open-link|relaunch a|b|stop]" >&2; exit 2 ;;
esac

started=$(date +%s)
stop >/dev/null

if [[ "${SKIP_BUILD:-0}" != 1 ]]; then
  echo "==> building in $ROOT_DIR"
  [[ -e "$ROOT_DIR/ThirdParty/GhosttyKit.xcframework" ]] || "$ROOT_DIR/scripts/prepare-ghosttykit.sh"
  cd "$ROOT_DIR"
  "$LOCK" swift build --product continuum-relay
  "$LOCK" scripts/make-app-bundle.sh --configuration debug --bundle-id "$ID_A" --name "Array Share A" --output "$APP_A"
  "$LOCK" scripts/make-app-bundle.sh --configuration debug --bundle-id "$ID_B" --name "Array Share B" --output "$APP_B"
fi
cd "$ROOT_DIR"
RELAY_BIN="$APPS/array-share-preview-relay"
cp "$(swift build --show-bin-path)/continuum-relay" "$RELAY_BIN" 2>/dev/null || [[ -x "$RELAY_BIN" ]]

echo "==> fresh state in $STATE"
rm -rf "$STATE/a" "$STATE/b"
for side in a b; do mkdir -p "$STATE/$side/project" "$STATE/$side/support" "$STATE/$side/tmux"; done
chmod 700 "$STATE/a" "$STATE/b"
defaults delete "$ID_A" >/dev/null 2>&1 || true
defaults delete "$ID_B" >/dev/null 2>&1 || true

echo "==> starting the local relay"
RELAY_DATA="$(mktemp -d /tmp/array-share-relay.XXXXXX)"
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

write_config() { # side label role screen-side
  python3 -I - "$STATE/$1/preview.json" "$2" "$3" "http://127.0.0.1:$RELAY_PORT" "$STATE/$1" "$4" <<'PY'
import json, sys
path, label, role, endpoint, root, side = sys.argv[1:7]
json.dump({"label": label, "role": role, "endpoint": endpoint, "enrollmentCode": "", "root": root,
           "exchange": root, "areaLabel": "", "side": side}, open(path, "w"))
PY
}
write_config a A host left
write_config b B guest right

echo "==> launching Array Share A and Array Share B in the background"
launch "$APP_A" a
launch "$APP_B" b
wait_ready a b

cat <<EOF
==> ready in $(( $(date +%s) - started ))s
    relay           http://127.0.0.1:$RELAY_PORT (data in $RELAY_DATA)
    Array Share A   person A: two agents on fake CLIs, no account yet
    Array Share B   person B: an empty canvas, no account yet
    Both run in the background; switch to them from the Dock.
    How to try it:  .plans/105-collaboration/SHARE-AGENT-PREVIEW.md
    Give B the copied link:  scripts/share-agent-preview.sh open-link
    Quit A, bring it back:   scripts/share-agent-preview.sh relaunch a
    Stop:                    scripts/share-agent-preview.sh stop
EOF
