#!/usr/bin/env bash
set -euo pipefail

LABEL="com.continuum.revived.relay.dev"
DOMAIN="gui/$(id -u)"
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEFAULT_APP_SUPPORT="$HOME/Library/Application Support/Continuum/DevRelay"
DEFAULT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_SUPPORT="${CONTINUUM_RELAY_DEV_DIR:-$DEFAULT_APP_SUPPORT}"
BIN_DIR="$APP_SUPPORT/bin"
BINARY="$BIN_DIR/continuum-relay"
LOG_DIR="$APP_SUPPORT/logs"
STDOUT_LOG="$LOG_DIR/stdout.log"
STDERR_LOG="$LOG_DIR/stderr.log"
MODE_FILE="$APP_SUPPORT/mode"
PLIST="${CONTINUUM_RELAY_DEV_PLIST:-$DEFAULT_PLIST}"
PORT="${CONTINUUM_RELAY_DEV_PORT:-8787}"
MAC_CHANNEL="${CONTINUUM_RELAY_MAC_CHANNEL:-dev}"
IOS_DOMAIN="dev.dylanreedx.continuum"
URL_KEY="continuum.relay.url"
TOKEN_KEY="continuum.relay.operatorToken"

usage() {
  cat <<'USAGE'
Usage: scripts/relay-dev.sh <command> [arguments]

  install [loopback|lan]  Build/install the release relay and load its LaunchAgent
  mode <loopback|lan>     Change bind mode and restart (loopback is the default)
  start | stop | restart  Manage the installed LaunchAgent
  status                  Report launchd, process, listener, health, and Mac sync state
  logs [lines]            Show captured stdout/stderr (default: 80 lines each)
  smoke                    Start the real relay on an ephemeral port and probe /v1/health
  simulator [device]      Configure a booted simulator (or supplied UDID) for this relay
  uninstall               Unload and remove only the managed dev relay and its defaults
USAGE
}

die() { printf 'relay-dev: %s\n' "$*" >&2; exit 2; }
info() { printf 'relay-dev: %s\n' "$*"; }
case "$MAC_CHANNEL" in
  prod) MAC_DOMAIN="dev.arrayapp.macos" ;;
  dev) MAC_DOMAIN="dev.arrayapp.macos.dev" ;;
  *) die "CONTINUUM_RELAY_MAC_CHANNEL must be dev or prod" ;;
esac
assert_managed_paths() {
  [[ "$APP_SUPPORT" == "$DEFAULT_APP_SUPPORT" && "$PLIST" == "$DEFAULT_PLIST" ]] \
    || die "refusing lifecycle mutation outside the manager-owned DevRelay paths"
}

valid_mode() { [[ "$1" == "loopback" || "$1" == "lan" ]]; }
current_mode() {
  local mode="loopback"
  if [[ -f "$MODE_FILE" ]]; then mode=$(cat "$MODE_FILE"); fi
  valid_mode "$mode" || die "invalid managed mode file: $MODE_FILE"
  printf '%s\n' "$mode"
}
bind_host() { [[ "$1" == "lan" ]] && printf '0.0.0.0\n' || printf '127.0.0.1\n'; }
client_url() { printf 'http://127.0.0.1:%s\n' "$PORT"; }

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

existing_token() {
  if [[ -n "${CONTINUUM_RELAY_OPERATOR_TOKEN:-}" ]]; then
    printf '%s' "$CONTINUUM_RELAY_OPERATOR_TOKEN"
    return
  fi
  local token=""
  token=$(defaults read "$MAC_DOMAIN" "$TOKEN_KEY" 2>/dev/null || true)
  if [[ -z "$token" && -f "$PLIST" ]]; then
    token=$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:CONTINUUM_RELAY_OPERATOR_TOKEN" "$PLIST" 2>/dev/null || true)
  fi
  printf '%s' "$token"
}

require_token() {
  local token
  token=$(existing_token)
  if [[ -z "$token" ]]; then
    token=$(openssl rand -hex 32)
  fi
  printf '%s' "$token"
}

