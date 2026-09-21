# Plan 002: Publish transcoded files atomically without overwriting user data

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: Plan 001
- **Category**: bug, security
- **Planned at**: commit `0e100d4`, 2026-09-21

## Why this matters

`TranscodeService.outputURL` derives `<stem>.mp4`, callers delete it with ignored errors, and FFmpeg receives `-y`. An unrelated user-owned MP4 can therefore be destroyed. Crashes and cancellation can also expose a partial file as the finished result.

## Current state

- `TranscodeService.swift:38-45` derives a predictable destination.
- `TranscodeService.swift:61-62,139-140` and `PlaylistStore.swift:123-140` delete it unconditionally.
- `runFFmpeg` writes directly to the destination with `-y`.

## Scope

In scope: `TranscodeService`, `PlaylistStore`, new output/artifact helper types, UI confirmation text, and tests. Out of scope: choosing audio tracks and changing codec presets.

## Steps

1. Introduce an output reservation type that chooses a non-conflicting visible destination such as `<stem>_airplay.mp4`, then a numbered variant if occupied. Never infer ownership from filename alone.
2. Write FFmpeg output to a unique temporary file in the destination directory so the final move is same-volume and atomic.
3. On success, validate first, then atomically move the temporary file into the reserved destination without overwrite. On failure/cancel, remove only the temporary file created by this job.
4. Remove `-y` for final user destinations. Never delete a pre-existing destination before the user confirms.
5. Make Retry reuse or replace only artifacts recorded as owned by the current `MediaItem`; otherwise reserve a new name.
6. Add tests for collisions, cancellation cleanup, retry, pre-existing files, and filenames with unusual Unicode/spaces.

## Verification

- Unit tests demonstrate that an existing same-stem MP4 remains byte-for-byte unchanged.
- A cancelled fake job leaves no partial visible destination.
- Build and full test commands from Plan 001 pass.

## STOP conditions

Stop if the design requires identifying app-owned files solely by basename or modification date. Use explicit job/artifact state instead.
