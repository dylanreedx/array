#!/bin/bash
# Two Array windows acting as two people, talking through a LOCAL relay, so
# collaboration can be tried by hand on one Mac.
#
#   scripts/multiplayer-preview.sh          # build, start the relay, launch A and B
#   scripts/multiplayer-preview.sh stop     # quit both, stop the relay, leave nothing running
#   scripts/multiplayer-preview.sh relaunch a   # bring A back after quitting it, state kept
#
# What it sets up (every run starts fresh):
# - "Array Dev A" and "Array Dev B" in ~/array-scratch/apps/, each with its own
#   dev bundle id (TCC keys grants by bundle id), its own CONTINUUM_APP_SUPPORT,
#   its own project root (~/array-scratch/mp-preview/{a,b}/project; never one
#   root for both, CLAUDE.md hazard 10) and its own tmux socket namespace.
# - continuum-relay on a free 127.0.0.1 port, its databases in a /tmp folder.
#   Each person gets a one-time enrollment code from the relay, the way
#   scripts/check-collaboration-pair.py enrolls its peers.
# - CONTINUUM_MULTIPLAYER_PREVIEW (see MultiplayerPreview.swift): the
#   collaboration credential lives in a file, not the Keychain; the check fakes
#   stand in for claude/codex/pi, so no agent ever spends real usage; the apps
#   never take focus.
# - The seed: A signs in, gets a Claude and a Codex agent on the fakes, creates
#   the shared workspace "Preview shared workspace" and invites B; B signs in
#   and accepts. Both open the shared workspace. Sharing tiles into it is left
#   for the person trying it (File > Share Zone).
#
# Never touches /Applications/Array.app, ~/Desktop/Array Dev.app, ~/Documents,
# the default tmux socket, a real CLI login or the Keychain.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir)/../.worktrees/.locks/app-build.sh"
STATE="$HOME/array-scratch/mp-preview"
APPS="$HOME/array-scratch/apps"
APP_A="$APPS/Array Dev A.app"
APP_B="$APPS/Array Dev B.app"
ID_A="dev.arrayapp.macos.mp-a"
ID_B="dev.arrayapp.macos.mp-b"

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
    [[ "$RELAY_DATA" == /tmp/array-mp-relay.* ]] && rm -rf "$RELAY_DATA"
    rm -f "$STATE/relay.env"
  fi
  for side in a b; do
    # The fakes run under the apps; their own servers and agent shells may outlive them.
    pkill -f "$STATE/$side/bin/" 2>/dev/null || true
    if [[ -d "$STATE/$side/tmux" ]] && command -v tmux >/dev/null; then
      env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$STATE/$side/tmux" tmux kill-server >/dev/null 2>&1 || true
    fi
  done
  local left
  left="$(app_pids "$APP_A")$(app_pids "$APP_B")$(pgrep -f "$STATE/[ab]/bin/" 2>/dev/null || true)"
  if [[ -n "$left" ]]; then echo "still running: $left" >&2; return 1; fi
  echo "==> multiplayer preview stopped; nothing left running"
}

launch() { # app side
  # `open -n -g`: a new instance, in the background. Never the bare executable,
  # which would die with this shell.
  # No window restoration: after a killed run macOS would otherwise ask
  # "reopen its windows?" before the app boots, and the seed would stall.
  env -u TMUX -u TMUX_PANE open -n -g \
    --env "CONTINUUM_PROJECT_ROOT=$STATE/$2/project" \
    --env "CONTINUUM_APP_SUPPORT=$STATE/$2/support" \
    --env "CONTINUUM_MULTIPLAYER_PREVIEW=$STATE/$2/preview.json" \
    --env "TMUX_TMPDIR=$STATE/$2/tmux" \
    --stdout "$STATE/$2/app.log" --stderr "$STATE/$2/app.log" \
    "$1" --args -ApplePersistenceIgnoreState YES
}
wait_ready() { # sides...
  for _ in $(seq 1 600); do
    for side in "$@"; do
      if [[ -f "$STATE/$side/error.json" ]]; then
        echo "FAIL: $side: $(cat "$STATE/$side/error.json")" >&2; exit 1
      fi
    done
    local all=1
    for side in "$@"; do [[ -f "$STATE/$side/ready.json" ]] || all=0; done
    [[ $all -eq 1 ]] && return 0
    sleep 0.3
  done
  echo "FAIL: timed out; logs in $STATE/{a,b}/app.log" >&2; exit 1
}

