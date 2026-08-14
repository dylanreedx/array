#!/usr/bin/env bash
# The FAST loop for program 96's sidebar work: build, reinstall, relaunch. ~35s.
#
# WHY THIS IS ALLOWED TO SKIP THE GATES. The redesigned row reaches the screen only
# through `AgentInboxView.cardStyleOverride`, which is nil everywhere except the
# Component Lab section that sets it. A visual change to that row therefore cannot
# alter production, cannot alter what any queue-94 gate renders, and cannot alter a
# committed baseline — so running seven checks to look at a colour is ceremony, not
# verification.
#
# WHAT STILL HAS TO HAPPEN, and when:
#
#   * before a decision is LOCKED (a ruling written into S0-density-review.md, or a
#     ledger entry claiming something is true) — the artifact and the gates, because
#     that is the point at which someone starts relying on the claim;
#   * before the 96 row becomes the DEFAULT rather than an injected override — all of
#     it, plus a tmux-isolated matrix run, because at that moment it stops being a
#     preview and starts being the product;
#   * any time this touches a file outside the preview path — the cell is shared with
#     `SidebarScreenshotChecks`, and `DesignTokens.swift` is shared with the whole app.
#
# Full pass, for those moments:
#   swift build --product Array
#   .build/debug/Array --sidebar-screenshot-check
#   .build/debug/Array --sidebar-ux-check
#   .build/debug/Array --agent-inbox-check
#   .build/debug/Array --sidebar-production-corpus-check
#   .build/debug/Array --ui-probe-check
#   .build/debug/Array --ui-contrast-check
#   swift run ContinuumRevivedAgentUIChecks
#   scripts/check-color-hygiene.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# This program's OWN bundle and OWN project root, never the shared preview app and
# never Dylan's workspace. Two installs on one project root overwrite each other's
# canvas — see hazard 10 in CLAUDE.md.
export DEV_APP_PATH="${DEV_APP_PATH:-$HOME/Desktop/Array Dev 96.app}"
export DEV_PROJECT_ROOT="${DEV_PROJECT_ROOT:-$HOME/array-scratch-96}"

"$ROOT_DIR/scripts/dev-app.sh" "$@"

# `dev-app.sh` returns as soon as LaunchServices takes the launch, which is BEFORE the
# app is up. Confirm it survived: an app started from an agent's shell that dies with
# that shell looks exactly like a launch that worked.
sleep 3
if pgrep -f "$DEV_APP_PATH/Contents/MacOS/Array" >/dev/null 2>&1; then
  echo "==> up: $(pgrep -f "$DEV_APP_PATH/Contents/MacOS/Array" | tr '\n' ' ')"
  echo "==> View → Component Lab → Sidebar 96 → Live Sidebar"
else
  echo "==> NOT RUNNING — the launch did not survive" >&2
  exit 1
fi
