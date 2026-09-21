# Plan 004: Make transcode jobs and cancellation race-safe

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: Plans 001 and 002
- **Category**: bug, tech-debt
- **Planned at**: commit `0e100d4`, 2026-09-21

## Why this matters

Retry and force-transcode can be invoked during an active job, cancellation does not establish that the subprocess has exited before another job begins, and the progress handler mutates captured variables concurrently. These are data-race and file-corruption risks and block Swift 6 readiness.

## Scope

In scope: `TranscodeService`, `PlaylistStore`, `MediaItemState`, playlist controls, and concurrency tests. Out of scope: codec choices and visual redesign.

## Steps

1. Create one explicit `TranscodeJob` owner per media item with an ID, lifecycle state, cancellation API, process reference, temporary artifact, and completion result.
2. Serialize mutable progress/parser state using actor isolation or another compiler-checked mechanism. Remove `@unchecked Sendable` where feasible; do not add new unchecked conformances.
3. Cancellation must request termination, await process exit, drain/close pipes, clean only the job's temporary file, and publish a cancelled state before replacement work starts.
4. Disable Retry, Force Transcode, Remove, and conflicting actions for active jobs, while providing a visible Cancel Transcode action.
5. Bound retained stderr diagnostics rather than accumulating an unlimited string.
6. Add tests using a controllable fake process runner for cancellation-before-launch, cancellation-during-run, replacement job, double completion, and queue removal.
7. Eliminate Swift concurrency and implicit-capture warnings rather than suppressing them.

## Verification

- Debug build contains no project-source warnings.
- Tests prove no two jobs for the same item can write concurrently and cancellation completion is awaited.
- Plan 001 test command passes.

## STOP conditions

Stop if a proposed solution relies on sleeps, global locks, or ignoring Sendable warnings.

