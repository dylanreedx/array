#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIGURATION=release
OUTPUT=""
DIAGNOSE_APP=""
IDENTITY="${CONTINUUM_CODESIGN_IDENTITY:-}"
PROFILE="${CONTINUUM_MACOS_PROVISIONING_PROFILE:-}"
ARTIFACT_DIR=""
DRY_RUN=0
SKIP_LAUNCH_SMOKE=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/provisioned-cloudkit-app.sh --output <ContinuumRevived.app> [options]
  scripts/provisioned-cloudkit-app.sh --diagnose <ContinuumRevived.app> [options]

Builds/signs or diagnoses a ContinuumRevived macOS .app for real CloudKit
proof. A manual codesign-only iCloud entitlement is not proof: the app must be
signed by a non-ad-hoc identity, carry the CloudKit entitlement, embed a matching
macOS provisioning profile, and pass a LaunchServices smoke test.

Options:
  --configuration debug|release       SwiftPM configuration for --output (default: release)
  --output <path>                     Build/sign this .app path
  --diagnose <path>                   Diagnose an already-built .app without rebuilding/signing
  --identity <codesign identity>      Apple Development identity (or set CONTINUUM_CODESIGN_IDENTITY)
  --profile <path>                    macOS provisioning profile (or set CONTINUUM_MACOS_PROVISIONING_PROFILE)
  --artifacts-dir <dir>               Directory for entitlements/logs/manifest
  --skip-launch-smoke                 Verify signing/provisioning but do not launch the app
  --dry-run                           Print the deterministic plan; build/sign/launch nothing
  -h, --help                          Show this help

