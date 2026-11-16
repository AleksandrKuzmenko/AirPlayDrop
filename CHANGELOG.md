# Changelog

## Unreleased

- Added an Apple-silicon-only DMG packaging pipeline with hardened-runtime signing and Apple notarization.
- Added pinned LGPL FFmpeg 9.0.2 and FFprobe builds with no GPL/nonfree components or network support.
- Prefer bundled media tools while retaining an explicit trusted-directory override for development.
- Removed the unavailable `libx264` fallback in favor of Apple VideoToolbox encoding.
- Fixed media probing failing on files whose FFprobe side data contains numbers (rotated phone videos, HDR10 light-level metadata, Dolby Vision configuration records); the Dolby Vision profile and rotation are now recorded.
- HDR and Dolby Vision files that AVFoundation cannot open (such as MKV) are now re-prepared for Apple TV before AirPlay playback instead of streaming a local-only copy.

## 0.1.0-alpha — 2026-09-22

- Replaced positional fallback numbers with capability-driven conversion plans.
- Added deterministic audio and text-subtitle stream selection.
- Added race-safe cancellation, transactional manifests, cache validation, and FFmpeg diagnostics.
- Added explicit local/AirPlay preparation controls with progress, cancel, retry, and cache reuse.
- Added preferred audio and subtitle language settings for newly imported media.
- Added resume playback history and timeline thumbnail previews.
- Added automatic discovery and manual attachment of external text subtitles.
- Added per-item audio and subtitle synchronization controls.
- Added optional Late Night dialogue-focused audio processing.
- Added bounded, cancellable FFprobe execution and AirPlay-safe `hvc1` tagging for HEVC remuxes.
- Added source-release automation, generated-media integration coverage, and open-source project documentation.
