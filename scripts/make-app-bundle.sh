#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIGURATION=release
OUTPUT=""
CHANNEL=dev

usage() {
  cat <<'USAGE'
Usage: scripts/make-app-bundle.sh [--configuration debug|release] [--channel dev|prod] --output <path>

Builds the SwiftPM Array executable and assembles a macOS .app bundle.
Channel split: the DEFAULT is the dev channel (bundle id dev.arrayapp.macos.dev,
name "Array Dev", own Application Support dir and defaults domain, updater
inert) — only the release pipeline passes --channel prod. This bundle is
unsigned/unprovisioned CloudKit-wise; use scripts/provisioned-cloudkit-app.sh
for real iCloud/CloudKit proof.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      [[ $# -ge 2 ]] || { echo "missing value for --configuration" >&2; exit 2; }
      CONFIGURATION="$2"
      shift 2
      ;;
    --channel)
      [[ $# -ge 2 ]] || { echo "missing value for --channel" >&2; exit 2; }
      CHANNEL="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "missing value for --output" >&2; exit 2; }
      OUTPUT="$2"
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

case "$CHANNEL" in
  dev|prod) ;;
  *) echo "--channel must be dev or prod" >&2; exit 2 ;;
esac

[[ -n "$OUTPUT" ]] || { echo "--output <path> is required" >&2; usage >&2; exit 2; }

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION" --product Array

BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
EXECUTABLE="$BUILD_DIR/Array"
PLIST_SOURCE="$ROOT_DIR/Packaging/Info.plist"
ICON_SOURCE="$ROOT_DIR/Packaging/AppIcon.icns"
BRAND_MARK_SOURCE="$ROOT_DIR/docs/38-tickets/96-agent-sidebar-product-redesign/brand-marks"
AGENT_SOUND_SOURCE="$ROOT_DIR/Resources/AgentSounds"
# Sparkle ships as an SPM binary artifact; layout pinned 2026-08-09 (Sparkle
# 2.9.5): bin/ tools + the xcframework live under .build/artifacts/sparkle.
SPARKLE_FRAMEWORK="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

# ContinuumRevivedCore declares SwiftPM resources (C8: continuum-spawn-agent.ts,
# Pi's spawn_agent extension). SwiftPM's generated Bundle.module accessor
# expects this bundle next to the executable (`Bundle.main.bundleURL`, which
# for a bare binary IS the executable's directory) — that layout doesn't exist
# inside a real .app, and codesign refuses to sign an executable with sibling
# content sitting outside Contents/ ("unsealed contents present in the bundle
# root"), so the bundle ships at the ordinary Contents/Resources location
# instead. PiExtensionInstaller resolves it there directly rather than via
# Bundle.module. Building the bundle but leaving it out of this copy step is
# exactly the shipped-but-not-bundled failure this ticket exists to end.
CORE_RESOURCE_BUNDLE="continuum-revived_ContinuumRevivedCore.bundle"
CORE_RESOURCE_BUNDLE_SOURCE="$BUILD_DIR/$CORE_RESOURCE_BUNDLE"

[[ -x "$EXECUTABLE" ]] || { echo "built executable not found: $EXECUTABLE" >&2; exit 1; }
[[ -f "$PLIST_SOURCE" ]] || { echo "Info.plist source not found: $PLIST_SOURCE" >&2; exit 1; }
[[ -f "$ICON_SOURCE" ]] || { echo "icon source not found: $ICON_SOURCE" >&2; exit 1; }
[[ -d "$BRAND_MARK_SOURCE" ]] || { echo "brand marks not found: $BRAND_MARK_SOURCE" >&2; exit 1; }
[[ -f "$AGENT_SOUND_SOURCE/manifest.json" ]] || { echo "agent sound manifest not found" >&2; exit 1; }
[[ -d "$SPARKLE_FRAMEWORK" ]] || { echo "Sparkle.framework not found: $SPARKLE_FRAMEWORK (run swift build first)" >&2; exit 1; }
[[ -d "$CORE_RESOURCE_BUNDLE_SOURCE" ]] || { echo "Core resource bundle not found: $CORE_RESOURCE_BUNDLE_SOURCE (run swift build first)" >&2; exit 1; }

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources" "$OUTPUT/Contents/Frameworks"
cp "$EXECUTABLE" "$OUTPUT/Contents/MacOS/Array"
chmod 0755 "$OUTPUT/Contents/MacOS/Array"
cp "$PLIST_SOURCE" "$OUTPUT/Contents/Info.plist"
cp "$ICON_SOURCE" "$OUTPUT/Contents/Resources/AppIcon.icns"
ditto "$CORE_RESOURCE_BUNDLE_SOURCE" "$OUTPUT/Contents/Resources/$CORE_RESOURCE_BUNDLE"
mkdir -p "$OUTPUT/Contents/Resources/BrandMarks"
for mark in anthropic.svg gemini.svg openai-light.svg xai-light.svg; do
  [[ -f "$BRAND_MARK_SOURCE/$mark" ]] || { echo "brand mark not found: $mark" >&2; exit 1; }
  cp "$BRAND_MARK_SOURCE/$mark" "$OUTPUT/Contents/Resources/BrandMarks/$mark"
done
ditto "$AGENT_SOUND_SOURCE" "$OUTPUT/Contents/Resources/AgentSounds"

# Channel stamping: Packaging/Info.plist carries the PROD identity; the dev
# channel re-stamps so macOS keys everything (prefs, LaunchServices, the
# in-app channel checks) off a distinct identity. Executable name stays Array.
if [[ "$CHANNEL" == "dev" ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.arrayapp.macos.dev' "$OUTPUT/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName "Array Dev"' "$OUTPUT/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName "Array Dev"' "$OUTPUT/Contents/Info.plist"
fi

# Sparkle: SwiftPM links the executable against @rpath/Sparkle.framework/… but
# only stamps rpaths for the bare-binary layout (@loader_path). Embed the
# framework where a bundle expects it and add the matching rpath.
ditto "$SPARKLE_FRAMEWORK" "$OUTPUT/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$OUTPUT/Contents/MacOS/Array"
# install_name_tool invalidates the linker's ad-hoc signature and arm64 refuses
# to run unsigned binaries; re-sign ad hoc (release-app.sh re-signs with
# Developer ID over this).
codesign --force --sign - "$OUTPUT/Contents/MacOS/Array"

# GhosttyKit is currently linked statically by SwiftPM. Do not copy the full
# xcframework unless a future otool -L check shows a runtime Ghostty dependency.
plutil -lint "$OUTPUT/Contents/Info.plist" >/dev/null

printf 'Assembled %s (channel: %s)\n' "$OUTPUT" "$CHANNEL"
printf 'CloudKit proof: no (unsigned/unprovisioned). Use scripts/provisioned-cloudkit-app.sh with a matching identity/profile.\n'