case "${1:-start}" in
  stop) stop; exit ;;
  relaunch)
    # Bring one person back after quitting them (the host-offline test),
    # keeping their account, workspace and agents. Never open the bundle from
    # Finder: without this environment it refuses to start.
    side="${2:-}"; [[ "$side" == a || "$side" == b ]] || { echo "usage: $0 relaunch a|b" >&2; exit 2; }
    [[ -f "$STATE/relay.env" ]] || { echo "no preview is running; use $0 start" >&2; exit 1; }
    app="$APP_A"; [[ "$side" == b ]] && app="$APP_B"
    [[ -z "$(app_pids "$app")" ]] || { echo "Array Dev $(echo "$side" | tr ab AB) is still running; quit it first" >&2; exit 1; }
    rm -f "$STATE/$side/ready.json" "$STATE/$side/error.json"
    launch "$app" "$side"
    wait_ready "$side"
    echo "==> Array Dev $(echo "$side" | tr ab AB) is back, in the background"
    exit ;;
  start) ;;
  *) echo "usage: $0 [start|stop|relaunch a|b]" >&2; exit 2 ;;
esac

started=$(date +%s)
stop >/dev/null

echo "==> building in $ROOT_DIR"
[[ -e "$ROOT_DIR/ThirdParty/GhosttyKit.xcframework" ]] || "$ROOT_DIR/scripts/prepare-ghosttykit.sh"
cd "$ROOT_DIR"
"$LOCK" swift build --product continuum-relay
"$LOCK" scripts/make-app-bundle.sh --configuration debug --bundle-id "$ID_A" --name "Array Dev A" --output "$APP_A"
"$LOCK" scripts/make-app-bundle.sh --configuration debug --bundle-id "$ID_B" --name "Array Dev B" --output "$APP_B"
RELAY_BIN="$(swift build --show-bin-path)/continuum-relay"

echo "==> fresh state in $STATE"
rm -rf "$STATE/a" "$STATE/b" "$STATE/exchange"
for side in a b; do mkdir -p "$STATE/$side/project" "$STATE/$side/support" "$STATE/$side/tmux"; done
mkdir -p "$STATE/exchange"
chmod 700 "$STATE/a" "$STATE/b" "$STATE/exchange"
defaults delete "$ID_A" >/dev/null 2>&1 || true
defaults delete "$ID_B" >/dev/null 2>&1 || true

echo "==> starting the local relay"
RELAY_DATA="$(mktemp -d /tmp/array-mp-relay.XXXXXX)"
# A new session, so the relay outlives this shell's process group, as `open`
# does for the apps. Only loopback, only this run's databases and keys.
python3 -I - "$RELAY_BIN" "$RELAY_DATA" "$STATE/relay.env" <<'PY'
import base64, json, os, socket, subprocess, sys, time
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
codes = {}
for label in ("A", "B"):
    out = subprocess.run([relay, "--collaboration-enroll", "Person " + label], env=env, capture_output=True, text=True, timeout=15, check=True)
    codes[label] = json.loads(out.stdout)["code"]
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
    f.write(f"RELAY_PID={process.pid}\nRELAY_DATA={data}\nRELAY_PORT={port}\nCODE_A={codes['A']}\nCODE_B={codes['B']}\n")
PY
# shellcheck disable=SC1091
source "$STATE/relay.env"
ENDPOINT="http://127.0.0.1:$RELAY_PORT"

write_config() { # side label role code screen-side
  python3 -I - "$STATE/$1/preview.json" "$2" "$3" "$ENDPOINT" "$4" "$STATE/$1" "$STATE/exchange" "$5" <<'PY'
import json, sys
path, label, role, endpoint, code, root, exchange, side = sys.argv[1:9]
json.dump({"label": label, "role": role, "endpoint": endpoint, "enrollmentCode": code, "root": root,
           "exchange": exchange, "areaLabel": "Preview shared workspace", "side": side}, open(path, "w"))
PY
}
write_config a A host "$CODE_A" left
write_config b B guest "$CODE_B" right

echo "==> launching Array Dev A and Array Dev B in the background"
launch "$APP_A" a
launch "$APP_B" b

echo "==> waiting for both people to sign in and open the shared workspace"
wait_ready a b

cat <<EOF
==> ready in $(( $(date +%s) - started ))s
    relay      $ENDPOINT (data in $RELAY_DATA)
    Array Dev A  person A, owner of "Preview shared workspace", two agents on fake CLIs
    Array Dev B  person B, editor in the same shared workspace
    Both are running in the background; switch to them from the Dock.
    Try list:  .plans/105-collaboration/PREVIEW.md
    Quit A, then bring A back:  scripts/multiplayer-preview.sh relaunch a
    Stop:      scripts/multiplayer-preview.sh stop
EOF