render_plist() {
  local mode=$1 token=$2 host
  host=$(bind_host "$mode")
  local e_binary e_host e_port e_token e_out e_err
  e_binary=$(printf '%s' "$BINARY" | xml_escape)
  e_host=$(printf '%s' "$host" | xml_escape)
  e_port=$(printf '%s' "$PORT" | xml_escape)
  e_token=$(printf '%s' "$token" | xml_escape)
  e_out=$(printf '%s' "$STDOUT_LOG" | xml_escape)
  e_err=$(printf '%s' "$STDERR_LOG" | xml_escape)
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$e_binary</string><string>--host</string><string>$e_host</string><string>--port</string><string>$e_port</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>CONTINUUM_RELAY_OPERATOR_TOKEN</key><string>$e_token</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$e_out</string>
  <key>StandardErrorPath</key><string>$e_err</string>
</dict></plist>
PLIST
}

loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }
bootout() {
  if loaded; then launchctl bootout "$DOMAIN/$LABEL"; fi
}
expected_pid() {
  launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '/^[[:space:]]*pid = / { print $3; exit }'
}
service_healthy() {
  local pid
  pid=$(expected_pid || true)
  [[ -n "$pid" ]] \
    && kill -0 "$pid" 2>/dev/null \
    && lsof -nP -a -p "$pid" -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 \
    && curl --fail --silent --max-time 1 "$(client_url)/v1/health" >/dev/null 2>&1
}
wait_for_health() {
  local i
  for i in $(seq 1 100); do
    service_healthy && return 0
    sleep 0.05
  done
  tail -n 10 "$STDERR_LOG" >&2 2>/dev/null || true
  die "LaunchAgent did not become healthy within 5 seconds"
}
unexpected_listener() {
  local expected=${1:-}
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | awk -v expected="$expected" '$0 != expected { print; exit }'
}
write_defaults() {
  local token=$1
  defaults write "$MAC_DOMAIN" "$URL_KEY" "$(client_url)"
  defaults write "$MAC_DOMAIN" "$TOKEN_KEY" "$token"
}

start_service() {
  assert_managed_paths
  [[ -x "$BINARY" ]] || die "not installed: run '$0 install'"
  [[ -f "$PLIST" ]] || die "missing LaunchAgent: run '$0 install'"
  if loaded && service_healthy; then
    info "$LABEL is already healthy"
    return 0
  fi
  if loaded; then
    launchctl kickstart -k "$DOMAIN/$LABEL"
  else
    local other
    other=$(unexpected_listener "" || true)
    [[ -z "$other" ]] || die "port $PORT is already owned by unexpected PID $other; stop it before starting the managed relay"
    launchctl bootstrap "$DOMAIN" "$PLIST"
  fi
  wait_for_health
}

install_service() {
  assert_managed_paths
  local mode=${1:-$(current_mode)}
  valid_mode "$mode" || die "mode must be loopback or lan"
  local token tmpbin tmpplist oldpid other
  token=$(require_token)
  [[ -n "$token" ]] || die "operator token is empty"
  oldpid=$(expected_pid || true)
  other=$(unexpected_listener "$oldpid" || true)
  [[ -z "$other" ]] || die "port $PORT is already owned by unexpected PID $other; stop it before install"

  info "building continuum-relay-legacy development compatibility service (release)"
  (cd "$ROOT_DIR" && swift build -c release --product continuum-relay-legacy)
  mkdir -p "$BIN_DIR" "$LOG_DIR" "$(dirname "$PLIST")"
  touch "$STDOUT_LOG" "$STDERR_LOG"
  chmod 600 "$STDOUT_LOG" "$STDERR_LOG"
  tmpbin="$BINARY.new.$$"
  cp "$ROOT_DIR/.build/release/continuum-relay-legacy" "$tmpbin"
  chmod 700 "$tmpbin"
  bootout
  mv -f "$tmpbin" "$BINARY"
  printf '%s\n' "$mode" > "$MODE_FILE"
  chmod 600 "$MODE_FILE"
  tmpplist="$PLIST.new.$$"
  render_plist "$mode" "$token" > "$tmpplist"
  chmod 600 "$tmpplist"
  plutil -lint "$tmpplist" >/dev/null
  mv -f "$tmpplist" "$PLIST"
  write_defaults "$token"
  start_service
  info "installed mode=$mode binary=$BINARY plist=$PLIST"
  if [[ "$mode" == "lan" ]]; then
    info "LAN mode explicitly exposes plain HTTP on all IPv4 interfaces; use only on a trusted network"
  fi
}

