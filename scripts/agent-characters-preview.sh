#!/usr/bin/env bash
# Builds Dylan's agent-characters preview (.plans/110-agent-characters/PREVIEW.md).
# It never launches it: Dylan does, with the line this prints.
#
#   bundle   ~/array-scratch/apps/Array Characters.app (remove when the program closes)
#   identity dev.arrayapp.macos.characters: its own defaults and TCC identity, and
#            the identity that opens the preview mode instead of the full app
#   store    ~/array-scratch-characters-support via CONTINUUM_APP_SUPPORT
#
# The preview is production views (sidebar, agent tiles, canvas) on a real
# supervisor that runs no CLI; scripted runtime events walk eight agents through
# every state. Characters are on.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${CHARACTERS_APP_PATH:-$HOME/array-scratch/apps/Array Characters.app}"
SUPPORT="${CHARACTERS_APP_SUPPORT:-$HOME/array-scratch-characters-support}"
mkdir -p "$(dirname "$APP_PATH")" "$SUPPORT"

"$ROOT_DIR/scripts/make-app-bundle.sh" --configuration debug --output "$APP_PATH" \
  --bundle-id dev.arrayapp.macos.characters --name "Array Characters"

echo "==> built $APP_PATH"
echo "==> launch it with:"
echo "open --env CONTINUUM_APP_SUPPORT=\"$SUPPORT\" \"$APP_PATH\""
