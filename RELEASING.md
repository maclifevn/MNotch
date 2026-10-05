# Releasing MNotch

MNotch uses Sparkle 2.10.0 for Developer ID releases outside the Mac App Store.
The stable signed feed is served as the latest GitHub Release asset:

`https://github.com/maclifevn/MNotch/releases/latest/download/appcast.xml`

The app follows MFinder's local release pattern: daily/manual checks, optional
download and install on quit, and a safety boundary before installation.
MNotch pauses new File Tray work and waits for queued copies, removals, cleanup
and the live drag session before relaunching. The wait window is nonmodal; Cancel
resumes File Tray and leaves the downloaded update available for a later retry.
Feed URL, bundle ID and the existing MNotch public key remain unchanged.

## One-time setup

The public Ed25519 key is committed in `Support/Info.plist`. The private key is
stored only in the Login Keychain under account `com.mnotch.app`.

Back it up once to a secure location with:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account com.mnotch.app \
  -x /secure/path/mnotch-sparkle-private-key
```

The exported file is as sensitive as a password. Store it in a password
manager and never commit it. Normal releases sign directly through Keychain;
`SPARKLE_PRIVATE_KEY_FILE` is an optional fallback for a protected temporary
file. Production build/sign/notarize/publish runs locally, as in MFinder.
CI validates packages and signs fixtures with disposable test keys only.

## Stable release

Before signing a public release, complete the acceptance matrix in [AUDIT.md](AUDIT.md).
`Scripts/build.sh` rebuilds the MediaRemote adapter with an explicit macOS 15.0
target, checks every Mach-O in the bundle, and archives UUID-matching dSYMs under
`build/symbols/<version>-<build>`. Preserve that directory with the exact ZIP and
source revision; symbols from a rebuild are not interchangeable. CI artifacts
need to be downloaded and retained before their GitHub retention period expires.

An ad-hoc candidate is suitable for local testing. It has not passed Developer ID
signing, notarization, Gatekeeper, or update-install acceptance.

1. Add `ReleaseNotes/X.Y.Z.md`, update `CHANGELOG.md`, review/test and commit.
   Tag that exact clean commit as `vX.Y.Z`. The release command supplies the
   version to the build; editing the default build script is unnecessary.
2. Prepare everything locally with one command:

   ```sh
   make release VERSION=X.Y.Z
   ```

   Build numbers default to the Git commit count. Override with
   `BUILD_NUMBER=N` if necessary; every version and build must exceed all
   published entries. Use the same override when publishing. Preparation
   verifies the signing key matches the app, builds/signs/notarizes/staples
   app and DMG, authenticates feed history, signs and tamper-tests the new
   appcast/ZIP, and writes `build/releases/X.Y.Z-N/` atomically with SHA-256
   manifest and matching symbols. Existing release directories are preserved.

   For the first Sparkle release only, a production HTTP 404 may be bootstrapped
   explicitly:

   ```sh
   MNOTCH_BOOTSTRAP_UPDATE_FEED=true make release VERSION=X.Y.Z
   ```

   Never use the bootstrap flag again after `appcast.xml` has been published;
   later releases must download and authenticate the existing feed first.

3. Push the reviewed commit/tag using your normal Git workflow. Publish the
   prepared output when ready:

   ```sh
   make publish VERSION=X.Y.Z
   ```

   This rechecks the exact clean source/tag, remote tag, manifest hashes,
   signatures and current signed feed (including an intervening newer release).
   It uploads the versioned ZIP/DMG, stable `MNotch.dmg`, appcast
   and manifest to a draft, then publishes the completed release as latest.
   A failed upload leaves a draft and may be retried; a published version is
   never overwritten. Symbol ZIPs stay local for retention.

4. Fetch the public feed/archive again, verify signatures, byte lengths and
   SHA-256 against the retained manifest, and check/install from the previous
   notarized MNotch build in `/Applications` before announcing. End-to-end
   installation requires the actual signed release; fixture signing tests do
   not prove that step.

`make release-check VERSION=X.Y.Z` checks clean source, tag and notes without
signing or publishing. Low-level `notarize.sh`, `create-dmg.sh`,
`build-update-feed.sh` and `verify-update-feed.sh` remain available.

Normal releases use seven daily Sparkle cohorts. Manual checks bypass the
delay. `make release VERSION=X.Y.Z CRITICAL=true` prepares a critical update
without phased rollout.

The first Sparkle-enabled version is a manual bootstrap download. Existing
versions that do not bundle Sparkle cannot discover it automatically.

## Rollback and retention

The appcast keeps five full ZIP versions and creates no deltas. Never publish
a downgrade; ship a hotfix with a higher build number. Keep the bundle ID,
Developer ID team, and Sparkle signing key stable across releases.

## Validation evidence

`Tests/MNotchTests/UpdateIntegrationTests.swift` covers wait/cancel/retry and
stale preparation. `Tests/BuildChecks/test_updates.py` runs real Sparkle tools
on ad-hoc fixture bundles with temporary Ed25519 keys outside Keychain: signed
bootstrap/upgrade, retained history, feed/ZIP tampering, wrong key, missing
history, downgrade rejection, URL/build/byte-length mismatches and release
preflight. Build Sparkle before running these checks; CI does so explicitly.
The canonical signing format is documented by
[Sparkle publishing](https://sparkle-project.org/documentation/publishing/).
