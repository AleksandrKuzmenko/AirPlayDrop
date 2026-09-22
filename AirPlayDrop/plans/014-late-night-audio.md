# Plan 014: Add an optional late-night dialogue mode

> **Executor instructions**: Follow every step and verification. Preserve the default audio path byte-for-byte at the argument level. Stop on any STOP condition and update the index when complete unless a reviewer owns it.
>
> **Drift check (run first)**: `git diff --stat 2eda4ef..HEAD -- AirPlayDrop/AirPlayDrop/Models/MediaTrack.swift AirPlayDrop/AirPlayDrop/Models/MediaItem.swift AirPlayDrop/AirPlayDrop/Models/PlaylistStore.swift AirPlayDrop/AirPlayDrop/Services/TranscodeService.swift AirPlayDrop/AirPlayDrop/Services/MediaArtifactValidator.swift AirPlayDrop/AirPlayDrop/Views/PlaylistView.swift AirPlayDrop/Tests/AirPlayDropTests.swift`
> If planner/audio arguments changed, reconcile them before proceeding and stop if default compatibility cannot be preserved.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/006-capability-planner.md`
- **Category**: direction, ux
- **Planned at**: commit `2eda4ef`, 2026-09-21

## Why this matters

Movie dialogue can be hard to hear at low volume because effects have much wider dynamics. An opt-in, clearly labeled dialogue-focused mode can improve night viewing while leaving the existing compatible AAC stereo output untouched by default.

## Current state

- `MediaTrack.swift:80-123` plans conversion and hard-codes AAC stereo at 192 kbps for transcoded audio.
- `TranscodeService.swift:93-103` appends the chosen step's audio arguments without filters.
- `MediaArtifactValidator.swift:12-22` does not include an audio-processing mode in cache identity.
- User direction explicitly excludes Atmos passthrough; do not broaden this into a multichannel pipeline.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project AirPlayDrop/AirPlayDrop.xcodeproj -scheme AirPlayDrop -configuration Debug -sdk macosx build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild -project AirPlayDrop/AirPlayDrop.xcodeproj -scheme AirPlayDrop -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **` |
| Hygiene | `git diff --check` | exit 0 |

## Scope

**In scope**:
- `AirPlayDrop/AirPlayDrop/Models/MediaTrack.swift`
- `AirPlayDrop/AirPlayDrop/Models/MediaItem.swift`
- `AirPlayDrop/AirPlayDrop/Models/PlaylistStore.swift`
- `AirPlayDrop/AirPlayDrop/Services/TranscodeService.swift`
- `AirPlayDrop/AirPlayDrop/Services/MediaArtifactValidator.swift`
- `AirPlayDrop/AirPlayDrop/Views/PlaylistView.swift`
- `AirPlayDrop/Tests/AirPlayDropTests.swift`

**Out of scope**: Atmos passthrough, lossless/multichannel redesign, AI dialogue isolation, per-device EQ, a general equalizer, and changing the default audio path.

## Git workflow

- Branch: `codex/014-late-night-audio`
- Use imperative commits such as `Add optional late-night audio processing`.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Define mode and measurable audio target

Add `AudioProcessingMode` with `standard` and `lateNight`. Standard must emit exactly today's audio arguments. For lateNight, first evaluate a deterministic one-pass FFmpeg filter chain using generated audio with quiet speech-band tones and loud transients. Prefer documented filters such as controlled compression plus loudness normalization; use fixed parameters and a versioned filter preset. Do not claim true dialogue isolation.

Acceptance for the fixture: output contains no sample peak above -0.5 dBFS, duration differs by at most 100 ms, quiet segment RMS rises by at least 4 dB, and loud-vs-quiet RMS gap shrinks by at least 6 dB. Measure with FFmpeg `astats`/`ebur128` output parsed by the test.

**Verify**: fixture test prints measured before/after values and passes all numeric thresholds.

### Step 2: Force audio transcode only for late-night mode

Thread the mode through `TranscodePlanner.plan`, `ConversionStep`, and `TranscodeService.prepare`. Selecting lateNight must prevent an audio-copy remux and apply the proven filter chain before AAC stereo encoding. Standard must preserve the existing step ordering and exact arguments. Video copy/encode decisions remain capability-driven and unchanged.

**Verify**: exact-array tests prove standard is unchanged, lateNight includes the filter and AAC encode, and compatible video is still copied.

### Step 3: Invalidate stale artifacts and expose the option

Store the per-item mode on `MediaItem`; changing it through `PlaylistStore` invalidates the prepared copy. Bump the artifact manifest schema and include mode plus filter-preset version. Add an `Audio Processing` menu with `Standard` and `Late Night (Dialogue Focus)` and explanatory help that it re-encodes audio.

**Verify**: tests reject cache reuse across modes/preset versions; Build succeeds and VoiceOver labels identify the selected mode.

### Step 4: Verify real output and failure behavior

Run preparation against a generated stereo fixture and probe the result for AAC, two channels, expected duration, and valid peaks. Confirm cancellation still removes temporary output. If the installed FFmpeg lacks a chosen filter, fail before conversion with an actionable dependency error rather than falling through every video strategy.

**Verify**: Tests pass with the filter available; the explicit missing-filter unit path returns the documented error.

## Test plan

- Unit tests for mode defaults, planner choice, exact arguments, item invalidation, and manifest identity.
- Generated-audio integration test for numeric loudness/dynamic-range targets and clipping protection.
- Regression test that standard mode preserves current remux/audio-transcode arguments.
- Final verification: Build, Tests, `git diff --check`.

## Done criteria

- [ ] Standard mode is behaviorally and argument-level compatible with current output.
- [ ] LateNight forces only the necessary audio encode and meets measured fixture thresholds.
- [ ] Cache identity includes mode and preset version.
- [ ] UI accurately describes dialogue focus without promising voice isolation.
- [ ] No Atmos, lossless, or multichannel expansion was added.
- [ ] Build and all tests pass.

## STOP conditions

- Stop if the selected filter is unavailable in the documented minimum FFmpeg installation.
- Stop if the measured fixture clips or cannot meet thresholds without severe pumping; report measurements and sample command.
- Stop if implementing the mode changes video strategy or standard-mode arguments.

## Maintenance notes

Any filter parameter change is a cache-breaking preset-version change. Reviewers should scrutinize default-path regressions and marketing language as closely as DSP details.