Typical dogfood build:
  CONTINUUM_CODESIGN_IDENTITY="Apple Development: Dylan Reed (...)" \
  CONTINUUM_MACOS_PROVISIONING_PROFILE="$HOME/Downloads/ContinuumRevived.provisionprofile" \
  scripts/provisioned-cloudkit-app.sh --configuration release \
    --output qa-runs/provisioned/ContinuumRevived.app
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      [[ $# -ge 2 ]] || { echo "missing value for --configuration" >&2; exit 2; }
      CONFIGURATION="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "missing value for --output" >&2; exit 2; }
      OUTPUT="$2"
      shift 2
      ;;
    --diagnose)
      [[ $# -ge 2 ]] || { echo "missing value for --diagnose" >&2; exit 2; }
      DIAGNOSE_APP="$2"
      shift 2
      ;;
    --identity)
      [[ $# -ge 2 ]] || { echo "missing value for --identity" >&2; exit 2; }
      IDENTITY="$2"
      shift 2
      ;;
    --profile)
      [[ $# -ge 2 ]] || { echo "missing value for --profile" >&2; exit 2; }
      PROFILE="$2"
      shift 2
      ;;
    --artifacts-dir)
      [[ $# -ge 2 ]] || { echo "missing value for --artifacts-dir" >&2; exit 2; }
      ARTIFACT_DIR="$2"
      shift 2
      ;;
    --skip-launch-smoke)
      SKIP_LAUNCH_SMOKE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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

case "$CONFIGURATION" in
  debug|release) ;;
  *) echo "--configuration must be debug or release" >&2; exit 2 ;;
esac

if [[ -n "$OUTPUT" && -n "$DIAGNOSE_APP" ]]; then
  echo "choose either --output or --diagnose, not both" >&2
  exit 2
fi
if [[ -z "$OUTPUT" && -z "$DIAGNOSE_APP" ]]; then
  echo "--output or --diagnose is required" >&2
  usage >&2
  exit 2
fi
if [[ -n "$OUTPUT" && "$OUTPUT" != *.app ]]; then
  echo "--output must end in .app: $OUTPUT" >&2
  exit 2
fi
if [[ -n "$DIAGNOSE_APP" && "$DIAGNOSE_APP" != *.app ]]; then
  echo "--diagnose must point at a .app bundle: $DIAGNOSE_APP" >&2
  exit 2
fi

cd "$ROOT_DIR"

required_tools=(/usr/libexec/PlistBuddy plutil codesign security swift /usr/bin/open)
missing_tools=()
for tool in "${required_tools[@]}"; do
  if [[ "$tool" == /* ]]; then
    [[ -x "$tool" ]] || missing_tools+=("$tool")
  elif ! command -v "$tool" >/dev/null 2>&1; then
    missing_tools+=("$tool")
  fi
done
if [[ ${#missing_tools[@]} -gt 0 ]]; then
  printf 'missing tools: %s\n' "${missing_tools[*]}" >&2
  exit 1
fi

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Packaging/Info.plist)
cloudkit_container=$(sed -n 's/.*cloudKitContainerIdentifier = "\(.*\)".*/\1/p' Sources/ContinuumRevivedCore/CompanionSyncConfig.swift | head -1)
[[ -n "$cloudkit_container" ]] || { echo "Unable to read CompanionSyncConfig.cloudKitContainerIdentifier" >&2; exit 1; }

stamp=$(date -u +%Y%m%dT%H%M%SZ)
if [[ -z "$ARTIFACT_DIR" ]]; then
  ARTIFACT_DIR="$ROOT_DIR/qa-runs/$stamp/provisioned-cloudkit-app"
fi

bool() {
  if [[ "$1" == "1" || "$1" == "true" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

mode="build"
app_path="$OUTPUT"
if [[ -n "$DIAGNOSE_APP" ]]; then
  mode="diagnose"
  app_path="$DIAGNOSE_APP"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF
Provisioned Continuum CloudKit app plan (dry-run)
mode: $mode
configuration: $CONFIGURATION
app path: $app_path
CloudKit container: $cloudkit_container
bundle id: $bundle_id
identity provided: $(bool "$([[ -n "$IDENTITY" ]] && echo 1 || echo 0)")
profile provided: $(bool "$([[ -n "$PROFILE" ]] && echo 1 || echo 0)")
manual codesign-only is not CloudKit proof; a matching embedded provisioning profile and launch smoke are required.
EOF
  if [[ "$mode" == "build" ]]; then
    cat <<EOF
planned commands:
  scripts/make-app-bundle.sh --configuration $CONFIGURATION --output "$app_path"
  security cms -D -i "<profile>" > "$ARTIFACT_DIR/profile.plist"
  cp "<profile>" "$app_path/Contents/embedded.provisionprofile"
  codesign --force --timestamp=none --sign "<identity>" --entitlements "$ARTIFACT_DIR/profile-entitlements.plist" "$app_path"
  codesign --verify --deep --strict --verbose=2 "$app_path"
EOF
  else
    cat <<EOF
planned diagnostics:
  codesign --verify --deep --strict --verbose=2 "$app_path"
  codesign -d --entitlements :- "$app_path"
  verify "$app_path/Contents/embedded.provisionprofile" contains $cloudkit_container
EOF
  fi
  if [[ "$SKIP_LAUNCH_SMOKE" -eq 1 ]]; then
    echo "planned launch smoke: skipped by --skip-launch-smoke"
  else
    echo "planned launch smoke: /usr/bin/open -n -W \"$app_path\" --args --menu-contract-check --launch-probe-sentinel <sentinel>"
  fi
  printf '{\n'
  printf '  "dryRun": true,\n'
  printf '  "mode": "%s",\n' "$mode"
  printf '  "configuration": "%s",\n' "$CONFIGURATION"
  printf '  "bundleIdentifier": "%s",\n' "$bundle_id"
  printf '  "containerIdentifier": "%s",\n' "$cloudkit_container"
  printf '  "identityProvided": %s,\n' "$(bool "$([[ -n "$IDENTITY" ]] && echo 1 || echo 0)")"
  printf '  "profileProvided": %s,\n' "$(bool "$([[ -n "$PROFILE" ]] && echo 1 || echo 0)")"
  printf '  "willBuild": false,\n'
  printf '  "willSign": false,\n'
  printf '  "willLaunchSmoke": false,\n'
  printf '  "plannedLaunchSmoke": %s,\n' "$(bool "$([[ "$SKIP_LAUNCH_SMOKE" -eq 0 ]] && echo 1 || echo 0)")"
  printf '  "realCloudKitProof": false\n'
  printf '}\n'
  exit 0
fi

mkdir -p "$ARTIFACT_DIR"
ARTIFACT_DIR=$(cd "$ARTIFACT_DIR" && pwd)

PROFILE_PLIST="$ARTIFACT_DIR/profile.plist"
PROFILE_ENTITLEMENTS="$ARTIFACT_DIR/profile-entitlements.plist"
SIGNED_ENTITLEMENTS="$ARTIFACT_DIR/signed-entitlements.plist"
CODESIGN_SIGN_LOG="$ARTIFACT_DIR/codesign-sign.txt"
CODESIGN_VERIFY_LOG="$ARTIFACT_DIR/codesign-verify.txt"
CODESIGN_DISPLAY_LOG="$ARTIFACT_DIR/codesign-display.txt"
PROFILE_LOG="$ARTIFACT_DIR/profile.txt"
LAUNCH_LOG="$ARTIFACT_DIR/launch-smoke.txt"
HEALTH_JSON="$ARTIFACT_DIR/health.json"
HEALTH_ERR="$ARTIFACT_DIR/health.stderr.txt"
MANIFEST="$ARTIFACT_DIR/manifest.json"

plist_print() {
  local path="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print $key" "$path" 2>/dev/null || true
}

profile_contains_cloudkit() {
  local decoded="$1"
  plist_print "$decoded" ':Entitlements:com.apple.developer.icloud-services' | grep -Fq 'CloudKit' && \
    plist_print "$decoded" ':Entitlements:com.apple.developer.icloud-container-identifiers' | grep -Fq "$cloudkit_container"
}

signed_entitlements_contain_cloudkit() {
  local entitlements="$1"
  grep -Fq 'com.apple.developer.icloud-services' "$entitlements" && \
    grep -Fq 'CloudKit' "$entitlements" && \
    grep -Fq 'com.apple.developer.icloud-container-identifiers' "$entitlements" && \
    grep -Fq "$cloudkit_container" "$entitlements"
}

profile_matches_bundle_id() {
  local decoded="$1"
  local app_identifier team_identifier prefix
  app_identifier=$(plist_print "$decoded" ':Entitlements:application-identifier')
  if [[ -z "$app_identifier" ]]; then
    app_identifier=$(plist_print "$decoded" ':Entitlements:com.apple.application-identifier')
  fi
  team_identifier=$(plist_print "$decoded" ':Entitlements:com.apple.developer.team-identifier')
  prefix=$(plist_print "$decoded" ':ApplicationIdentifierPrefix:0')
  [[ -n "$team_identifier" ]] || team_identifier="$prefix"

  if [[ -n "$app_identifier" ]]; then
    [[ "$app_identifier" == "$team_identifier.$bundle_id" || "$app_identifier" == *".$bundle_id" || "$app_identifier" == "$team_identifier.*" || "$app_identifier" == *".*" ]] && return 0
    return 1
  fi

  # Real proof needs a profile scoped to this app id. If Apple changes key
  # spelling, fail closed here and let the launch smoke be re-run after the
  # parser is updated rather than accepting an unverified profile.
  return 1
}

fail_diagnostic() {
  local classification="$1"
  local detail="$2"
  local code="${3:-1}"
  {
    echo "FAIL: $classification"
    echo "$detail"
    echo "Artifacts: $ARTIFACT_DIR"
  } >&2
  cat > "$MANIFEST" <<EOF
{
  "verdict": "failed",
  "classification": "$classification",
  "appPath": "$app_path",
  "bundleIdentifier": "$bundle_id",
  "containerIdentifier": "$cloudkit_container",
  "artifactsDir": "$ARTIFACT_DIR"
}
EOF
  exit "$code"
}

decode_profile() {
  local source_profile="$1"
  local output_plist="$2"
  [[ -f "$source_profile" ]] || fail_diagnostic "missing-provisioning-profile" "Provisioning profile not found: $source_profile"
  security cms -D -i "$source_profile" > "$output_plist" 2>"$PROFILE_LOG" || {
    cat "$PROFILE_LOG" >&2 || true
    fail_diagnostic "invalid-provisioning-profile" "security cms could not decode the provisioning profile: $source_profile"
  }
  plutil -convert xml1 "$output_plist" >/dev/null
  plutil -lint "$output_plist" >/dev/null
}

verify_profile_for_continuum() {
  local decoded="$1"
  /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$decoded" > "$PROFILE_ENTITLEMENTS" 2>>"$PROFILE_LOG" || \
    fail_diagnostic "invalid-provisioning-profile" "Provisioning profile has no Entitlements dictionary: $decoded"
  plutil -lint "$PROFILE_ENTITLEMENTS" >/dev/null

  profile_contains_cloudkit "$decoded" || fail_diagnostic \
    "entitlement-present-but-profile-missing-cloudkit-container" \
    "The provisioning profile does not authorize CloudKit container $cloudkit_container. Manual codesign-only entitlements are known to launch-kill and are not proof."

  profile_matches_bundle_id "$decoded" || fail_diagnostic \
    "entitlement-present-but-profile-does-not-match-bundle-id" \
    "The provisioning profile app identifier does not match bundle id $bundle_id."
}

verify_app_shape() {
  local app="$1"
  [[ -d "$app" ]] || fail_diagnostic "missing-app-bundle" "App bundle not found: $app"
  [[ -f "$app/Contents/Info.plist" ]] || fail_diagnostic "invalid-app-bundle" "Missing Contents/Info.plist: $app"
  [[ -x "$app/Contents/MacOS/continuum-revived" ]] || fail_diagnostic "invalid-app-bundle" "Missing executable Contents/MacOS/continuum-revived: $app"
  local actual_bundle_id
  actual_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
  [[ "$actual_bundle_id" == "$bundle_id" ]] || fail_diagnostic "wrong-bundle-identifier" "Expected $bundle_id, got $actual_bundle_id in $app"
}

diagnose_signed_app() {
  local app="$1"
  verify_app_shape "$app"

  set +e
  codesign --verify --deep --strict --verbose=2 "$app" >"$CODESIGN_VERIFY_LOG" 2>&1
  local verify_status=$?
  codesign -dv "$app" >"$CODESIGN_DISPLAY_LOG" 2>&1
  local display_status=$?
  codesign -d --entitlements :- "$app" >"$SIGNED_ENTITLEMENTS" 2>>"$CODESIGN_DISPLAY_LOG"
  local entitlements_status=$?
  set -e

  if [[ "$verify_status" -ne 0 || "$display_status" -ne 0 ]]; then
    fail_diagnostic "unsigned-or-invalid-code-signature" "codesign verification failed for $app. See $CODESIGN_VERIFY_LOG."
  fi

  if [[ "$entitlements_status" -ne 0 ]] || ! signed_entitlements_contain_cloudkit "$SIGNED_ENTITLEMENTS"; then
    fail_diagnostic "unentitled" "The app signature does not contain CloudKit service/container entitlement $cloudkit_container. See $SIGNED_ENTITLEMENTS."
  fi

  if grep -Fq 'Signature=adhoc' "$CODESIGN_DISPLAY_LOG"; then
    fail_diagnostic "entitlement-present-but-ad-hoc-signed" "The app has the iCloud entitlement but is ad-hoc signed. That is not provisioned CloudKit proof and can be launch-killed."
  fi

  local embedded_profile="$app/Contents/embedded.provisionprofile"
  if [[ ! -f "$embedded_profile" ]]; then
    fail_diagnostic "entitlement-present-but-unprovisioned" "The app has the iCloud entitlement but no embedded provisioning profile. This is the known manual codesign-only failure mode; do not treat it as CloudKit proof."
  fi
  decode_profile "$embedded_profile" "$PROFILE_PLIST"
  verify_profile_for_continuum "$PROFILE_PLIST"

  local launch_status=0 sentinel_status=0 health_status=0
  local launch_sentinel="$ARTIFACT_DIR/launch-smoke-sentinel.txt"
  if [[ "$SKIP_LAUNCH_SMOKE" -eq 0 ]]; then
    rm -f "$launch_sentinel"
    set +e
    /usr/bin/open -n -W "$app" --args --menu-contract-check --launch-probe-sentinel "$launch_sentinel" >"$LAUNCH_LOG" 2>&1
    launch_status=$?
    set -e
    if [[ ! -f "$launch_sentinel" ]] || ! grep -Fq 'menu-contract-check passed' "$launch_sentinel"; then
      sentinel_status=1
    fi
    if [[ "$launch_status" -ne 0 || "$sentinel_status" -ne 0 ]]; then
      fail_diagnostic "entitlement-present-but-unprovisioned-or-launch-killed" "LaunchServices smoke failed for an entitlement-bearing app. This usually means the entitlement is not actually provisioned for this signature/profile pair (the known RBS Code=5 / NSPOSIX 163 class). See $LAUNCH_LOG."
    fi
  fi

  set +e
  "$app/Contents/MacOS/continuum-revived" --companion-sync-health-check >"$HEALTH_JSON" 2>"$HEALTH_ERR"
  health_status=$?
  set -e
  if [[ "$health_status" -ne 0 ]]; then
    fail_diagnostic "health-check-failed" "The signed app executable failed --companion-sync-health-check. See $HEALTH_JSON and $HEALTH_ERR."
  fi
  if ! grep -Eq '"desktopSignedWithICloudEntitlement"[[:space:]]*:[[:space:]]*true' "$HEALTH_JSON"; then
    fail_diagnostic "health-check-unentitled" "The app ran but reported desktopSignedWithICloudEntitlement=false. See $HEALTH_JSON."
  fi

  cat > "$MANIFEST" <<EOF
{
  "verdict": "passed",
  "mode": "$mode",
  "appPath": "$app",
  "bundleIdentifier": "$bundle_id",
  "containerIdentifier": "$cloudkit_container",
  "signedCloudKitEntitlement": true,
  "embeddedProvisioningProfile": true,
  "profileCloudKitContainer": true,
  "launchSmoke": "$(if [[ "$SKIP_LAUNCH_SMOKE" -eq 1 ]]; then echo skipped; else echo passed; fi)",
  "healthCheckDesktopSignedWithICloudEntitlement": true,
  "artifactsDir": "$ARTIFACT_DIR",
  "healthJSON": "$HEALTH_JSON"
}
EOF

  printf 'Provisioned CloudKit app diagnostics passed\n'
  printf 'app: %s\n' "$app"
  printf 'container: %s\n' "$cloudkit_container"
  printf 'health JSON: %s\n' "$HEALTH_JSON"
  printf 'manifest: %s\n' "$MANIFEST"
}

if [[ "$mode" == "build" ]]; then
  [[ -n "$IDENTITY" ]] || fail_diagnostic "missing-codesign-identity" "Set CONTINUUM_CODESIGN_IDENTITY or pass --identity with an Apple Development signing identity. Ad-hoc signing is not CloudKit proof."
  [[ -n "$PROFILE" ]] || fail_diagnostic "missing-provisioning-profile" "Set CONTINUUM_MACOS_PROVISIONING_PROFILE or pass --profile with a macOS provisioning profile that authorizes $bundle_id and $cloudkit_container."

  decode_profile "$PROFILE" "$PROFILE_PLIST"
  verify_profile_for_continuum "$PROFILE_PLIST"

  mkdir -p "$(dirname "$OUTPUT")"
  scripts/make-app-bundle.sh --configuration "$CONFIGURATION" --output "$OUTPUT"
  verify_app_shape "$OUTPUT"
  cp "$PROFILE" "$OUTPUT/Contents/embedded.provisionprofile"

  set +e
  codesign --force --timestamp=none --sign "$IDENTITY" --entitlements "$PROFILE_ENTITLEMENTS" "$OUTPUT" >"$CODESIGN_SIGN_LOG" 2>&1
  sign_status=$?
  set -e
  if [[ "$sign_status" -ne 0 ]]; then
    fail_diagnostic "codesign-failed" "codesign failed with the supplied identity/profile. See $CODESIGN_SIGN_LOG."
  fi
  app_path="$OUTPUT"
fi

diagnose_signed_app "$app_path"
