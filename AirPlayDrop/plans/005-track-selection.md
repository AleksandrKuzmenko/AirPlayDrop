# Plan 005: Let users choose audio and subtitle tracks explicitly

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: Plans 001 and 003
- **Category**: bug, direction
- **Planned at**: commit `0e100d4`, 2026-09-21

## Why this matters

The AirPlay path hardcodes the first audio stream, downmixes it, strips language metadata, and drops subtitles. Multilingual releases can therefore play the wrong language, and users cannot inspect the choice before a multi-hour conversion.

## Scope

In scope: a probe service, media-track models, `MediaItem`, playlist/details UI, transcode argument construction, artifact manifest, and tests. Out of scope: OCR, subtitle downloading, and subtitle editing.

## Steps

1. Locate `ffprobe` beside the selected FFmpeg executable and decode `-show_streams -show_format` JSON through `Process` arguments. Provide a clear dependency error when unavailable.
2. Model video, audio, and subtitle streams with stable stream index, codec, language, title, channel layout, disposition/default, and compatibility flags.
3. Present track choices before conversion. Default to the source default disposition, then preferred system language, then first track. Always show the resolved choice in the confirmation UI.
4. Map the selected audio stream explicitly and preserve its language/title metadata. Default AirPlay output to stereo AAC for reliability, while clearly labeling the downmix.
5. Allow a selected text subtitle to be converted to an Apple-compatible format when feasible, or explicitly choose "No subtitles". Unsupported bitmap subtitles must be reported rather than silently dropped.
6. Persist selections in the artifact manifest and include them in cache validity.
7. Add pure argument-generation tests for multiple languages, no audio, 5.1-to-stereo, default dispositions, text subtitles, and unsupported subtitles.

## Verification

- A generated multi-audio fixture converts the selected non-first language.
- AVFoundation sees the output audio track and retained language metadata.
- Build and full tests pass.

## STOP conditions

Stop if FFprobe JSON is parsed with ad-hoc string splitting or if unsupported subtitles are silently discarded despite a user selection.

