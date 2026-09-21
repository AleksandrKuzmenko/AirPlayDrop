# AirPlayDrop

AirPlayDrop is a macOS utility for local video playback and reliable AirPlay preparation. This is a source-first 0.1.0-alpha.

Requirements: macOS 14+, Xcode 15+, and separately installed FFmpeg/FFprobe (brew install ffmpeg).

From the repository root:

    xcodebuild -project AirPlayDrop/AirPlayDrop.xcodeproj -scheme AirPlayDrop -configuration Debug -sdk macosx build CODE_SIGNING_ALLOWED=NO
    xcodebuild -project AirPlayDrop/AirPlayDrop.xcodeproj -scheme AirPlayDrop -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO

The app does not bundle FFmpeg, upload media, or modify source files. See CONTRIBUTING.md, SECURITY.md, and AirPlayDrop/docs/DISTRIBUTION.md.
