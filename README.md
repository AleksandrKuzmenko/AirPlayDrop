# AirPlayDrop

AirPlayDrop is a native Apple-silicon macOS utility for playing local video and preparing difficult media for reliable playback on Apple TV through AirPlay. It inspects each file, keeps compatible streams whenever possible, and uses its bundled FFmpeg only when conversion or repackaging is required.

The project is currently a **0.1.x alpha**. The release process produces an arm64-only, Developer ID-signed and Apple-notarized DMG; source builds remain supported for contributors.

## Features

- Drag-and-drop playlist and native macOS playback controls.
- AirPlay route selection and an explicit **Prepare for Apple TV / AirPlay** workflow.
- Media probing before conversion, with named remux, audio-conversion, and Apple VideoToolbox hardware-encode strategies.
- Per-file audio-track and text-subtitle selection.
- Preferred audio and subtitle languages for newly imported files.
- Automatic discovery and manual attachment of external `.srt`, `.vtt`, `.ass`, and `.ssa` subtitles.
- Per-file audio and subtitle synchronization adjustment from -10 to +10 seconds.
- Apple TV video checks: video the Mac plays but Apple TV cannot decode, such as 10-bit or 4:2:2 H.264, 4:2:2 HEVC, AV1, video above 2160p or 60 fps, or interlaced video, is converted before AirPlay playback instead of streamed as-is. Interlaced video is deinterlaced to full frame rate whenever it is encoded.
- Surround audio preserved for Apple TV: AAC, AC3, and E-AC3 tracks are copied unchanged, and other multichannel audio is converted to E-AC3 up to 5.1.
- Optional Late Night audio processing for quieter peaks and clearer dialogue.
- Resume playback for unfinished videos and timeline thumbnail previews while scrubbing.
- Cancellable conversion, progress reporting, actionable FFmpeg diagnostics, and reuse of validated prepared copies.

AirPlayDrop does not implement Chromecast, a phone remote, subtitle OCR, Atmos from TrueHD sources, or persistent multi-playlist management.

## Requirements

- macOS 14 Sonoma or later.
- A Mac with Apple silicon (M1 or later). Intel Macs are not supported.
- Xcode 15.4 or later for source builds.

Release DMGs include a minimal-dependency, arm64 FFmpeg/FFprobe build. No Homebrew installation is required. A source checkout can build the same pinned toolchain with:

```sh
./scripts/build-bundled-ffmpeg.sh
```

AirPlayDrop prefers an explicitly configured FFmpeg directory, then the tools bundled inside the app, followed by `PATH` and standard package-manager locations. The override under **AirPlayDrop → Settings** is useful for development or testing another trusted build.

## Build and run

Clone the repository and open the Xcode project:

```sh
git clone https://github.com/AleksandrKuzmenko/AirPlayDrop.git
cd AirPlayDrop
open AirPlayDrop/AirPlayDrop.xcodeproj
```

In Xcode, select the **AirPlayDrop** scheme and **My Mac**, then press **Run**. Code signing is needed only when launching through Xcode; the command-line verification build disables it.

To build from Terminal:

```sh
xcodebuild \
  -project AirPlayDrop/AirPlayDrop.xcodeproj \
  -scheme AirPlayDrop \
  -configuration Debug \
  -sdk macosx \
  build CODE_SIGNING_ALLOWED=NO
```

The resulting development app is stored under Xcode's DerivedData directory. For normal development, running it directly from Xcode is the simplest option.

## Using AirPlayDrop

1. Drop one or more videos into the window, or press **Command-O**.
2. Wait for probing to finish, then choose the desired audio and subtitle tracks from the item's context menu.
3. For ordinary local playback, select the item and press **Play**.
4. For HDR, Dolby Vision, MKV, or otherwise troublesome files, choose **Prepare for → Apple TV / AirPlay** and wait for validation to complete.
5. Choose the Apple TV with the AirPlay button and start playback.

Prepared MP4 files and their `.airplay.json` validation manifests are written beside the source video. The original media file is never overwritten. Changing track, synchronization, subtitle, or audio-processing choices invalidates the prepared selection and requires preparation again.

Playback language preferences apply to files imported after the preference changes. Late Night mode uses dynamic-range compression and limiting; it is not speech isolation. Only text subtitles are supported—bitmap subtitle formats such as PGS require OCR and are intentionally out of scope.

## Privacy and local data

Media never leaves the Mac through AirPlayDrop itself. The app does not contain analytics, advertising, accounts, or network upload code.

For resume playback, AirPlayDrop stores a bounded history of up to 100 local file identities and playback positions in macOS application preferences. Prepared-copy manifests contain source fingerprints and selected preparation options and remain beside the prepared video. Anyone receiving a copied manifest may be able to infer the original filename or folder structure, so omit `.airplay.json` files when sharing prepared videos.

FFmpeg and FFprobe are separate programs executed locally with structured argument arrays. Release builds bundle a pinned LGPL build with no GPL/nonfree components or network support. Its notices are inside the app and the corresponding source archive is published with each DMG. A user-configured external build may have different licensing and capabilities.

## Troubleshooting

### FFmpeg is not found

The signed release includes both tools. If a development build cannot find them, build the pinned copies:

```sh
./scripts/build-bundled-ffmpeg.sh
```

Alternatively, use **FFmpeg Settings** to select a trusted directory containing `ffmpeg` and `ffprobe`, then run the version check.

### Audio plays but video is black on Apple TV

Stop playback and use **Prepare for → Apple TV / AirPlay**. Dolby Vision and some HEVC-in-MKV files need an AirPlay-safe MP4 sample entry or an HDR10-compatible fallback. Dolby Vision profile 5 files have no HDR10 fallback and are kept as Dolby Vision instead. AirPlayDrop also converts camera and editing formats that the Mac plays but Apple TV cannot decode, such as 10-bit or 4:2:2 H.264 and 4:2:2 HEVC, when playback starts on an AirPlay route.

### The wrong audio or subtitle track was selected

Open the playlist item's context menu, choose the desired track, and prepare the file again. Preferred languages can be configured under **Playback Settings**.

### Preparation fails

Use the failure detail shown by the item, confirm sufficient free disk space beside the source, and run the FFmpeg version check. AirPlayDrop tries the least destructive compatible strategy first and falls back to re-encoding when necessary.

## Development and verification

Run the complete local verification gate from the repository root:

```sh
./scripts/verify.sh
```

The script runs the unsigned Debug build, all unit tests, and `git diff --check`. Tests use generated fixtures and mocks; copyrighted or personal media must never be committed.

The project has no Swift package dependencies. It links Apple AVFoundation and AVKit. Packaged releases include the pinned FFmpeg/FFprobe runtime; ordinary Xcode debug builds can use either that locally built runtime or a trusted external installation.

## Distribution

See [AirPlayDrop/docs/DISTRIBUTION.md](AirPlayDrop/docs/DISTRIBUTION.md) for the Apple-silicon packaging, signing, notarization, checksum, and FFmpeg licensing procedure.

Release assets include the signed and notarized arm64 DMG, its SHA-256 checksum, and the exact FFmpeg source archive and checksum required to reproduce the bundled LGPL binaries. Unsigned application bundles are not published.

## Contributing and security

Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change. Please report security issues privately as described in [SECURITY.md](SECURITY.md), not in a public issue.

AirPlayDrop is available under the [MIT License](LICENSE). Community participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
