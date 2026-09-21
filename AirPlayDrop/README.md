# AirPlayDrop

AirPlayDrop is a macOS utility for playing local video files and preparing
formats that macOS and Apple TV can play reliably over AirPlay. The project is
an early, source-first `0.1.0-alpha` release.

## Requirements

- macOS 14 or newer
- Xcode 15 or newer
- FFmpeg and FFprobe installed separately (for example, `brew install ffmpeg`)

Build and test from the repository root:

```sh
xcodebuild -project AirPlayDrop.xcodeproj -scheme AirPlayDrop \
  -configuration Debug -sdk macosx build CODE_SIGNING_ALLOWED=NO
xcodebuild -project AirPlayDrop.xcodeproj -scheme AirPlayDrop \
  -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

AirPlayDrop does not bundle FFmpeg, upload media, or alter the source file. A
transcode is written to a new file in the source directory only after it has
been validated. HDR/Dolby Vision, subtitle and multi-audio compatibility is
still evolving; always keep the original media until you have checked playback.

This alpha is intended for developers and testers. It is not currently a
signed or notarized binary distribution. See [CONTRIBUTING.md](CONTRIBUTING.md),
[SECURITY.md](SECURITY.md), and [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).
