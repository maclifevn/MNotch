#!/bin/bash
# Verify valid Sparkle signatures, then prove modified feed/archive rejection.
set -euo pipefail

APPCAST="${1:?missing appcast}"
ARCHIVE="${2:?missing archive}"
SIGN_UPDATE="${3:?missing sign_update}"
EXPECTED_VERSION="${4:-}"
PRIVATE_KEY="${SPARKLE_PRIVATE_KEY_FILE:-}"
ACCOUNT="${MNOTCH_SPARKLE_ACCOUNT:-com.mnotch.app}"

KEY_ARGS=()
if [[ -n "$PRIVATE_KEY" ]]; then
    KEY_ARGS+=(--ed-key-file "$PRIVATE_KEY")
else
    KEY_ARGS+=(--account "$ACCOUNT")
fi

ARCHIVE_SIGNATURE="$(/usr/bin/ruby -r rexml/document -e '
  doc = REXML::Document.new(File.read(ARGV[0]))
  enclosure = REXML::XPath.first(doc, "//*[local-name()=\"enclosure\"]")
  abort("appcast enclosure missing") unless enclosure
  enclosure.attributes.each_attribute do |attribute|
    if attribute.expanded_name.end_with?("edSignature")
      puts attribute.value
      exit
    end
  end
  abort("archive signature missing")
' "$APPCAST")"

if [[ -n "$EXPECTED_VERSION" ]]; then
    /usr/bin/ruby -r rexml/document -e '
      doc = REXML::Document.new(File.read(ARGV[0]))
      expected = ARGV[1]
      item = REXML::XPath.match(doc, "//item").find do |candidate|
        node = REXML::XPath.first(
          candidate,
          "*[local-name()=\"shortVersionString\"]"
        )
        node&.text == expected
      end
      abort("expected version #{expected} missing from appcast") unless item
      build = REXML::XPath.first(item, "*[local-name()=\"version\"]")&.text
      abort("Sparkle build version missing") if build.to_s.empty?
      enclosure = REXML::XPath.first(item, "enclosure")
      expected_suffix = "/v#{expected}/MNotch-#{expected}.zip"
      archive_url = enclosure ? enclosure.attributes["url"].to_s : ""
      unless archive_url.end_with?(expected_suffix)
        abort("archive URL does not match #{expected_suffix}")
      end
    ' "$APPCAST" "$EXPECTED_VERSION"
fi

"$SIGN_UPDATE" "${KEY_ARGS[@]}" --verify "$APPCAST"
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
