#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
unset ARRAY_AGENT_ID TMUX TMUX_PANE
export TERM=xterm-256color CONTINUUM_SKIP_UI_BASELINES=1
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
builds="$(ps -Ao command | grep -c '^/Applications/Xcode.app/.*/usr/bin/swift-build' || true)"
free="$(memory_pressure | awk '/System-wide memory free percentage/ {gsub(/%/,"",$NF); print $NF}')"
disk="$(df -g . | awk 'NR==2 {print $4}')"
if (( builds >= 4 || free < 25 || disk < 20 )); then
    echo "Resource gate refused build: builds=$builds memory=$free disk=$disk" >&2
    exit 1
fi
scratch="$(mktemp -d /tmp/array-prepass.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
cp scripts/checks/candidate-prepass-main.swift "$scratch/main.swift"
swiftc -DARRAY_CHECKS Sources/ContinuumRevived/App/CandidatePrepass.swift "$scratch/main.swift" -o "$scratch/check" </dev/null
git init -q "$scratch/repo"
mkdir -p "$scratch/repo/scripts" "$scratch/repo/docs/internals"
echo '{"version":1,"mappedLegs":0,"checks":[],"exceptions":[],"targetedOnly":[]}' > "$scratch/repo/scripts/check-coverage-manifest.json"
echo '#!/bin/bash' > "$scratch/repo/scripts/run-matrix.sh"
echo '{}' > "$scratch/repo/docs/internals/notification-senders.json"
git -C "$scratch/repo" add .
git -C "$scratch/repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'test(prepass): root' 
base="$(git -C "$scratch/repo" rev-parse HEAD)"
echo fixture > "$scratch/repo/fixture.swift"
echo 'raise SystemExit("CHECKOUT SCRIPT EXECUTED")' > "$scratch/repo/scripts/gate-prepass.py"

git -C "$scratch/repo" add .
git -C "$scratch/repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'test(prepass): candidate'
head="$(git -C "$scratch/repo" rev-parse HEAD)"
"$scratch/check" "$scratch/repo" "$base" "$PWD/Sources/ContinuumRevived/Resources/GatePrepass/evaluator.py" "$scratch/host-support" "$head" </dev/null
