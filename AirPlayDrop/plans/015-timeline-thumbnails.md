# Plan 015: Preview frames while scrubbing the timeline

> **Executor instructions**: Follow the plan and verification gates in order. Thumbnail generation must remain optional and failure-tolerant. Stop on any STOP condition and update the index when complete unless a reviewer owns it.
>
> **Drift check (run first)**: `git diff --stat 2eda4ef..HEAD -- AirPlayDrop/AirPlayDrop/Services/PlaybackController.swift AirPlayDrop/AirPlayDrop/Views/TransportBarView.swift AirPlayDrop/Tests/AirPlayDropTests.swift AirPlayDrop/AirPlayDrop.xcodeproj/project.pbxproj`
> Plan 011 modifies the same transport lifecycle. Confirm it is DONE and compare the current slider/controller code with the excerpts below.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/011-resume-playback.md`
- **Category**: direction, ux, perf
- **Planned at**: commit `2eda4ef`, 2026-09-21

## Why this matters

A frame preview makes seeking in long films substantially faster. The feature must avoid the repeated `AVAssetImageGenerator` failures seen on some Dolby Vision sources, stay responsive during rapid scrubbing, and degrade to the existing timestamp-only UI.

## Current state

- `TransportBarView.swift:6-28` tracks scrub state and renders a plain `Slider`.
- `PlaybackController.swift:13-16` exposes the loaded item, current time, and duration.
- `MediaItem.swift:35-36` prefers the prepared compatible copy through `playbackURL`.
- There is no thumbnail cache or cancellation abstraction.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project AirPlayDrop/AirPlayDrop.xcodeproj -scheme AirPlayDrop -configuration Debug -sdk macosx build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild -project AirPlayDrop/AirPlayDrop.xcodeproj -scheme AirPlayDrop -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **` |
| Hygiene | `git diff --check` | exit 0 |

## Scope

**In scope**:
- `AirPlayDrop/AirPlayDrop/Services/ThumbnailProvider.swift` (create)
- `AirPlayDrop/AirPlayDrop/Services/PlaybackController.swift`
- `AirPlayDrop/AirPlayDrop/Views/TransportBarView.swift`
- `AirPlayDrop/Tests/AirPlayDropTests.swift`
- `AirPlayDrop/AirPlayDrop.xcodeproj/project.pbxproj`

**Out of scope**: pre-generating a complete storyboard, disk caches, chapter editing, scene detection, thumbnail export, and decoding through FFmpeg.

## Git workflow

- Branch: `codex/015-timeline-thumbnails`
- Use imperative commits such as `Preview frames during timeline scrubbing`.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Add an injectable, bounded thumbnail provider

Create an actor-backed `ThumbnailProvider` with an injectable image-generation protocol. Production uses `AVAssetImageGenerator`, applies preferred track transform, requests at most a 480x270 source image for a roughly 240-point preview, and permits a small time tolerance. Quantize requests to two-second buckets and keep a 30-entry in-memory LRU keyed by standardized playback URL fingerprint plus bucket. Never write thumbnails to disk.

**Verify**: fake-generator tests cover quantization, cache hit, LRU eviction at 31 entries, URL-key separation, and non-finite/out-of-range rejection.

### Step 2: Cancel stale scrub work

Expose an async request from `PlaybackController` or a dedicated view model. Cancel the previous request whenever the scrub bucket changes or the loaded item changes. Associate every result with an item identity and request generation so a late frame cannot appear for a new movie. Prefer `MediaItem.playbackURL`, because a prepared MP4 is more likely to decode than the original DV file.

**Verify**: deterministic tests hold the first fake request, issue a second, complete them out of order, and prove only the current result is published.

### Step 3: Add the preview without replacing native slider behavior

While scrubbing, show a compact image and formatted timestamp above the slider. Preserve the native `Slider`, keyboard seeking, current accessibility value, and commit-on-release behavior. At narrow window widths, keep the preview inside the content bounds. When no frame is available, show timestamp only.

**Verify**: Build and Tests pass. Manually inspect at the app's minimum width and a wide window, using mouse, keyboard, and VoiceOver.

### Step 4: Make failures quiet and bounded

Treat unsupported/cancelled image-generation errors as an unavailable preview, not playback failure. Log at most once per item/error category and stop requesting frames for that item until its playback URL changes. Do not retry on every 0.25-second player tick.

**Verify**: a fake generator that always fails is called once for the disabled item, playback/scrubbing still works, and no user alert appears. A successful URL change re-enables generation.

## Test plan

- Unit-test cache and request coordination with fakes; no copyrighted fixture is required.
- Add one optional generated H.264 fixture integration test for a non-empty CGImage near the midpoint.
- Regression-test stale cancellation, item switching, and failure suppression.
- Final verification: Build, Tests, `git diff --check`.

## Done criteria

- [ ] Scrubbing can show a correctly timed, bounded preview from the active playback URL.
- [ ] Cache holds at most 30 in-memory images and writes nothing to disk.
- [ ] Stale requests cannot update a new item or newer scrub position.
- [ ] Decode failure falls back to timestamp-only without alerts or log spam.
- [ ] Native slider keyboard and accessibility behavior remains intact.
- [ ] Build and all tests pass.

## STOP conditions

- Stop if implementation requires replacing the native Slider with an inaccessible custom control.
- Stop if `AVAssetImageGenerator` cannot decode both the generated fixture and a prepared compatible MP4; report errors before considering another decoder.
- Stop if Plan 011 is incomplete and creates unresolved conflicts in transport state.

## Maintenance notes

Thumbnail caching is intentionally memory-only and small. If prepared artifacts are invalidated, clear matching thumbnails immediately; never use source-file thumbnails as evidence that playback is compatible.
