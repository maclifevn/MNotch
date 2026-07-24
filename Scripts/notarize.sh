#!/bin/bash
# Build, Developer ID sign, notarize, staple and package MNotch for sharing.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/MNotch.app"
DIST_DIR="$ROOT/build/distribution"
SUBMISSION_ZIP="$DIST_DIR/MNotch-notarization.zip"
FINAL_ZIP="$DIST_DIR/MNotch.zip"

SIGN_ID="${SIGN_ID:-Developer ID Application: Anh Tuan Vu Nguyen (CF5PGH3KGK)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-MNotch-notary}"

CONFIG=release SIGN_ID="$SIGN_ID" Scripts/build.sh

codesign --verify --deep --strict --verbose=2 "$APP"
SIGN_INFO="$(codesign -d --verbose=4 "$APP" 2>&1)"
grep -q 'Runtime Version' <<<"$SIGN_INFO"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
ditto -c -k --keepParent "$APP" "$SUBMISSION_ZIP"

xcrun notarytool submit "$SUBMISSION_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# Package again after stapling so the distributed copy contains its ticket and
# can be validated even when the recipient is offline.
ditto -c -k --keepParent "$APP" "$FINAL_ZIP"
rm -f "$SUBMISSION_ZIP"

echo "Notarized distribution: $FINAL_ZIP"
