#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${IOS_PREVIEW_LIVE_OUT:-$(mktemp -d /tmp/array-ios-preview-live.XXXXXX)}
args=(
  --backend-package "${IOS_PREVIEW_LIVE_BACKEND_PACKAGE:?Set the extracted, pinned expo-device-hub package directory}"
  --ws-package "${IOS_PREVIEW_LIVE_WS_PACKAGE:?Set the installed ws package directory}"
  --device-type "${IOS_PREVIEW_LIVE_DEVICE_TYPE:?Set an installed simulator device type identifier}"
  --runtime "${IOS_PREVIEW_LIVE_RUNTIME:?Set an installed iOS runtime identifier}"
  --out "$OUT"
)
if [[ -n "${IOS_PREVIEW_LIVE_COMPANION_APP:-}" ]]; then
  args+=(--companion-app "$IOS_PREVIEW_LIVE_COMPANION_APP")
fi
if [[ -n "${IOS_PREVIEW_LIVE_ARRAY_BIN:-}" ]]; then
  args+=(--array-bin "$IOS_PREVIEW_LIVE_ARRAY_BIN")
fi
if [[ -n "${IOS_PREVIEW_LIVE_ARRAY_CHECK:-}" ]]; then
  args+=("--array-check=$IOS_PREVIEW_LIVE_ARRAY_CHECK")
fi
python3 "$ROOT_DIR/Tools/IOSPreviewProof/run-live.py" "${args[@]}"
