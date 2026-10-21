#!/bin/bash
# Create a polished drag-to-Applications DMG from the notarized release app.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/MNotch.app"
DIST_DIR="$ROOT/build/distribution"
FINAL_DMG="$DIST_DIR/MNotch.dmg"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mnotch-dmg.XXXXXX")"
RW_DMG="$WORK_DIR/MNotch-rw.dmg"
MOUNT_DIR=""
MOUNT_DEVICE=""
BACKGROUND="$WORK_DIR/background.png"

SIGN_ID="${SIGN_ID:-Developer ID Application: Anh Tuan Vu Nguyen (CF5PGH3KGK)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-MNotch-notary}"
VOLUME_NAME="MNotch"
MOUNTED=false

cleanup() {
    if [[ "$MOUNTED" == true ]]; then
        hdiutil detach "${MOUNT_DEVICE:-$MOUNT_DIR}" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

[[ -d "$APP" ]] || { echo "Missing $APP; run Scripts/notarize.sh first." >&2; exit 1; }
xcrun stapler validate "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

mkdir -p "$DIST_DIR"
swift Scripts/create-dmg-background.swift "$BACKGROUND"

# Optional headless metadata writer for release hosts without Finder automation.
# It builds the same layout directly, without opening windows or sharing mounts.
if [[ -n "${MNOTCH_DMG_LAYOUT_PYTHON:-}" ]]; then
    "$MNOTCH_DMG_LAYOUT_PYTHON" Scripts/create-dmg-headless.py \
        "$APP" "$FINAL_DMG" "$BACKGROUND"
else
# Detach any leftover "MNotch" volumes from a previous run. Otherwise the new
# image mounts as "MNotch 1/2/…", but the Finder AppleScript below targets the
# clashing name and writes the layout/.DS_Store to the WRONG volume — the final
# DMG ends up with no background.
while IFS= read -r v; do
    hdiutil detach "$v" -force >/dev/null 2>&1 || true
done < <(ls -d /Volumes/"$VOLUME_NAME"* 2>/dev/null || true)

hdiutil create \
    -size 32m \
    -fs HFS+ \
    -volname "$VOLUME_NAME" \
    -ov \
    "$RW_DMG" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG" \
    -readwrite \
    -noverify \
    -noautoopen)"
MOUNT_DEVICE="$(awk '/Apple_HFS/ {print $1}' <<<"$ATTACH_OUTPUT" | tail -1)"
MOUNT_DIR="$(sed -n 's/^.*Apple_HFS[[:space:]]*//p' <<<"$ATTACH_OUTPUT" | tail -1)"
MOUNTED=true
[[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]] || {
    echo "Could not determine mounted DMG path." >&2
    exit 1
}
# The real volume name as mounted (should be exactly "$VOLUME_NAME" now that we
# cleaned up, but target whatever actually mounted so Finder never picks a
# clashing volume).
ACTUAL_VOLUME="$(basename "$MOUNT_DIR")"

ditto "$APP" "$MOUNT_DIR/MNotch.app"
ln -s /Applications "$MOUNT_DIR/Applications"
mkdir -p "$MOUNT_DIR/.background"
cp "$BACKGROUND" "$MOUNT_DIR/.background/background.png"
cp "$ROOT/Support/AppIcon.icns" "$MOUNT_DIR/.VolumeIcon.icns"

SETFILE="$(command -v SetFile || command -v setfile || true)"
if [[ -n "$SETFILE" ]]; then
    "$SETFILE" -a V "$MOUNT_DIR/.background"
    "$SETFILE" -a V "$MOUNT_DIR/.VolumeIcon.icns"
    "$SETFILE" -a C "$MOUNT_DIR"
fi

# Finder owns .DS_Store layout metadata. Keep this script native and avoid a
# third-party create-dmg dependency.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$ACTUAL_VOLUME"
        open
        tell container window
            set current view to icon view
            set toolbar visible to false
            set statusbar visible to false
            set pathbar visible to false
            set sidebar width to 0
            set bounds to {160, 140, 800, 550}
        end tell
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 104
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.png"
        set position of item "MNotch.app" to {160, 205}
        set position of item "Applications" to {480, 205}
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

# Finder writes the .DS_Store (window layout + background reference)
# asynchronously. Detaching too early is why the mounted image looked right but
# the final DMG lost its background — wait for the flush and confirm it landed.
sync
for _ in 1 2 3 4 5 6; do
    [[ -f "$MOUNT_DIR/.DS_Store" ]] && break
    sleep 1
done
sleep 2
[[ -f "$MOUNT_DIR/.DS_Store" ]] || echo "warning: .DS_Store not written; DMG may lack its background" >&2
# Make the volume read-only-ish so the layout sticks through conversion.
chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true
sync

hdiutil detach "$MOUNT_DEVICE" >/dev/null 2>&1 \
    || hdiutil detach "$MOUNT_DIR" -force >/dev/null
MOUNTED=false

rm -f "$FINAL_DMG"
hdiutil convert "$RW_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$FINAL_DMG" >/dev/null

fi

codesign --force --sign "$SIGN_ID" --timestamp "$FINAL_DMG"
hdiutil verify "$FINAL_DMG" >/dev/null

xcrun notarytool submit "$FINAL_DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$FINAL_DMG"
xcrun stapler validate "$FINAL_DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$FINAL_DMG"

echo "Notarized disk image: $FINAL_DMG"
