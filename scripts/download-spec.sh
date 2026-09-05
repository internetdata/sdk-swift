#!/bin/bash

# Refreshes the pinned OpenAPI spec from the published one.
#
# Sources/InternetData/openapi.yaml is what the build plugin reads, so a build
# stays reproducible and offline and the diff shows exactly which spec version
# produced the client. The generator wants the document beside its config inside
# the target rather than in a spec/ directory of its own, which is why it lives
# there rather than at the repository root.
#
# Run this deliberately, then commit the spec change alongside whatever it
# changed in the hand-written layer, so a reviewer sees both.

set -euo pipefail

cd "$(dirname "$0")/.."

SPEC_URL="${SPEC_URL:-https://s3.internetdata.io/internetdata-public/openapi/openapi.yaml}"

curl -fsS "$SPEC_URL" -o Sources/InternetData/openapi.yaml
echo "Sources/InternetData/openapi.yaml <- ${SPEC_URL}"
grep -m1 '^  version:' Sources/InternetData/openapi.yaml
