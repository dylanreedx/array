#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ghostty_src="${GHOSTTY_SRC:-/Users/dylan/Library/Mobile Documents/com~apple~CloudDocs/personal/ghostty-src}"
source_framework="${ghostty_src}/macos/GhosttyKit.xcframework"
target_dir="${repo_root}/ThirdParty"
target_framework="${target_dir}/GhosttyKit.xcframework"

if [[ ! -d "${source_framework}" ]]; then
  echo "GhosttyKit.xcframework not found at: ${source_framework}" >&2
  echo "Set GHOSTTY_SRC to a local Ghostty source checkout that has macos/GhosttyKit.xcframework." >&2
  exit 1
fi

mkdir -p "${target_dir}"
rm -f "${target_framework}"
ln -s "${source_framework}" "${target_framework}"

echo "Linked ${target_framework} -> ${source_framework}"
