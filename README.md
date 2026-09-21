# AirPlayDrop

AirPlayDrop is a macOS utility for local video playback and reliable AirPlay preparation. This is a source-first 0.1.0-alpha.

Requirements: macOS 14+, Xcode 15+, and separately installed FFmpeg/FFprobe (brew install ffmpeg).

AirPlayDrop probes every source before conversion, chooses a compatible named strategy, and lets you select the audio and text-subtitle streams from the playlist context menu. Use **Prepare for → Apple TV / AirPlay** before casting HDR or Dolby Vision material. Preparation can be cancelled or retried, and a validated prepared copy is reused when the source and track selection have not changed.

The app searches `PATH` and common Homebrew locations for FFmpeg. If your tools are elsewhere, open **AirPlayDrop → Settings** (or the toolbar gear), enter the folder containing both `ffmpeg` and `ffprobe`, and run the built-in version check.

From the repository root:

    xcodebuild -project AirPlayDrop/AirPlayDrop.xcodeproj -scheme AirPlayDrop -configuration Debug -sdk macosx build CODE_SIGNING_ALLOWED=NO
    xcodebuild -project AirPlayDrop/AirPlayDrop.xcodeproj -scheme AirPlayDrop -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO

The app does not bundle FFmpeg, upload media, or modify source files. See CONTRIBUTING.md, SECURITY.md, and AirPlayDrop/docs/DISTRIBUTION.md.
