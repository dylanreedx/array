#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DRY_RUN=0
ALLOW_UNENTITLED=0
PUBLISH_FIXTURE_IF_EMPTY=0
DEVICE_NAME=""
DESKTOP_APP=""
PROVISIONED_APP_SCRIPT="scripts/provisioned-cloudkit-app.sh"
PROVISIONED_APP_DIAGNOSED=0

usage() {
  cat <<'USAGE'
Usage: scripts/companion-dogfood-start.sh [--dry-run] [--device <name>] [--desktop-app <path>] [--publish-fixture-if-empty] [--allow-unentitled]

Preflights the paired Continuum companion dogfood run. Dry-run prints intended
actions and launches nothing. Real CloudKit proof refuses SwiftPM executables,
unentitled apps, ad-hoc/manual-entitlement apps, and entitlement-bearing apps
that lack a matching embedded provisioning profile/LaunchServices smoke.

Provisioned desktop app path:
  CONTINUUM_CODESIGN_IDENTITY="Apple Development: ..." \
  CONTINUUM_MACOS_PROVISIONING_PROFILE="/path/to/ContinuumRevived.provisionprofile" \
  scripts/provisioned-cloudkit-app.sh --configuration release \
    --output qa-runs/provisioned/ContinuumRevived.app

Then pass that output with --desktop-app. If --desktop-app is omitted in a real
run, this script tries the same provisioned build path under its artifact dir.
Use --allow-unentitled only for non-proof diagnostics.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --allow-unentitled)
      ALLOW_UNENTITLED=1
      shift
      ;;
    --publish-fixture-if-empty)
      PUBLISH_FIXTURE_IF_EMPTY=1
      shift
      ;;
    --device)
      [[ $# -ge 2 ]] || { echo "missing value for --device" >&2; exit 2; }
      DEVICE_NAME="$2"
      shift 2
      ;;
    --desktop-app)
      [[ $# -ge 2 ]] || { echo "missing value for --desktop-app" >&2; exit 2; }
      DESKTOP_APP="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cd "$ROOT_DIR"

desktop_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Packaging/Info.plist)
ios_bundle_id="dev.dylanreedx.continuum"
cloudkit_container=$(sed -n 's/.*cloudKitContainerIdentifier = "\(.*\)".*/\1/p' Sources/ContinuumRevivedCore/CompanionSyncConfig.swift | head -1)
apns_topic="$ios_bundle_id"
team_id="${CONTINUUM_APPLE_TEAM_ID:-}"
artifact_dir="qa-runs/$(date -u +%Y%m%dT%H%M%SZ)/companion-dogfood"
provisioned_default_app="$artifact_dir/ContinuumRevived-provisioned.app"
unentitled_default_app="$artifact_dir/ContinuumRevived-unentitled-diagnostics.app"

required_tools=(/usr/libexec/PlistBuddy plutil xcrun codesign security swift /usr/bin/open)
missing_tools=()
for tool in "${required_tools[@]}"; do
  if [[ "$tool" == /* ]]; then
    [[ -x "$tool" ]] || missing_tools+=("$tool")
  elif ! command -v "$tool" >/dev/null 2>&1; then
    missing_tools+=("$tool")
  fi
done

if [[ -z "$cloudkit_container" ]]; then
  echo "Unable to read CompanionSyncConfig.cloudKitContainerIdentifier" >&2
  exit 1
fi

if [[ -n "$DESKTOP_APP" && "$DESKTOP_APP" != *.app && "$ALLOW_UNENTITLED" -ne 1 ]]; then
  echo "Refusing SwiftPM/raw executable for real CloudKit proof: $DESKTOP_APP" >&2
  echo "Use a provisioned .app from $PROVISIONED_APP_SCRIPT, pass --dry-run, or pass --allow-unentitled for non-proof diagnostics." >&2
  exit 1
fi

check_desktop_entitlement() {
  local app_path="$1"
  if [[ -n "$app_path" && "$app_path" == *.app && -d "$app_path" ]]; then
    codesign -d --entitlements :- "$app_path" 2>/dev/null | grep -q "$cloudkit_container"
    return
  fi
  return 1
}

entitlements_source="Sources/ContinuumRevived/ContinuumRevived.entitlements"
source_entitlements_reference=false
if grep -q "$cloudkit_container" "$entitlements_source"; then
  source_entitlements_reference=true
fi

desktop_entitled=false
if check_desktop_entitlement "$DESKTOP_APP"; then
  desktop_entitled=true
fi

will_launch_devices=false
if [[ "$DRY_RUN" -eq 0 ]]; then
  will_launch_devices=true
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  mkdir -p "$artifact_dir"
  if [[ -z "$DESKTOP_APP" ]]; then
    if [[ "$ALLOW_UNENTITLED" -eq 1 ]]; then
      DESKTOP_APP="$unentitled_default_app"
      scripts/make-app-bundle.sh --configuration release --channel prod --output "$DESKTOP_APP"
      echo "WARNING: built unentitled diagnostics app at $DESKTOP_APP; this is not CloudKit proof because --allow-unentitled was supplied." >&2
    else
      DESKTOP_APP="$provisioned_default_app"
      "$PROVISIONED_APP_SCRIPT" \
        --configuration release \
        --output "$DESKTOP_APP" \
        --artifacts-dir "$artifact_dir/provisioned-build"
      PROVISIONED_APP_DIAGNOSED=1
    fi
  fi

  if [[ "$DESKTOP_APP" != *.app && "$ALLOW_UNENTITLED" -ne 1 ]]; then
    echo "Refusing SwiftPM/raw executable for real CloudKit proof: $DESKTOP_APP" >&2
    echo "Use $PROVISIONED_APP_SCRIPT --output <ContinuumRevived.app> with a matching identity/profile." >&2
    exit 1
  fi

  if [[ "$ALLOW_UNENTITLED" -ne 1 ]]; then
    if [[ "$PROVISIONED_APP_DIAGNOSED" -ne 1 ]]; then
      "$PROVISIONED_APP_SCRIPT" \
        --diagnose "$DESKTOP_APP" \
        --artifacts-dir "$artifact_dir/provisioned-diagnostics"
    fi
    desktop_entitled=true
  elif check_desktop_entitlement "$DESKTOP_APP"; then
    desktop_entitled=true
  else
    desktop_entitled=false
  fi
fi

printf 'Continuum companion dogfood preflight\n'
printf 'desktop bundle id: %s\n' "$desktop_bundle_id"
printf 'iOS bundle id: %s\n' "$ios_bundle_id"
printf 'CloudKit container: %s\n' "$cloudkit_container"
printf 'APNS topic: %s\n' "$apns_topic"
if [[ -n "$team_id" ]]; then
  printf 'Apple team id: %s\n' "$team_id"
else
  printf 'Apple team id: unavailable in environment\n'
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'dry-run: no desktop or iOS app will be launched\n'
  printf 'source entitlement reference: %s (not signing/provisioning proof)\n' "$source_entitlements_reference"
fi
if [[ -n "$DESKTOP_APP" ]]; then
  printf 'desktop app: %s\n' "$DESKTOP_APP"
else
  printf 'desktop app: provisioned build output will be %s\n' "$provisioned_default_app"
fi
printf 'provisioned desktop build command: CONTINUUM_CODESIGN_IDENTITY="Apple Development: ..." CONTINUUM_MACOS_PROVISIONING_PROFILE="/path/to/ContinuumRevived.provisionprofile" %s --configuration release --output "%s"\n' "$PROVISIONED_APP_SCRIPT" "$provisioned_default_app"
printf 'manual codesign-only entitlement proof: refused (known launch-kill class when unprovisioned)\n'
if [[ -n "$DEVICE_NAME" ]]; then
  printf 'device launch plan: launch %s on matching device "%s"\n' "$ios_bundle_id" "$DEVICE_NAME"
else
  printf 'device launch plan: discover connected iPhone with xcrun devicectl, then launch %s\n' "$ios_bundle_id"
fi
if [[ "$PUBLISH_FIXTURE_IF_EMPTY" -eq 1 ]]; then
  printf 'fixture policy: publish explicit temporary dogfood fixture only if empty\n'
fi
if [[ "$ALLOW_UNENTITLED" -eq 1 ]]; then
  printf 'unentitled diagnostics mode: yes; health may run with desktopSignedWithICloudEntitlement=false and is not CloudKit proof\n'
fi
printf 'paired Continuum instance required: yes\n'
printf 'freshness/heartbeat required: yes\n'
printf 'artifact directory: %s\n' "$artifact_dir"

printf '{\n'
printf '  "dryRun": %s,\n' "$([[ "$DRY_RUN" -eq 1 ]] && echo true || echo false)"
printf '  "willLaunchDevices": %s,\n' "$will_launch_devices"
printf '  "pairedInstanceRequired": true,\n'
printf '  "freshnessRequired": true,\n'
printf '  "desktopBundleIdentifier": "%s",\n' "$desktop_bundle_id"
printf '  "iosBundleIdentifier": "%s",\n' "$ios_bundle_id"
printf '  "containerIdentifier": "%s",\n' "$cloudkit_container"
printf '  "apnsTopic": "%s",\n' "$apns_topic"
printf '  "teamIdentifierAvailable": %s,\n' "$([[ -n "$team_id" ]] && echo true || echo false)"
printf '  "sourceEntitlementsReferenceContainsCloudKit": %s,\n' "$source_entitlements_reference"
printf '  "desktopSignedWithICloudEntitlement": %s,\n' "$desktop_entitled"
printf '  "requiresProvisionedDesktopApp": %s,\n' "$([[ "$ALLOW_UNENTITLED" -eq 1 ]] && echo false || echo true)"
printf '  "publishFixtureIfEmpty": %s,\n' "$([[ "$PUBLISH_FIXTURE_IF_EMPTY" -eq 1 ]] && echo true || echo false)"
printf '  "missingToolCount": %s\n' "${#missing_tools[@]}"
printf '}\n'

if [[ ${#missing_tools[@]} -gt 0 ]]; then
  printf 'missing tools: %s\n' "${missing_tools[*]}" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  exit 0
fi

health_json="$artifact_dir/health.json"
health_err="$artifact_dir/health.stderr.txt"
if [[ -n "$DESKTOP_APP" && "$DESKTOP_APP" == *.app ]]; then
  desktop_executable="$DESKTOP_APP/Contents/MacOS/Array"
  [[ -x "$desktop_executable" ]] || { echo "Desktop app executable not found: $desktop_executable" >&2; exit 1; }
  "$desktop_executable" --companion-sync-health-check >"$health_json" 2>"$health_err"
elif [[ -n "$DESKTOP_APP" ]]; then
  "$DESKTOP_APP" --companion-sync-health-check >"$health_json" 2>"$health_err"
else
  .build/debug/Array --companion-sync-health-check >"$health_json" 2>"$health_err"
fi
if [[ "$ALLOW_UNENTITLED" -ne 1 ]] && ! grep -Eq '"desktopSignedWithICloudEntitlement"[[:space:]]*:[[:space:]]*true' "$health_json"; then
  echo "Health check did not report desktopSignedWithICloudEntitlement=true; refusing to call this CloudKit proof. See $health_json and $health_err." >&2
  exit 1
fi
printf 'health JSON: %s\n' "$health_json"
printf 'Next: launch the paired iPhone, open Agents and Canvas, and capture observations in %s/README.md\n' "$artifact_dir"
