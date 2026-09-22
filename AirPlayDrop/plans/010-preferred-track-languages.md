# Plan 010: Remember preferred audio and subtitle languages

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving on. If a STOP condition occurs, stop and report instead of improvising. When finished, update this plan's row in `AirPlayDrop/plans/README.md` unless a reviewer owns the index.
>
> **Drift check (run first)**: `git diff --stat 2eda4ef..HEAD -- AirPlayDrop/AirPlayDrop/Models/MediaTrack.swift AirPlayDrop/AirPlayDrop/Models/PlaylistStore.swift AirPlayDrop/AirPlayDrop/Services/FFprobeService.swift AirPlayDrop/AirPlayDrop/MainWindowView.swift AirPlayDrop/Tests/AirPlayDropTests.swift AirPlayDrop/AirPlayDrop.xcodeproj/project.pbxproj`
> If an in-scope file changed, compare the excerpts below with live code. Stop if the selection lifecycle no longer matches this plan.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: `plans/005-track-selection.md`
- **Category**: direction, ux
- **Planned at**: commit `2eda4ef`, 2026-09-21

## Why this matters

Track selection exists, but every newly imported file starts from the current macOS locale and subtitles are always off. Persistent, explicit preferences remove repetitive setup while preserving the user's per-item override.

## Current state

- `AirPlayDrop/AirPlayDrop/Services/FFprobeService.swift:82-105` resolves one audio language and creates `TrackSelection(... subtitleID: nil, subtitlePolicy: .omit)`.
- `AirPlayDrop/AirPlayDrop/Models/PlaylistStore.swift:141-147` probes each file and unconditionally applies `FFprobeService.defaultSelection(from:)`.
- `AirPlayDrop/AirPlayDrop/MainWindowView.swift:222-256` has a Settings UI for the FFmpeg directory and diagnostics; follow its `UserDefaults` persistence pattern.
- `AirPlayDrop/AirPlayDrop/Models/MediaTrack.swift:42-53` defines the current subtitle policy and track selection.

```swift
static func defaultSelection(from info: MediaInfo,
    preferredLanguage: String? = Locale.current.language.languageCode?.identifier) -> TrackSelection
```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project AirPlayDrop/AirPlayDrop.xcodeproj -scheme AirPlayDrop -configuration Debug -sdk macosx build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild -project AirPlayDrop/AirPlayDrop.xcodeproj -scheme AirPlayDrop -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **` |
| Patch hygiene | `git diff --check` | exit 0, no output |

## Scope

**In scope**:
- `AirPlayDrop/AirPlayDrop/Models/PlaybackPreferences.swift` (create)
- `AirPlayDrop/AirPlayDrop/Models/MediaTrack.swift`
- `AirPlayDrop/AirPlayDrop/Models/PlaylistStore.swift`
- `AirPlayDrop/AirPlayDrop/Services/FFprobeService.swift`
- `AirPlayDrop/AirPlayDrop/MainWindowView.swift`
- `AirPlayDrop/Tests/AirPlayDropTests.swift`
- `AirPlayDrop/AirPlayDrop.xcodeproj/project.pbxproj`

**Out of scope**: playlist persistence, online metadata, per-title rules, external subtitle discovery, and changing an explicit selection after import.

## Git workflow

- Branch: `codex/010-preferred-languages`
- Commit logical units using the existing imperative style, for example `Remember preferred media languages`.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Add a typed, injectable preference store

Create `PlaybackPreferences.swift` with Codable/Equatable values for an ordered list of preferred audio language codes, an ordered list of preferred subtitle codes, and a subtitle default mode: `off`, `forcedPreferred`, or `preferred`. Persist a single versioned value in injected `UserDefaults`; production uses `.standard`, tests use a named suite. Normalize codes case-insensitively and remove blank/duplicate entries while preserving order. Use macOS locale as the default audio fallback and keep subtitles off by default.

**Verify**: run the Tests command after adding round-trip, defaults, normalization, and corrupt-data fallback tests; expect all tests to pass.

### Step 2: Make default selection deterministic

Change `FFprobeService.defaultSelection` to accept the typed preferences. Match exact normalized track-language codes first, then the primary language subtag (`en` should match `en-US`), while retaining this fallback order: preferred+default, preferred, stream default, first audio. For subtitles, only text subtitles are eligible; `off` selects none, `preferred` selects the first matching/default text track, and `forcedPreferred` requires a forced-disposition signal. Extend `FFprobeStream`/`MediaTrack` with `isForced` instead of inferring it from titles.

**Verify**: tests cover missing language tags, regional tags, multiple preference order, forced-only behavior, bitmap subtitle rejection, and stable first-track fallback; run the Tests command and expect success.

### Step 3: Apply preferences only when metadata first loads

Inject the preference store into `PlaylistStore`. In `launchMetadataJob`, apply defaults after probing a new item. Never overwrite a user's explicit `chooseAudio`/`chooseSubtitle` selection during retry or preparation. If preferences change, they affect future imports only.

**Verify**: add a regression test that changes preferences after an explicit selection and proves the existing item is unchanged; run the Tests command.

### Step 4: Add a compact Playback section in Settings

Add ordered audio/subtitle language inputs and the subtitle default-mode picker to the existing Settings view. Store stable language codes, show human-readable localized names when available, and include a clear reset-to-system-default action. Accessibility labels must state that preferences apply to newly imported videos.

**Verify**: run Build and Tests; manually launch the app, change preferences, reopen Settings, and confirm values persist and a newly imported multi-track fixture chooses the expected streams.

## Test plan

- Unit-test preference serialization, sanitization, and language matching in `AirPlayDrop/Tests/AirPlayDropTests.swift`.
- Extend the existing FFprobe/default-selection tests rather than creating a second test target.
- Include an injected `UserDefaults(suiteName:)` and remove its persistent domain in teardown.
- Final verification: Build, Tests, and `git diff --check` all succeed.

## Done criteria

- [ ] Preferences persist across relaunch and have safe defaults.
- [ ] Audio and text-subtitle defaults follow documented deterministic ordering.
- [ ] Existing explicit item selections are never rewritten.
- [ ] No playlist or remote-control persistence was added.
- [ ] Build and all tests pass.
- [ ] Only in-scope files and the plan index are modified.

## STOP conditions

- Stop if FFprobe does not expose forced disposition in the supported fixture; report the fixture and do not use title-string heuristics.
- Stop if preference changes require migrating any user media files.
- Stop if implementing this requires persisting the playlist.

## Maintenance notes

Keep stored language codes independent of localized display names. External subtitle discovery in Plan 012 should consume this same preference resolver rather than duplicate language matching.
