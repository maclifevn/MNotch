#!/bin/bash
# Build MediaRemoteAdapter.framework + TestClient from vendored source
# (ungive/mediaremote-adapter, BSD-3) with raw clang — no cmake, no Xcode.
set -euo pipefail

cd "$(dirname "$0")/.."
V="$PWD/Vendor/mediaremote-adapter"
OUT="$V/build"
FW="$OUT/MediaRemoteAdapter.framework"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"

rm -rf "$OUT"
mkdir -p "$FW/Versions/A/Resources" "$OUT/objects"

ADAPTER_SOURCES=(
    "$V"/src/adapter/*.m
    "$V"/src/private/*.m
    "$V"/src/utility/*.m
)

# dsymutil needs the compilation objects to exist. A compile-and-link command
# with multiple .m inputs deletes its temporary objects before dsymutil runs.
ADAPTER_OBJECTS=()
for source in "${ADAPTER_SOURCES[@]}"; do
    object="$OUT/objects/$(basename "${source%.m}").o"
    clang -c -fobjc-arc -fvisibility=default -O2 -g -arch arm64 \
        -mmacosx-version-min="$DEPLOYMENT_TARGET" -I"$V/include" -I"$V/src" \
        "$source" -o "$object"
    ADAPTER_OBJECTS+=("$object")
done

clang -dynamiclib -fobjc-arc -O2 -g -arch arm64 -mmacosx-version-min="$DEPLOYMENT_TARGET" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name "@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" \
    "${ADAPTER_OBJECTS[@]}" \
    -o "$FW/Versions/A/MediaRemoteAdapter"

cat > "$FW/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.vandenbe.MediaRemoteAdapter</string>
	<key>CFBundleName</key>
	<string>MediaRemoteAdapter</string>
	<key>CFBundleExecutable</key>
	<string>MediaRemoteAdapter</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>0.1.0</string>
</dict>
</plist>
PLIST

ln -s A "$FW/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
ln -s Versions/Current/Resources "$FW/Resources"

clang -fobjc-arc -O2 -g -arch arm64 -mmacosx-version-min="$DEPLOYMENT_TARGET" \
    -I"$V/src/test" \
    -framework Foundation -framework MediaPlayer \
    "$V"/src/test/*.m \
    -o "$OUT/MediaRemoteAdapterTestClient"

xcrun dsymutil "$FW/Versions/A/MediaRemoteAdapter" -o "$OUT/MediaRemoteAdapter.framework.dSYM"
codesign --force --sign - "$FW"
codesign --force --sign - "$OUT/MediaRemoteAdapterTestClient"

echo "Built $FW"
