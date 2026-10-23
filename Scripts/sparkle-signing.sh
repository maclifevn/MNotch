#!/bin/bash
# Sourced by feed commands. Never export the production Keychain private key.
ACCOUNT="${MNOTCH_SPARKLE_ACCOUNT:-com.mnotch.app}"
PRIVATE_KEY="${SPARKLE_PRIVATE_KEY_FILE:-}"
KEY_ARGS=()
if [[ -n "$PRIVATE_KEY" ]]; then
    [[ -f "$PRIVATE_KEY" ]] || { echo "Signing key file not found" >&2; exit 1; }
    SIGNING_PUBLIC_KEY="$(swift "$ROOT/Scripts/sparkle-public-key.swift" "$PRIVATE_KEY")"
    KEY_ARGS+=(--ed-key-file "$PRIVATE_KEY")
else
    SIGNING_PUBLIC_KEY="$("$(dirname "$SIGN_UPDATE")/generate_keys" --account "$ACCOUNT" -p)"
    KEY_ARGS+=(--account "$ACCOUNT")
fi
[[ -n "$SIGNING_PUBLIC_KEY" ]] || { echo "Sparkle signing key is not configured" >&2; exit 1; }
