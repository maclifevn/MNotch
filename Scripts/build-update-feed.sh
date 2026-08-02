#!/bin/bash
# Build and sign the Sparkle feed for an already notarized MNotch ZIP.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

VERSION="${1:?usage: build-update-feed.sh VERSION ZIP RELEASE_NOTES OUTPUT_DIR [critical]}"
ZIP="${2:?missing update ZIP}"
RELEASE_NOTES="${3:?missing release notes}"
OUTPUT_DIR="${4:?missing output directory}"
CRITICAL="${5:-false}"

SPARKLE_ROOT="$ROOT/.build/artifacts/sparkle/Sparkle"
GENERATE_APPCAST="$SPARKLE_ROOT/bin/generate_appcast"
SIGN_UPDATE="$SPARKLE_ROOT/bin/sign_update"
ACCOUNT="${MNOTCH_SPARKLE_ACCOUNT:-com.mnotch.app}"
PRIVATE_KEY="${SPARKLE_PRIVATE_KEY_FILE:-}"
RELEASE_REPOSITORY="${MNOTCH_RELEASE_REPOSITORY:-maclifevn/MNotch}"
CURRENT_FEED="${MNOTCH_CURRENT_FEED_URL:-https://github.com/maclifevn/MNotch/releases/latest/download/appcast.xml}"
BOOTSTRAP="${MNOTCH_BOOTSTRAP_UPDATE_FEED:-false}"

[[ -x "$GENERATE_APPCAST" ]] || { echo "error: generate_appcast not found" >&2; exit 1; }
[[ -x "$SIGN_UPDATE" ]] || { echo "error: sign_update not found" >&2; exit 1; }
[[ -f "$ZIP" ]] || { echo "error: update ZIP not found" >&2; exit 1; }
[[ -f "$RELEASE_NOTES" ]] || { echo "error: release notes not found" >&2; exit 1; }
if [[ -n "$PRIVATE_KEY" && ! -f "$PRIVATE_KEY" ]]; then
    echo "error: SPARKLE_PRIVATE_KEY_FILE does not exist" >&2
    exit 1
fi
if [[ "$BOOTSTRAP" != "true" && "$BOOTSTRAP" != "false" ]]; then
    echo "error: MNOTCH_BOOTSTRAP_UPDATE_FEED must be true or false" >&2
    exit 1
fi

KEY_ARGS=()
if [[ -n "$PRIVATE_KEY" ]]; then
    KEY_ARGS+=(--ed-key-file "$PRIVATE_KEY")
else
    KEY_ARGS+=(--account "$ACCOUNT")
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mnotch-appcast.XXXXXX")"
ARCHIVES="$WORK_DIR/archives"
mkdir -p "$ARCHIVES" "$OUTPUT_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

# Preserve prior entries only after authenticating the signed production feed.
# Missing history is allowed only for an explicitly marked first release; this
# prevents a typo or network failure from silently replacing a live feed.
HTTP_STATUS=""
if HTTP_STATUS="$(/usr/bin/curl --fail --silent --show-error --location \
    --write-out '%{http_code}' --output "$ARCHIVES/appcast.xml" \
    "$CURRENT_FEED")"; then
    "$SIGN_UPDATE" "${KEY_ARGS[@]}" --verify "$ARCHIVES/appcast.xml"
else
    CURL_STATUS=$?
    rm -f "$ARCHIVES/appcast.xml"
    if [[ "$HTTP_STATUS" == "404" && "$BOOTSTRAP" == "true" ]]; then
        echo "No production appcast yet; creating the explicit bootstrap feed."
    else
        echo "error: could not authenticate the current appcast" >&2
        echo "       URL: $CURRENT_FEED (HTTP ${HTTP_STATUS:-unknown})" >&2
        echo "       use MNOTCH_BOOTSTRAP_UPDATE_FEED=true only for the first release" >&2
        exit "$CURL_STATUS"
    fi
fi

ARCHIVE_NAME="MNotch-${VERSION}.zip"
NOTES_NAME="MNotch-${VERSION}.md"
ditto "$ZIP" "$ARCHIVES/$ARCHIVE_NAME"
ditto "$RELEASE_NOTES" "$ARCHIVES/$NOTES_NAME"

ARGS=(
    "${KEY_ARGS[@]}"
    --download-url-prefix "https://github.com/${RELEASE_REPOSITORY}/releases/download/v${VERSION}/"
    --link "https://github.com/${RELEASE_REPOSITORY}/releases/tag/v${VERSION}"
    --embed-release-notes
    --maximum-versions 5
    --maximum-deltas 0
    --disable-signing-warning
)
if [[ "$CRITICAL" == "true" ]]; then
    ARGS+=(--critical-update-version "")
else
    # Seven daily cohorts for background checks; manual checks are immediate.
    ARGS+=(--phased-rollout-interval 86400)
fi

"$GENERATE_APPCAST" "${ARGS[@]}" "$ARCHIVES"
ditto "$ARCHIVES/appcast.xml" "$OUTPUT_DIR/appcast.xml"
ditto "$ARCHIVES/$ARCHIVE_NAME" "$OUTPUT_DIR/$ARCHIVE_NAME"
ditto "$ARCHIVES/$NOTES_NAME" "$OUTPUT_DIR/$NOTES_NAME"

SPARKLE_PRIVATE_KEY_FILE="$PRIVATE_KEY" \
MNOTCH_SPARKLE_ACCOUNT="$ACCOUNT" \
    Scripts/verify-update-feed.sh \
        "$OUTPUT_DIR/appcast.xml" \
        "$OUTPUT_DIR/$ARCHIVE_NAME" \
        "$SIGN_UPDATE" \
        "$VERSION"

echo "Signed Sparkle feed ready at $OUTPUT_DIR/appcast.xml"
