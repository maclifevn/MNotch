#!/bin/bash
# Build MNotch.app from the SwiftPM executable — no Xcode required.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/MNotch.app"
VERSION="${VERSION:-0.1.0}"
BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# Stable signing identity keeps TCC grants (Accessibility, Calendar, Bluetooth)
# across rebuilds. Falls back to ad-hoc if the cert doesn't exist —
# see Scripts/sign-cert-setup.md to create "MNotch Dev" once.
SIGN_ID="${SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "MNotch Dev"; then
        SIGN_ID="MNotch Dev"
    else
        SIGN_ID="-"
    fi
fi

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG" --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$ROOT/.build/arm64-apple-macosx/$CONFIG/MNotch" "$APP/Contents/MacOS/MNotch"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUM/" \
    "$ROOT/Support/Info.plist" > "$APP/Contents/Info.plist"

cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/"

# MediaRemote adapter (vendored source from ungive/mediaremote-adapter, BSD-3)
ADAPTER_DIR="$ROOT/Vendor/mediaremote-adapter"
if [[ ! -d "$ADAPTER_DIR/build/MediaRemoteAdapter.framework" ]]; then
    Scripts/build-adapter.sh
fi
cp -R "$ADAPTER_DIR/build/MediaRemoteAdapter.framework" "$APP/Contents/Frameworks/"
cp "$ADAPTER_DIR/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
cp "$ADAPTER_DIR/build/MediaRemoteAdapterTestClient" "$APP/Contents/Resources/"

# Agent hook relay (installed into ~/.claude/settings.json at runtime)
cp "$ROOT/Vendor/agent-relay/mnotch-relay.pl" "$APP/Contents/Resources/"

codesign --force --deep -s "$SIGN_ID" "$APP"

echo "Built $APP (version $VERSION build $BUILD_NUM, signed: $SIGN_ID)"
