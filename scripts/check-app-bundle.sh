#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIGURATION=debug
OUTPUT_DIR=""
BUNDLE_PATH=""

usage() {
  cat <<'USAGE'
Usage: scripts/check-app-bundle.sh [--configuration debug|release] [--output-dir <dir>] [--bundle <path>]

Builds (unless --bundle is supplied) and verifies the Array.app bundle.
Writes manifest.json, file.txt, otool-L.txt, and ghostty-artifacts.txt under the run directory.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      [[ $# -ge 2 ]] || { echo "missing value for --configuration" >&2; exit 2; }
      CONFIGURATION="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { echo "missing value for --output-dir" >&2; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --bundle)
      [[ $# -ge 2 ]] || { echo "missing value for --bundle" >&2; exit 2; }
      BUNDLE_PATH="$2"
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

case "$CONFIGURATION" in
  debug|release) ;;
  *) echo "--configuration must be debug or release" >&2; exit 2 ;;
esac

cd "$ROOT_DIR"
if [[ -z "$OUTPUT_DIR" ]]; then
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  OUTPUT_DIR="$ROOT_DIR/qa-runs/$stamp/app-bundle"
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

if [[ -z "$BUNDLE_PATH" ]]; then
  BUNDLE_PATH="$OUTPUT_DIR/Array.app"
  "$ROOT_DIR/scripts/make-app-bundle.sh" --configuration "$CONFIGURATION" --output "$BUNDLE_PATH"
fi

PLIST="$BUNDLE_PATH/Contents/Info.plist"
EXE="$BUNDLE_PATH/Contents/MacOS/Array"
RESOURCES="$BUNDLE_PATH/Contents/Resources"
FILE_LOG="$OUTPUT_DIR/file.txt"
OTOOL_LOG="$OUTPUT_DIR/otool-L.txt"
GHOSTTY_LOG="$OUTPUT_DIR/ghostty-artifacts.txt"
SELF_CHECK_LOG="$OUTPUT_DIR/self-checks.txt"
CODESIGN_LOG="$OUTPUT_DIR/codesign.txt"
LAUNCH_LOG="$OUTPUT_DIR/launchservices.txt"
LAUNCH_SENTINEL="$OUTPUT_DIR/launchservices-sentinel.txt"
MANIFEST="$OUTPUT_DIR/manifest.json"
REAL_SUPPORT="$HOME/Library/Application Support"
REAL_PREFS="$HOME/Library/Preferences"
NEW_DEFAULTS_PLIST="$REAL_PREFS/dev.arrayapp.macos.plist"
LEGACY_BUNDLED_DEFAULTS_PLIST="$REAL_PREFS/com.continuum.revived.plist"
OLD_DEFAULTS_PLIST="$REAL_PREFS/continuum-revived.plist"

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" == "$expected" ]] || { echo "FAIL: $label expected '$expected' got '$actual'" >&2; exit 1; }
}

[[ -d "$BUNDLE_PATH/Contents/MacOS" ]] || { echo "FAIL: missing Contents/MacOS" >&2; exit 1; }
[[ -d "$RESOURCES" ]] || { echo "FAIL: missing Contents/Resources" >&2; exit 1; }
[[ -f "$PLIST" ]] || { echo "FAIL: missing Info.plist" >&2; exit 1; }
[[ -x "$EXE" ]] || { echo "FAIL: missing executable $EXE" >&2; exit 1; }
plutil -lint "$PLIST" >/dev/null

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")
bundle_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")
bundle_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$PLIST")
bundle_display=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST")
bundle_package=$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$PLIST")
bundle_short_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
minimum_system=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")
icon_file=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$PLIST")

assert_eq "dev.arrayapp.macos" "$bundle_id" "CFBundleIdentifier"
assert_eq "Array" "$bundle_executable" "CFBundleExecutable"
assert_eq "Array" "$bundle_name" "CFBundleName"
assert_eq "Array" "$bundle_display" "CFBundleDisplayName"
assert_eq "APPL" "$bundle_package" "CFBundlePackageType"
assert_eq "14.0" "$minimum_system" "LSMinimumSystemVersion"
[[ -n "$bundle_short_version" ]] || { echo "FAIL: missing short version" >&2; exit 1; }
[[ -n "$bundle_version" ]] || { echo "FAIL: missing bundle version" >&2; exit 1; }
[[ -f "$RESOURCES/${icon_file%.icns}.icns" || -f "$RESOURCES/$icon_file" ]] || { echo "FAIL: missing icon resource for $icon_file" >&2; exit 1; }

/usr/bin/file "$EXE" | tee "$FILE_LOG"
/usr/bin/otool -L "$EXE" | tee "$OTOOL_LOG"
find "$BUNDLE_PATH" \( -path '*GhosttyKit*' -o -name 'libghostty*' \) -print | sort | tee "$GHOSTTY_LOG"

if find "$BUNDLE_PATH" \( -path '*ios-arm64*' -o -path '*ios-arm64-simulator*' \) -print -quit | grep -q .; then
  echo "FAIL: forbidden iOS GhosttyKit slice found in bundle" >&2
  exit 1
fi
forbidden_slices_absent=true

if grep -Eiq 'GhosttyKit|libghostty|@rpath/.*ghostty' "$OTOOL_LOG"; then
  ghostty_runtime_dependency=true
  if [[ ! -s "$GHOSTTY_LOG" ]]; then
    echo "FAIL: otool reports a Ghostty runtime dependency but no Ghostty artifact is bundled" >&2
    exit 1
  fi
else
  ghostty_runtime_dependency=false
fi

before_support=$(find "$REAL_SUPPORT" -maxdepth 1 \( -iname '*continuum*' -o -name 'Array' \) -print 2>/dev/null | sort || true)
plist_snapshot() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    printf 'absent'
  else
    plutil -convert json -o - "$path" 2>/dev/null || cat "$path"
  fi
}

cleanup_empty_created_plist() {
  local before="$1" path="$2"
  if [[ "$before" == "absent" && -e "$path" ]] && [[ "$(plist_snapshot "$path")" == "{}" ]]; then
    rm -f "$path"
  fi
}

before_new_defaults=$(plist_snapshot "$NEW_DEFAULTS_PLIST")
before_legacy_bundled_defaults=$(plist_snapshot "$LEGACY_BUNDLED_DEFAULTS_PLIST")
before_old_defaults=$(plist_snapshot "$OLD_DEFAULTS_PLIST")
project_root=$(mktemp -d "${TMPDIR:-/tmp}/continuum-bundle-project.XXXXXX")
app_support=$(mktemp -d "${TMPDIR:-/tmp}/continuum-bundle-appsupport.XXXXXX")
isolated_home=$(mktemp -d "${TMPDIR:-/tmp}/continuum-bundle-home.XXXXXX")
: > "$SELF_CHECK_LOG"
self_checks=(--palette-duplicate-root-check --file-tree-boot-persistence-check --menu-contract-check --delete-confirm-policy-defaults-check)
if [[ -n "${CONTINUUM_BUNDLE_CHECK_FORCE_FAIL:-}" ]]; then
  self_checks+=("$CONTINUUM_BUNDLE_CHECK_FORCE_FAIL")
fi
self_check_names=()
self_check_codes=()
for check in "${self_checks[@]}"; do
  printf '==> %s\n' "$check" | tee -a "$SELF_CHECK_LOG"
  set +e
  HOME="$isolated_home" \
    CFFIXED_USER_HOME="$isolated_home" \
    CONTINUUM_PROJECT_ROOT="$project_root" \
    CONTINUUM_APP_SUPPORT="$app_support" \
    "$EXE" "$check" 2>&1 | tee -a "$SELF_CHECK_LOG"
  status=${PIPESTATUS[0]}
  set -e
  self_check_names+=("$check")
  self_check_codes+=("$status")
  printf '<== %s exit %s\n' "$check" "$status" | tee -a "$SELF_CHECK_LOG"
done

set +e
{
  echo "==> codesign --force --deep --sign - $BUNDLE_PATH"
  codesign --force --deep --sign - "$BUNDLE_PATH"
  sign_status=$?
  echo "<== codesign sign exit $sign_status"
  echo "==> codesign --verify --deep --strict --verbose=2 $BUNDLE_PATH"
  codesign --verify --deep --strict --verbose=2 "$BUNDLE_PATH"
  verify_status=$?
  echo "<== codesign verify exit $verify_status"
} >"$CODESIGN_LOG" 2>&1
codesign_status=$verify_status
if [[ "$sign_status" != "0" ]]; then
  codesign_status=$sign_status
fi
set -e
cat "$CODESIGN_LOG"

launch_project_root=$(mktemp -d "${TMPDIR:-/tmp}/continuum-bundle-launch-project.XXXXXX")
launch_app_support=$(mktemp -d "${TMPDIR:-/tmp}/continuum-bundle-launch-appsupport.XXXXXX")
launch_home=$(mktemp -d "${TMPDIR:-/tmp}/continuum-bundle-launch-home.XXXXXX")
rm -f "$LAUNCH_SENTINEL"
set +e
HOME="$launch_home" \
  CFFIXED_USER_HOME="$launch_home" \
  CONTINUUM_PROJECT_ROOT="$launch_project_root" \
  CONTINUUM_APP_SUPPORT="$launch_app_support" \
  open -n -W "$BUNDLE_PATH" --args --menu-contract-check --launch-probe-sentinel "$LAUNCH_SENTINEL" >"$LAUNCH_LOG" 2>&1
open_status=$?
set -e
cat "$LAUNCH_LOG"
if [[ -f "$LAUNCH_SENTINEL" ]] && grep -q 'menu-contract-check passed' "$LAUNCH_SENTINEL"; then
  sentinel_status=0
else
  sentinel_status=1
  echo "FAIL: LaunchServices self-check sentinel missing or invalid: $LAUNCH_SENTINEL" | tee -a "$LAUNCH_LOG"
fi
launch_status=$open_status
if [[ "$sentinel_status" != "0" ]]; then
  launch_status=$sentinel_status
fi
rm -rf "$project_root" "$app_support" "$isolated_home" "$launch_project_root" "$launch_app_support" "$launch_home"
after_support=$(find "$REAL_SUPPORT" -maxdepth 1 \( -iname '*continuum*' -o -name 'Array' \) -print 2>/dev/null | sort || true)
cleanup_empty_created_plist "$before_new_defaults" "$NEW_DEFAULTS_PLIST"
cleanup_empty_created_plist "$before_legacy_bundled_defaults" "$LEGACY_BUNDLED_DEFAULTS_PLIST"
cleanup_empty_created_plist "$before_old_defaults" "$OLD_DEFAULTS_PLIST"
after_new_defaults=$(plist_snapshot "$NEW_DEFAULTS_PLIST")
after_legacy_bundled_defaults=$(plist_snapshot "$LEGACY_BUNDLED_DEFAULTS_PLIST")
after_old_defaults=$(plist_snapshot "$OLD_DEFAULTS_PLIST")
if [[ "$before_support" != "$after_support" ]]; then
  echo "FAIL: real Application Support Array/continuum entries changed" >&2
  exit 1
fi
if [[ "$before_new_defaults" != "$after_new_defaults" || "$before_legacy_bundled_defaults" != "$after_legacy_bundled_defaults" || "$before_old_defaults" != "$after_old_defaults" ]]; then
  echo "FAIL: real Array/Continuum defaults plists changed" >&2
  exit 1
fi
persistent_pollution=false
real_defaults_pollution=false

self_check_names_joined=$(IFS=$'\n'; echo "${self_check_names[*]}")
self_check_codes_joined=$(IFS=$'\n'; echo "${self_check_codes[*]}")
manifest_verdict=passed
for code in "${self_check_codes[@]}" "$codesign_status" "$launch_status"; do
  if [[ "$code" != "0" ]]; then
    manifest_verdict=failed
  fi
done

BUNDLE_PATH="$BUNDLE_PATH" PLIST="$PLIST" EXE="$EXE" OUTPUT_DIR="$OUTPUT_DIR" \
FILE_LOG="$FILE_LOG" OTOOL_LOG="$OTOOL_LOG" GHOSTTY_LOG="$GHOSTTY_LOG" SELF_CHECK_LOG="$SELF_CHECK_LOG" \
CODESIGN_LOG="$CODESIGN_LOG" LAUNCH_LOG="$LAUNCH_LOG" LAUNCH_SENTINEL="$LAUNCH_SENTINEL" \
bundle_id="$bundle_id" bundle_executable="$bundle_executable" bundle_name="$bundle_name" \
bundle_package="$bundle_package" icon_file="$icon_file" minimum_system="$minimum_system" \
forbidden_slices_absent="$forbidden_slices_absent" ghostty_runtime_dependency="$ghostty_runtime_dependency" \
persistent_pollution="$persistent_pollution" real_defaults_pollution="$real_defaults_pollution" \
defaults_key="continuum.deleteConfirmPolicy" old_defaults_domain="continuum-revived" \
isolated_home="$isolated_home" cf_fixed_user_home="$isolated_home" \
self_check_names="$self_check_names_joined" self_check_codes="$self_check_codes_joined" \
codesign_status="$codesign_status" launch_status="$launch_status" manifest_verdict="$manifest_verdict" \
MANIFEST="$MANIFEST" \
/usr/bin/python3 - <<'PY'
import json, os, pathlib
names = os.environ["self_check_names"].splitlines()
codes = [int(code) for code in os.environ["self_check_codes"].splitlines()]
self_checks = [{"name": name, "exitCode": code} for name, code in zip(names, codes)]
menu = next((item for item in self_checks if item["name"] == "--menu-contract-check"), {"name": "--menu-contract-check", "exitCode": None})
manifest = {
    "verdict": os.environ["manifest_verdict"],
    "bundlePath": os.environ["BUNDLE_PATH"],
    "infoPlist": os.environ["PLIST"],
    "executable": os.environ["EXE"],
    "bundleIdentifier": os.environ["bundle_id"],
    "bundleExecutable": os.environ["bundle_executable"],
    "bundleName": os.environ["bundle_name"],
    "bundlePackageType": os.environ["bundle_package"],
    "minimumSystemVersion": os.environ["minimum_system"],
    "iconFile": os.environ["icon_file"],
    "ghosttyRuntimeDependency": os.environ["ghostty_runtime_dependency"] == "true",
    "ghosttyForbiddenSlicesAbsent": os.environ["forbidden_slices_absent"] == "true",
    "persistentAppSupportPollution": os.environ["persistent_pollution"] == "true",
    "realDefaultsPollution": os.environ["real_defaults_pollution"] == "true",
    "menuContract": menu,
    "editMenuContract": menu,
    "defaultsDomain": os.environ["bundle_id"],
    "defaultsKey": os.environ["defaults_key"],
    "oldDefaultsDomain": os.environ["old_defaults_domain"],
    "isolatedHome": os.environ["isolated_home"],
    "cfFixedUserHome": os.environ["cf_fixed_user_home"],
    "bundleSelfChecks": self_checks,
    "codesignVerification": {"exitCode": int(os.environ["codesign_status"]), "log": os.environ["CODESIGN_LOG"]},
    "launchServicesProbe": {"command": "open -n -W <bundle> --args --menu-contract-check --launch-probe-sentinel <path>", "exitCode": int(os.environ["launch_status"]), "log": os.environ["LAUNCH_LOG"], "sentinel": os.environ["LAUNCH_SENTINEL"]},
    "fileLog": os.environ["FILE_LOG"],
    "otoolLog": os.environ["OTOOL_LOG"],
    "ghosttyArtifactsLog": os.environ["GHOSTTY_LOG"],
    "selfCheckLog": os.environ["SELF_CHECK_LOG"],
}
pathlib.Path(os.environ["MANIFEST"]).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY

if [[ "$manifest_verdict" != "passed" ]]; then
  printf 'Bundle check failed. Manifest: %s\n' "$MANIFEST" >&2
  exit 1
fi
printf 'Bundle check passed. Manifest: %s\n' "$MANIFEST"
