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

SPARKLE_BIN="${MNOTCH_SPARKLE_BIN:-$ROOT/.build/artifacts/sparkle/Sparkle/bin}"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
RELEASE_REPOSITORY="${MNOTCH_RELEASE_REPOSITORY:-maclifevn/MNotch}"
CURRENT_FEED="${MNOTCH_CURRENT_FEED_URL:-https://github.com/maclifevn/MNotch/releases/latest/download/appcast.xml}"
BOOTSTRAP="${MNOTCH_BOOTSTRAP_UPDATE_FEED:-false}"
CURRENT_FEED_FILE="${MNOTCH_CURRENT_FEED_FILE:-}"

[[ -x "$GENERATE_APPCAST" ]] || { echo "error: generate_appcast not found" >&2; exit 1; }
[[ -x "$SIGN_UPDATE" ]] || { echo "error: sign_update not found" >&2; exit 1; }
[[ -f "$ZIP" ]] || { echo "error: update ZIP not found" >&2; exit 1; }
[[ -f "$RELEASE_NOTES" ]] || { echo "error: release notes not found" >&2; exit 1; }
if [[ "$BOOTSTRAP" != "true" && "$BOOTSTRAP" != "false" ]]; then
    echo "error: MNOTCH_BOOTSTRAP_UPDATE_FEED must be true or false" >&2
    exit 1
fi
[[ "$CRITICAL" == "true" || "$CRITICAL" == "false" ]] || {
    echo "error: critical must be true or false" >&2; exit 1;
}
source Scripts/sparkle-signing.sh
python3 Scripts/update-metadata.py "$ZIP" "$VERSION" --signing-public-key "$SIGNING_PUBLIC_KEY" >/dev/null

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mnotch-appcast.XXXXXX")"
ARCHIVES="$WORK_DIR/archives"
mkdir -p "$ARCHIVES"
trap 'rm -rf "$WORK_DIR"' EXIT

# Preserve prior entries only after authenticating the signed production feed.
# Missing history is allowed only for an explicitly marked first release; this
# prevents a typo or network failure from silently replacing a live feed.
HTTP_STATUS=""
if [[ -n "$CURRENT_FEED_FILE" ]]; then
    if [[ -f "$CURRENT_FEED_FILE" ]]; then
        ditto "$CURRENT_FEED_FILE" "$ARCHIVES/appcast.xml"
    elif [[ "$BOOTSTRAP" != "true" ]]; then
        echo "error: current feed file is missing; bootstrap must be explicit" >&2; exit 1
    fi
elif HTTP_STATUS="$(/usr/bin/curl --fail --silent --show-error --location \
    --connect-timeout 10 --max-time 60 --max-filesize 2097152 \
    --proto '=https' --proto-redir '=https' \
    --write-out '%{http_code}' --output "$ARCHIVES/appcast.xml" \
    "$CURRENT_FEED")"; then
    : # Authenticate below before parsing or re-signing any history.
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
if [[ -f "$ARCHIVES/appcast.xml" ]]; then
    "$SIGN_UPDATE" "${KEY_ARGS[@]}" --verify "$ARCHIVES/appcast.xml"
    python3 Scripts/update-metadata.py "$ZIP" "$VERSION" --current-feed "$ARCHIVES/appcast.xml" >/dev/null
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
MNOTCH_SPARKLE_BIN="$SPARKLE_BIN" Scripts/verify-update-feed.sh \
        "$ARCHIVES/appcast.xml" \
        "$ARCHIVES/$ARCHIVE_NAME" \
        "$SIGN_UPDATE" \
        "$VERSION"

# Expose only a fully verified output, never a half-signed feed on failure.
mkdir -p "$OUTPUT_DIR"
ditto "$ARCHIVES/appcast.xml" "$OUTPUT_DIR/appcast.xml"
ditto "$ARCHIVES/$ARCHIVE_NAME" "$OUTPUT_DIR/$ARCHIVE_NAME"
ditto "$ARCHIVES/$NOTES_NAME" "$OUTPUT_DIR/$NOTES_NAME"

echo "Signed Sparkle feed ready at $OUTPUT_DIR/appcast.xml"
