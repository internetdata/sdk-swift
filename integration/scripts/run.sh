#!/bin/bash

# Runs the integration suite against the package as PUBLISHED, which is the one
# thing the suite in ../Tests cannot check: it builds this working tree, so it
# stays green through a tag that never landed, a product a consumer cannot name,
# or a build plugin that only ever ran for us.
#
#   ./scripts/run.sh
#   SDK_LOCAL_PATH=.. ./scripts/run.sh    # verify this suite before a tag exists
#
# Two conditions make a run meaningless rather than failing, and each one skips
# with a reason instead:
#
#   1. Nothing published satisfies the declared range. SwiftPM resolves a
#      version from a git TAG, so before the first release there is no artifact.
#   2. The staging key is missing or EMPTY. Every endpoint here needs a bearer
#      key, so without one there is nothing to exercise at all; the suite skips
#      from the inside, naming the secret, rather than failing.
#
# Swift runs natively when the toolchain is present and inside the official
# image otherwise, so a dev box with no Swift and a CI container both use this
# one entry point.

set -euo pipefail

cd "$(dirname "$0")/.."

PACKAGE_URL="https://github.com/internetdata/sdk-swift.git"
# Mirrors the range in Package.swift. Both are read by hand rather than parsed:
# a manifest is Swift, and the gate has to run before anything is built.
RANGE_LOW="1.0.0"
RANGE_HIGH="2.0.0"
SECRET="INTERNETDATA_STAGING_KEY"

IMAGE="${SWIFT_IMAGE:-swift:6.3}"
LOCAL_PATH="${SDK_LOCAL_PATH:-}"

function main() {
    local versions=""
    if [ -n "$LOCAL_PATH" ] ; then
        echo "==> LOCAL: building against $LOCAL_PATH, NOT the published package."
        echo "==> This verifies the suite, and proves nothing about a release."
    else
        versions="$(published_versions)"
        if [ -z "$versions" ] ; then
            skip "no ${RANGE_LOW} <= tag < ${RANGE_HIGH} exists at ${PACKAGE_URL}," \
                "so there is no published artifact to test"
            return 0
        fi
        echo "==> ${PACKAGE_URL} publishes ${versions//$'\n'/, } within [${RANGE_LOW}, ${RANGE_HIGH})"
    fi

    report_credential

    # Both removed so every run resolves the range afresh. A kept Package.resolved
    # would pin whatever the first run happened to pick, and the daily run would
    # stop noticing new releases.
    rm -f Package.resolved
    rm -rf .build

    swift_run package resolve
    if [ -z "$LOCAL_PATH" ] ; then
        assert_resolved_from_git "$versions"
    fi
    swift_run test
}

# `git ls-remote` reads the same tags SwiftPM resolves from, so the range is
# evaluated against exactly what a consumer would get. A repo with no matching
# tag and a repo with no tags at all mean the same thing here.
function published_versions() {
    local refs tag
    refs="$(git ls-remote --tags --refs "$PACKAGE_URL" 2>/dev/null || true)"
    # Not a pipeline: a `while` whose last iteration skips a tag exits non-zero,
    # which `set -e` would read as the lookup itself having failed.
    while read -r tag ; do
        if [ -n "$tag" ] && in_range "$tag" ; then
            echo "$tag"
        fi
    done < <(printf '%s\n' "$refs" | sed -n 's#.*refs/tags/v\{0,1\}\([0-9]\+\.[0-9]\+\.[0-9]\+\)$#\1#p')
    return 0
}

function in_range() {
    local tag="$1"
    local lowest highest
    lowest="$(printf '%s\n%s\n' "$tag" "$RANGE_LOW" | sort -V | head -1)"
    highest="$(printf '%s\n%s\n' "$tag" "$RANGE_HIGH" | sort -V | head -1)"
    [ "$lowest" = "$RANGE_LOW" ] && [ "$highest" = "$tag" ] && [ "$tag" != "$RANGE_HIGH" ]
}

# The suite is worthless if SwiftPM built a local checkout instead, and that
# failure is silent: every test passes, against the wrong code. A path
# dependency is never pinned, so an entry naming the remote at a published
# version is the proof that the resolver went to the network.
function assert_resolved_from_git() {
    local versions="$1" resolved
    # Whitespace-stripped and matched as one string rather than parsed: the
    # official Swift image carries no python, jq or any other JSON reader, and
    # SwiftPM writes the pins with its keys in a fixed order.
    resolved="$(tr -d ' \n' < Package.resolved \
        | grep -o "\"location\":\"${PACKAGE_URL}\",\"state\":{[^}]*}" \
        | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' || true)"
    if [ -z "$resolved" ] ; then
        echo "FAILED: Package.resolved pins no version of ${PACKAGE_URL}," \
            "so the tests would run against something other than the release" >&2
        exit 1
    fi
    if ! printf '%s\n' "$versions" | grep -qx "$resolved" ; then
        echo "FAILED: resolved ${resolved}, which is not one of ${versions//$'\n'/, }" >&2
        exit 1
    fi
    echo "==> resolved sdk-swift ${resolved} from ${PACKAGE_URL}"
}

# Names only, never values: these logs are public.
function report_credential() {
    # Empty counts as absent: CI interpolates a secret that does not exist to an
    # empty string, so the variable is SET and a plain unset check never fires,
    # while an empty key is sent as no key at all.
    if [ -n "${!SECRET:-}" ] ; then
        echo "==> ${SECRET} is present"
        return 0
    fi
    notice "no ${SECRET}: every test skips from inside the suite, naming the secret"
}

function swift_run() {
    echo "==> swift $*"
    if command -v swift >/dev/null 2>&1 ; then
        if [ -n "$LOCAL_PATH" ] ; then
            INTERNETDATA_SDK_LOCAL_PATH="$(local_checkout)" swift "$@"
        else
            swift "$@"
        fi
        return 0
    fi
    # One build volume per toolchain: a scratch path shared between two Swift
    # versions fails the moment you switch images.
    local slug
    slug="$(echo "$IMAGE" | tr ':/.' '---')"
    local args=(
        --rm -v "$PWD:/pkg" -w /pkg
        -v "internetdata-swift-integration-${slug}:/build"
        -e "$SECRET"
    )
    if [ -n "$LOCAL_PATH" ] ; then
        args+=(-v "$(cd "$LOCAL_PATH" && pwd):/sdk-swift" -e INTERNETDATA_SDK_LOCAL_PATH=/sdk-swift)
    fi
    docker run "${args[@]}" "$IMAGE" swift "$@" --scratch-path /build
}

# SwiftPM takes a local package's identity from its DIRECTORY NAME, and the
# manifest names the product against `sdk-swift`, so a checkout in a directory
# called anything else does not resolve at all. Under docker the mount point
# settles it; natively, a symlink does.
function local_checkout() {
    local target
    target="$(cd "$LOCAL_PATH" && pwd)"
    if [ "$(basename "$target")" = "sdk-swift" ] ; then
        echo "$target"
        return 0
    fi
    local link="${TMPDIR:-/tmp}/internetdata-sdk-swift-$$/sdk-swift"
    mkdir -p "$(dirname "$link")"
    ln -sfn "$target" "$link"
    echo "$link"
}

function skip() {
    echo "==> SKIPPED: $*"
    notice "Integration suite skipped: $*"
}

# Surfaced on the workflow run itself, so a skip is visible without opening the
# log and reading to the end of it.
function notice() {
    if [ "${GITHUB_ACTIONS:-}" = "true" ] ; then
        echo "::notice title=Integration::$*"
    fi
}

main "$@"
