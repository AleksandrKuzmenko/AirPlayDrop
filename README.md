# AirPlayDrop

AirPlayDrop is a native macOS utility for playing local video and preparing difficult media for reliable playback on Apple TV through AirPlay. It inspects each file, keeps compatible streams whenever possible, and uses a separately installed FFmpeg only when conversion or repackaging is required.

The project is currently a **source-first 0.1.0 alpha**. It is intended for technically comfortable macOS users and contributors; signed and notarized application downloads are not available yet.

## Features

- Drag-and-drop playlist and native macOS playback controls.
- AirPlay route selection and an explicit **Prepare for Apple TV / AirPlay** workflow.
- Media probing before conversion, with named remux, audio-conversion, hardware-encode, and software fallback strategies.
- Per-file audio-track and text-subtitle selection.
- Preferred audio and subtitle languages for newly imported files.
- Automatic discovery and manual attachment of external `.srt`, `.vtt`, `.ass`, and `.ssa` subtitles.
- Per-file audio and subtitle synchronization adjustment from -10 to +10 seconds.
- Optional Late Night audio processing for quieter peaks and clearer dialogue.
- Resume playback for unfinished videos and timeline thumbnail previews while scrubbing.
- Cancellable conversion, progress reporting, actionable FFmpeg diagnostics, and reuse of validated prepared copies.

AirPlayDrop does not implement Chromecast, a phone remote, subtitle OCR, Atmos passthrough, or persistent multi-playlist management.

## Requirements

- macOS 14 Sonoma or later.
- Xcode 15.4 or later for source builds.
- FFmpeg and FFprobe installed separately.

The easiest dependency installation is Homebrew:

```sh
brew install ffmpeg
```

AirPlayDrop searches `PATH`, `/opt/homebrew/bin`, `/usr/local/bin`, and `/usr/bin`. If the tools are elsewhere, open **AirPlayDrop → Settings** or click **FFmpeg Settings** in the toolbar, choose the directory containing both executables, and run the built-in version check.

## Build and run

Clone the repository and open the Xcode project:

```sh
git clone https://github.com/AleksandrKuzmenko/APremote.git
cd APremote
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

FFmpeg and FFprobe are separate programs executed locally with structured argument arrays. Their licensing and enabled codecs depend on the installation selected by the user.

## Troubleshooting

### FFmpeg is not found

Confirm both commands work in Terminal:

```sh
ffmpeg -version
ffprobe -version
```

Then use **FFmpeg Settings** to select their common directory and run the version check.

### Audio plays but video is black on Apple TV

Stop playback and use **Prepare for → Apple TV / AirPlay**. Dolby Vision and some HEVC-in-MKV files need an AirPlay-safe MP4 sample entry or an HDR10-compatible fallback.

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

The project has no Swift package dependencies. It links Apple AVFoundation and AVKit and expects FFmpeg/FFprobe at runtime for probing and preparation.

## Distribution

The alpha is distributed as source only. See [AirPlayDrop/docs/DISTRIBUTION.md](AirPlayDrop/docs/DISTRIBUTION.md) for the signing, notarization, architecture, checksum, and multimedia-licensing requirements that apply before binary distribution.

Version tags create immutable source archives and SHA-256 checksums through GitHub Actions. Unsigned application bundles are intentionally not published.

## Contributing and security

Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change. Please report security issues privately as described in [SECURITY.md](SECURITY.md), not in a public issue.

AirPlayDrop is available under the [MIT License](LICENSE). Community participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
