# Contributing

Thanks for helping improve AirPlayDrop. The project is a native macOS application and currently accepts focused fixes, tests, documentation improvements, and changes that strengthen reliable local or AirPlay playback.

## Setup

1. Use an Apple-silicon Mac with macOS 14 or later.
2. Install Xcode 15.4 or later and select its command-line tools.
3. Clone the repository and run `./scripts/build-bundled-ffmpeg.sh` if you are working on probing, preparation, or distribution behavior. The script needs `meson`, `ninja`, and `pkg-config` to build dav1d (`brew install meson ninja pkgconf`).
4. Open `AirPlayDrop/AirPlayDrop.xcodeproj`, select the AirPlayDrop scheme, and run it on My Mac.

## Making changes

- Keep each change focused and explain the user-visible reason.
- Preserve structured `Process.arguments`; never construct shell command strings from media paths.
- Validate generated media before marking it ready.
- Add unit tests for pure logic and state transitions.
- Add deterministic generated-fixture integration coverage for FFmpeg-facing changes when practical.
- Never commit copyrighted or personal media, credentials, signing material, DerivedData, or user-specific Xcode files.
- Keep macOS 14 and Xcode 15.4 compatibility unless a version change is explicitly discussed and documented.
- Do not enable FFmpeg GPL or nonfree components in a redistributable build.

## Verification

From the repository root, run:

```sh
./scripts/verify.sh
```

The script builds the app without signing, runs the full test suite, and checks the diff for whitespace errors. FFmpeg integration tests are kept separate so the ordinary unit suite remains deterministic.

## Pull requests

Describe the problem, the chosen behavior, verification performed, and any user-facing limitations. Include screenshots for visible UI changes. Link an issue when one exists and update README or CHANGELOG when behavior changes.

By contributing, you agree that your contribution is licensed under the repository's MIT License and that participation follows the Code of Conduct.
