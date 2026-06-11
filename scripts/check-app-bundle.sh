#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIGURATION=debug
OUTPUT_DIR=""
BUNDLE_PATH=""

usage() {
  cat <<'USAGE'
Usage: scripts/check-app-bundle.sh [--configuration debug|release] [--output-dir <dir>] [--bundle <path>]

Builds (unless --bundle is supplied) and verifies the ContinuumRevived.app bundle.
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

if [[ -z "$BUNDLE_PATH" ]]; then
  BUNDLE_PATH="$OUTPUT_DIR/ContinuumRevived.app"
  "$ROOT_DIR/scripts/make-app-bundle.sh" --configuration "$CONFIGURATION" --output "$BUNDLE_PATH"
fi

PLIST="$BUNDLE_PATH/Contents/Info.plist"
EXE="$BUNDLE_PATH/Contents/MacOS/continuum-revived"
RESOURCES="$BUNDLE_PATH/Contents/Resources"
FILE_LOG="$OUTPUT_DIR/file.txt"
OTOOL_LOG="$OUTPUT_DIR/otool-L.txt"
GHOSTTY_LOG="$OUTPUT_DIR/ghostty-artifacts.txt"
SELF_CHECK_LOG="$OUTPUT_DIR/self-checks.txt"
MANIFEST="$OUTPUT_DIR/manifest.json"
REAL_SUPPORT="$HOME/Library/Application Support"
REAL_PREFS="$HOME/Library/Preferences"
NEW_DEFAULTS_PLIST="$REAL_PREFS/com.continuum.revived.plist"
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

assert_eq "com.continuum.revived" "$bundle_id" "CFBundleIdentifier"
assert_eq "continuum-revived" "$bundle_executable" "CFBundleExecutable"
assert_eq "Continuum Revived" "$bundle_name" "CFBundleName"
assert_eq "Continuum Revived" "$bundle_display" "CFBundleDisplayName"
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

before_support=$(find "$REAL_SUPPORT" -maxdepth 1 -iname '*continuum*' -print 2>/dev/null | sort || true)
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
before_old_defaults=$(plist_snapshot "$OLD_DEFAULTS_PLIST")
project_root=$(mktemp -d "${TMPDIR:-/tmp}/continuum-bundle-project.XXXXXX")
app_support=$(mktemp -d "${TMPDIR:-/tmp}/continuum-bundle-appsupport.XXXXXX")
isolated_home=$(mktemp -d "${TMPDIR:-/tmp}/continuum-bundle-home.XXXXXX")
: > "$SELF_CHECK_LOG"
self_checks=(--palette-duplicate-root-check --file-tree-boot-persistence-check --menu-contract-check --delete-confirm-policy-defaults-check)
for check in "${self_checks[@]}"; do
  printf '==> %s\n' "$check" | tee -a "$SELF_CHECK_LOG"
  HOME="$isolated_home" \
    CFFIXED_USER_HOME="$isolated_home" \
    CONTINUUM_PROJECT_ROOT="$project_root" \
    CONTINUUM_APP_SUPPORT="$app_support" \
    "$EXE" "$check" 2>&1 | tee -a "$SELF_CHECK_LOG"
done
rm -rf "$project_root" "$app_support" "$isolated_home"
after_support=$(find "$REAL_SUPPORT" -maxdepth 1 -iname '*continuum*' -print 2>/dev/null | sort || true)
cleanup_empty_created_plist "$before_new_defaults" "$NEW_DEFAULTS_PLIST"
cleanup_empty_created_plist "$before_old_defaults" "$OLD_DEFAULTS_PLIST"
after_new_defaults=$(plist_snapshot "$NEW_DEFAULTS_PLIST")
after_old_defaults=$(plist_snapshot "$OLD_DEFAULTS_PLIST")
if [[ "$before_support" != "$after_support" ]]; then
  echo "FAIL: real Application Support continuum entries changed" >&2
  exit 1
fi
if [[ "$before_new_defaults" != "$after_new_defaults" || "$before_old_defaults" != "$after_old_defaults" ]]; then
  echo "FAIL: real Continuum defaults plists changed" >&2
  exit 1
fi
persistent_pollution=false
real_defaults_pollution=false

BUNDLE_PATH="$BUNDLE_PATH" PLIST="$PLIST" EXE="$EXE" OUTPUT_DIR="$OUTPUT_DIR" \
FILE_LOG="$FILE_LOG" OTOOL_LOG="$OTOOL_LOG" GHOSTTY_LOG="$GHOSTTY_LOG" SELF_CHECK_LOG="$SELF_CHECK_LOG" \
bundle_id="$bundle_id" bundle_executable="$bundle_executable" bundle_name="$bundle_name" \
bundle_package="$bundle_package" icon_file="$icon_file" minimum_system="$minimum_system" \
forbidden_slices_absent="$forbidden_slices_absent" ghostty_runtime_dependency="$ghostty_runtime_dependency" \
persistent_pollution="$persistent_pollution" real_defaults_pollution="$real_defaults_pollution" \
defaults_key="continuum.deleteConfirmPolicy" old_defaults_domain="continuum-revived" \
isolated_home="$isolated_home" cf_fixed_user_home="$isolated_home" \
MANIFEST="$MANIFEST" \
uv run python - <<'PY'
import json, os, pathlib
manifest = {
    "verdict": "passed",
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
    "menuContract": {"name": "--menu-contract-check", "exitCode": 0},
    "editMenuContract": {"name": "--menu-contract-check", "exitCode": 0},
    "defaultsDomain": os.environ["bundle_id"],
    "defaultsKey": os.environ["defaults_key"],
    "oldDefaultsDomain": os.environ["old_defaults_domain"],
    "isolatedHome": os.environ["isolated_home"],
    "cfFixedUserHome": os.environ["cf_fixed_user_home"],
    "bundleSelfChecks": [
        {"name": "--palette-duplicate-root-check", "exitCode": 0},
        {"name": "--file-tree-boot-persistence-check", "exitCode": 0},
        {"name": "--menu-contract-check", "exitCode": 0},
        {"name": "--delete-confirm-policy-defaults-check", "exitCode": 0},
    ],
    "fileLog": os.environ["FILE_LOG"],
    "otoolLog": os.environ["OTOOL_LOG"],
    "ghosttyArtifactsLog": os.environ["GHOSTTY_LOG"],
    "selfCheckLog": os.environ["SELF_CHECK_LOG"],
}
pathlib.Path(os.environ["MANIFEST"]).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY

printf 'Bundle check passed. Manifest: %s\n' "$MANIFEST"
