#!/bin/bash
# Verify valid Sparkle signatures, then prove modified feed/archive rejection.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

APPCAST="${1:?missing appcast}"
ARCHIVE="${2:?missing archive}"
SIGN_UPDATE="${3:?missing sign_update}"
EXPECTED_VERSION="${4:?missing expected version}"
source Scripts/sparkle-signing.sh

"$SIGN_UPDATE" "${KEY_ARGS[@]}" --verify "$APPCAST"
ARCHIVE_SIGNATURE="$(python3 Scripts/update-metadata.py "$ARCHIVE" "$EXPECTED_VERSION" \
    --appcast "$APPCAST" --repository "${MNOTCH_RELEASE_REPOSITORY:-maclifevn/MNotch}" \
    --signing-public-key "$SIGNING_PUBLIC_KEY")"
"$SIGN_UPDATE" "${KEY_ARGS[@]}" --verify "$ARCHIVE" "$ARCHIVE_SIGNATURE"

TAMPER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mnotch-tamper.XXXXXX")"
trap 'rm -rf "$TAMPER_DIR"' EXIT
ditto "$APPCAST" "$TAMPER_DIR/appcast.xml"
ditto "$ARCHIVE" "$TAMPER_DIR/update.zip"

/usr/bin/ruby -e '
  file = ARGV[0]
  contents = File.binread(file)
  abort("appcast tamper marker missing") unless contents.sub!("MNotch", "MNotcx")
  File.binwrite(file, contents)
' "$TAMPER_DIR/appcast.xml"
/usr/bin/printf 'x' >> "$TAMPER_DIR/update.zip"

if "$SIGN_UPDATE" "${KEY_ARGS[@]}" --verify \
    "$TAMPER_DIR/appcast.xml" >/dev/null 2>&1; then
    echo "error: tampered appcast was accepted" >&2
    exit 1
fi
if "$SIGN_UPDATE" "${KEY_ARGS[@]}" --verify \
    "$TAMPER_DIR/update.zip" "$ARCHIVE_SIGNATURE" >/dev/null 2>&1; then
    echo "error: tampered archive was accepted" >&2
    exit 1
fi

echo "Sparkle signatures and tamper rejection passed"
