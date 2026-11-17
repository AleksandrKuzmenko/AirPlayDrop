# Changelog

## Unreleased

- Added an Apple-silicon-only DMG packaging pipeline with hardened-runtime signing and Apple notarization.
- Added pinned LGPL FFmpeg 9.0.2 and FFprobe builds with no GPL/nonfree components or network support.
- Prefer bundled media tools while retaining an explicit trusted-directory override for development.
- Removed the unavailable `libx264` fallback in favor of Apple VideoToolbox encoding.
- Fixed media probing failing on files whose FFprobe side data contains numbers (rotated phone videos, HDR10 light-level metadata, Dolby Vision configuration records); the Dolby Vision profile and rotation are now recorded.
- HDR and Dolby Vision files that AVFoundation cannot open (such as MKV) are now re-prepared for Apple TV before AirPlay playback instead of streaming a local-only copy.
- Fixed AV1 videos failing every preparation strategy: the bundled FFmpeg now includes the pinned dav1d 1.5.4 software decoder. With an external FFmpeg that lacks dav1d, AirPlayDrop uses VideoToolbox hardware decoding on Macs that support it and otherwise reports a clear error.
- HDR10 and HLG sources that cannot be stream-copied, such as AV1 and VP9, are now encoded as 10-bit HEVC with explicit BT.2020 and PQ/HLG tags instead of 8-bit H.264. Prepared HDR copies are rejected if they lose their HDR transfer function. The bundled FFmpeg adds the `setparams` filter for this.
- Surround audio is no longer always downmixed to stereo. AAC, AC3, and E-AC3 tracks are copied unchanged, keeping any Dolby Atmos in E-AC3. Other multichannel audio, such as DTS, TrueHD, FLAC, or Opus, is encoded as E-AC3 up to 5.1, with 7.1 downmixed to 5.1. The bundled FFmpeg adds the E-AC3 encoder; builds without it fall back to multichannel AAC. Stereo sources and Late Night mode stay stereo AAC. Copies prepared by earlier versions are re-prepared.
- AirPlay now checks video against what Apple TV can decode, not what the Mac can play. H.264 must be 8-bit 4:2:0 Baseline, Main, or High, HEVC must be 8- or 10-bit 4:2:0 Main or Main 10, and video must be at most 2160p and 60 fps. These limits follow Apple's HLS authoring specification and the Apple TV 4K specifications. Other video, including 10-bit and 4:2:2 H.264, 4:2:2 HEVC, and AV1 or VP9 even in MP4, is converted before AirPlay playback instead of being streamed or stream-copied unchanged. Conversions scale down to 2160p and halve high frame rates when needed, and each AirPlay copy is re-probed and rejected if it is still outside these limits. Locally prepared copies are probed too, so one that is already compatible is not converted again. AirPlay copies prepared by earlier versions are re-prepared. Local playback is unchanged.
- The FFmpeg build script now starts from an empty build directory so it keeps working after Xcode SDK updates.

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
