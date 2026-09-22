# Plan 011: Resume unfinished playback safely

> **Executor instructions**: Follow every step and verification gate. Stop and report on any STOP condition. Update this plan's row in `AirPlayDrop/plans/README.md` when complete unless a reviewer owns the index.
>
> **Drift check (run first)**: `git diff --stat 2eda4ef..HEAD -- AirPlayDrop/AirPlayDrop/Services/PlaybackController.swift AirPlayDrop/AirPlayDrop/MainWindowView.swift AirPlayDrop/AirPlayDrop/Views/TransportBarView.swift AirPlayDrop/Tests/AirPlayDropTests.swift AirPlayDrop/AirPlayDrop.xcodeproj/project.pbxproj`
> If these files changed, reconcile the playback lifecycle below before editing; stop on semantic mismatch.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/009-complete-user-journey.md`
- **Category**: direction, ux
- **Planned at**: commit `2eda4ef`, 2026-09-21

## Why this matters

Long movies currently restart after the app or item is closed. A conservative resume store makes the utility feel dependable without turning the transient playlist into a media library.

## Current state

- `PlaybackController.swift:51-58` receives player time every 0.25 seconds.
- `PlaybackController.swift:71-75` changes the selected item after tearing down the old player.
- `PlaybackController.swift:122-127` resets time to zero without retaining it.
- `PlaybackController.swift:130-140` seeks to zero on natural completion.
- `TransportBarView.swift:14-28` owns the current scrub slider.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project AirPlayDrop/AirPlayDrop.xcodeproj -scheme AirPlayDrop -configuration Debug -sdk macosx build CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild -project AirPlayDrop/AirPlayDrop.xcodeproj -scheme AirPlayDrop -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO` | `** TEST SUCCEEDED **` |
| Hygiene | `git diff --check` | exit 0 |

## Scope

**In scope**:
- `AirPlayDrop/AirPlayDrop/Services/PlaybackHistoryStore.swift` (create)
- `AirPlayDrop/AirPlayDrop/Services/PlaybackController.swift`
- `AirPlayDrop/AirPlayDrop/MainWindowView.swift`
- `AirPlayDrop/AirPlayDrop/Views/TransportBarView.swift`
- `AirPlayDrop/Tests/AirPlayDropTests.swift`
- `AirPlayDrop/AirPlayDrop.xcodeproj/project.pbxproj`

**Out of scope**: persistent playlists, cloud sync, user accounts, cross-device history, watch-state catalogs, and changing playback speed.

## Git workflow

- Branch: `codex/011-resume-playback`
- Use imperative commits such as `Remember unfinished playback positions`.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Build a bounded playback-history store

Create an injectable store backed by a versioned Codable payload in `UserDefaults`. Key entries by a stable source identity made from standardized source path plus current file size and modification date; never use `MediaItem.id`. Store position, observed duration, and update date. Keep at most 100 entries, evict oldest, and discard malformed/non-finite values.

Resume eligibility must be a pure function: position at least 30 seconds, duration known, and at least 60 seconds remains. Natural completion and Start Over remove the entry.

**Verify**: unit tests cover identity changes when a file is replaced, thresholds, eviction, corrupt data, and deletion; run Tests.

### Step 2: Save at lifecycle boundaries without writing four times per second

Inject the history store into `PlaybackController`. Persist at most once every five seconds while playing, and always save the final eligible value before item replacement, stop, AirPlay conversion teardown, or app termination. Never perform synchronous disk work in the 0.25-second observer. Clear history from the natural-end callback.

**Verify**: use an injected spy store to prove throttling plus final writes on `prepare(item:)`, `stop()`, and the AirPlay compatibility path; run Tests.

### Step 3: Offer Resume or Start Over after the player is ready

Expose a pending resume proposal from `PlaybackController` only after duration is known. In `MainWindowView`, show a non-blocking banner or compact confirmation with `Resume from H:MM:SS` and `Start Over`. Resume performs one precise seek and then preserves the prior play/pause intent; Start Over clears history and seeks to zero. Do not auto-play a paused item.

**Verify**: tests prove one prompt per load, no prompt below thresholds, no prompt after completion, and no duplicate prompt when the prepared AirPlay URL replaces the source URL.

### Step 4: Add a visible reset for the current item

Add `Start Over` near transport controls when the loaded item has resumable progress. It must seek to zero and clear the saved entry. Supply keyboard and accessibility labels without changing Slider behavior.

**Verify**: Build and Tests pass; manually play a generated two-minute fixture beyond 30 seconds, quit/relaunch, re-import, resume, then finish playback and confirm no subsequent prompt.

## Test plan

- Unit-test the pure identity and eligibility logic using temporary files and isolated defaults.
- Test controller integration with injected history and time abstractions; do not make tests sleep five seconds.
- Keep all tests in `AirPlayDrop/Tests/AirPlayDropTests.swift` unless the target is deliberately split in a separate change.
- Final verification: Build, Tests, `git diff --check`.

## Done criteria

- [ ] Eligible unfinished playback survives relaunch and is keyed to the source file fingerprint.
- [ ] Natural completion and Start Over clear history.
- [ ] Periodic persistence is throttled and bounded to 100 entries.
- [ ] Prepared-copy changes do not create duplicate history.
- [ ] No playlist persistence or cloud sync is introduced.
- [ ] Build and all tests pass.

## STOP conditions

- Stop if the implementation would key history by transient UUID or prepared-output path.
- Stop if app termination cannot be observed with public SwiftUI/AppKit lifecycle APIs; report the missing hook and retain the periodic/final-item-switch saves.
- Stop if resume causes autoplay when prior intent was paused.

## Maintenance notes

The original source identity is authoritative even when playback uses an `_airplay.mp4` artifact. Plan 015 will also modify transport UI; implement this plan first to reduce overlap.
