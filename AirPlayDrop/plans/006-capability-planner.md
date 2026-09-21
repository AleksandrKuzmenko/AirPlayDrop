# Plan 006: Select one capability-driven conversion plan

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: MED
- **Depends on**: Plans 003 and 005
- **Category**: perf, architecture
- **Planned at**: commit `0e100d4`, 2026-09-21

## Why this matters

The current cascade may copy an entire unsupported MKV into a generic MP4 and later process the original again for AirPlay. Large 4K files incur duplicate reads/writes and confusing prompts. A deterministic plan should be chosen from source capabilities, destination profile, and selected tracks before starting work.

## Scope

In scope: `TranscodeService`, probe models, a pure `TranscodePlanner`, presets, confirmation UI, and tests. Out of scope: live streaming transcoding and non-Apple receivers.

## Steps

1. Define target profiles: `localPlayback`, `appleTV4KHDR`, and `maximumCompatibilitySDR`, with explicit container/video/audio/subtitle constraints.
2. Implement a pure planner returning one typed plan: direct play, remux, audio-only transcode, HDR10-safe DV-base remux, hardware encode, or software fallback. Include reasons and estimated work.
3. Replace numeric strategy indexes and cascade control flow with typed strategies and one primary plan plus an explicit fallback only after a diagnosed failure.
4. For the AirPlay-first app path, avoid generating a generic intermediate when the final Apple TV profile can be created directly.
5. Show the proposed plan, selected tracks, destination, free-space estimate, and quality implications before starting.
6. Add a conservative free-space preflight including temporary `faststart` overhead.
7. Add table-driven planner tests covering current Dolby Vision/HDR cases, SDR H.264, incompatible audio, no audio, unsupported video, and insufficient disk space.

## Verification

- Planner tests prove the known HDR/DV MKV takes one AirPlay-safe whole-file pass rather than generic remux plus second conversion.
- No numeric `startingAt`/`endBefore` strategy API remains.
- Build and tests pass.

## STOP conditions

Stop if source capabilities cannot be determined reliably; report the missing probe fields rather than falling back to filename-based decisions.