status_service() {
  local failures=0 pid="" mode url configured_url command health sync_log sync_line
  mode=$(current_mode)
  url=$(client_url)
  printf 'mode: %s (bind %s)\n' "$mode" "$(bind_host "$mode")"
  printf 'binary: %s\n' "$BINARY"
  printf 'plist: %s\n' "$PLIST"
  if loaded; then
    printf 'launchd: loaded\n'
    pid=$(expected_pid || true)
  else
    printf 'launchd: NOT LOADED\n'; failures=1
  fi
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    command=$(ps -p "$pid" -o command= 2>/dev/null || true)
    if [[ "$command" == "$BINARY --host "*" --port $PORT"* && "$command" != *"operator-token"* ]]; then
      printf 'process: pid=%s expected-binary=yes argv-secret=no\n' "$pid"
    else
      printf 'process: pid=%s EXPECTED BINARY/ARGV MISMATCH\n' "$pid"; failures=1
    fi
  else
    printf 'process: no launchd pid\n'; failures=1
  fi
  if [[ -n "$pid" ]] && lsof -nP -a -p "$pid" -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    printf 'listener: pid=%s tcp:%s\n' "$pid" "$PORT"
  else
    printf 'listener: MISSING expected pid/port\n'; failures=1
  fi
  health=$(curl --fail --silent --show-error --max-time 2 "$url/v1/health" 2>/dev/null || true)
  if [[ "$health" == *'"latestSeq"'* && "$health" == *'"subscribers"'* ]]; then
    printf 'health: %s\n' "$health"
  else
    printf 'health: FAILED %s/v1/health\n' "$url"; failures=1
  fi
  configured_url=$(defaults read "$MAC_DOMAIN" "$URL_KEY" 2>/dev/null || true)
  if [[ "$configured_url" == "$url" ]]; then
    printf 'mac-config: url=%s operator-token=%s\n' "$configured_url" "$(defaults read "$MAC_DOMAIN" "$TOKEN_KEY" >/dev/null 2>&1 && printf configured || printf missing)"
  else
    printf 'mac-config: url=%s (expected %s)\n' "${configured_url:-missing}" "$url"; failures=1
  fi
  sync_log="$HOME/Library/Application Support/Array/companion-sync.log"
  if [[ -f "$sync_log" ]]; then
    sync_line=$(tail -n 1 "$sync_log" | sed -E 's/(Bearer[[:space:]]+)[^[:space:]]+/\1<redacted>/Ig; s/([Tt]oken[=:])[A-Za-z0-9._~-]+/\1<redacted>/g; s/[A-Fa-f0-9]{32,}/<redacted>/g')
    printf 'mac-sync-latest: %s\n' "$sync_line"
  else
    printf 'mac-sync-latest: unavailable (%s)\n' "$sync_log"
  fi
  return "$failures"
}

