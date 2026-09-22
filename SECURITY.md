# Security policy

## Supported versions

AirPlayDrop is currently an alpha. Security fixes are applied to the latest commit on `main` and to the most recent tagged prerelease when a backport is practical.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private vulnerability reporting form:

https://github.com/AleksandrKuzmenko/AirPlayDrop/security/advisories/new

Include the affected version or commit, macOS version, reproduction steps, impact, and any suggested mitigation. Avoid attaching personal media; use a minimal generated fixture whenever possible.

The maintainer will aim to acknowledge a complete report within seven days, keep the reporter informed of material progress, and coordinate disclosure after a fix is available. This is a best-effort commitment for a volunteer-maintained alpha, not a service-level agreement.

## Security model

AirPlayDrop processes user-selected local files and launches separately installed FFmpeg and FFprobe binaries using structured argument arrays. It does not execute shell command text, bundle multimedia binaries, upload media, include analytics, or operate a network service.

Only configure an FFmpeg directory you trust. A malicious executable named `ffmpeg` or `ffprobe` in a configured directory or inherited `PATH` runs with the current user's permissions.
