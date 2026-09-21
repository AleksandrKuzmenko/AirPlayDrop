# Plan 001: Establish a repeatable test and CI baseline

> Follow every step and verification gate. Stop rather than weakening assertions or excluding production files to make tests pass. The reviewer maintains `plans/README.md`.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests, dx
- **Planned at**: commit `0e100d4`, 2026-09-21

## Why this matters

Codec and state regressions have already produced both audio-only and video-only outputs. The project has one application target and no automated tests or CI. Establish a one-command verification baseline before changing transcoding behavior.

## Current state

- `AirPlayDrop/AirPlayDrop.xcodeproj/project.pbxproj` defines only the `AirPlayDrop` application target.
- Pure logic exists in `MediaItemState`, `TranscodeService.outputURL`, progress parsing, and format compatibility decisions but is not testable outside the app target.
- `xcodebuild ... build CODE_SIGNING_ALLOWED=NO` succeeds with Swift concurrency warnings.

## Scope

In scope: Xcode project, a new `AirPlayDropTests` target, test fixtures/helpers, `.github/workflows/ci.yml`, and minimal access-level changes required for testing. Out of scope: production behavior changes and binary releases.

## Steps

1. Add a macOS unit-test target using XCTest. Keep production files in the app target and use `@testable import AirPlayDrop`.
2. Add deterministic tests for output naming, state equality, duration/progress parsing, compatibility classification, and playlist/transcode state transitions that do not launch real FFmpeg.
3. Add tiny generated media fixtures or a fixture-generation script; do not commit copyrighted media or large binaries.
4. Add GitHub Actions CI on a supported macOS runner that runs Debug build, unit tests, and `git diff --check`.
5. Resolve all compiler warnings in files touched by test enablement; do not suppress Swift concurrency diagnostics.

## Verification

- `xcodebuild -project AirPlayDrop.xcodeproj -scheme AirPlayDrop -configuration Debug -sdk macosx build CODE_SIGNING_ALLOWED=NO` exits 0.
- `xcodebuild -project AirPlayDrop.xcodeproj -scheme AirPlayDrop -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO` exits 0 with nonzero executed tests.
- `git diff --check` exits 0.

## Done criteria

- Tests cover success and failure behavior, not only object construction.
- CI uses the same commands documented for contributors.
- No test relies on the user's Movies folder, Apple TV, network, or Homebrew installation.

## STOP conditions

Stop if Xcode cannot share a scheme containing the test action, or if testing requires copying production sources into the test target instead of importing the app module.