smoke() {
  local candidate token dir out err pid="" port="" health=""
  candidate="$BINARY"
  [[ -x "$candidate" ]] || candidate="$ROOT_DIR/.build/release/continuum-relay-legacy"
  [[ -x "$candidate" ]] || die "no release binary; run '$0 install' or 'swift build -c release --product continuum-relay-legacy'"
  token=$(openssl rand -hex 32)
  dir=$(mktemp -d "${TMPDIR:-/tmp}/continuum-relay-smoke.XXXXXX")
  out="$dir/stdout.log"; err="$dir/stderr.log"
  cleanup_smoke() { [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true; rm -rf "$dir"; }
  trap cleanup_smoke EXIT INT TERM
  CONTINUUM_RELAY_OPERATOR_TOKEN="$token" "$candidate" --host 127.0.0.1 --port 0 >"$out" 2>"$err" & pid=$!
  for _ in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || { cat "$err" >&2; die "smoke subprocess exited before readiness"; }
    port=$(sed -nE 's/.*ready url=http:\/\/127\.0\.0\.1:([0-9]+).*/\1/p' "$out" | tail -1)
    [[ -n "$port" ]] && break
    sleep 0.05
  done
  [[ -n "$port" ]] || die "smoke timed out waiting for readiness line"
  health=$(curl --fail --silent --show-error --max-time 2 "http://127.0.0.1:$port/v1/health")
  [[ "$health" == *'"latestSeq"'* ]] || die "smoke health payload malformed"
  ! grep -F "$token" "$out" "$err" >/dev/null || die "operator token leaked to relay logs"
  command=$(ps -p "$pid" -o command=)
  [[ "$command" != *"$token"* && "$command" != *"operator-token"* ]] || die "operator token leaked to argv"
  info "smoke healthy pid=$pid port=$port health=$health argv-secret=no log-secret=no"
  cleanup_smoke
  trap - EXIT INT TERM
}

configure_simulator() {
  local device=${1:-booted}
  xcrun simctl spawn "$device" defaults write "$IOS_DOMAIN" "$URL_KEY" "$(client_url)"
  info "configured simulator $device url=$(client_url)"
}

uninstall_service() {
  assert_managed_paths
  bootout
  rm -f "$PLIST"
  rm -rf "$APP_SUPPORT"
  defaults delete "$MAC_DOMAIN" "$URL_KEY" >/dev/null 2>&1 || true
  defaults delete "$MAC_DOMAIN" "$TOKEN_KEY" >/dev/null 2>&1 || true
  info "uninstalled $LABEL and removed only $APP_SUPPORT, $PLIST, and Continuum relay defaults"
}

command=${1:-}
case "$command" in
  install) shift; [[ $# -le 1 ]] || die "install accepts at most one mode"; install_service "${1:-$(current_mode)}" ;;
  mode) shift; [[ $# -eq 1 ]] || die "mode requires loopback or lan"; valid_mode "$1" || die "mode must be loopback or lan"; install_service "$1" ;;
  start) shift; [[ $# -eq 0 ]] || die "start takes no arguments"; start_service ;;
  stop) shift; [[ $# -eq 0 ]] || die "stop takes no arguments"; assert_managed_paths; bootout; info "stopped $LABEL" ;;
  restart) shift; [[ $# -eq 0 ]] || die "restart takes no arguments"; assert_managed_paths; bootout; start_service ;;
  status) shift; [[ $# -eq 0 ]] || die "status takes no arguments"; status_service ;;
  logs) shift; [[ $# -le 1 ]] || die "logs accepts an optional line count"; lines=${1:-80}; [[ "$lines" =~ ^[0-9]+$ ]] || die "log line count must be numeric"; printf '==> %s\n' "$STDOUT_LOG"; tail -n "$lines" "$STDOUT_LOG" 2>/dev/null || true; printf '==> %s\n' "$STDERR_LOG"; tail -n "$lines" "$STDERR_LOG" 2>/dev/null || true ;;
  smoke) shift; [[ $# -eq 0 ]] || die "smoke takes no arguments"; smoke ;;
  simulator) shift; [[ $# -le 1 ]] || die "simulator accepts an optional device UDID"; configure_simulator "${1:-booted}" ;;
  uninstall) shift; [[ $# -eq 0 ]] || die "uninstall takes no arguments"; uninstall_service ;;
  __contract) shift; [[ $# -eq 1 ]] || die "__contract requires a mode"; valid_mode "$1" || die "invalid contract mode"; render_plist "$1" "${CONTINUUM_RELAY_DEV_TEST_TOKEN:-contract-test-token}" ;;
  -h|--help|help) usage ;;
  "") usage; exit 2 ;;
  *) die "unknown command: $command" ;;
esac
