#!/bin/bash

# Builds and runs the suite inside the official Swift image.
#
# Swift needs no local toolchain this way, and the build directory lives in a
# named volume rather than in the checkout, so a container run cannot leave a
# root-owned .build behind. Pass extra swift arguments through:
#
#   ./scripts/test.sh                       # the whole suite
#   ./scripts/test.sh --filter Conformance  # one suite
#   INTERNETDATA_LIVE=1 ./scripts/test.sh   # including the live checks

set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="${SWIFT_IMAGE:-swift:6.3}"
COMMAND="${SWIFT_COMMAND:-test}"

# One build volume per toolchain: a scratch path shared between two Swift
# versions fails with "module compiled with Swift X cannot be imported by the
# Swift Y compiler" the moment you switch images.
SLUG="$(echo "$IMAGE" | tr ':/.' '---')"

exec docker run --rm \
    -v "$PWD:/pkg" -w /pkg \
    -v "internetdata-swift-build-${SLUG}:/build" \
    -v "internetdata-swift-cache-${SLUG}:/cache" \
    -e INTERNETDATA_LIVE \
    -e INTERNETDATA_API_KEY \
    "$IMAGE" \
    swift "$COMMAND" --scratch-path /build --cache-path /cache "$@"
