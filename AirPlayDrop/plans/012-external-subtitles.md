# Plan 012: Attach and prepare external text subtitles

> **Executor instructions**: Follow this plan in order, run every verification, and stop rather than inventing behavior when a STOP condition is met. Update the plan index when complete unless a reviewer owns it.
>
> **Drift check (run first)**: `git diff --stat 2eda4ef..HEAD -- AirPlayDrop/AirPlayDrop/Models/MediaTrack.swift AirPlayDrop/AirPlayDrop/Models/MediaItem.swift AirPlayDrop/AirPlayDrop/Models/PlaylistStore.swift AirPlayDrop/AirPlayDrop/Services/FileImportService.swift AirPlayDrop/AirPlayDrop/Services/TranscodeService.swift AirPlayDrop/AirPlayDrop/Services/MediaArtifactValidator.swift AirPlayDrop/AirPlayDrop/Views/PlaylistView.swift AirPlayDrop/AirPlayDrop/MainWindowView.swift AirPlayDrop/Tests/AirPlayDropTests.swift AirPlayDrop/AirPlayDrop.xcodeproj/project.pbxproj`
> Stop if selection or manifest structures have drifted beyond straightforward reconciliation.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: `plans/010-preferred-track-languages.md`
- **Category**: direction, ux
- **Planned at**: commit `2eda4ef`, 2026-09-21

## Why this matters

Many releases ship subtitles as sidecar files, but AirPlayDrop only exposes embedded tracks. Supporting local text subtitles covers the common case while deliberately avoiding OCR, subtitle downloading, and privacy-sensitive network services.

## Current state

- `FileImportService.swift:15-20` allows only video types in the open panel.
- `MediaTrack.swift:49-53` represents subtitles only as an integer stream ID.
- `PlaylistView.swift:84-102` lists only probed embedded subtitle tracks.
- `TranscodeService.swift:81-102` assumes every selected stream is input `0` and converts selected subtitles to `mov_text`.
- `MediaArtifactValidator.swift:12-22` manifests audio selection but not subtitle identity or sidecar fingerprint.

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
- `AirPlayDrop/AirPlayDrop/Services/ExternalSubtitleService.swift` (create)
- `AirPlayDrop/AirPlayDrop/Services/FileImportService.swift`
- `AirPlayDrop/AirPlayDrop/Services/TranscodeService.swift`
- `AirPlayDrop/AirPlayDrop/Services/MediaArtifactValidator.swift`
- `AirPlayDrop/AirPlayDrop/Views/PlaylistView.swift`
- `AirPlayDrop/AirPlayDrop/MainWindowView.swift`
- `AirPlayDrop/Tests/AirPlayDropTests.swift`
- `AirPlayDrop/AirPlayDrop.xcodeproj/project.pbxproj`

**Out of scope**: OCR/image subtitles, online search/download, subtitle editing, styling preservation beyond FFmpeg `mov_text`, directory watching, and automatic translation.

## Git workflow

- Branch: `codex/012-external-subtitles`
- Use imperative commits such as `Support external text subtitles`.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Model subtitle origin explicitly

Replace the overloaded `subtitleID` concept with a Codable, Equatable `SubtitleSelection` enum: none, embedded stream ID, or external local-file descriptor. The external descriptor contains standardized URL, detected language code, display name, file size, and modification date. Keep audio selection unchanged. Update equality and invalidation call sites atomically.

**Verify**: compile and run tests for round-trip encoding and all three selection variants.

### Step 2: Discover safe local text sidecars

Create `ExternalSubtitleService` supporting case-insensitive `.srt`, `.vtt`, `.ass`, and `.ssa`. For a video named `Movie.mkv`, discover `Movie.srt` and suffix variants such as `Movie.en.srt` in the same directory only. Parse the final suffix as a language code when valid, sort exact basename first then preferred language order from Plan 010, and deduplicate standardized URLs. Do not recurse or access the network.

**Verify**: use a temporary directory to test exact-name, language suffix, case, unsupported extensions, unrelated basename, and deterministic ordering.

### Step 3: Add explicit attachment and selection UI

Add `Attach Subtitle…` to each playlist item's subtitle menu. Use a dedicated open panel limited to supported subtitle types and attach only to that item. Show discovered and attached sidecars alongside embedded text tracks, with `None` always available. If a preferred-language sidecar is discovered, select it only during initial metadata load; never override a later explicit choice.

**Verify**: Build and Tests pass; manual smoke test attaches an SRT outside the video directory and shows its filename in the selected menu.

### Step 4: Map external subtitles through FFmpeg correctly

In `TranscodeService.ffmpegArguments`, add the sidecar as a second `-i` before mapping and map `1:0`; embedded streams continue to map from `0:<id>`. Convert supported sidecars to `mov_text`. Construct arguments from typed inputs so option ordering is testable and paths remain one argument even when they contain spaces. Reject a missing or changed sidecar before starting FFmpeg with a user-readable error.

**Verify**: argument tests prove input ordering and mapping for embedded, external, and no subtitle. Run an end-to-end test with a generated video plus tiny SRT when FFmpeg is installed; otherwise the test should use the repo's existing explicit skip behavior.

### Step 5: Make prepared-artifact reuse subtitle-aware

Bump the manifest schema and record the full subtitle selection fingerprint. Cached artifacts are reusable only when audio and subtitle selections, source fingerprints, and required codec constraints match. Changing or removing a sidecar must invalidate the artifact without deleting the user's subtitle file.

**Verify**: tests prove a modified sidecar rejects the cache, an unchanged sidecar reuses it, and selecting None rejects an artifact prepared with subtitles.

## Test plan

- Add model, discovery, argument-construction, and manifest-cache tests to `AirPlayDrop/Tests/AirPlayDropTests.swift`.
- Include paths containing spaces and non-ASCII characters.
- End-to-end fixture checks output contains video, audio when present, and one subtitle stream.
- Final verification: Build, Tests, `git diff --check`.

## Done criteria

- [ ] Users can select None, an embedded text track, or one local sidecar.
- [ ] Same-directory sidecars are discovered deterministically using preferences.
- [ ] External paths map as FFmpeg input 1 and yield `mov_text` in prepared MP4.
- [ ] Cache reuse includes the sidecar fingerprint.
- [ ] No OCR, subtitle network service, or translation was added.
- [ ] Build and all tests pass.

## STOP conditions

- Stop if a supported format cannot be converted by the minimum documented FFmpeg dependency; report the exact command and version.
- Stop if sandbox/security-scoped access is introduced elsewhere before this plan; design bookmark persistence separately instead of storing a bare URL.
- Stop if bitmap subtitles would require OCR; keep them unavailable and explain why.

## Maintenance notes

Plan 013 must reuse the typed embedded/external subtitle selection. Any future sandboxed distribution will need security-scoped bookmark handling for explicitly attached files.
