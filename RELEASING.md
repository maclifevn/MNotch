# Releasing MNotch

MNotch uses Sparkle 2.9.4 for Developer ID releases outside the Mac App Store.
The stable signed feed is served as the latest GitHub Release asset:

`https://github.com/maclifevn/MNotch/releases/latest/download/appcast.xml`

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
manager and never commit it. For CI, store its contents as an encrypted secret
and write it to a temporary file exposed through `SPARKLE_PRIVATE_KEY_FILE`.

## Stable release

1. Increase the default `VERSION` in `Scripts/build.sh`. Build numbers come
   from the Git commit count and must remain monotonic.
2. Add `ReleaseNotes/X.Y.Z.md` and update `CHANGELOG.md`.
3. Commit and tag that exact commit as `vX.Y.Z`.
4. Build, sign, notarize, and staple the app and DMG:

   ```sh
   VERSION=X.Y.Z Scripts/notarize.sh
   Scripts/create-dmg.sh
   ```

5. Generate and tamper-test the signed feed:

   ```sh
   Scripts/build-update-feed.sh \
     X.Y.Z \
     build/distribution/MNotch.zip \
     ReleaseNotes/X.Y.Z.md \
     build/distribution/update-feed
   ```

   For the first Sparkle-enabled release only, explicitly allow creation of a
   new feed:

   ```sh
   MNOTCH_BOOTSTRAP_UPDATE_FEED=true Scripts/build-update-feed.sh \
     X.Y.Z \
     build/distribution/MNotch.zip \
     ReleaseNotes/X.Y.Z.md \
     build/distribution/update-feed
   ```

   Never use the bootstrap flag again after `appcast.xml` has been published;
   later releases must download and authenticate the existing feed first.

6. Create the GitHub Release with these assets:

   - `build/distribution/MNotch.dmg`
   - `build/distribution/update-feed/MNotch-X.Y.Z.zip`
   - `build/distribution/update-feed/appcast.xml`

   The appcast deliberately references the versioned ZIP in the same tag. Do
   not publish the feed unless that archive is present and notarized.

7. Verify the public feed and archive URLs, then check from the previous
   notarized MNotch build in `/Applications`.

Normal releases use seven daily Sparkle cohorts. Manual checks bypass the
delay. Pass `true` as the final `build-update-feed.sh` argument for a critical
update without phased rollout.

The first Sparkle-enabled version is a manual bootstrap download. Existing
versions that do not bundle Sparkle cannot discover it automatically.

## Rollback and retention

The appcast keeps five full ZIP versions and creates no deltas. Never publish
a downgrade; ship a hotfix with a higher build number. Keep the bundle ID,
Developer ID team, and Sparkle signing key stable across releases.
