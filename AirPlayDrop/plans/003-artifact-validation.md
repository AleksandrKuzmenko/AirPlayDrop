# Plan 003: Validate media artifacts before playback or cache reuse

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: Plans 001 and 002
- **Category**: bug
- **Planned at**: commit `0e100d4`, 2026-09-21

## Why this matters

FFmpeg exit status zero is not enough: a prior output contained AAC packets but AVFoundation exposed no audio track. Cached files are currently accepted when a predictable path exists. Only a fully validated artifact should become `.ready`.

## Scope

In scope: `VideoFormatProbe`, `TranscodeService`, `PlaylistStore`, a new `MediaArtifactValidator`, and tests. Out of scope: codec-strategy selection and track-selection UI.

## Steps

1. Define a structured validation result covering readable duration, at least one video track, expected `hvc1`/codec profile for AirPlay HDR output, at least one AVFoundation-visible audio track when the source has audio, sane duration tolerance, and file non-emptiness.
2. Validate temporary output before atomic publication and again before cached reuse.
3. Store a lightweight sidecar manifest for app-owned artifacts containing canonical source path, source size and modification timestamp, selected tracks/preset, output validation summary, and schema version. Do not store sensitive media metadata beyond what is needed for cache validity.
4. Reject stale, unrelated, incomplete, or incompatible cache entries and leave them untouched; produce a new reserved destination.
5. Surface actionable validation errors in `MediaItemState.failed`.
6. Add tests for missing audio, truncated output, wrong source fingerprint, stale manifest, duration mismatch, and valid cache reuse.

## Verification

- Tests reproduce the six-channel AAC/AVFoundation-zero-audio regression using generated fixtures or mocked probe results.
- No code path sets `.ready` for a generated artifact without a successful validation result.
- Plan 001 build/test commands pass.

## STOP conditions

Stop if validation would require shipping copyrighted fixtures or trusting FFprobe alone for Apple playback compatibility; use generated fixtures and AVFoundation checks.
