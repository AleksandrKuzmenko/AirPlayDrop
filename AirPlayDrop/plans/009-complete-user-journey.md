# Plan 009: Complete the AirPlay conversion and playback user journey

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: Plans 003, 004, and 006
- **Category**: direction, ux
- **Planned at**: commit `0e100d4`, 2026-09-21

## Why this matters

Selecting AirPlay can tear down playback and start conversion, but completion does not restore playback intent. Users also lack a clear cancel action, phase information, disk-space status, and a post-conversion next step.

## Scope

In scope: playback/store coordination, observable job state, alerts/sheets, playlist controls, accessibility labels, and UI tests where stable. Out of scope: controlling Apple TV hardware automatically beyond AVFoundation-supported route behavior.

## Steps

1. Model user playback intent separately from current `AVPlayer` state: selected item, requested route mode, requested play/pause, and pending preparation.
2. When AirPlay requires preparation, pause safely, retain intent, show the conversion plan, and begin only after confirmation.
3. Show phases (`probing`, `preparing`, `encoding/remuxing`, `finalizing`, `validating`), percent where meaningful, destination, selected audio/subtitles, and a working Cancel button.
4. On successful validation, restore the selected item and prompt the user to reselect the AirPlay route if macOS dropped it; automatically resume only when the route is still active and prior intent was play.
5. On cancellation/failure, preserve the source item and any previous valid artifact, present recovery actions, and never leave the row falsely marked ready.
6. Add accessibility labels, keyboard behavior, and state-machine tests for success, cancellation, route loss, validation failure, and playlist removal during preparation.

## Verification

- State tests cover each transition and prove no automatic replay occurs after explicit user cancellation.
- Manual smoke test with a generated short HDR-like fixture follows one understandable path from import through prepared playback.
- Build/tests pass without project-source warnings.

## STOP conditions

Stop if the implementation attempts to programmatically select an AirPlay route through private API. Use only public AVKit/AVFoundation behavior and user guidance.
