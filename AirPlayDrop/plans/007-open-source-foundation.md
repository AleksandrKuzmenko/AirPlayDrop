# Plan 007: Prepare a clean and legally open source repository

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: Plan 001
- **Category**: docs, dx
- **Planned at**: commit `0e100d4`, 2026-09-21

## Why this matters

Without a license the project is not legally open source. The repository also lacks onboarding, contribution, support, and security documentation and currently tracks macOS/Xcode machine state.

## Scope

In scope: repository documentation, templates, `.gitignore`, Xcode metadata cleanup, copyright metadata, and project naming. Out of scope: publishing the GitHub repository or creating public issues.

## Steps

1. Add an MIT license attributed to the repository owner and update the app copyright field.
2. Add a concise README covering purpose, alpha maturity, screenshots placeholder, macOS requirement, Xcode build/test commands, Homebrew FFmpeg/FFprobe requirement, supported formats, data-safety behavior, known limitations, privacy, troubleshooting, and contribution links.
3. Add `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, `CHANGELOG.md`, and issue/PR templates appropriate for a small maintainer-led utility.
4. Add a standard macOS/Xcode `.gitignore`; remove tracked `.DS_Store`, `xcuserdata`, and other machine state from the implementation branch.
5. Add `AGENTS.md` with exact build/test rules, preservation of media fixtures, and prohibition against touching real user media in tests.
6. Ensure docs consistently use the product name AirPlayDrop and mark the initial release `0.1.0-alpha` rather than `1.0`.

## Verification

- `git ls-files` contains no `.DS_Store` or `xcuserdata` entries.
- README setup commands work from a fresh checkout.
- License, contribution, security, and changelog files exist and link to each other correctly.
- Build/tests pass.

## STOP conditions

Stop if the repository owner's legal name/copyright attribution cannot be determined from existing Git metadata; use the GitHub owner name and flag it for human review rather than inventing an identity.

