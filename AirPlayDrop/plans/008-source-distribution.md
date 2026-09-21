# Plan 008: Define a safe source-first distribution model

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: Plan 007
- **Category**: security, docs, dx
- **Planned at**: commit `0e100d4`, 2026-09-21

## Why this matters

The app currently searches hard-coded FFmpeg paths, disables App Sandbox, and has no signing/notarization workflow. The initial release should be honest and reproducible without pretending an unsigned binary is production-ready or accidentally redistributing a GPL-enabled FFmpeg build.

## Scope

In scope: runtime dependency discovery/configuration, diagnostics UI, distribution documentation, versioning, and source-release CI. Out of scope: signing credentials, notarization submission, Mac App Store release, bundled FFmpeg, auto-update, and publishing a release.

## Steps

1. Make FFmpeg/FFprobe discovery explicit: supported standard locations plus a user-selectable executable location persisted safely. Validate executable identity/version and show it in diagnostics.
2. Add a startup/preflight dependency status instead of failing only after conversion begins.
3. Document why the alpha is source-first, that FFmpeg is separately installed and executed, and that the app does not bundle or link FFmpeg.
4. Add `docs/DISTRIBUTION.md` describing future Developer ID signing, hardened runtime, notarization, universal architecture, sandbox/helper investigation, and FFmpeg license-compliance gates.
5. Add CI that can create a source archive/checksum only. Do not upload unsigned `.app`, `.dmg`, or bundled multimedia binaries.
6. Align `MARKETING_VERSION`/build number with `0.1.0-alpha` semantics supported by Xcode and document the versioning policy.

## Verification

- The app reports a clear usable/missing/incompatible FFmpeg and FFprobe status.
- Tests cover discovery without depending on the host's actual Homebrew paths.
- Release workflow cannot publish an unsigned application binary.
- Build/tests pass.

## STOP conditions

Stop before adding any Apple signing secret, notarization credential, FFmpeg binary, or public release. Those require explicit maintainer action and legal review.

