#!/usr/bin/env bash
set -euo pipefail

# Build only relay sources in the exact deployment toolchain; never copy app
# state, credentials or unrelated canvas work into the Docker build context.
RELAY_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RELAY_CONTEXT=$(mktemp -d "${TMPDIR:-/tmp}/array-relay-linux-check.XXXXXX")
trap 'rm -rf "$RELAY_CONTEXT"' EXIT
mkdir -p "$RELAY_CONTEXT/Sources"
cp -p "$RELAY_ROOT/Dockerfile" "$RELAY_ROOT/RelayPackage.swift" "$RELAY_CONTEXT/"
for target in ContinuumRevivedCollaborationClient ContinuumRevivedCollaborationProtocol ContinuumRevivedCollaborationService ContinuumRevivedCollaborationServiceChecks ContinuumRevivedRelayProtocol ContinuumRevivedRelayCore ContinuumRevivedRelayNIO continuum-relay ContinuumRevivedRelayCoreChecks ContinuumRevivedRelayIntegrationChecks; do
  cp -pR "$RELAY_ROOT/Sources/$target" "$RELAY_CONTEXT/Sources/$target"
done
# Under amd64 emulation SwiftPM's resource copy can fail with EINTR
# ("Interrupted system call"), which Foundation does not retry. Retry the
# build once for that error only; a real compile failure still fails.
BUILD_LOG="$RELAY_CONTEXT.build.log"
trap 'rm -rf "$RELAY_CONTEXT" "$BUILD_LOG"' EXIT
build_image() {
  docker build --platform linux/amd64 --progress plain --target checks \
    --tag array-relay-review:notification-checks "$RELAY_CONTEXT" 2>&1 | tee "$BUILD_LOG"
}
if ! build_image; then
  if grep -F 'Interrupted system call' "$BUILD_LOG" >/dev/null; then
    echo "relay linux check: build interrupted by EINTR under emulation; retrying once" >&2
    build_image
  else
    exit 1
  fi
fi
# BuildKit may reuse successful RUN layers. Execute witnesses again on every
# gate invocation so the matrix reports a witnessed run of the rebuilt image.
docker run --rm --platform linux/amd64 --network none \
  --entrypoint /src/.build/release/ContinuumRevivedRelayCoreChecks \
  array-relay-review:notification-checks
docker run --rm --platform linux/amd64 --network none \
  --entrypoint /src/.build/release/ContinuumRevivedRelayIntegrationChecks \
  array-relay-review:notification-checks
docker run --rm --platform linux/amd64 --network none \
  --entrypoint /src/.build/release/ContinuumRevivedCollaborationServiceChecks \
  array-relay-review:notification-checks
