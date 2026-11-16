# Distribution model

AirPlayDrop binary releases target Apple silicon only (`arm64`) on macOS 14 or later. Intel and universal builds are intentionally out of scope. Release artifacts are distributed as a Developer ID-signed, hardened-runtime app inside a signed and Apple-notarized DMG.

## Bundled FFmpeg policy

`scripts/build-bundled-ffmpeg.sh` downloads the pinned FFmpeg 9.0.2 source archive from ffmpeg.org, verifies its SHA-256 checksum, and builds native arm64 `ffmpeg` and `ffprobe` binaries. The configuration disables network access, autodetection, debugging, documentation, FFplay, GPL components, and nonfree components. It keeps broad built-in demuxing and decoding for user media while limiting encoders, muxers, filters, protocols, and devices to AirPlayDrop's preparation paths. It enables Apple AudioToolbox and VideoToolbox plus macOS system compression and character-conversion libraries.

The script also downloads the pinned dav1d 1.5.4 source from VideoLAN, verifies its SHA-256 checksum, and links it statically for software AV1 decoding. FFmpeg's built-in AV1 decoder needs a hardware accelerator, which Apple silicon only provides from M3 onward. Building dav1d requires `meson`, `ninja`, and `pkg-config` (`brew install meson ninja pkgconf`).

The build script rejects non-arm64 output and package-manager library linkage. It also checks for the encoders, filters, and bitstream filters used by AirPlayDrop. The app runs FFmpeg as a separate executable; it does not link FFmpeg libraries into the Swift application.

Each release ships the LGPL and FFmpeg license notices inside the app. The exact verified FFmpeg source archive and its checksum are published beside the DMG. `THIRD_PARTY_NOTICES.md` records the version, source URL, configure policy, and source checksum.

## Release prerequisites

The release Mac must have:

- Apple silicon and the supported Xcode command-line tools;
- `meson`, `ninja`, and `pkg-config` for the dav1d build;
- a valid `Developer ID Application` certificate in the login keychain;
- App Store Connect notarization credentials saved as a `notarytool` keychain profile; and
- access to `ffmpeg.org`, `downloads.videolan.org`, and Apple's notarization service.

Store notarization credentials locally without putting secrets in the repository or shell history:

```sh
xcrun notarytool store-credentials AirPlayDrop-notary \
  --apple-id "APPLE_ID" \
  --team-id "TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

## Build, sign, and notarize

From a clean tagged checkout, run:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: NAME (TEAM_ID)" \
NOTARY_PROFILE="AirPlayDrop-notary" \
AIRPLAYDROP_VERSION="VERSION" \
./scripts/package-dmg.sh
```

The packaging script performs this release gate:

1. Build and verify the pinned arm64 FFmpeg/FFprobe toolchain.
2. Build the Release app for arm64 only.
3. Install the tools and license notices in the app resources.
4. Sign nested executables, then sign and verify the hardened-runtime app.
5. Submit the app to Apple notarization and staple the accepted ticket.
6. Create and sign a DMG containing the app and an Applications shortcut.
7. Submit the DMG to notarization, staple and validate its ticket.
8. Emit SHA-256 checksums and copy the exact FFmpeg source archive beside the DMG.

For local pipeline testing only, `ALLOW_ADHOC=1 ./scripts/package-dmg.sh` creates a clearly named `-adhoc.dmg`. Ad-hoc artifacts are not notarized and must never be attached to a public release.

## Publication checklist

- Run `./scripts/verify.sh` and keep the worktree clean except for the intended version change.
- Confirm `file`/`lipo` report arm64 for the app, FFmpeg, and FFprobe.
- Run `codesign --verify --deep --strict` on the mounted app.
- Run `spctl --assess --type execute` on the mounted app and `spctl --assess --type open` on the DMG.
- Run `xcrun stapler validate` on both app and DMG.
- Mount the DMG on a clean Apple-silicon Mac without Homebrew FFmpeg and complete a representative probe, remux, audio conversion, and VideoToolbox transcode.
- Publish the DMG checksum and exact FFmpeg source archive/checksum with the GitHub release.
- Create a new immutable version tag; never move or reuse a published tag.

Mac App Store distribution would require a sandbox-compatible helper architecture and is not currently planned.
