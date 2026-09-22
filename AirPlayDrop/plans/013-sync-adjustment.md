# Plan 013: Add per-item audio and subtitle synchronization

> **Executor instructions**: Execute each step and verification in order. This plan includes a timing-semantics spike; do not ship guessed FFmpeg arguments. Stop and report on any STOP condition. Update the plan index when complete unless a reviewer owns it.
>
> **Drift check (run first)**: `git diff --stat 2eda4ef..HEAD -- AirPlayDrop/AirPlayDrop/Models/MediaItem.swift AirPlayDrop/AirPlayDrop/Models/MediaTrack.swift AirPlayDrop/AirPlayDrop/Models/PlaylistStore.swift AirPlayDrop/AirPlayDrop/Services/TranscodeService.swift AirPlayDrop/AirPlayDrop/Services/MediaArtifactValidator.swift AirPlayDrop/AirPlayDrop/Views/PlaylistView.swift AirPlayDrop/Tests/AirPlayDropTests.swift`
> Plan 012 intentionally changes subtitle selection. Confirm it is DONE and base this work on its live types.

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: HIGH
- **Depends on**: `plans/012-external-subtitles.md`
- **Category**: direction, ux
- **Planned at**: commit `2eda4ef`, 2026-09-21

## Why this matters

Some media and sidecar subtitles are consistently early or late. A small per-item correction is valuable, but FFmpeg timestamp options have input-order and negative-offset traps, so the behavior must be fixture-proven before UI is exposed.

## Current state

- `MediaItem.swift:16-19` holds per-item track selection but no timing adjustment.
- `TranscodeService.swift:93-103` builds one-input FFmpeg arguments directly.
- `MediaArtifactValidator.swift:93-96` expects output duration within two seconds or two percent of the source.
- There is no audio-delay or subtitle-delay symbol in the project at commit `2eda4ef`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| FFmpeg presence | `ffmpeg -version && ffprobe -version` | both exit 0, or STOP and report missing dependency for the timing spike |
| Build | `xcodebuild -project AirPlayDrop/AirPlayDrop.xcodeproj -scheme AirPlayDrop -configuration Debug -sdk macosx build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild -project AirPlayDrop/AirPlayDrop.xcodeproj -scheme AirPlayDrop -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **` |
| Hygiene | `git diff --check` | exit 0 |

## Scope

**In scope**:
- `AirPlayDrop/AirPlayDrop/Models/MediaItem.swift`
- `AirPlayDrop/AirPlayDrop/Models/MediaTrack.swift`
- `AirPlayDrop/AirPlayDrop/Models/PlaylistStore.swift`
- `AirPlayDrop/AirPlayDrop/Services/TranscodeService.swift`
- `AirPlayDrop/AirPlayDrop/Services/MediaArtifactValidator.swift`
- `AirPlayDrop/AirPlayDrop/Views/PlaylistView.swift`
- `AirPlayDrop/Tests/AirPlayDropTests.swift`

**Out of scope**: automatic lip-sync detection, device/route calibration, live drift correction, playback-rate changes, and persisting the playlist.

## Git workflow

- Branch: `codex/013-sync-adjustment`
- Commit the fixture-backed timing engine separately from UI; use imperative messages such as `Add fixture-tested media sync offsets`.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Prove one timestamp strategy with generated fixtures

Before app code, generate a five-second video with a visible once-per-second frame counter, short audio beeps at known timestamps, and an SRT cue at a known timestamp. Test positive and negative audio and subtitle shifts. Define the public sign convention as: positive milliseconds play the chosen stream later; negative milliseconds play it earlier. Use `ffprobe -show_packets` (and subtitle packet timestamps) to assert actual shifts within 50 ms and that video starts at zero.

Prefer timestamp/filter arguments that affect only the selected stream. Do not use global `-ss`, `-copyts`, or an output offset that moves video. Record the proven command shape as comments beside the argument builder and as exact-array tests.

**Verify**: fixture script/commands exit 0 for `+750`, `-750`, and `0` ms for both selected audio and subtitle; observed timestamps match the sign convention.

### Step 2: Add a clamped typed adjustment

Add a Codable/Equatable/Sendable `SyncAdjustment` with audio and subtitle milliseconds, both clamped to `-10_000...10_000`, defaulting to zero. Store it on `MediaItem` as transient per-item state. Add `PlaylistStore` mutation methods that cancel/invalidate a prepared artifact exactly as track changes do.

**Verify**: tests cover clamping, zero defaults, equality, and artifact invalidation.

### Step 3: Generate fixture-proven FFmpeg arguments

Extend `TranscodeService.ffmpegArguments` to apply the proven strategy to only the selected audio and subtitle, including external subtitles from Plan 012. Zero offsets must produce the prior argument array exactly. Ensure negative offsets do not silently drop leading content; if trimming is unavoidable, document and validate the maximum expected duration delta. Pass adjustment through planner/preparation interfaces.

**Verify**: exact-array unit tests plus the Step 1 end-to-end fixture pass for embedded and external subtitles.

### Step 4: Make cache validation adjustment-aware

Bump the artifact manifest schema and include both offsets. Cached output is valid only for an identical adjustment. Adapt duration validation only to the measured fixture behavior; do not broadly weaken validation.

**Verify**: cache tests accept identical offsets and reject each changed offset; existing corrupt/truncated artifact tests still fail as before.

### Step 5: Expose clear per-item controls

Add an `Adjust Synchronization…` sheet or popover from the playlist item's context menu. Provide labeled audio and subtitle fields/steppers in milliseconds, the sign explanation, bounded input, a Reset button, and a message that preparation must run again. Disable subtitle adjustment when no subtitle is selected.

**Verify**: Build and Tests pass; manually confirm `+750 ms` delays a generated beep/cue, `-750 ms` advances it, and Reset restores the original preparation plan.

## Test plan

- Pure tests: bounds, sign convention, no-op compatibility, exact FFmpeg argument ordering, manifest equality.
- Integration tests: generated packet timestamps for positive/negative audio and embedded/external subtitle shifts.
- Regression tests: video timestamp stays zero, selected audio remains present, cancellation remains race-safe.
- Final verification: Build, Tests, `git diff --check`.

## Done criteria

- [ ] Positive means later and negative means earlier everywhere in code and UI.
- [ ] Generated fixtures prove audio and subtitle timing within 50 ms.
- [ ] Video timing is unchanged and zero offsets preserve prior command shape.
- [ ] Cache identity includes both offsets.
- [ ] No automatic sync analysis or route calibration was added.
- [ ] Build and all tests pass.

## STOP conditions

- Stop if no FFmpeg command can shift negative audio/subtitles without moving video or losing unacceptable content; report fixture evidence.
- Stop if Plan 012 is not complete or its external-subtitle model is still changing.
- Stop if satisfying duration validation would require disabling it globally.

## Maintenance notes

Timing behavior is an external-tool contract. Keep the generated fixture test whenever FFmpeg minimum versions or argument ordering changes.
