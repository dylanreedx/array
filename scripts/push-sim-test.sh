#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP_BIN="$ROOT_DIR/.build/debug/Array"
BUNDLE_ID="dev.dylanreedx.continuum"
DEVICE=""
OUT=""
DELAY="2"
SCREENSHOTS=1
INSTALL=1

usage() {
  cat <<'USAGE' >&2
Usage: scripts/push-sim-test.sh [--device <name|udid>] [--out <dir>] [--delay <seconds>] [--no-screenshots] [--no-install]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      DEVICE="$2"
      shift 2
      ;;
    --out)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      OUT="$2"
      shift 2
      ;;
    --delay)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      DELAY="$2"
      shift 2
      ;;
    --no-screenshots)
      SCREENSHOTS=0
      shift
      ;;
    --no-install)
      INSTALL=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "push-sim-test: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$OUT" ]]; then
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/continuum-push-sim.XXXXXX")
fi
PAYLOAD_DIR="$OUT/payloads"
SHOT_DIR="$OUT/shots"
DERIVED_DATA="$OUT/DerivedData"

mkdir -p "$PAYLOAD_DIR"
if [[ "$SCREENSHOTS" -eq 1 ]]; then
  mkdir -p "$SHOT_DIR"
fi

echo "push-sim-test: out=$OUT"

if [[ ! -x "$APP_BIN" ]]; then
  echo "push-sim-test: building Array"
  (cd "$ROOT_DIR" && swift build)
fi

"$APP_BIN" --push-payload-dump "$PAYLOAD_DIR"

booted_device_line() {
  xcrun simctl list devices booted | awk '/Booted/ && /\([0-9A-Fa-f-]{36}\)/ { print; exit }'
}

device_udid_from_line() {
  sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/'
}

device_name_from_line() {
  sed -E 's/^[[:space:]]*([^()]+)[[:space:]]+\([0-9A-Fa-f-]{36}\).*/\1/' | sed 's/[[:space:]]*$//'
}

if [[ -n "$DEVICE" ]]; then
  DEVICE_LINE=$(xcrun simctl list devices available | grep -F "$DEVICE" | head -n 1 || true)
  if [[ -z "$DEVICE_LINE" ]]; then
    echo "push-sim-test: device not found: $DEVICE" >&2
    exit 1
  fi
  UDID=$(printf '%s\n' "$DEVICE_LINE" | device_udid_from_line)
  NAME=$(printf '%s\n' "$DEVICE_LINE" | device_name_from_line)
else
  DEVICE_LINE=$(booted_device_line || true)
  if [[ -n "$DEVICE_LINE" ]]; then
    UDID=$(printf '%s\n' "$DEVICE_LINE" | device_udid_from_line)
    NAME=$(printf '%s\n' "$DEVICE_LINE" | device_name_from_line)
  else
    DEVICE_LINE=$(xcrun simctl list devices available | awk '/iPhone/ && /\([0-9A-Fa-f-]{36}\)/ && !/unavailable/ { line=$0 } END { print line }')
    if [[ -z "$DEVICE_LINE" ]]; then
      echo "push-sim-test: no available iPhone simulator found" >&2
      exit 1
    fi
    UDID=$(printf '%s\n' "$DEVICE_LINE" | device_udid_from_line)
    NAME=$(printf '%s\n' "$DEVICE_LINE" | device_name_from_line)
    echo "push-sim-test: booting $NAME ($UDID)"
    xcrun simctl boot "$UDID" || true
    xcrun simctl bootstatus "$UDID" -b
  fi
fi

echo "push-sim-test: device=$NAME udid=$UDID"

if xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" >/dev/null 2>&1; then
  echo "push-sim-test: app already installed: $BUNDLE_ID"
else
  if [[ "$INSTALL" -eq 0 ]]; then
    echo "push-sim-test: app is not installed and --no-install was passed: $BUNDLE_ID" >&2
    exit 1
  fi
  echo "push-sim-test: building and installing iOS app"
  (
    cd "$ROOT_DIR/ios"
    xcodegen generate
    xcodebuild -project Continuum.xcodeproj -scheme Continuum -destination "id=$UDID" -derivedDataPath "$DERIVED_DATA" build
  )
  BUILT_APP=$(find "$DERIVED_DATA/Build/Products" -type d -name "Continuum.app" -print -quit)
  if [[ -z "$BUILT_APP" ]]; then
    echo "push-sim-test: built app not found under $DERIVED_DATA/Build/Products" >&2
    exit 1
  fi
  xcrun simctl install "$UDID" "$BUILT_APP"
fi

echo "push-sim-test: launching $BUNDLE_ID"
launch_err=$(mktemp "${TMPDIR:-/tmp}/continuum-simctl-launch.XXXXXX")
if xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null 2>"$launch_err"; then
  rm -f "$launch_err"
else
  launch_status=$?
  launch_error=$(<"$launch_err")
  rm -f "$launch_err"
  launch_error_lower=$(printf '%s' "$launch_error" | tr '[:upper:]' '[:lower:]')
  if [[ "$launch_error_lower" == *"already running"* || "$launch_error_lower" == *"already launched"* ]]; then
    echo "push-sim-test: app already running; continuing"
  else
    echo "push-sim-test: launch failed for $BUNDLE_ID (exit $launch_status)" >&2
    if [[ -n "$launch_error" ]]; then
      printf '%s\n' "$launch_error" >&2
    fi
    exit "$launch_status"
  fi
fi
echo "push-sim-test: first launch may require tapping Allow for notification permission in the simulator."

sent=0
failed=0
for category in N1 N2 N3 N4 N5 N6 N7 N8; do
  payload="$PAYLOAD_DIR/$category.apns"
  if xcrun simctl push "$UDID" "$BUNDLE_ID" "$payload"; then
    echo "push-sim-test: $category push accepted"
    sent=$((sent + 1))
  else
    echo "push-sim-test: $category push FAILED" >&2
    failed=$((failed + 1))
  fi
  sleep "$DELAY"
  if [[ "$SCREENSHOTS" -eq 1 ]]; then
    xcrun simctl io "$UDID" screenshot "$SHOT_DIR/$category.png"
  fi
done

echo "push-sim-test: sent=$sent failed=$failed out=$OUT"
echo "push-sim-test: visual confirmation owed: banners, lock-screen actions, category suppression, deep-link routing; tag visual-gate-owed for morning screenshot review."
echo "push-sim-test: simctl push exit 0 confirms simulator acceptance/delivery, not rendered notification UI."
echo "push-sim-test: done out=$OUT"

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi
