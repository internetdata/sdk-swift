#!/bin/bash

# Builds and runs the suite inside the official Swift image.
#
# Swift needs no local toolchain this way. The build directory stays inside the
# container and goes with it, so a run can neither leave a root-owned .build in
# the checkout nor pile builds up on disk; only fetched dependencies persist, in
# a volume per toolchain. Pass extra swift arguments through:
#
#   ./scripts/test.sh                       # the whole suite
#   ./scripts/test.sh --filter Conformance  # one suite
#   INTERNETDATA_LIVE=1 ./scripts/test.sh   # including the live checks

set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="${SWIFT_IMAGE:-swift:6.3}"
COMMAND="${SWIFT_COMMAND:-test}"

SLUG="$(echo "$IMAGE" | tr ':/.' '---')"

exec docker run --rm \
    -v "$PWD:/pkg" -w /pkg \
    -v "internetdata-swift-cache-${SLUG}:/cache" \
    -e INTERNETDATA_LIVE \
    -e INTERNETDATA_API_KEY \
    "$IMAGE" \
    swift "$COMMAND" --scratch-path /build --cache-path /cache "$@"
